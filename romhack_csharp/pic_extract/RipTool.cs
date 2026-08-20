using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using SummonNightLib;

public static class RipTool
{
    public static void Run(string? openRouterKey = null, string? openRouterProxy = null)
    {
        var data = File.ReadAllBytes("rom/CM3000.DAT");
        Console.WriteLine("=== Extracting character sprite parts ===");

        var outBase = "pic_output/chars";
        Directory.CreateDirectory(outBase);

        for (var i = 0; i < 0x44; ++i)
        {
            var dd = ExtractUtil.GetSubcontent(data, 0x89 + i);

            var off0 = GetSubContentOffset(dd, 0, out _);
            var off1 = GetSubContentOffset(dd, 1, out _);
            var off2 = GetSubContentOffset(dd, 2, out _);
            var off3 = GetSubContentOffset(dd, 3, out _);

            using var bmp0 = ParseTim(dd, off0, out var is4bpp0);
            using var bmp1 = ParseTim(dd, off1, out var is4bpp1);

            var (sub2Label, sub2Flags, sub2Anims, sub2FrameDatas, sub2Rects) = ParseAnimSpriteBlob(dd, off2, "sub2");
            var (sub3Label, sub3Flags, sub3Anims, sub3FrameDatas, sub3Rects) = ParseAnimSpriteBlob(dd, off3, "sub3");

            var texMap2 = BuildRectTexMap(sub2FrameDatas);
            for (var j = 0; j < sub2Rects.Count; j++)
            {
                var texIdx = texMap2.TryGetValue(j, out var t) ? t : 0;
                var bmp = texIdx == 0 ? bmp0 : bmp1;
                if (bmp == null) continue;
                var path = Path.Combine(outBase, $"char_{i}_sub2_part_{j}.gif");
                ExportPart(bmp, sub2Rects[j], path, texIdx == 0 ? is4bpp0 : is4bpp1);
                ImageMetaWriter.Write(path, "CM3000.DAT", 0x89 + i, texIdx,
                    sub2Rects[j].U, sub2Rects[j].V, sub2Rects[j].W, sub2Rects[j].H);
            }

            var texMap3 = BuildRectTexMap(sub3FrameDatas);
            for (var j = 0; j < sub3Rects.Count; j++)
            {
                var texIdx = texMap3.TryGetValue(j, out var t) ? t : 0;
                var bmp = texIdx == 0 ? bmp0 : bmp1;
                if (bmp == null) continue;
                var path = Path.Combine(outBase, $"char_{i}_sub3_part_{j}.gif");
                ExportPart(bmp, sub3Rects[j], path, texIdx == 0 ? is4bpp0 : is4bpp1);
                ImageMetaWriter.Write(path, "CM3000.DAT", 0x89 + i, texIdx,
                    sub3Rects[j].U, sub3Rects[j].V, sub3Rects[j].W, sub3Rects[j].H);
            }
        }

        if (!string.IsNullOrEmpty(openRouterKey))
        {
            CharNameClassifier.Run(openRouterKey, openRouterProxy);
            CharNameDedup.Run();
        }

        for (var i = 3; i < 63; ++i)
        {
            var subContent = ExtractUtil.GetSubcontent(data, i);
            Console.WriteLine($"\nmapname{i}: offset=0x{BitConverter.ToInt32(subContent, 4):X} {subContent.Length} bytes");
            Parse(subContent, 0, $"mapname{i}");
        }

        ExtractShopImages();
        ExtractMapImages(12);
        ExtractMapImages(13);
        ExtractMapscreenTitles();
        ExtractSaveloadUi();
        ExtractChapterNameImages();

        Console.WriteLine("\nDone.");
    }

    private static Color[] ParseCluts(byte[] subData, int offset, int clutW, int clutH)
    {
        var colors = new List<Color>();
        for (var i = 0; i < clutW * clutH; i++)
        {
            var c = BitConverter.ToUInt16(subData, offset + i * 2);
            var r = (c & 0x1F) << 3;
            var g = ((c >> 5) & 0x1F) << 3;
            var b = ((c >> 10) & 0x1F) << 3;
            var a = (i == 0 && r == 0 && g == 0 && b == 0) ? 0 : (c == 0 ? 0 : 255);
            colors.Add(Color.FromArgb(a, r, g, b));
        }
        return colors.ToArray();
    }

    private static Bitmap ParsePix(byte[] subData, int offset, int pixW, int pixH, Color[] cluts, bool bit4)
    {
        pixW *= 2;
        var width = bit4 ? pixW * 2 : pixW;
        var height = pixH;
        var bitmap = new Bitmap(width, height, PixelFormat.Format8bppIndexed);

        var palette = bitmap.Palette;
        for (var i = 0; i < 256; i++)
            palette.Entries[i] = i < cluts.Length ? cluts[i] : cluts[0];
        bitmap.Palette = palette;

        var rect = new Rectangle(0, 0, width, height);
        var bmpData = bitmap.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format8bppIndexed);
        var pixels = new byte[bmpData.Stride * height];
        for (var y = 0; y < pixH; y++)
        {
            for (var x = 0; x < pixW; x++)
            {
                var index = subData[offset + y * pixW + x];
                if (bit4)
                {
                    pixels[y * bmpData.Stride + x * 2] = (byte)(index & 0xF);
                    pixels[y * bmpData.Stride + x * 2 + 1] = (byte)((index >> 4) & 0xF);
                }
                else
                {
                    pixels[y * bmpData.Stride + x] = index;
                }
            }
        }
        Marshal.Copy(pixels, 0, bmpData.Scan0, pixels.Length);
        bitmap.UnlockBits(bmpData);

        return bitmap;
    }

    private static void Parse(byte[] subData, int offset, string filename)
    {
        var bitmap = ParseTim(subData, offset, out var is4bpp, false);
        var outDir = Path.Combine("pic_output", "mapnames");
        Directory.CreateDirectory(outDir);
        var gifPath = Path.Combine(outDir, filename + ".gif");
        bitmap!.Save(gifPath, ImageFormat.Gif);
        SaveAct(bitmap, gifPath, is4bpp);
        var index = int.Parse(filename.AsSpan(7));
        ImageMetaWriter.Write(gifPath, "CM3000.DAT", index, -1);
    }

    private static Bitmap? ParseTim(byte[] subData, int offset, out bool is4bpp, bool skipWhenOffsetZero = true)
    {
        is4bpp = false;
        if (offset == 0 && skipWhenOffsetZero)
            return null;
        if (offset < 0 || offset + 16 > subData.Length)
            return null;

        var clut = BitConverter.ToInt32(subData, offset + 4);
        var clutW = BitConverter.ToUInt16(subData, clut + offset);
        var clutH = BitConverter.ToUInt16(subData, clut + offset + 2);
        var pix = BitConverter.ToInt32(subData, offset + 8);
        var pixW = BitConverter.ToUInt16(subData, pix + offset);
        var pixH = BitConverter.ToUInt16(subData, pix + offset + 2);
        Console.WriteLine($"  TIM: {pixW}*{pixH} words, CLUT {clutW}*{clutH}");
        is4bpp = clutW != 256;
        var cluts = ParseCluts(subData, offset + clut + 4, clutW, clutH);
        return ParsePix(subData, offset + pix + 4, pixW, pixH, cluts, is4bpp);
    }

    private static ushort ReadU16(byte[] d, int off) => (ushort)(d[off] | (d[off + 1] << 8));

    private static int GetSubContentOffset(byte[] dd, int index, out int size)
    {
        var cur = BitConverter.ToInt32(dd, 4 + index * 4) & 0xFFFFFF;
        if (cur == 0)
        {
            size = 0;
            return 0;
        }

        var entryCount = ReadU16(dd, 0);
        var next = index + 1;
        while (next < entryCount)
        {
            var nextOff = BitConverter.ToInt32(dd, 4 + next * 4) & 0xFFFFFF;
            if (nextOff != 0)
            {
                size = nextOff - cur;
                return cur;
            }
            next++;
        }

        size = dd.Length - cur;
        return cur;
    }

    private static List<PartRect> ParsePartRects(byte[] dd, int blockBase)
    {
        var rects = new List<PartRect>();
        if (blockBase + 4 > dd.Length) return rects;

        var count = BitConverter.ToUInt32(dd, blockBase);
        for (var i = 0; i < count && blockBase + 4 + (i + 1) * 4 <= dd.Length; i++)
        {
            var pos = blockBase + 4 + i * 4;
            rects.Add(new PartRect(dd[pos], dd[pos + 1], dd[pos + 2], dd[pos + 3]));
        }
        return rects;
    }

    private static List<FrameData> ParseFrameDataBlock(byte[] dd, int blockBase)
    {
        var frameDataList = new List<FrameData>();
        if (blockBase + 4 > dd.Length) return frameDataList;

        var count = BitConverter.ToUInt32(dd, blockBase);
        var offsets = new List<int>();
        for (var i = 0; i < count && blockBase + 4 + (i + 1) * 2 <= dd.Length; i++)
            offsets.Add(ReadU16(dd, blockBase + 4 + i * 2));

        foreach (var off in offsets)
        {
            var fdBase = blockBase + off;
            if (fdBase + 4 > dd.Length) continue;

            var partCount = dd[fdBase];
            var parts = new List<FramePart>();
            var cursor = fdBase + 4;
            for (var p = 0; p < partCount && cursor + 8 <= dd.Length; p++)
            {
                var flags = dd[cursor];
                var rectIndex = dd[cursor + 1];
                var localX = dd[cursor + 2];
                var localY = dd[cursor + 3];
                var attr = BitConverter.ToUInt32(dd, cursor + 4);

                ushort? sx = null, sy = null;
                if ((flags & 0x04) != 0 && cursor + 12 <= dd.Length)
                {
                    sx = ReadU16(dd, cursor + 8);
                    sy = ReadU16(dd, cursor + 10);
                    cursor += 12;
                }
                else
                {
                    cursor += 8;
                }
                parts.Add(new FramePart(flags, rectIndex, localX, localY, attr, sx, sy));
            }
            frameDataList.Add(new FrameData(partCount, parts));
        }
        return frameDataList;
    }

    private static List<AnimData> ParseAnimDataBlock(byte[] dd, int blockBase)
    {
        var anims = new List<AnimData>();
        if (blockBase + 4 > dd.Length) return anims;

        var count = BitConverter.ToUInt32(dd, blockBase);
        var offsets = new List<int>();
        for (var i = 0; i < count && blockBase + 4 + (i + 1) * 2 <= dd.Length; i++)
            offsets.Add(ReadU16(dd, blockBase + 4 + i * 2));

        foreach (var off in offsets)
        {
            var animBase = blockBase + off;
            if (animBase + 2 > dd.Length) continue;

            var frameCount = ReadU16(dd, animBase);
            var frames = new List<AnimFrameEntry>();
            for (var f = 0; f < frameCount && animBase + 4 + (f + 1) * 4 <= dd.Length; f++)
            {
                var entry = BitConverter.ToUInt32(dd, animBase + 4 + f * 4);
                var fdIdx = (int)(entry & 0x7f);
                var duration = (int)((entry >> 7) & 0x3f);
                var offsetX = (int)(entry << 9) >> 22;
                var offsetY = (int)(entry >> 23);
                frames.Add(new AnimFrameEntry(entry, fdIdx, duration, offsetX, offsetY));
            }
            anims.Add(new AnimData(frameCount, frames));
        }
        return anims;
    }

    private static (string? label, uint flags, List<AnimData> anims, List<FrameData> frameDatas, List<PartRect> rects)
        ParseAnimSpriteBlob(byte[] dd, int blobOff, string label)
    {
        if (blobOff <= 0 || blobOff + 16 > dd.Length)
            return (null, 0, new(), new(), new());

        var flags = BitConverter.ToUInt32(dd, blobOff);
        var animOff = BitConverter.ToInt32(dd, blobOff + 4);
        var frameOff = BitConverter.ToInt32(dd, blobOff + 8);
        var partOff = BitConverter.ToInt32(dd, blobOff + 12);

        var animBase = blobOff + animOff;
        var frameBase = blobOff + frameOff;
        var partBase = blobOff + partOff;

        var rects = ParsePartRects(dd, partBase);
        var frameDatas = ParseFrameDataBlock(dd, frameBase);
        var anims = ParseAnimDataBlock(dd, animBase);

        return (label, flags, anims, frameDatas, rects);
    }

    private static void ExportPart(Bitmap bmp, PartRect rect, string path, bool is4bpp)
    {
        if (rect.U + rect.W > bmp.Width || rect.V + rect.H > bmp.Height)
            return;
        var area = new Rectangle(rect.U, rect.V, rect.W, rect.H);
        using var sprite = bmp.Clone(area, bmp.PixelFormat);
        sprite.Save(path, ImageFormat.Gif);
        SaveAct(bmp, path, is4bpp);
    }

    private static Dictionary<int, int> BuildRectTexMap(List<FrameData> frameDatas)
    {
        var map = new Dictionary<int, int>();
        foreach (var fd in frameDatas)
        foreach (var part in fd.Parts)
        {
            var texIdx = (int)(part.Attr & 3);
            if (!map.ContainsKey(part.RectIndex))
                map[part.RectIndex] = texIdx;
        }
        return map;
    }

    private static void SaveAct(Bitmap bmp, string gifPath, bool is4bpp)
    {
        var actPath = Path.ChangeExtension(gifPath, ".act");
        var palette = bmp.Palette;
        var colorCount = is4bpp ? 16 : 256;
        var actData = new byte[768];
        var seen = new HashSet<int>();
        for (var i = 0; i < colorCount; i++)
        {
            var c = palette.Entries[i];
            var r = (int)c.R;
            var g = (int)c.G;
            var b = (int)c.B;
            var key = (r << 16) | (g << 8) | b;
            if (seen.Add(key))
            {
                actData[i * 3] = (byte)r;
                actData[i * 3 + 1] = (byte)g;
                actData[i * 3 + 2] = (byte)b;
                continue;
            }
            var tweak = 0;
            while (true)
            {
                var inc = tweak / 3 + 1;
                var channel = tweak % 3;
                var cr = channel == 0 ? Math.Min(r + inc, 255) : r;
                var cg = channel == 1 ? Math.Min(g + inc, 255) : g;
                var cb = channel == 2 ? Math.Min(b + inc, 255) : b;
                key = (cr << 16) | (cg << 8) | cb;
                if (seen.Add(key))
                {
                    actData[i * 3] = (byte)cr;
                    actData[i * 3 + 1] = (byte)cg;
                    actData[i * 3 + 2] = (byte)cb;
                    break;
                }
                tweak++;
            }
        }
        Console.WriteLine(actPath);
        File.WriteAllBytes(actPath, actData);
    }

    private static void ExtractShopImages()
    {
        var cm2000Path = "rom/CM2000.DAT";
        if (!File.Exists(cm2000Path))
        {
            Console.WriteLine("\nCM2000.DAT not found, skipping shop images extraction.");
            return;
        }

        Console.WriteLine("\n=== Extracting shop images ===");
        var cm2000 = File.ReadAllBytes(cm2000Path);
        var shopData = ExtractUtil.GetSubcontent(cm2000, 7);

        var outDir = "pic_output/shop";
        Directory.CreateDirectory(outDir);

        int[] pictureIndices = { 5, 6, 8 };
        foreach (var idx in pictureIndices)
        {
            var off = GetSubContentOffset(shopData, idx, out var size);
            if (off == 0)
            {
                Console.WriteLine($"  shop_sub_{idx}: empty, skipping");
                continue;
            }

            using var bmp = ParseTim(shopData, off, out var is4bpp);
            if (bmp == null)
            {
                Console.WriteLine($"  shop_sub_{idx}: failed to parse TIM at offset 0x{off:X}");
                continue;
            }

            var path = Path.Combine(outDir, $"shop_{idx}.gif");
            bmp.Save(path, ImageFormat.Gif);
            SaveAct(bmp, path, is4bpp);
            ImageMetaWriter.Write(path, "CM2000.DAT", 7, idx);
            Console.WriteLine($"  shop_sub_{idx}: {bmp.Width}x{bmp.Height}, size=0x{size:X} saved");
        }
    }

    private static void ExtractMapImages(int subContentId)
    {
        var cm2000Path = "rom/CM2000.DAT";
        if (!File.Exists(cm2000Path))
        {
            Console.WriteLine("\nCM2000.DAT not found, skipping map images extraction.");
            return;
        }

        Console.WriteLine($"\n=== Extracting map images (subcontent {subContentId}) ===");
        var cm2000 = File.ReadAllBytes(cm2000Path);
        var mapData = ExtractUtil.GetSubcontent(cm2000, subContentId);

        var outDir = $"pic_output/map/{subContentId}";
        Directory.CreateDirectory(outDir);

        var subCount = ReadU16(mapData, 0);
        Console.WriteLine($"  sub-content count: {subCount}");

        for (var idx = 0; idx < subCount; idx++)
        {
            var off = GetSubContentOffset(mapData, idx, out var size);
            if (off == 0) continue;

            using var bmp = ParseTim(mapData, off, out var is4bpp);
            if (bmp == null) continue;

            var path = Path.Combine(outDir, $"map_sub_{idx}.gif");
            bmp.Save(path, ImageFormat.Gif);
            SaveAct(bmp, path, is4bpp);
            ImageMetaWriter.Write(path, "CM2000.DAT", subContentId, idx);
            Console.WriteLine($"  map_sub_{idx}: {bmp.Width}x{bmp.Height}, size=0x{size:X} saved");
        }
    }

    private static void ExtractMapscreenTitles()
    {
        var cm2000Path = "rom/CM2000.DAT";
        if (!File.Exists(cm2000Path))
        {
            Console.WriteLine("\nCM2000.DAT not found, skipping mapscreen titles extraction.");
            return;
        }

        Console.WriteLine("\n=== Extracting mapscreen titles ===");
        var cm2000 = File.ReadAllBytes(cm2000Path);
        var subData = ExtractUtil.GetSubcontent(cm2000, 1);

        var outDir = "pic_output/misc";
        Directory.CreateDirectory(outDir);

        var off = GetSubContentOffset(subData, 0x11, out var size);
        if (off == 0)
        {
            Console.WriteLine("  mapscreen_titles: slot 0x11 empty, skipping");
            return;
        }

        using var bmp = ParseTim(subData, off, out var is4bpp);
        if (bmp == null)
        {
            Console.WriteLine($"  mapscreen_titles: failed to parse TIM at offset 0x{off:X}");
            return;
        }

        var path = Path.Combine(outDir, "mapscreen_titles.gif");
        bmp.Save(path, ImageFormat.Gif);
        SaveAct(bmp, path, is4bpp);
        ImageMetaWriter.Write(path, "CM2000.DAT", 1, 0x11);
        Console.WriteLine($"  mapscreen_titles: {bmp.Width}x{bmp.Height}, size=0x{size:X} saved");
    }

    private static void ExtractSaveloadUi()
    {
        var cm2000Path = "rom/CM2000.DAT";
        if (!File.Exists(cm2000Path))
        {
            Console.WriteLine("\nCM2000.DAT not found, skipping saveload UI extraction.");
            return;
        }

        Console.WriteLine("\n=== Extracting saveload UI (CM2000 0x15 flat[3] pal0) ===");
        var cm2000 = File.ReadAllBytes(cm2000Path);
        var dd = ExtractUtil.GetSubcontent(cm2000, 0x15);
        var off = GetSubContentOffset(dd, 3, out var size);
        if (off == 0)
        {
            Console.WriteLine("  saveload_ui: slot 3 empty, skipping");
            return;
        }

        using var bmp = ParseTim(dd, off, out var is4bpp);
        if (bmp == null)
        {
            Console.WriteLine($"  saveload_ui: failed to parse TIM at offset 0x{off:X}");
            return;
        }

        var outDir = "pic_output/misc";
        Directory.CreateDirectory(outDir);
        var path = Path.Combine(outDir, "saveload_ui.gif");
        bmp.Save(path, System.Drawing.Imaging.ImageFormat.Gif);
        SaveAct(bmp, path, is4bpp);
        ImageMetaWriter.Write(path, "CM2000.DAT", 0x15, 3);
        Console.WriteLine($"  saveload_ui: {bmp.Width}x{bmp.Height}, size=0x{size:X} saved (pal0 of 16x16 CLUT)");
    }

    private static void ExtractChapterNameImages()
    {
        var cm2000Path = "rom/CM2000.DAT";
        if (!File.Exists(cm2000Path))
        {
            Console.WriteLine("\nCM2000.DAT not found, skipping tilemap UI images extraction.");
            return;
        }

        Console.WriteLine("\n=== Extracting tilemap UI images (CM2000 ID 0x2D-0x2F) ===");
        var cm2000 = File.ReadAllBytes(cm2000Path);

        var outDir = "pic_output/chapter_titles";
        Directory.CreateDirectory(outDir);

        for (var id = 0x2D; id <= 0x4D; id++)
        {
            var dd = ExtractUtil.GetSubcontent(cm2000, id);
            using var bmp = BuildTilemapImage(dd, out var is4bpp,
                out var atlasCols, out var atlasRows, out var mapCols, out var mapRows);
            if (bmp == null)
            {
                Console.WriteLine($"  ui_{id:X2}: unsupported format (4bpp), skipping");
                continue;
            }

            var path = Path.Combine(outDir, $"chapter_title_{id:X2}.gif");
            bmp.Save(path, ImageFormat.Gif);
            SaveAct(bmp, path, is4bpp);
            ImageMetaWriter.WriteTilemap(path, "CM2000.DAT", id, atlasCols, atlasRows, mapCols, mapRows);
            Console.WriteLine($"  ui_{id:X2}: {bmp.Width}x{bmp.Height} saved ({atlasCols}x{atlasRows} atlas tiles)");
        }
    }

    // {flags, clut, image, tilemap} encapsulation used by CM2000 ID 0x2D-0x2F.
    // The 8bpp atlas is a sheet of 16x16 tiles; a 20x15 tilemap places them onto a
    // 320x240 screen. Each ushort tilemap entry encodes the atlas texel coordinate:
    //   U = (e & 0x1F) << 3,  V = ((e >> 5) & 0x1F) << 3
    // and a 16x16 block is drawn at screen (col*16, row*16). entry 0 = empty cell.
    private static Bitmap? BuildTilemapImage(byte[] dd, out bool is4bpp,
        out int atlasCols, out int atlasRows, out int mapCols, out int mapRows)
    {
        is4bpp = false;
        atlasCols = atlasRows = mapCols = mapRows = 0;
        var clutOff = BitConverter.ToInt32(dd, 4) & 0xFFFFFF;
        var imageOff = BitConverter.ToInt32(dd, 8) & 0xFFFFFF;
        var tilemapOff = BitConverter.ToInt32(dd, 12) & 0xFFFFFF;

        var clutW = ReadU16(dd, clutOff);
        var clutH = ReadU16(dd, clutOff + 2);
        is4bpp = clutW != 256;
        if (is4bpp) return null; // 0x2D-0x4D are all 8bpp; 4bpp atlas not handled here

        var cluts = ParseCluts(dd, clutOff + 4, clutW, clutH);

        var atlasW = ReadU16(dd, imageOff) * 2; // 8bpp: words * 2 = pixels per row
        var atlasH = ReadU16(dd, imageOff + 2);
        var atlasStart = imageOff + 4;

        var mapW = ReadU16(dd, tilemapOff);
        var mapH = ReadU16(dd, tilemapOff + 2);
        var mapStart = tilemapOff + 4;

        const int ts = 16;
        atlasCols = atlasW / ts;
        atlasRows = atlasH / ts;
        mapCols = mapW;
        mapRows = mapH;
        var width = mapW * ts;
        var height = mapH * ts;
        var bitmap = new Bitmap(width, height, PixelFormat.Format8bppIndexed);

        var palette = bitmap.Palette;
        for (var i = 0; i < 256; i++)
            palette.Entries[i] = i < cluts.Length ? cluts[i] : cluts[0];
        bitmap.Palette = palette;

        var rect = new Rectangle(0, 0, width, height);
        var bmpData = bitmap.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format8bppIndexed);
        var pixels = new byte[bmpData.Stride * height];

        for (var r = 0; r < mapH; r++)
        {
            for (var c = 0; c < mapW; c++)
            {
                var e = ReadU16(dd, mapStart + (r * mapW + c) * 2);
                if (e == 0) continue; // empty cell -> stays transparent (index 0)
                var u = (e & 0x1F) << 3;
                var v = ((e >> 5) & 0x1F) << 3;
                for (var y = 0; y < ts; y++)
                {
                    var sy = v + y;
                    if (sy >= atlasH) break;
                    for (var x = 0; x < ts; x++)
                    {
                        var sx = u + x;
                        if (sx >= atlasW) continue;
                        pixels[(r * ts + y) * bmpData.Stride + c * ts + x] =
                            dd[atlasStart + sy * atlasW + sx];
                    }
                }
            }
        }

        Marshal.Copy(pixels, 0, bmpData.Scan0, pixels.Length);
        bitmap.UnlockBits(bmpData);
        return bitmap;
    }

    private record PartRect(byte U, byte V, byte W, byte H);
    private record FramePart(byte Flags, byte RectIndex, byte LocalX, byte LocalY, uint Attr, ushort? ScaleX, ushort? ScaleY);
    private record FrameData(byte PartCount, List<FramePart> Parts);
    private record AnimFrameEntry(uint RawEntry, int FrameDataIndex, int Duration, int OffsetX, int OffsetY);
    private record AnimData(ushort FrameCount, List<AnimFrameEntry> Frames);
}
