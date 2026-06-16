using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.Json;
using SummonNightLib;

public static class ImageWriteBack
{
    public static void Apply(string picOutputDir, string translatedDir, string romDir)
    {
        if (!Directory.Exists(translatedDir))
        {
            Console.WriteLine($"pic_output_translated not found: {translatedDir}");
            return;
        }

        Console.WriteLine("\n=== Image WriteBack ===");

        var datBuffers = new Dictionary<string, byte[]>();
        var picOutputBase = Path.GetFullPath(picOutputDir);
        var translatedBase = Path.GetFullPath(translatedDir);

        foreach (var translatedFile in Directory.GetFiles(translatedDir, "*.gif", SearchOption.AllDirectories))
        {
            var relativePath = Path.GetRelativePath(translatedBase, translatedFile);
            var originalFile = Path.Combine(picOutputBase, relativePath);
            var metaFile = originalFile + ".meta.json";

            if (!File.Exists(originalFile))
            {
                Console.WriteLine($"  Skipping {relativePath}: no original in pic_output");
                continue;
            }
            if (!File.Exists(metaFile))
            {
                Console.WriteLine($"  Skipping {relativePath}: no meta file");
                continue;
            }

            var meta = JsonSerializer.Deserialize<ImageMeta>(File.ReadAllText(metaFile))!;
            var romPath = Path.Combine(romDir, meta.DatFile);

            if (!datBuffers.TryGetValue(meta.DatFile, out var datBuffer))
            {
                datBuffer = File.ReadAllBytes(romPath);
                datBuffers[meta.DatFile] = datBuffer;
            }

            var (pixDataOffset, pixBytesPerRow, pixH, bit4) = GetTimPixelInfo(datBuffer, meta);
            var totalPixBytes = pixBytesPerRow * pixH;
            var expectedWidth = bit4 ? pixBytesPerRow * 2 : pixBytesPerRow;

            using var translatedBmp = new Bitmap(translatedFile);
            if (translatedBmp.PixelFormat != PixelFormat.Format8bppIndexed)
                throw new InvalidOperationException(
                    $"{relativePath}: translated GIF is not 8bpp indexed (got {translatedBmp.PixelFormat})");

            if (translatedBmp.Width != expectedWidth || translatedBmp.Height != pixH)
                throw new InvalidOperationException(
                    $"{relativePath}: size mismatch - translated {translatedBmp.Width}x{translatedBmp.Height} vs expected {expectedWidth}x{pixH} ({(bit4 ? "4bpp" : "8bpp")})");

            var rect = new Rectangle(0, 0, translatedBmp.Width, translatedBmp.Height);
            var bmpData = translatedBmp.LockBits(rect, ImageLockMode.ReadOnly, translatedBmp.PixelFormat);
            var indices = new byte[bmpData.Stride * bmpData.Height];
            Marshal.Copy(bmpData.Scan0, indices, 0, indices.Length);
            translatedBmp.UnlockBits(bmpData);

            var maxIndex = bit4 ? 15 : 255;
            var newPixData = new byte[totalPixBytes];
            for (var y = 0; y < pixH; y++)
            {
                for (var x = 0; x < pixBytesPerRow; x++)
                {
                    if (bit4)
                    {
                        var lo = indices[y * bmpData.Stride + x * 2];
                        var hi = indices[y * bmpData.Stride + x * 2 + 1];
                        if (lo > maxIndex || hi > maxIndex)
                            throw new InvalidOperationException(
                                $"{relativePath}: 4bpp index out of range at pixel ({x * 2},{y}): [{lo}, {hi}] (max {maxIndex})");
                        newPixData[y * pixBytesPerRow + x] = (byte)(lo | (hi << 4));
                    }
                    else
                    {
                        var idx = indices[y * bmpData.Stride + x];
                        if (idx > maxIndex)
                            throw new InvalidOperationException(
                                $"{relativePath}: 8bpp index out of range at pixel ({x},{y}): {idx} (max {maxIndex})");
                        newPixData[y * pixBytesPerRow + x] = idx;
                    }
                }
            }

            Buffer.BlockCopy(newPixData, 0, datBuffer, pixDataOffset, totalPixBytes);
            Console.WriteLine($"  Wrote {relativePath}: {totalPixBytes} bytes -> {meta.DatFile} offset 0x{pixDataOffset:X} ({(bit4 ? "4bpp" : "8bpp")})");
        }

        foreach (var metaFile in Directory.GetFiles(picOutputDir, "*.meta.json", SearchOption.AllDirectories))
        {
            var meta = JsonSerializer.Deserialize<ImageMeta>(File.ReadAllText(metaFile))!;
            if (!datBuffers.ContainsKey(meta.DatFile))
            {
                var romPath = Path.Combine(romDir, meta.DatFile);
                if (File.Exists(romPath))
                    datBuffers[meta.DatFile] = File.ReadAllBytes(romPath);
            }
        }

        foreach (var (datFile, buffer) in datBuffers)
        {
            var mod2Path = Path.Combine(romDir, datFile + ".mod2");
            File.WriteAllBytes(mod2Path, buffer);
            Console.WriteLine($"  -> {mod2Path}");
        }
    }

    private static (int pixDataOffset, int pixBytesPerRow, int pixH, bool bit4) GetTimPixelInfo(byte[] datBuffer, ImageMeta meta)
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
        var bit4 = clutW != 256;

        var pix = BitConverter.ToInt32(datBuffer, timOffset + 8);
        var pixW = BitConverter.ToUInt16(datBuffer, timOffset + pix);
        var pixH = BitConverter.ToUInt16(datBuffer, timOffset + pix + 2);

        var pixDataOffset = timOffset + pix + 4;
        var pixBytesPerRow = pixW * 2;

        return (pixDataOffset, pixBytesPerRow, pixH, bit4);
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
