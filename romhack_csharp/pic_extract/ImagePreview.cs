using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.Json;
using SummonNightLib;

public static class ImagePreview
{
    public static void Generate(string picOutputDir, string translatedDir, string romDir, string previewDir)
    {
        if (!Directory.Exists(translatedDir))
        {
            Console.WriteLine($"pic_output_translated not found: {translatedDir}");
            return;
        }

        Console.WriteLine("\n=== Image Preview ===");

        var datCaches = new Dictionary<string, byte[]>();
        var picOutputBase = Path.GetFullPath(picOutputDir);
        var translatedBase = Path.GetFullPath(translatedDir);

        foreach (var translatedFile in Directory.GetFiles(translatedDir, "*.gif", SearchOption.AllDirectories))
        {
            var relativePath = Path.GetRelativePath(translatedBase, translatedFile);
            var originalFile = Path.Combine(picOutputBase, relativePath);
            var metaFile = originalFile + ".meta.json";

            if (!File.Exists(originalFile) || !File.Exists(metaFile))
                continue;

            var meta = JsonSerializer.Deserialize<ImageMeta>(File.ReadAllText(metaFile))!;
            var romPath = Path.Combine(romDir, meta.DatFile);

            if (!datCaches.TryGetValue(meta.DatFile, out var datBuffer))
            {
                datBuffer = File.ReadAllBytes(romPath);
                datCaches[meta.DatFile] = datBuffer;
            }

            var (pixDataOffset, pixBytesPerRow, pixH, bit4, clutOffset, clutCount) = GetTimInfo(datBuffer, meta);
            var expectedWidth = bit4 ? pixBytesPerRow * 2 : pixBytesPerRow;

            using var translatedBmp = new Bitmap(translatedFile);
            if (translatedBmp.PixelFormat != PixelFormat.Format8bppIndexed ||
                translatedBmp.Width != expectedWidth || translatedBmp.Height != pixH)
                continue;

            var rect = new Rectangle(0, 0, translatedBmp.Width, translatedBmp.Height);
            var tData = translatedBmp.LockBits(rect, ImageLockMode.ReadOnly, translatedBmp.PixelFormat);
            var tIndices = new byte[tData.Stride * tData.Height];
            Marshal.Copy(tData.Scan0, tIndices, 0, tIndices.Length);
            translatedBmp.UnlockBits(tData);

            var outRelDir = Path.GetDirectoryName(relativePath) ?? "";
            var outDir = Path.Combine(previewDir, outRelDir);
            Directory.CreateDirectory(outDir);
            var filename = Path.GetFileNameWithoutExtension(relativePath);

            var cluts = ParseCluts(datBuffer, clutOffset, clutCount);
            var previewPath = Path.Combine(outDir, filename + ".gif");
            SavePreview(tIndices, tData.Stride, translatedBmp.Width, pixH, cluts, previewPath);

            var diffPath = Path.Combine(outDir, filename + "_diff.png");
            SaveDiff(datBuffer, pixDataOffset, pixBytesPerRow, pixH, bit4, tIndices, tData.Stride, diffPath);

            Console.WriteLine($"  Preview: {previewPath}");
            Console.WriteLine($"  Diff:    {diffPath}");
        }
    }

    private static void SavePreview(byte[] indices, int stride, int width, int height, Color[] cluts, string path)
    {
        using var bmp = new Bitmap(width, height, PixelFormat.Format8bppIndexed);
        var palette = bmp.Palette;
        for (var i = 0; i < 256; i++)
            palette.Entries[i] = i < cluts.Length ? cluts[i] : Color.Black;
        bmp.Palette = palette;

        var rect = new Rectangle(0, 0, width, height);
        var bmpData = bmp.LockBits(rect, ImageLockMode.WriteOnly, bmp.PixelFormat);
        for (var y = 0; y < height; y++)
            Marshal.Copy(indices, y * stride, IntPtr.Add(bmpData.Scan0, y * bmpData.Stride), width);
        bmp.UnlockBits(bmpData);

        bmp.Save(path, ImageFormat.Gif);
    }

    private static void SaveDiff(byte[] datBuffer, int pixDataOffset, int pixBytesPerRow, int pixH, bool bit4,
        byte[] translatedIndices, int translatedStride, string path)
    {
        using var diffBmp = new Bitmap(translatedIndices.Length / translatedStride > 0 ? translatedIndices.Length / translatedStride : pixH,
            Math.Max(pixBytesPerRow * (bit4 ? 2 : 1), 1), PixelFormat.Format24bppRgb);
        
        var width = bit4 ? pixBytesPerRow * 2 : pixBytesPerRow;
        var height = pixH;
        using var realDiffBmp = new Bitmap(width, height, PixelFormat.Format24bppRgb);
        
        var rect = new Rectangle(0, 0, width, height);
        var diffData = realDiffBmp.LockBits(rect, ImageLockMode.WriteOnly, realDiffBmp.PixelFormat);
        var diffPixels = new byte[diffData.Stride * height];

        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < pixBytesPerRow; x++)
            {
                byte origLo, origHi;
                if (bit4)
                {
                    var raw = datBuffer[pixDataOffset + y * pixBytesPerRow + x];
                    origLo = (byte)(raw & 0xF);
                    origHi = (byte)((raw >> 4) & 0xF);
                }
                else
                {
                    origLo = datBuffer[pixDataOffset + y * pixBytesPerRow + x];
                    origHi = origLo;
                }

                var transLo = translatedIndices[y * translatedStride + x * 2];
                var transHi = bit4 ? translatedIndices[y * translatedStride + x * 2 + 1] : transLo;

                SetDiffPixel(diffPixels, diffData.Stride, y, x * 2, origLo == transLo);
                if (bit4)
                    SetDiffPixel(diffPixels, diffData.Stride, y, x * 2 + 1, origHi == transHi);
            }
        }
        Marshal.Copy(diffPixels, 0, diffData.Scan0, diffPixels.Length);
        realDiffBmp.UnlockBits(diffData);

        realDiffBmp.Save(path, ImageFormat.Png);
    }

    private static void SetDiffPixel(byte[] pixels, int stride, int y, int x, bool same)
    {
        var off = y * stride + x * 3;
        var v = same ? (byte)255 : (byte)0;
        pixels[off] = v;
        pixels[off + 1] = v;
        pixels[off + 2] = v;
    }

    private static (int pixDataOffset, int pixBytesPerRow, int pixH, bool bit4, int clutOffset, int clutCount)
        GetTimInfo(byte[] datBuffer, ImageMeta meta)
    {
        var sectorOffset = ExtractUtil.ReadUShort(datBuffer, 0x10 + meta.SubContentId * 4);
        var subContentStart = sectorOffset * 0x800;

        int timOffset;
        if (meta.SubSlotIndex == -1)
        {
            timOffset = subContentStart;
        }
        else
        {
            var subData = ExtractUtil.GetSubcontent(datBuffer, meta.SubContentId);
            var slotOff = GetSubContentOffset(subData, meta.SubSlotIndex, out _);
            timOffset = subContentStart + slotOff;
        }

        var clut = BitConverter.ToInt32(datBuffer, timOffset + 4);
        var clutW = BitConverter.ToUInt16(datBuffer, timOffset + clut);
        var clutH = BitConverter.ToUInt16(datBuffer, timOffset + clut + 2);
        var bit4 = clutW != 256;

        var pix = BitConverter.ToInt32(datBuffer, timOffset + 8);
        var pixW = BitConverter.ToUInt16(datBuffer, timOffset + pix);
        var pixH = BitConverter.ToUInt16(datBuffer, timOffset + pix + 2);

        var pixDataOffset = timOffset + pix + 4;
        var pixBytesPerRow = pixW * 2;
        var clutOffset = timOffset + clut + 4;
        var clutCount = clutW * clutH;

        return (pixDataOffset, pixBytesPerRow, pixH, bit4, clutOffset, clutCount);
    }

    private static Color[] ParseCluts(byte[] datBuffer, int offset, int count)
    {
        var colors = new Color[count];
        for (var i = 0; i < count; i++)
        {
            var c = BitConverter.ToUInt16(datBuffer, offset + i * 2);
            var r = c & 0x1F;
            var g = (c >> 5) & 0x1F;
            var b = (c >> 10) & 0x1F;
            colors[i] = Color.FromArgb(i == 0 ? 0 : 255, r << 3, g << 3, b << 3);
        }
        return colors;
    }

    private static int GetSubContentOffset(byte[] dd, int index, out int size)
    {
        var cur = BitConverter.ToInt32(dd, 4 + index * 4) & 0xFFFFFF;
        if (cur == 0)
        {
            size = 0;
            return 0;
        }

        var entryCount = (ushort)(dd[0] | (dd[1] << 8));
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
}
