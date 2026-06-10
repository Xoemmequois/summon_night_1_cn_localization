using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using SummonNightLib;

public static class PreviewMapname
{
    public static void Generate(byte[] data, string translatedDir, string outputDir, string originalMapnamesDir)
    {
        if (!Directory.Exists(translatedDir))
        {
            Console.WriteLine($"mapnames_translated not found: {translatedDir}");
            return;
        }

        Directory.CreateDirectory(outputDir);

        foreach (var file in Directory.GetFiles(translatedDir, "mapname*.gif"))
        {
            var filename = Path.GetFileNameWithoutExtension(file);
            if (!filename.StartsWith("mapname") || !int.TryParse(filename.AsSpan(7), out var mapIndex))
            {
                Console.WriteLine($"  Skipping unrecognized file: {file}");
                continue;
            }

            var originalFile = Path.Combine(originalMapnamesDir, $"mapname{mapIndex}.gif");
            if (!File.Exists(originalFile))
            {
                Console.WriteLine($"  Skipping mapname{mapIndex}: no corresponding original GIF found");
                continue;
            }

            var subData = ExtractUtil.GetSubcontent(data, mapIndex);
            using var origBmp = ParseTim(subData, 0, false);
            if (origBmp == null)
            {
                Console.WriteLine($"  Skipping mapname{mapIndex}: failed to parse original TIM");
                continue;
            }

            using var translatedBmp = new Bitmap(file);
            if (translatedBmp.PixelFormat != PixelFormat.Format8bppIndexed)
            {
                throw new InvalidOperationException(
                    $"mapname{mapIndex}: translated GIF is not 8bpp indexed (got {translatedBmp.PixelFormat})");
            }

            if (translatedBmp.Width != origBmp.Width || translatedBmp.Height != origBmp.Height)
            {
                throw new InvalidOperationException(
                    $"mapname{mapIndex}: size mismatch - translated {translatedBmp.Width}x{translatedBmp.Height} vs original {origBmp.Width}x{origBmp.Height}");
            }

            var rect = new Rectangle(0, 0, translatedBmp.Width, translatedBmp.Height);
            var bmpData = translatedBmp.LockBits(rect, ImageLockMode.ReadOnly, translatedBmp.PixelFormat);
            var indices = new byte[bmpData.Stride * bmpData.Height];
            Marshal.Copy(bmpData.Scan0, indices, 0, indices.Length);
            translatedBmp.UnlockBits(bmpData);

            var outBmp = new Bitmap(origBmp.Width, origBmp.Height, PixelFormat.Format8bppIndexed);
            outBmp.Palette = origBmp.Palette;

            var outRect = new Rectangle(0, 0, outBmp.Width, outBmp.Height);
            var outData = outBmp.LockBits(outRect, ImageLockMode.WriteOnly, outBmp.PixelFormat);
            for (var y = 0; y < outBmp.Height; y++)
            {
                Marshal.Copy(indices, y * bmpData.Stride,
                    IntPtr.Add(outData.Scan0, y * outData.Stride), outBmp.Width);
            }
            outBmp.UnlockBits(outData);

            var outputPath = Path.Combine(outputDir, $"mapname{mapIndex}.gif");
            outBmp.Save(outputPath, ImageFormat.Gif);
            Console.WriteLine($"  Generated preview: {outputPath}");
        }
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
}
