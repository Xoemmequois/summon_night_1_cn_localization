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
    // 共享区: code 0x8540~0x87FF ↔ mapIndex 768~1343 (IndexToSjis 线性反推)
    private const int SharedMapIndexStart = 768;
    private const int SharedMapIndexEnd = 1343;
    // GlyphIndexBase: ceil((0x801B1000 - 0x801ACCE0) / 18) = 955 = 0x3BB
    // 0x3BB * 18 = 0x4326, 0x801ACCE0 + 0x4326 = 0x801B1006 → S.F 前 6 字节 padding
    private const int GlyphIndexBase = 0x3BB;
    public const int SfPadding = GlyphIndexBase * 18 - (int)(0x801B1000u - 0x801ACCE0u);
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
        List<int> validStages,
        IReadOnlyList<char> sharedChars,
        IReadOnlyDictionary<char, ushort>? persistedCodes = null)
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
        var ownChars = neededChars.Where(c => !sharedChars.Contains(c)).ToList();
        var charList = sharedChars.Concat(ownChars).ToList();
        Console.WriteLine(
            $"SmallFont: {charList.Count} unique characters needed ({sharedChars.Count} shared)");

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

        // 四阶段分配: 共享预钉 → 共享游标 → 自有预钉 → 自有游标.
        // usedIndices 记录本次构建已占用的 mapIndex, 预钉与游标共用, 防止碰撞.
        // (原实现边分配边写 subContent, 现在延迟到字形循环统一写, 用 usedIndices 代替.)
        var usedIndices = new HashSet<int>();
        var mapIdxByChar = new Dictionary<char, int>();
        var sharedCursor = SharedMapIndexStart;
        var ownCursor = MapIndexStart;
        var kept = 0;
        var changed = 0;
        var warned = new List<(char Ch, ushort PrevSjis, int PrevIdx)>();

        bool IsSlotFree(int mapIdx) =>
            ExtractUtil.ReadUShort(subContent, mapStartInSub + mapIdx * 2) == 0 &&
            !usedIndices.Contains(mapIdx);

        // 预钉: 有持久化编码且区域/槽位允许 → 占位. 返回 true = 该字符仍需游标分配.
        bool Pin(char ch, int mapIndexMin, int mapIndexMax)
        {
            if (persistedCodes == null || !persistedCodes.TryGetValue(ch, out var prevSjis))
                return true;
            var prevIdx = PersistCodeStore.SjisToMapIndex(prevSjis);
            if (prevIdx >= mapIndexMin && prevIdx <= mapIndexMax && IsSlotFree(prevIdx))
            {
                usedIndices.Add(prevIdx);
                mapIdxByChar[ch] = prevIdx;
                kept++;
                return false;
            }
            changed++;
            warned.Add((ch, prevSjis, prevIdx));
            return true;
        }

        // 阶段 1: 共享预钉 (编码必须落在共享区 [768,1343], code 0x8540-0x87FF)
        for (var i = 0; i < sharedChars.Count; i++)
        {
            Pin(sharedChars[i], SharedMapIndexStart, SharedMapIndexEnd);
        }

        // 阶段 2: 共享游标兜底
        foreach (var ch in sharedChars)
        {
            if (mapIdxByChar.ContainsKey(ch)) continue;

            while (sharedCursor <= SharedMapIndexEnd && !IsSlotFree(sharedCursor))
            {
                sharedCursor++;
            }

            if (sharedCursor > SharedMapIndexEnd)
                throw new InvalidOperationException(
                    $"Shared region exhausted! Need {sharedChars.Count} shared chars, " +
                    $"allocated only {mapIdxByChar.Count}. Region mapIndex [{SharedMapIndexStart}-" +
                    $"{SharedMapIndexEnd}] (code 0x8540-0x87FF)");

            usedIndices.Add(sharedCursor);
            mapIdxByChar[ch] = sharedCursor;
            sharedCursor++;
        }

        // 阶段 3: 自有预钉 ([524,4607], 允许落入共享区——只要阶段 1/2 没占掉)
        foreach (var ch in ownChars)
        {
            Pin(ch, MapIndexStart, MapIndexEnd - 1);
        }

        // 阶段 4: 自有游标兜底
        foreach (var ch in ownChars)
        {
            if (mapIdxByChar.ContainsKey(ch)) continue;

            while (ownCursor < MapIndexEnd && !IsSlotFree(ownCursor))
            {
                ownCursor++;
            }

            if (ownCursor >= MapIndexEnd)
                throw new InvalidOperationException(
                    $"No more free map entries! Needed {charList.Count} chars, " +
                    $"allocated only {mapIdxByChar.Count}. Total map entries: {MapIndexEnd}");

            usedIndices.Add(ownCursor);
            mapIdxByChar[ch] = ownCursor;
            ownCursor++;
        }

        foreach (var (ch, prevSjis, prevIdx) in warned)
        {
            var newIdx = mapIdxByChar[ch];
            Console.WriteLine(
                $"PersistCodes: warning - '{ch}' previous code " +
                $"0x{PersistCodeStore.ToDisplayCode(prevSjis):X4} (mapIndex {prevIdx}) " +
                $"cannot be kept, reassigned to " +
                $"0x{PersistCodeStore.ToDisplayCode(IndexToSjis(newIdx)):X4} (mapIndex {newIdx}). " +
                $"Old saves may garble this char.");
        }
        Console.WriteLine($"PersistCodes: kept {kept}, changed {changed}");

        for (var i = 0; i < charList.Count; i++)
        {
            var ch = charList[i];
            var mapIdx = mapIdxByChar[ch];

            Encode12x12Glyph(ch, glyphBuf);
            Array.Copy(glyphBuf, 0, glyphData, SfPadding + i * 18, 18);

            var sjis = IndexToSjis(mapIdx);
            var glyphIdx = (ushort)(GlyphIndexBase + i);
            charMap[ch] = (sjis, glyphIdx);

            var writeBuf = new byte[2];
            writeBuf[0] = (byte)(glyphIdx & 0xFF);
            writeBuf[1] = (byte)((glyphIdx >> 8) & 0xFF);
            Buffer.BlockCopy(writeBuf, 0, subContent, mapStartInSub + mapIdx * 2, 2);
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
            (sharedChars.Count > 0
                ? $"shared mapIdx [{SharedMapIndexStart}..{sharedCursor - 1}], "
                : "") +
            $"own last mapIdx={ownCursor - 1}");

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
