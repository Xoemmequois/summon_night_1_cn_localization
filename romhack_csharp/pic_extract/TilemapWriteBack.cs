using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

// In-place write-back for the {flags,clut,image,tilemap} atlas format (CM2000 0x2D-0x4D).
//
// The edited GIF is the assembled 320x240 (mapCols*16 x mapRows*16) screen. We re-pack it:
//   1. split into 16x16 cells, deduplicate identical cells into unique atlas tiles,
//   2. lay the unique tiles into the existing atlas grid (cols x rows),
//   3. rebuild the tilemap so every screen cell points at its tile.
// Atlas/CLUT/tilemap offsets and sizes are unchanged, so the subcontent byte length is
// identical -> no sector shift, no .DAT re-layout. The only constraint is that the edited
// image must not need more unique 16x16 tiles than the atlas capacity (cols*rows).
public static class TilemapWriteBack
{
    public const string FormatTag = "tilemap";
    private const int Ts = 16;

    public static void Apply(byte[] dat, ImageMeta meta, string editedGifPath, string label)
    {
        // Locate the subcontent inside the .DAT (sector_offset ushort at 0x10 + id*4).
        var idxBase = 0x10 + meta.SubContentId * 4;
        var sectorOff = dat[idxBase] | (dat[idxBase + 1] << 8);
        var subStart = sectorOff * 0x800;

        int Ru16(int o) => dat[subStart + o] | (dat[subStart + o + 1] << 8);
        int Ru32(int o) => BitConverter.ToInt32(dat, subStart + o) & 0xFFFFFF;

        var imageOff = Ru32(8);
        var tilemapOff = Ru32(12);
        var atlasW = Ru16(imageOff) * 2; // 8bpp
        var atlasH = Ru16(imageOff + 2);
        var atlasPix = subStart + imageOff + 4;
        var mapW = Ru16(tilemapOff);
        var mapH = Ru16(tilemapOff + 2);
        var mapData = subStart + tilemapOff + 4;

        var atlasCols = atlasW / Ts;
        var atlasRows = atlasH / Ts;
        var capacity = atlasCols * atlasRows;

        using var bmp = new Bitmap(editedGifPath);
        if (bmp.PixelFormat != PixelFormat.Format8bppIndexed)
            throw new InvalidOperationException(
                $"{label}: edited GIF is not 8bpp indexed (got {bmp.PixelFormat})");

        var expW = mapW * Ts;
        var expH = mapH * Ts;
        if (bmp.Width != expW || bmp.Height != expH)
            throw new InvalidOperationException(
                $"{label}: size mismatch - edited {bmp.Width}x{bmp.Height} vs expected {expW}x{expH}");

        var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        var bd = bmp.LockBits(rect, ImageLockMode.ReadOnly, bmp.PixelFormat);
        var stride = bd.Stride;
        var pix = new byte[stride * bmp.Height];
        Marshal.Copy(bd.Scan0, pix, 0, pix.Length);
        bmp.UnlockBits(bd);

        // Canonicalize same-color index remaps (keeps genuinely unchanged pixels byte-stable
        // despite editors re-mapping among duplicate CLUT colors).
        var (cluts, origScreen, ow, oh) = RenderOriginal(dat, meta);
        CanonicalizeSameColor(pix, stride, origScreen, ow, oh, cluts);

        // Deduplicate 16x16 cells -> unique atlas tiles, and build tilemap entries.
        var slots = new Dictionary<string, int>();
        var uniqueTiles = new List<byte[]>();
        var entries = new ushort[mapW * mapH];

        for (var r = 0; r < mapH; r++)
        {
            for (var c = 0; c < mapW; c++)
            {
                var tile = new byte[Ts * Ts];
                for (var y = 0; y < Ts; y++)
                    for (var x = 0; x < Ts; x++)
                        tile[y * Ts + x] = pix[(r * Ts + y) * stride + c * Ts + x];

                var key = Convert.ToBase64String(tile);
                if (!slots.TryGetValue(key, out var slot))
                {
                    slot = uniqueTiles.Count;
                    if (slot >= capacity)
                        throw new InvalidOperationException(
                            $"{label}: needs more than {capacity} unique 16x16 tiles " +
                            $"(atlas {atlasCols}x{atlasRows}). In-place write-back not possible - " +
                            "reduce distinct tiles or use atlas-expansion mode.");
                    slots[key] = slot;
                    uniqueTiles.Add(tile);
                }

                // Column-major slot placement (matches the original: fill down a column,
                // then move right) so atlas/tilemap byte layout stays close to the game's.
                var sc = slot / atlasRows;
                var sr = slot % atlasRows;
                var u = sc * Ts;
                var v = sr * Ts;
                // entry: bit15 visible; U=(e&0x1F)<<3, V=((e>>5)&0x1F)<<3
                entries[r * mapW + c] = (ushort)(0x8000 | ((u >> 3) & 0x1F) | (((v >> 3) & 0x1F) << 5));
            }
        }

        // Rewrite atlas pixels (clear, then place each unique tile at its slot).
        Array.Clear(dat, atlasPix, atlasW * atlasH);
        for (var slot = 0; slot < uniqueTiles.Count; slot++)
        {
            var sc = slot / atlasRows;
            var sr = slot % atlasRows;
            var tile = uniqueTiles[slot];
            for (var y = 0; y < Ts; y++)
                for (var x = 0; x < Ts; x++)
                    dat[atlasPix + (sr * Ts + y) * atlasW + (sc * Ts + x)] = tile[y * Ts + x];
        }

        // Rewrite tilemap.
        for (var i = 0; i < entries.Length; i++)
        {
            dat[mapData + i * 2] = (byte)(entries[i] & 0xFF);
            dat[mapData + i * 2 + 1] = (byte)(entries[i] >> 8);
        }

        Console.WriteLine(
            $"  Wrote {label}: {uniqueTiles.Count}/{capacity} atlas tiles, tilemap {mapW}x{mapH} " +
            $"-> {meta.DatFile} sub 0x{meta.SubContentId:X2} @0x{subStart:X} (in-place)");
    }

    // Renders the ORIGINAL assembled screen (indices) and CLUT for a tilemap subcontent,
    // used by the preview/diff pass.
    public static (Color[] cluts, byte[] screen, int width, int height) RenderOriginal(byte[] dat, ImageMeta meta)
    {
        var idxBase = 0x10 + meta.SubContentId * 4;
        var sectorOff = dat[idxBase] | (dat[idxBase + 1] << 8);
        var subStart = sectorOff * 0x800;

        int Ru16(int o) => dat[subStart + o] | (dat[subStart + o + 1] << 8);
        int Ru32(int o) => BitConverter.ToInt32(dat, subStart + o) & 0xFFFFFF;

        var clutOff = Ru32(4);
        var imageOff = Ru32(8);
        var tilemapOff = Ru32(12);

        var clutW = Ru16(clutOff);
        var cluts = new Color[256];
        for (var i = 0; i < 256; i++)
        {
            if (i < clutW)
            {
                var c = Ru16(clutOff + 4 + i * 2);
                var r = (c & 0x1F) << 3;
                var g = ((c >> 5) & 0x1F) << 3;
                var b = ((c >> 10) & 0x1F) << 3;
                var a = (i == 0 && r == 0 && g == 0 && b == 0) ? 0 : (c == 0 ? 0 : 255);
                cluts[i] = Color.FromArgb(a, r, g, b);
            }
            else
            {
                cluts[i] = Color.Black;
            }
        }

        var atlasW = Ru16(imageOff) * 2;
        var atlasH = Ru16(imageOff + 2);
        var atlasPix = subStart + imageOff + 4;
        var mapW = Ru16(tilemapOff);
        var mapH = Ru16(tilemapOff + 2);
        var mapData = subStart + tilemapOff + 4;

        var width = mapW * Ts;
        var height = mapH * Ts;
        var screen = new byte[width * height];

        for (var r = 0; r < mapH; r++)
        {
            for (var c = 0; c < mapW; c++)
            {
                var e = dat[mapData + (r * mapW + c) * 2] | (dat[mapData + (r * mapW + c) * 2 + 1] << 8);
                if (e == 0) continue;
                var u = (e & 0x1F) << 3;
                var v = ((e >> 5) & 0x1F) << 3;
                for (var y = 0; y < Ts; y++)
                {
                    var sy = v + y;
                    if (sy >= atlasH) break;
                    for (var x = 0; x < Ts; x++)
                    {
                        var sx = u + x;
                        if (sx >= atlasW) continue;
                        screen[(r * Ts + y) * width + c * Ts + x] = dat[atlasPix + sy * atlasW + sx];
                    }
                }
            }
        }

        return (cluts, screen, width, height);
    }

    // Restores the original index for pixels whose index changed but resolves to the same
    // CLUT color (the CLUT has duplicate colors; editors may re-map among them on save).
    // Shared by write-back and the preview/diff so the diff reflects the write-back result.
    public static void CanonicalizeSameColor(byte[] pix, int pixStride, byte[] origScreen,
        int width, int height, Color[] cluts)
    {
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                int t = pix[y * pixStride + x];
                int o = origScreen[y * width + x];
                if (t != o && cluts[t].ToArgb() == cluts[o].ToArgb())
                    pix[y * pixStride + x] = (byte)o;
            }
        }
    }
}
