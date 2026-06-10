using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using SummonNightLib;

public static class WriteBackMapname
{
    public static byte[] Apply(byte[] data, string translatedDir, string originalMapnamesDir)
    {
        if (!Directory.Exists(translatedDir))
        {
            Console.WriteLine($"mapnames_translated not found: {translatedDir}");
            return data;
        }

        var modified = new byte[data.Length];
        Buffer.BlockCopy(data, 0, modified, 0, data.Length);

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

            var sectorOffset = ExtractUtil.ReadUShort(modified, 0x10 + mapIndex * 4);
            var sectorLen = ExtractUtil.ReadUShort(modified, 0x10 + mapIndex * 4 + 2);
            var fileOffset = sectorOffset * 0x800;
            var fileLen = sectorLen * 0x800;

            if (fileOffset + 12 > modified.Length)
            {
                Console.WriteLine($"  Skipping mapname{mapIndex}: invalid sector offset");
                continue;
            }

            var clut = BitConverter.ToInt32(modified, fileOffset + 4);
            var pix = BitConverter.ToInt32(modified, fileOffset + 8);
            if (clut <= 0 || pix <= 0 || fileOffset + pix + 4 > fileOffset + fileLen)
            {
                Console.WriteLine($"  Skipping mapname{mapIndex}: invalid TIM offsets");
                continue;
            }

            var clutW = BitConverter.ToUInt16(modified, fileOffset + clut);
            var bit4 = clutW != 256;

            var pixW = BitConverter.ToUInt16(modified, fileOffset + pix);
            var pixH = BitConverter.ToUInt16(modified, fileOffset + pix + 2);
            var pixDataOffset = fileOffset + pix + 4;
            var pixBytesPerRow = pixW * 2;
            var totalPixBytes = pixBytesPerRow * pixH;

            if (pixDataOffset + totalPixBytes > modified.Length)
            {
                Console.WriteLine($"  Skipping mapname{mapIndex}: pixel data out of bounds");
                continue;
            }

            using var translatedBmp = new Bitmap(file);
            if (translatedBmp.PixelFormat != PixelFormat.Format8bppIndexed)
            {
                throw new InvalidOperationException(
                    $"mapname{mapIndex}: translated GIF is not 8bpp indexed (got {translatedBmp.PixelFormat})");
            }

            var expectedWidth = bit4 ? pixBytesPerRow * 2 : pixBytesPerRow;
            if (translatedBmp.Width != expectedWidth || translatedBmp.Height != pixH)
            {
                throw new InvalidOperationException(
                    $"mapname{mapIndex}: size mismatch - translated {translatedBmp.Width}x{translatedBmp.Height} vs expected {expectedWidth}x{pixH} ({(bit4 ? "4bpp" : "8bpp")})");
            }

            var rect = new Rectangle(0, 0, translatedBmp.Width, translatedBmp.Height);
            var bmpData = translatedBmp.LockBits(rect, ImageLockMode.ReadOnly, translatedBmp.PixelFormat);
            var indices = new byte[bmpData.Stride * bmpData.Height];
            Marshal.Copy(bmpData.Scan0, indices, 0, indices.Length);
            translatedBmp.UnlockBits(bmpData);

            var newPixData = new byte[totalPixBytes];
            for (var y = 0; y < pixH; y++)
            {
                for (var x = 0; x < pixBytesPerRow; x++)
                {
                    if (bit4)
                    {
                        var lo = indices[y * bmpData.Stride + x * 2] & 0xF;
                        var hi = indices[y * bmpData.Stride + x * 2 + 1] & 0xF;
                        newPixData[y * pixBytesPerRow + x] = (byte)(lo | (hi << 4));
                    }
                    else
                    {
                        newPixData[y * pixBytesPerRow + x] = indices[y * bmpData.Stride + x];
                    }
                }
            }

            Buffer.BlockCopy(newPixData, 0, modified, pixDataOffset, totalPixBytes);
            Console.WriteLine($"  Wrote mapname{mapIndex}: {totalPixBytes} bytes ({(bit4 ? "4bpp" : "8bpp")}) at offset 0x{pixDataOffset:X}");
        }

        return modified;
    }
}
