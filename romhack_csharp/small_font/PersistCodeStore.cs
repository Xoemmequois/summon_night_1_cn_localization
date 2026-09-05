using System.Text.Json;

namespace small_font;

public static class PersistCodeStore
{
    private const int MapIndexMin = 524;
    private const int MapIndexMax = 4607;

    /// <summary>
    /// 读取持久化编码表 (char → SJIS)。文件不存在 → 空表 (首次构建)。
    /// JSON 整体损坏 → 抛异常; 单条非法 → 警告跳过。
    /// </summary>
    public static Dictionary<char, ushort> Load(string path)
    {
        var result = new Dictionary<char, ushort>();
        if (!File.Exists(path))
        {
            Console.WriteLine($"PersistCodes: {Path.GetFileName(path)} not found (first build), no pinning");
            return result;
        }

        var raw = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path))
                  ?? throw new InvalidOperationException(
                      $"{path}: invalid JSON, expected object of char -> \"0xXXXX\"");

        var usedCodes = new HashSet<ushort>();
        foreach (var (key, value) in raw)
        {
            if (key.Length != 1)
            {
                Console.WriteLine($"PersistCodes: warning - skip invalid key '{key}'");
                continue;
            }

            if (!TryParseCode(value, out var sjis))
            {
                Console.WriteLine($"PersistCodes: warning - skip '{key}': unparseable code '{value}'");
                continue;
            }

            var mapIndex = SjisToMapIndex(sjis);
            if (mapIndex is < MapIndexMin or > MapIndexMax)
            {
                Console.WriteLine(
                    $"PersistCodes: warning - skip '{key}': code 0x{sjis:X4} -> mapIndex {mapIndex}, " +
                    $"outside [{MapIndexMin},{MapIndexMax}]");
                continue;
            }

            if (!usedCodes.Add(sjis))
            {
                Console.WriteLine(
                    $"PersistCodes: warning - skip '{key}': code 0x{sjis:X4} already used by another char");
                continue;
            }

            result[key[0]] = sjis;
        }

        Console.WriteLine($"PersistCodes: loaded {result.Count} entries from {Path.GetFileName(path)}");
        return result;
    }

    /// <summary>
    /// 合并写回: 旧条目保留, currentChars 中每个字符更新为 charMap 实际分配的编码。
    /// 被写回的文件不携带 Load 时被警告跳过的非法条目 (下次构建自动清理)。
    /// </summary>
    public static void Save(
        string path,
        IReadOnlyDictionary<char, ushort> oldCodes,
        IEnumerable<char> currentChars,
        Dictionary<char, (ushort Sjis, ushort Index)> charMap)
    {
        var merged = new Dictionary<string, string>();
        foreach (var pair in oldCodes)
        {
            merged[pair.Key.ToString()] = $"0x{pair.Value:X4}";
        }

        var updated = 0;
        foreach (var ch in currentChars)
        {
            if (!charMap.TryGetValue(ch, out var entry)) continue;
            merged[ch.ToString()] = $"0x{entry.Sjis:X4}";
            updated++;
        }

        var options = new JsonSerializerOptions { WriteIndented = true };
        File.WriteAllText(path, JsonSerializer.Serialize(merged, options));
        Console.WriteLine(
            $"PersistCodes: wrote {merged.Count} entries ({updated} current) -> {Path.GetFileName(path)}");
    }

    /// <summary>IndexToSjis 的逆换算: lead=低字节(0x81~0x99), trail=高字节。</summary>
    public static int SjisToMapIndex(ushort sjis)
    {
        var lead = sjis & 0xFF;
        var trail = sjis >> 8;
        return (lead - 0x81) * 0xC0 + (trail - 0x40);
    }

    private static bool TryParseCode(string value, out ushort sjis)
    {
        sjis = 0;
        if (string.IsNullOrEmpty(value) || !value.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
            return false;
        return ushort.TryParse(value[2..], System.Globalization.NumberStyles.HexNumber, null, out sjis);
    }
}
