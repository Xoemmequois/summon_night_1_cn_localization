using System.Text.Json;
using SummonNightLib;

namespace small_font;

public static class RomTextWriter
{
    /// <summary>
    /// 将翻译文本编码为 SJIS 并写回 ROM。严格验证字符映射和长度。
    /// </summary>
    public static void WriteRomText(
        byte[] romData,
        string jsonPath,
        Dictionary<char, (ushort Sjis, ushort Index)> charMap,
        List<int> validStages)
    {
        var json = File.ReadAllText(jsonPath);
        var items = JsonSerializer.Deserialize<List<TranslationItem>>(json) ?? new();

        foreach (var item in items)
        {
            if (!validStages.Contains(item.Stage)) continue;
            if (string.IsNullOrEmpty(item.Translation)) continue;

            var parts = item.Key.Split("-0x");
            if (parts.Length < 2) continue;
            var hexPart = parts[^1];
            if (!int.TryParse(hexPart,
                    System.Globalization.NumberStyles.HexNumber,
                    null, out var offset)) continue;

            var nullPos = offset;
            while (nullPos < romData.Length - 1 &&
                   !(romData[nullPos] == 0x00 && romData[nullPos + 1] == 0x00))
                nullPos += 2;
            var origByteLen = nullPos - offset + 2;

            var newBytes = new List<byte>();
            foreach (var ch in item.Translation)
            {
                if (ch == '@')
                {
                    newBytes.Add(0x40);
                    newBytes.Add(0x00);
                    continue;
                }

                if (ch == 'n')
                {
                    newBytes.Add(0x6E);
                    newBytes.Add(0x00);
                    continue;
                }

                if (!charMap.TryGetValue(ch, out var m))
                    throw new InvalidOperationException(
                        $"Character '{ch}' (U+{(int)ch:X4}) not in small font map. " +
                        $"At offset 0x{offset:X} key={item.Key}");

                newBytes.Add((byte)(m.Sjis & 0xFF));
                newBytes.Add((byte)(m.Sjis >> 8));
            }

            newBytes.Add(0x00);
            newBytes.Add(0x00);

            if (newBytes.Count > origByteLen)
                throw new InvalidOperationException(
                    $"Translation too long at 0x{offset:X} key={item.Key}: " +
                    $"{newBytes.Count} bytes > {origByteLen} bytes");

            Array.Copy(newBytes.ToArray(), 0, romData, offset, newBytes.Count);
        }

        Console.WriteLine($"RomTextWriter: patched ROM text in-place");
    }
}
