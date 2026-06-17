using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.Json;

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

            var tim = TimPixelHelper.ParseTim(datBuffer, meta);

            using var translatedBmp = new Bitmap(translatedFile);
            if (translatedBmp.PixelFormat != PixelFormat.Format8bppIndexed)
                throw new InvalidOperationException(
                    $"{relativePath}: translated GIF is not 8bpp indexed (got {translatedBmp.PixelFormat})");

            int expectedW, expectedH;
            if (meta.RectU != null)
            {
                expectedW = meta.RectW!.Value;
                expectedH = meta.RectH!.Value;
            }
            else
            {
                expectedW = tim.Stride;
                expectedH = tim.PixH;
            }

            if (translatedBmp.Width != expectedW || translatedBmp.Height != expectedH)
                throw new InvalidOperationException(
                    $"{relativePath}: size mismatch - translated {translatedBmp.Width}x{translatedBmp.Height} vs expected {expectedW}x{expectedH} ({(tim.Bit4 ? "4bpp" : "8bpp")})");

            var rect = new Rectangle(0, 0, translatedBmp.Width, translatedBmp.Height);
            var bmpData = translatedBmp.LockBits(rect, ImageLockMode.ReadOnly, translatedBmp.PixelFormat);
            var tIndices = new byte[bmpData.Stride * translatedBmp.Height];
            Marshal.Copy(bmpData.Scan0, tIndices, 0, tIndices.Length);
            translatedBmp.UnlockBits(bmpData);

            var maxIndex = tim.Bit4 ? 15 : 255;
            if (meta.RectU != null)
            {
                for (var y = 0; y < meta.RectH!.Value; y++)
                {
                    for (var x = 0; x < meta.RectW!.Value; x++)
                    {
                        var idx = tIndices[y * bmpData.Stride + x];
                        if (idx > maxIndex)
                            throw new InvalidOperationException(
                                $"{relativePath}: {(tim.Bit4 ? "4bpp" : "8bpp")} index out of range at pixel ({x},{y}): {idx} (max {maxIndex})");
                        tim.PixelIndices[(meta.RectV!.Value + y) * tim.Stride + (meta.RectU.Value + x)] = idx;
                    }
                }
            }
            else
            {
                for (var y = 0; y < tim.PixH; y++)
                {
                    for (var x = 0; x < expectedW; x++)
                    {
                        var idx = tIndices[y * bmpData.Stride + x];
                        if (idx > maxIndex)
                            throw new InvalidOperationException(
                                $"{relativePath}: {(tim.Bit4 ? "4bpp" : "8bpp")} index out of range at pixel ({x},{y}): {idx} (max {maxIndex})");
                        tim.PixelIndices[y * tim.Stride + x] = idx;
                    }
                }
            }

            var rawPix = TimPixelHelper.PackToRaw(tim, tim.PixelIndices);
            Buffer.BlockCopy(rawPix, 0, datBuffer, tim.RawPixDataOffset, rawPix.Length);
            var rectInfo = meta.RectU != null
                ? $" rect {meta.RectU},{meta.RectV} {meta.RectW}x{meta.RectH}"
                : "";
            Console.WriteLine($"  Wrote {relativePath}: {rawPix.Length} bytes -> {meta.DatFile} offset 0x{tim.RawPixDataOffset:X}{rectInfo} ({(tim.Bit4 ? "4bpp" : "8bpp")})");
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
}
