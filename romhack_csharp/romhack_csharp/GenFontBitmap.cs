using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;


namespace romhack_csharp;

public static class GenFontBitmap
{
    public static void GenerateFontBitmap(char ch, byte[] output)
    {
        if (output is null)
        {
            throw new ArgumentNullException(nameof(output));
        }

        if (output.Length != 28)
        {
            throw new ArgumentException("output length must be 28 bytes.", nameof(output));
        }

        Array.Clear(output, 0, output.Length);

        using var bitmap = new Bitmap(14, 14, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.White);
        graphics.SmoothingMode = SmoothingMode.None;
        graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
        graphics.PixelOffsetMode = PixelOffsetMode.None;
        graphics.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;

        using var font = new Font("SimSun", 14, FontStyle.Regular, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(Color.Black);
        using var format = StringFormat.GenericTypographic;
        format.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces;
        graphics.DrawString(ch.ToString(), font, brush, new PointF(0, 0), format);

        for (var y = 0; y < 14; y++)
        {
            for (var x = 0; x < 14; x++)
            {
                var color = bitmap.GetPixel(x, y);
                if (color.R >= 128 && color.G >= 128 && color.B >= 128)
                {
                    continue;
                }

                var xOut = x + 1; // left padding
                var bitIndex = 15 - xOut;
                var byteIndex = y * 2 + (1 - bitIndex / 8);
                var bitMask = (byte)(1 << (bitIndex % 8));
                output[byteIndex] |= bitMask;
            }
        }
    } 

    public static void PrintFontBitmap(byte[] glyph)
    {
        if (glyph is null)
        {
            throw new ArgumentNullException(nameof(glyph));
        }

        if (glyph.Length != 28)
        {
            throw new ArgumentException("glyph length must be 28 bytes.", nameof(glyph));
        }

        for (var y = 0; y < 14; y++)
        {
            var rowIndex = y * 2;
            var row = (ushort)((glyph[rowIndex] << 8) | glyph[rowIndex + 1]);
            var line = new char[16];
            for (var x = 0; x < 16; x++)
            {
                var bit = (row >> (15 - x)) & 1;
                line[x] = bit == 1 ? '█' : '　';
            }

            Console.WriteLine(line);
        }
    }
}
