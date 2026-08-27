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
        ExtractBattlePrepareUI();
        ExtractBattleUI();
        ExtractChapterNameImages();
        ExtractCatGameHelp();
        ExtractCatGameRewards();
        ExtractCatGameBanner();
        ExtractFishGameBanner();

        Console.WriteLine("\nDone.");
    }

    // Extracts the CLUT and applies same-color avoidance here (not in SaveAct) so the
    // bitmap palette itself carries unique colors - GIF, ACT and any downstream tool
    // all agree on one color per index. Duplicate entries get nudged (+1 on R/G/B,
    // cycling with growing increment); alpha/transparency stays untouched.
    private static Color[] ParseCluts(byte[] subData, int offset, int clutW, int clutH)
    {
        var colors = new List<Color>();
        var seen = new HashSet<int>();
        for (var i = 0; i < clutW * clutH; i++)
        {
            var c = BitConverter.ToUInt16(subData, offset + i * 2);
            var r = (c & 0x1F) << 3;
            var g = ((c >> 5) & 0x1F) << 3;
            var b = ((c >> 10) & 0x1F) << 3;
            var a = (i == 0 && r == 0 && g == 0 && b == 0) ? 0 : (c == 0 ? 0 : 255);
            AvoidDuplicateColor(seen, ref r, ref g, ref b);
            colors.Add(Color.FromArgb(a, r, g, b));
        }
        return colors.ToArray();
    }

    // Keeps a set of unique RGB24 keys; nudges (r,g,b) until its key is unseen.
    private static void AvoidDuplicateColor(HashSet<int> seen, ref int r, ref int g, ref int b)
    {
        if (seen.Add((r << 16) | (g << 8) | b))
            return;
        var tweak = 0;
        while (true)
        {
            var inc = tweak / 3 + 1;
            var channel = tweak % 3;
            var cr = channel == 0 ? Math.Min(r + inc, 255) : r;
            var cg = channel == 1 ? Math.Min(g + inc, 255) : g;
            var cb = channel == 2 ? Math.Min(b + inc, 255) : b;
            if (seen.Add((cr << 16) | (cg << 8) | cb))
            {
                r = cr;
                g = cg;
                b = cb;
                return;
            }
            tweak++;
        }
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

    // The palette already went through same-color avoidance in ParseCluts, so the ACT
    // is just a straight dump of the same colors the GIF uses.
    private static void SaveAct(Bitmap bmp, string gifPath, bool is4bpp)
    {
        var actPath = Path.ChangeExtension(gifPath, ".act");
        var palette = bmp.Palette;
        var colorCount = is4bpp ? 16 : 256;
        var actData = new byte[768];
        for (var i = 0; i < colorCount; i++)
        {
            var c = palette.Entries[i];
            actData[i * 3] = c.R;
            actData[i * 3 + 1] = c.G;
            actData[i * 3 + 2] = c.B;
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

        // Primary copy: CM2000 subcontent 1 flat 0x11.
        ExtractMapscreenTitle(cm2000, 1, 0x11, "mapscreen_titles");

        // Duplicate copy: byte-identical pixel data + CLUT also live in
        // subcontent 3 flat 17 as a {flags=0, clut=+16, pix=+0x74} TIM blob.
        ExtractMapscreenTitle(cm2000, 3, 17, "mapscreen_titles2");
    }

    private static void ExtractMapscreenTitle(byte[] cm2000, int subContentId, int slotIndex, string filename)
    {
        var subData = ExtractUtil.GetSubcontent(cm2000, subContentId);

        var outDir = "pic_output/misc";
        Directory.CreateDirectory(outDir);

        var off = GetSubContentOffset(subData, slotIndex, out var size);
        if (off == 0)
        {
            Console.WriteLine($"  {filename}: sub{subContentId} slot {slotIndex} empty, skipping");
            return;
        }

        using var bmp = ParseTim(subData, off, out var is4bpp);
        if (bmp == null)
        {
            Console.WriteLine($"  {filename}: failed to parse TIM at offset 0x{off:X}");
            return;
        }

        var path = Path.Combine(outDir, filename + ".gif");
        bmp.Save(path, ImageFormat.Gif);
        SaveAct(bmp, path, is4bpp);
        ImageMetaWriter.Write(path, "CM2000.DAT", subContentId, slotIndex);
        Console.WriteLine($"  {filename}: {bmp.Width}x{bmp.Height}, size=0x{size:X} saved");
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

    private static void ExtractBattlePrepareUI()
    {
        var cm2000Path = "rom/CM2000.DAT";
        if (!File.Exists(cm2000Path))
        {
            Console.WriteLine("\nCM2000.DAT not found, skipping battle prepare UI extraction.");
            return;
        }

        Console.WriteLine("\n=== Extracting battle prepare UI (CM2000 0x10 sector 0x2DF -> 0xD78) ===");
        var cm2000 = File.ReadAllBytes(cm2000Path);
        var dd = ExtractUtil.GetSubcontent(cm2000, 0x10);
        const int timBase = 0xB60;
        using var bmp = ParseTim(dd, timBase, out var is4bpp);
        if (bmp == null)
        {
            Console.WriteLine($"  battle_prepare_ui: failed to parse TIM at offset 0x{timBase:X}");
            return;
        }

        var outDir = "pic_output/misc";
        Directory.CreateDirectory(outDir);
        var path = Path.Combine(outDir, "battle_prepare_ui.gif");
        bmp.Save(path, System.Drawing.Imaging.ImageFormat.Gif);
        SaveAct(bmp, path, is4bpp);
        ImageMetaWriter.WriteRawTim(path, "CM2000.DAT", 0x10, timBase);
        var size = dd.Length - timBase;
        Console.WriteLine($"  battle_prepare_ui: {bmp.Width}x{bmp.Height}, TIM base 0x{timBase:X} CLUT 16x16 PIX 64x256 size=0x{size:X} saved");
    }

    // CM4000.DAT subcontent 1: first 96 sectors CD-read to 0x80138000 for battle UI.
    // TIM descriptor {flags=0, clut=+16, pix=+532} at +0x9720: 16x16 CLUT,
    // PIX 64w x 256h => 256x256 4bpp, pixel data at +0x9938 == the LoadImage VRAM
    // upload source (rect 384,0).
    private static void ExtractBattleUI()
    {
        var cm4000Path = "rom/CM4000.DAT";
        if (!File.Exists(cm4000Path))
        {
            Console.WriteLine("\nCM4000.DAT not found, skipping battle UI extraction.");
            return;
        }

        Console.WriteLine("\n=== Extracting battle UI (CM4000 0x01 TIM @subcontent+0x9720) ===");
        var cm4000 = File.ReadAllBytes(cm4000Path);
        var dd = ExtractUtil.GetSubcontent(cm4000, 1);
        const int timBase = 0x9720;
        using var bmp = ParseTim(dd, timBase, out var is4bpp);
        if (bmp == null)
        {
            Console.WriteLine($"  battle_ui: failed to parse TIM at offset 0x{timBase:X}");
            return;
        }

        var outDir = "pic_output/misc";
        Directory.CreateDirectory(outDir);
        var path = Path.Combine(outDir, "battle_ui.gif");
        bmp.Save(path, System.Drawing.Imaging.ImageFormat.Gif);
        SaveAct(bmp, path, is4bpp);
        ImageMetaWriter.WriteRawTim(path, "CM4000.DAT", 1, timBase);
        Console.WriteLine($"  battle_ui: {bmp.Width}x{bmp.Height} saved");
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

    // CM2000.DAT subcontent 0x17 ("SCP" container, sector 0x4A1 + 140 sectors,
    // CD-read wholesale to 0x80110000 for the cat game-help screens): a directory
    // of u32 offsets in [+8, +0x4C) followed by the "SCP\0" magic. Two sub-block
    // shapes exist:
    //   - chapter-title style {flags=0x91/0x11, clut 256x1 (8bpp atlas), 20x15 tilemap}
    //     handled by ExtractCatGameHelp; each atlas is uploaded raw to VRAM
    //     (e.g. block+0xF10 pixel data == LoadImage source 0x80111128, rect 72x256).
    //   - whole-image style {flags=0/1, image@+0x214, tilemap=0} handled by
    //     ExtractCatGameRewards / ExtractCatGameBanner; the encapsulation doubles as
    //     a TIM header and uploads as a raw VRAM page (block+0x3485C pixels ==
    //     LoadImage source 0x80144A74, rect 768,0,64,256 => 256x256 4bpp with a 16x16
    //     CLUT; block+0x3CCD4 pixels == source 0x8014CEEC, rect 128x136 => 256x136
    //     8bpp with a 256x1 CLUT).
    private static void ExtractCatGameHelp()
    {
        var cm2000Path = "rom/CM2000.DAT";
        if (!File.Exists(cm2000Path))
        {
            Console.WriteLine("\nCM2000.DAT not found, skipping cat game help extraction.");
            return;
        }

        Console.WriteLine("\n=== Extracting cat game help images (CM2000 ID 0x17 SCP container) ===");
        var cm2000 = File.ReadAllBytes(cm2000Path);
        var dd = ExtractUtil.GetSubcontent(cm2000, 0x17);

        var outDir = "pic_output/misc";
        Directory.CreateDirectory(outDir);

        var tableEnd = ReadU16(dd, 4); // directory byte size (u32 at +4)
        var n = 0;
        for (var slot = 8; slot + 4 <= tableEnd; slot += 4)
        {
            var off = BitConverter.ToInt32(dd, slot) & 0xFFFFFF;
            if (off < 0x50 || off >= dd.Length) continue;

            // Keep only chapter-title-style sub-blocks: clut 256x1 (8bpp) + 20x15 map.
            var clutOff = BitConverter.ToInt32(dd, off + 4) & 0xFFFFFF;
            var imageOff = BitConverter.ToInt32(dd, off + 8) & 0xFFFFFF;
            var tilemapOff = BitConverter.ToInt32(dd, off + 12) & 0xFFFFFF;
            if (clutOff != 0x10 || imageOff <= 0 || tilemapOff <= imageOff) continue;
            if (ReadU16(dd, off + clutOff) != 256 || ReadU16(dd, off + clutOff + 2) != 1) continue;
            if (ReadU16(dd, off + tilemapOff) != 20 || ReadU16(dd, off + tilemapOff + 2) != 15) continue;

            var sub = new byte[dd.Length - off];
            Buffer.BlockCopy(dd, off, sub, 0, sub.Length);
            using var bmp = BuildTilemapImage(sub, out var is4bpp,
                out var atlasCols, out var atlasRows, out var mapCols, out var mapRows);
            if (bmp == null)
            {
                Console.WriteLine($"  cat_game_help_{n:X2}: unsupported format (4bpp), skipping");
                continue;
            }

            var path = Path.Combine(outDir, $"cat_game_help_{n:D2}.gif");
            bmp.Save(path, ImageFormat.Gif);
            SaveAct(bmp, path, is4bpp);
            ImageMetaWriter.WriteTilemap(path, "CM2000.DAT", 0x17,
                atlasCols, atlasRows, mapCols, mapRows, baseOffset: off);
            Console.WriteLine(
                $"  cat_game_help_{n:D2}: block +0x{off:X} {bmp.Width}x{bmp.Height} saved ({atlasCols}x{atlasRows} atlas tiles)");
            n++;
        }
    }

    // Whole-image member of the SCP container (see ExtractCatGameHelp): CM2000 0x17
    // block+0x3485C, {flags=0, clut@+0x10 (16x16), image@+0x214, tilemap=0}. The pixel
    // header {64 words, 256 rows} uploads raw to VRAM rect (768,0,64,256) => 256x256 4bpp,
    // low nibble first; pixels reference only palette bank 0 (entries 0-15). The layout
    // equals a TIM ({tag slot holds flags}, clut off at +4, pix off at +8), so ParseTim
    // decodes it directly and write-back goes through the standard TIM path by emitting
    // SubSlotIndex=-2 with TimBase=block offset.
    private static void ExtractCatGameRewards()
    {
        var cm2000Path = "rom/CM2000.DAT";
        if (!File.Exists(cm2000Path))
        {
            Console.WriteLine("\nCM2000.DAT not found, skipping cat game rewards extraction.");
            return;
        }

        Console.WriteLine("\n=== Extracting cat game reward image (CM2000 ID 0x17 block+0x3485C) ===");
        var cm2000 = File.ReadAllBytes(cm2000Path);
        var dd = ExtractUtil.GetSubcontent(cm2000, 0x17);
        const int baseOff = 0x3485C;

        var tilemapOff = BitConverter.ToInt32(dd, baseOff + 12) & 0xFFFFFF;
        if (ReadU16(dd, baseOff + 0x10) != 16 || ReadU16(dd, baseOff + 0x12) != 16 || tilemapOff != 0)
            throw new InvalidOperationException(
                $"cat_game_rewards: block+0x{baseOff:X} no longer matches the expected 4bpp whole-image layout");

        using var bmp = ParseTim(dd, baseOff, out var is4bpp);
        if (bmp == null || !is4bpp)
            throw new InvalidOperationException("cat_game_rewards: failed to parse as a 4bpp TIM-style image");

        var outDir = "pic_output/misc";
        Directory.CreateDirectory(outDir);
        var path = Path.Combine(outDir, "cat_game_rewards.gif");
        bmp.Save(path, ImageFormat.Gif);
        SaveAct(bmp, path, is4bpp);
        ImageMetaWriter.WriteRawTim(path, "CM2000.DAT", 0x17, baseOff);
        Console.WriteLine($"  cat_game_rewards: {bmp.Width}x{bmp.Height} saved (block+0x{baseOff:X}, 4bpp)");
    }

    // Whole-image member of the SCP container (see ExtractCatGameRewards): CM2000 0x17
    // block+0x3CCD4, {flags=1, clut@+0x10 (256x1), image@+0x214 {128 words, 136 rows},
    // tilemap=0}. Pixels upload raw to VRAM (LoadImage source 0x8014CEEC, rect 128x136
    // halfwords) => 256x136 8bpp. TIM-shaped like block+0x3485C, so the standard
    // ParseTim / WriteRawTim path applies unchanged.
    private static void ExtractCatGameBanner()
    {
        var cm2000Path = "rom/CM2000.DAT";
        if (!File.Exists(cm2000Path))
        {
            Console.WriteLine("\nCM2000.DAT not found, skipping cat game banner extraction.");
            return;
        }

        Console.WriteLine("\n=== Extracting cat game banner image (CM2000 ID 0x17 block+0x3CCD4) ===");
        var cm2000 = File.ReadAllBytes(cm2000Path);
        var dd = ExtractUtil.GetSubcontent(cm2000, 0x17);
        const int baseOff = 0x3CCD4;

        var tilemapOff = BitConverter.ToInt32(dd, baseOff + 12) & 0xFFFFFF;
        if (ReadU16(dd, baseOff + 0x10) != 256 || ReadU16(dd, baseOff + 0x12) != 1 || tilemapOff != 0)
            throw new InvalidOperationException(
                $"cat_game_banner: block+0x{baseOff:X} no longer matches the expected 8bpp whole-image layout");

        using var bmp = ParseTim(dd, baseOff, out var is4bpp);
        if (bmp == null || is4bpp)
            throw new InvalidOperationException("cat_game_banner: failed to parse as an 8bpp TIM-style image");

        var outDir = "pic_output/misc";
        Directory.CreateDirectory(outDir);
        var path = Path.Combine(outDir, "cat_game_banner.gif");
        bmp.Save(path, ImageFormat.Gif);
        SaveAct(bmp, path, is4bpp);
        ImageMetaWriter.WriteRawTim(path, "CM2000.DAT", 0x17, baseOff);
        Console.WriteLine($"  cat_game_banner: {bmp.Width}x{bmp.Height} saved (block+0x{baseOff:X}, 8bpp)");
    }

    // Whole-image member of a second SCP container: CM2000 0x1A (sector 0x59D + 203
    // sectors, CD-read to 0x80110000 for the fish game screens). Block+0x54174 has the
    // same TIM-shaped encapsulation {flags=1, clut@+0x10 (256x1), image@+0x214
    // {128 words, 136 rows}, tilemap=0}; pixels upload raw to VRAM (LoadImage source
    // 0x8016438C, rect 128x136 halfwords) => 256x136 8bpp.
    private static void ExtractFishGameBanner()
    {
        var cm2000Path = "rom/CM2000.DAT";
        if (!File.Exists(cm2000Path))
        {
            Console.WriteLine("\nCM2000.DAT not found, skipping fish game banner extraction.");
            return;
        }

        Console.WriteLine("\n=== Extracting fish game banner image (CM2000 ID 0x1A block+0x54174) ===");
        var cm2000 = File.ReadAllBytes(cm2000Path);
        var dd = ExtractUtil.GetSubcontent(cm2000, 0x1A);
        const int baseOff = 0x54174;

        var tilemapOff = BitConverter.ToInt32(dd, baseOff + 12) & 0xFFFFFF;
        if (ReadU16(dd, baseOff + 0x10) != 256 || ReadU16(dd, baseOff + 0x12) != 1 || tilemapOff != 0)
            throw new InvalidOperationException(
                $"fish_game_banner: block+0x{baseOff:X} no longer matches the expected 8bpp whole-image layout");

        using var bmp = ParseTim(dd, baseOff, out var is4bpp);
        if (bmp == null || is4bpp)
            throw new InvalidOperationException("fish_game_banner: failed to parse as an 8bpp TIM-style image");

        var outDir = "pic_output/misc";
        Directory.CreateDirectory(outDir);
        var path = Path.Combine(outDir, "fish_game_banner.gif");
        bmp.Save(path, ImageFormat.Gif);
        SaveAct(bmp, path, is4bpp);
        ImageMetaWriter.WriteRawTim(path, "CM2000.DAT", 0x1A, baseOff);
        Console.WriteLine($"  fish_game_banner: {bmp.Width}x{bmp.Height} saved (block+0x{baseOff:X}, 8bpp)");
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
