// See https://aka.ms/new-console-template for more information

using System.Diagnostics;
using System.Drawing;
using SummonNightLib;

Color[] ParseCluts(byte[] subData, int offset, int clutW, int clutH)
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

Bitmap ParsePix(byte[] subData, int offset, int pixW, int pixH, Color[] cluts, bool bit4)
{
    pixW *= 2;
    var bitmap = new Bitmap(bit4 ? pixW * 2 : pixW, pixH);
    for (var y = 0; y < pixH; y++)
    {
        for (var x = 0; x < pixW; x++)
        {
            var index = subData[offset + y * pixW + x];
            if (bit4)
            {
                bitmap.SetPixel(x * 2, y, cluts[(index) & 0xF]);
                bitmap.SetPixel(x * 2 + 1, y, cluts[(index >> 4) & 0xF]);
            }
            else
            {
                bitmap.SetPixel(x, y, cluts[index]);
            }
            
        }
    }
    return bitmap;
}


void Parse(byte[] subData, int offset, string suffix)
{
    var header = BitConverter.ToInt32(subData, offset);
    var clut = BitConverter.ToInt32(subData, offset + 4);
    var clutW = BitConverter.ToUInt16(subData, clut + offset);
    var clutH = BitConverter.ToUInt16(subData, clut + offset + 2);
    var pix = BitConverter.ToInt32(subData, offset + 8);
    var pixW = BitConverter.ToUInt16(subData, pix + offset);
    var pixH = BitConverter.ToUInt16(subData, pix + offset + 2);
    Console.WriteLine($"Header {header} Clut {clut:x8} {clutW}*{clutH} Pix {pix:x8} {pixW}*{pixH}");
    var cluts = ParseCluts(subData, offset + clut + 4, clutW, clutH);
    var bitmap = ParsePix(subData, offset + pix + 4, pixW, pixH, cluts, clutW != 256);
    bitmap.Save($"test_{suffix}.png");
}

var data = File.ReadAllBytes("rom/CM3000.DAT");
var subData = ExtractUtil.GetSubcontent(data, 0x89 + 0x3e);
// 以人类可读的方式输出subData 前0x50 个字节的内容
for (var i = 0; i < 0x50; i += 16)
{
    var count = Math.Min(16, 0x50 - i);
    var hex = BitConverter.ToString(subData, i, count).Replace("-", " ");
    Console.WriteLine($"{i:X4}: {hex}");
}
var k = BitConverter.ToInt32(subData, 4);
for (var i = 1; i <= 2; ++i)
{
    var offset = BitConverter.ToInt32(subData, i * 4);
    Console.WriteLine($"{i*4:X4} Offset {offset :X4}");
    Parse(subData, offset, $"_{i}");
}


var subContent = ExtractUtil.GetSubcontent(data, 0x2E);
Parse(subContent, 0, "mapname");