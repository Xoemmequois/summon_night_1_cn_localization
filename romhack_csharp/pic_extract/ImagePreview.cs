using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.Json;

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

            var tim = TimPixelHelper.ParseTim(datBuffer, meta);

            using var translatedBmp = new Bitmap(translatedFile);
            if (translatedBmp.PixelFormat != PixelFormat.Format8bppIndexed)
                continue;

            var tRect = new Rectangle(0, 0, translatedBmp.Width, translatedBmp.Height);
            var tData = translatedBmp.LockBits(tRect, ImageLockMode.ReadOnly, translatedBmp.PixelFormat);
            var tIndices = new byte[tData.Stride * translatedBmp.Height];
            Marshal.Copy(tData.Scan0, tIndices, 0, tIndices.Length);
            translatedBmp.UnlockBits(tData);

            var outRelDir = Path.GetDirectoryName(relativePath) ?? "";
            var outDir = Path.Combine(previewDir, outRelDir);
            Directory.CreateDirectory(outDir);
            var filename = Path.GetFileNameWithoutExtension(relativePath);

            var previewPath = Path.Combine(outDir, filename + ".gif");
            SavePreview(tIndices, tData.Stride, translatedBmp.Width, translatedBmp.Height, tim.Cluts, previewPath);

            var diffPath = Path.Combine(outDir, filename + "_diff.png");
            SaveDiff(tim, meta, tIndices, tData.Stride, translatedBmp.Width, translatedBmp.Height, diffPath);

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

    private static void SaveDiff(TimPixelHelper.TimPixelData tim, ImageMeta meta,
        byte[] translatedIndices, int tStride, int tWidth, int tHeight, string path)
    {
        using var diffBmp = new Bitmap(tWidth, tHeight, PixelFormat.Format24bppRgb);
        var rect = new Rectangle(0, 0, tWidth, tHeight);
        var diffData = diffBmp.LockBits(rect, ImageLockMode.WriteOnly, diffBmp.PixelFormat);
        var diffPixels = new byte[diffData.Stride * tHeight];

        var srcYOff = meta.RectV ?? 0;
        var srcXOff = meta.RectU ?? 0;

        for (var y = 0; y < tHeight; y++)
        {
            for (var x = 0; x < tWidth; x++)
            {
                var orig = tim.PixelIndices[(srcYOff + y) * tim.Stride + (srcXOff + x)];
                var trans = translatedIndices[y * tStride + x];
                var same = orig == trans;
                var off = y * diffData.Stride + x * 3;
                var v = same ? (byte)255 : (byte)0;
                diffPixels[off] = v;
                diffPixels[off + 1] = v;
                diffPixels[off + 2] = v;
            }
        }
        Marshal.Copy(diffPixels, 0, diffData.Scan0, diffPixels.Length);
        diffBmp.UnlockBits(diffData);

        diffBmp.Save(path, ImageFormat.Png);
    }
}
