using System.Drawing;
using System.Drawing.Imaging;
using romhack_csharp;
using SummonNightLib;

var data = File.ReadAllBytes("rom/CM1200.DAT");
var subContent = ExtractUtil.GetSubcontent(data, 8);

const int mapStart = 0x28E0;
const int glyphStart = 0x4CE0;
const int glyphSize = 18;

int maxIndex = 0;
for (int i = mapStart; i < glyphStart; i += 2)
{
    int index = BitConverter.ToUInt16(subContent, i);
    if (index > maxIndex) maxIndex = index;
}

Console.WriteLine($"Max index found in mapping table: {maxIndex}");

int glyphCount = maxIndex + 1;
int charsPerRow = 8;
int charWidth = 12;
int charHeight = 12;
int rows = (glyphCount + charsPerRow - 1) / charsPerRow;

using var bitmap = new Bitmap(charsPerRow * charWidth, rows * charHeight, PixelFormat.Format32bppArgb);
using (var g = Graphics.FromImage(bitmap))
{
    g.Clear(Color.Transparent);
}

for (int i = 0; i < glyphCount; i++)
{
    int glyphOffset = glyphStart + i * glyphSize;
    if (glyphOffset + glyphSize > subContent.Length)
    {
        Console.WriteLine($"Warning: Glyph {i} is out of bounds. Skipping.");
        break;
    }

    int row = i / charsPerRow;
    int col = i % charsPerRow;
    int startX = col * charWidth;
    int startY = row * charHeight;

    DrawGlyph(bitmap, subContent, glyphOffset, startX, startY);
}

bitmap.Save("small_font.png", ImageFormat.Png);
Console.WriteLine("Done! small_font.png saved.");

static void DrawGlyph(Bitmap bitmap, byte[] subContent, int offset, int startX, int startY)
{
    // 参考反汇编代码逻辑生成字形
    // 每个字形18字节，分为12行，每行12位。
    // 数据以 ushort (16位) 数组形式访问
    
    ushort[] puVar1 = new ushort[9];
    for (int i = 0; i < 9; i++)
    {
        // PS1 是小端序，这里读取 16 位无符号整数
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
            // 在 12 位的 lineData 中，高位在左
            bool isSet = (lineData & (0x800 >> x)) != 0;
            if (isSet)
            {
                bitmap.SetPixel(startX + x, startY + y, Color.Black);
            }
        }
    }
}

new RomTextRipper().Rip();