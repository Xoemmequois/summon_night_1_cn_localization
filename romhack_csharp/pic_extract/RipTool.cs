using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using SummonNightLib;

public static class RipTool
{
    public static void Run()
    {
        var data = File.ReadAllBytes("rom/CM3000.DAT");
        Console.WriteLine("=== Extracting character sprite parts ===");

        var outBase = "pic_output/chars";
        Directory.CreateDirectory(outBase);

        for (var i = 0; i < 0x44; ++i)
        {
            var dd = ExtractUtil.GetSubcontent(data, 0x89 + i);

            var off0 = BitConverter.ToInt32(dd, 4);
            var off1 = BitConverter.ToInt32(dd, 8);
            var off2 = BitConverter.ToInt32(dd, 12);
            var off3 = BitConverter.ToInt32(dd, 16);

            using var bmp0 = ParseTim(dd, off0);
            using var bmp1 = ParseTim(dd, off1);

            var (sub2Label, sub2Flags, sub2Anims, sub2FrameDatas, sub2Rects) = ParseAnimSpriteBlob(dd, off2, "sub2");
            var (sub3Label, sub3Flags, sub3Anims, sub3FrameDatas, sub3Rects) = ParseAnimSpriteBlob(dd, off3, "sub3");

            var texMap2 = BuildRectTexMap(sub2FrameDatas);
            for (var j = 0; j < sub2Rects.Count; j++)
            {
                var texIdx = texMap2.TryGetValue(j, out var t) ? t : 0;
                var bmp = texIdx == 0 ? bmp0 : bmp1;
                if (bmp == null) continue;
                var path = Path.Combine(outBase, $"char_{i}_sub2_part_{j}.gif");
                if (!File.Exists(path))
                    ExportPart(bmp, sub2Rects[j], path);
            }

            var texMap3 = BuildRectTexMap(sub3FrameDatas);
            for (var j = 0; j < sub3Rects.Count; j++)
            {
                var texIdx = texMap3.TryGetValue(j, out var t) ? t : 0;
                var bmp = texIdx == 0 ? bmp0 : bmp1;
                if (bmp == null) continue;
                var path = Path.Combine(outBase, $"char_{i}_sub3_part_{j}.gif");
                if (!File.Exists(path))
                    ExportPart(bmp, sub3Rects[j], path);
            }
        }

        for (var i = 3; i < 63; ++i)
        {
            var subContent = ExtractUtil.GetSubcontent(data, i);
            Console.WriteLine($"\nmapname{i}: offset=0x{BitConverter.ToInt32(subContent, 4):X} {subContent.Length} bytes");
            Parse(subContent, 0, $"mapname{i}");
        }

        Console.WriteLine("\n=== Writing translated mapnames back to CM3000.DAT ===");
        var modifiedData = WriteBackMapname.Apply(data, "pic_output/mapnames_translated", "pic_output/mapnames");
        File.WriteAllBytes("rom/CM3000.DAT.mod2", modifiedData);

        Console.WriteLine("\nDone.");
    }

    private static Color[] ParseCluts(byte[] subData, int offset, int clutW, int clutH)
    {
        var colors = new List<Color>();
        for (var i = 0; i < clutW * clutH; i++)
        {
            var c = BitConverter.ToUInt16(subData, offset + i * 2);
            var r = c & 0x1F;
            var g = (c >> 5) & 0x1F;
            var b = (c >> 10) & 0x1F;
            var a = c == 0 ? 0 : 255;
            colors.Add(Color.FromArgb(a, r << 3, g << 3, b << 3));
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
        var bitmap = ParseTim(subData, offset, false);
        var outDir = Path.Combine("pic_output", "mapnames");
        Directory.CreateDirectory(outDir);
        bitmap!.Save(Path.Combine(outDir, filename + ".gif"), ImageFormat.Gif);
    }

    private static Bitmap? ParseTim(byte[] subData, int offset, bool skipWhenOffsetZero = true)
    {
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
        var cluts = ParseCluts(subData, offset + clut + 4, clutW, clutH);
        return ParsePix(subData, offset + pix + 4, pixW, pixH, cluts, clutW != 256);
    }

    private static ushort ReadU16(byte[] d, int off) => (ushort)(d[off] | (d[off + 1] << 8));

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

    private static void ExportPart(Bitmap bmp, PartRect rect, string path)
    {
        if (rect.U + rect.W > bmp.Width || rect.V + rect.H > bmp.Height)
            return;
        var area = new Rectangle(rect.U, rect.V, rect.W, rect.H);
        using var sprite = bmp.Clone(area, bmp.PixelFormat);
        sprite.Save(path, ImageFormat.Gif);
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

    private record PartRect(byte U, byte V, byte W, byte H);
    private record FramePart(byte Flags, byte RectIndex, byte LocalX, byte LocalY, uint Attr, ushort? ScaleX, ushort? ScaleY);
    private record FrameData(byte PartCount, List<FramePart> Parts);
    private record AnimFrameEntry(uint RawEntry, int FrameDataIndex, int Duration, int OffsetX, int OffsetY);
    private record AnimData(ushort FrameCount, List<AnimFrameEntry> Frames);
}
