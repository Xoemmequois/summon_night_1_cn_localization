using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Text.Json;
using SummonNightLib;

namespace small_font;

public static class SmallFontBuilder
{
    private const int MapIndexEnd = 4608;
    private const int MapIndexStart = 524;
    // GlyphIndexBase: ceil((0x801B1000 - 0x801ACCE0) / 18) = 955 = 0x3BB
    // 0x3BB * 18 = 0x4326, 0x801ACCE0 + 0x4326 = 0x801B1006 → S.F 前 6 字节 padding
    private const int GlyphIndexBase = 0x3BB;
    private const int SfPadding = GlyphIndexBase * 18 - (int)(0x801B1000u - 0x801ACCE0u);
    private const uint SmallFontRamBase = 0x801B1000u;
    private const uint SmallFontRamEnd = 0x801B8000u;

    /// <summary>
    /// 完整构建流程: 渲染字形 → 输出 S.F → 修补 CM1200 map table → 返回字符映射
    /// </summary>
    public static Dictionary<char, (ushort Sjis, ushort Index)> Build(
        string romTextJsonPath,
        string cm1200Path,
        string outputSfPath,
        string outputCm1200Path,
        List<int> validStages)
    {
        // 1. 读取翻译, 提取需要的新汉字
        var json = File.ReadAllText(romTextJsonPath);
        var items = JsonSerializer.Deserialize<List<TranslationItem>>(json) ?? new();
        var neededChars = new HashSet<char>();
        foreach (var item in items)
        {
            if (!validStages.Contains(item.Stage)) continue;
            if (string.IsNullOrEmpty(item.Translation)) continue;
            foreach (var ch in item.Translation)
            {
                if (ch == '@' || ch == 'n') continue;
                neededChars.Add(ch);
            }
        }
        var charList = neededChars.ToList();
        Console.WriteLine($"SmallFont: {charList.Count} unique characters needed");

        // 2. 读 CM1200.DAT subcontent 8
        var cm1200 = File.ReadAllBytes(cm1200Path);
        var subContent = ExtractUtil.GetSubcontent(cm1200, 8);
        const int mapStartInSub = 0x28E0;

        // 3. 渲染字形 + 写 S.F + 分配 map 条目
        // S.F: 前 6 字节 padding（因为 GlyphIndexBase=0x3BB, 第一个 glyph 地址=0x801B1006）
        var glyphCount = charList.Count;
        if (SmallFontRamBase + (uint)(SfPadding + glyphCount * 18) > SmallFontRamEnd)
        {
            var glyphBytes = (SmallFontRamEnd - SmallFontRamBase - (uint)SfPadding) / 18;
            throw new InvalidOperationException(
                $"S.F 过大: {glyphCount} 字 ×18B + padding {SfPadding}B = {SfPadding + glyphCount * 18} 字节, " +
                $"装载 0x{SmallFontRamBase:X}~0x{SmallFontRamBase + (uint)(SfPadding + glyphCount * 18):X} " +
                $"超过上限 0x{SmallFontRamEnd:X}. 可用 {SmallFontRamEnd - SmallFontRamBase} 字节, " +
                $"扣除 padding 后最多 {glyphBytes} 字");
        }
        var glyphData = new byte[SfPadding + glyphCount * 18];
        var glyphBuf = new byte[18];
        var charMap = new Dictionary<char, (ushort Sjis, ushort Index)>();
        int mapIdx = MapIndexStart;

        for (var i = 0; i < charList.Count; i++)
        {
            while (mapIdx < MapIndexEnd)
            {
                var existing = ExtractUtil.ReadUShort(subContent, mapStartInSub + mapIdx * 2);
                if (existing == 0) break;
                mapIdx++;
            }

            if (mapIdx >= MapIndexEnd)
                throw new InvalidOperationException(
                    $"No more free map entries! Needed {charList.Count} chars, " +
                    $"allocated only {i}. Total map entries: {MapIndexEnd}");

            Encode12x12Glyph(charList[i], glyphBuf);
            Array.Copy(glyphBuf, 0, glyphData, SfPadding + i * 18, 18);

            var sjis = IndexToSjis(mapIdx);
            var glyphIdx = (ushort)(GlyphIndexBase + i);
            charMap[charList[i]] = (sjis, glyphIdx);

            var writeBuf = new byte[2];
            writeBuf[0] = (byte)(glyphIdx & 0xFF);
            writeBuf[1] = (byte)((glyphIdx >> 8) & 0xFF);
            Buffer.BlockCopy(writeBuf, 0, subContent, mapStartInSub + mapIdx * 2, 2);

            mapIdx++;
        }

        // 4. 将修改后的 subContent 写回 CM1200
        var subHdr = 0x10 + 8 * 4;
        var sectOff = ExtractUtil.ReadUShort(cm1200, subHdr);
        var contentStart = sectOff * 0x800;
        Buffer.BlockCopy(subContent, 0, cm1200, contentStart, subContent.Length);

        // 5. 输出文件
        File.WriteAllBytes(outputSfPath, glyphData);
        File.WriteAllBytes(outputCm1200Path, cm1200);

        Console.WriteLine(
            $"SmallFont: {charList.Count} glyphs, " +
            $"S.F={glyphData.Length} bytes, " +
            $"CM1200 patched with last mapIdx={mapIdx - 1}");

        return charMap;
    }

    private static void Encode12x12Glyph(char ch, byte[] output)
    {
        Array.Clear(output, 0, 18);

        using var bitmap = new Bitmap(12, 12, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bitmap);
        g.Clear(Color.White);
        g.SmoothingMode = SmoothingMode.None;
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        g.PixelOffsetMode = PixelOffsetMode.None;
        g.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;

        using var font = new Font("SimSun", 12, FontStyle.Regular, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(Color.Black);
        using var fmt = StringFormat.GenericTypographic;
        fmt.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces;
        g.DrawString(ch.ToString(), font, brush, new PointF(0, 0), fmt);

        var lines = new ushort[12];
        for (var y = 0; y < 12; y++)
        {
            ushort line = 0;
            for (var x = 0; x < 12; x++)
            {
                var c = bitmap.GetPixel(x, y);
                if (c.R < 128 || c.G < 128 || c.B < 128)
                    line |= (ushort)(0x800 >> x);
            }
            lines[y] = line;
        }

        // Pack: 3 ushorts (48 bits LE) = 4 rows (4x12=48 bits)
        output[0]  = (byte)(((lines[0] & 0xF) << 4) | ((lines[1] >> 8) & 0xF));
        output[1]  = (byte)((lines[0] >> 4) & 0xFF);
        output[2]  = (byte)((lines[2] >> 4) & 0xFF);
        output[3]  = (byte)(lines[1] & 0xFF);
        output[4]  = (byte)(lines[3] & 0xFF);
        output[5]  = (byte)(((lines[2] & 0xF) << 4) | ((lines[3] >> 8) & 0xF));
        output[6]  = (byte)(((lines[4] & 0xF) << 4) | ((lines[5] >> 8) & 0xF));
        output[7]  = (byte)((lines[4] >> 4) & 0xFF);
        output[8]  = (byte)((lines[6] >> 4) & 0xFF);
        output[9]  = (byte)(lines[5] & 0xFF);
        output[10] = (byte)(lines[7] & 0xFF);
        output[11] = (byte)(((lines[6] & 0xF) << 4) | ((lines[7] >> 8) & 0xF));
        output[12] = (byte)(((lines[8] & 0xF) << 4) | ((lines[9] >> 8) & 0xF));
        output[13] = (byte)((lines[8] >> 4) & 0xFF);
        output[14] = (byte)((lines[10] >> 4) & 0xFF);
        output[15] = (byte)(lines[9] & 0xFF);
        output[16] = (byte)(lines[11] & 0xFF);
        output[17] = (byte)(((lines[10] & 0xF) << 4) | ((lines[11] >> 8) & 0xF));
    }

    private static ushort IndexToSjis(int mapIndex)
    {
        var lead = (byte)(0x81 + mapIndex / 0xC0);
        var trail = (byte)(0x40 + mapIndex % 0xC0);
        return (ushort)(lead | (trail << 8));
    }
}
