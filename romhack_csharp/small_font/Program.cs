using System.Drawing;
using System.Drawing.Imaging;
using System.Text;
using romhack_csharp;
using SummonNightLib;

var data = File.ReadAllBytes("rom/CM1200.DAT");
var subContent = ExtractUtil.GetSubcontent(data, 8);

const int mapStart = 0x28E0;
const int glyphStart = 0x4CE0;
const int glyphSize = 18;

const int charWidth = 12;
const int charHeight = 12;

// 注册 Shift-JIS 编码提供程序 (for .NET 8.0)
Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
var sjis = Encoding.GetEncoding("shift-jis");

string outputDir = "exported_glyphs";
if (!Directory.Exists(outputDir))
{
    Directory.CreateDirectory(outputDir);
}

for (int i = 0; i < (glyphStart - mapStart); i += 2)
{
    int indexInMap = i / 2;
    int glyphIndex = BitConverter.ToUInt16(subContent, mapStart + i);
    
    if (glyphIndex == 0) continue;

    // 计算 SHIFT-JIS 字符
    // 每个双字节所处的下标i，取模0xC0后加上0x40是高位，除以0xC0后加上0x81是低位
    // 注意：这里 i 是相对于 mapStart 的偏移，即 0, 2, 4...
    // 但原话中的 "下标i" 通常指元素序号或偏移量，这里我们按元素序号或字节偏移量来尝试。
    // 如果是字节偏移量 i:
    byte high = (byte)((indexInMap % 0xC0) + 0x40);
    byte low = (byte)((indexInMap / 0xC0) + 0x81);
    
    byte[] sjisBytes = new byte[] { low, high }; // SHIFT-JIS 通常是 low (lead) then high (trail)
    string charName = sjis.GetString(sjisBytes);
    
    // 清理非法文件名字符
    foreach (char c in Path.GetInvalidFileNameChars())
    {
        charName = charName.Replace(c, '_');
    }

    int glyphOffset = glyphStart + glyphIndex * glyphSize;
    if (glyphOffset + glyphSize > subContent.Length)
    {
        Console.WriteLine($"Warning: Glyph {glyphIndex} for char {charName} is out of bounds. Skipping.");
        continue;
    }

    using var bitmap = new Bitmap(charWidth, charHeight, PixelFormat.Format32bppArgb);
    DrawGlyph(bitmap, subContent, glyphOffset, 0, 0);
    
    string fileName = Path.Combine(outputDir, $"{charName}.png");
    // 如果文件名冲突，可以加一个索引
    if (File.Exists(fileName))
    {
         fileName = Path.Combine(outputDir, $"{charName}_{glyphIndex}.png");
    }
    bitmap.Save(fileName, ImageFormat.Png);
}

Console.WriteLine("Done! Glyphs exported to exported_glyphs folder.");

static void DrawGlyph(Bitmap bitmap, byte[] subContent, int offset, int startX, int startY)
{
    ushort[] puVar1 = new ushort[9];
    for (int i = 0; i < 9; i++)
    {
        puVar1[i] = BitConverter.ToUInt16(subContent, offset + i * 2);
    }

    ushort[] lines = new ushort[12];
    lines[0] = (ushort)(puVar1[0] >> 4);
    lines[1] = (ushort)((puVar1[0] & 0xf) << 8 | puVar1[1] >> 8);
    lines[2] = (ushort)((puVar1[1] & 0xff) << 4 | puVar1[2] >> 12);
    lines[3] = (ushort)(puVar1[2] & 0xfff);
    
    lines[4] = (ushort)(puVar1[3] >> 4);
    lines[5] = (ushort)((puVar1[3] & 0xf) << 8 | puVar1[4] >> 8);
    lines[6] = (ushort)((puVar1[4] & 0xff) << 4 | puVar1[5] >> 12);
    lines[7] = (ushort)(puVar1[5] & 0xfff);
    
    lines[8] = (ushort)(puVar1[6] >> 4);
    lines[9] = (ushort)((puVar1[6] & 0xf) << 8 | puVar1[7] >> 8);
    lines[10] = (ushort)((puVar1[7] & 0xff) << 4 | puVar1[8] >> 12);
    lines[11] = (ushort)(puVar1[8] & 0xfff);

    for (int y = 0; y < 12; y++)
    {
        ushort lineData = lines[y];
        for (int x = 0; x < 12; x++)
        {
            bool isSet = (lineData & (0x800 >> x)) != 0;
            if (isSet)
            {
                bitmap.SetPixel(startX + x, startY + y, Color.Black);
            }
        }
    }
}

new RomTextRipper().Rip();