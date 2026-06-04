using romhack_csharp;
using System.Text.Json;
using SummonNightLib;
using small_font;

internal static class Program
{
    private static readonly Dictionary<(int, int), string> Hash = new();
    private static readonly Dictionary<char, byte[]> Chars = new();
    private static byte[] _cm1100 = Array.Empty<byte>();
    private static int _charIndex;

    private static void Main(string[] args)
    {
        var config = Config.Load(Path.Combine(Directory.GetCurrentDirectory(), "config.json"));
        
        if (args.Contains("--rip") || !Directory.Exists("rom"))
        {
            new GameTextRipper(config).Rip();
            return;
        }

        LoadTranslations(config, "zh_CN_translated.json");
        Console.WriteLine($"Hash entries: {Hash.Count}");

        _cm1100 = File.ReadAllBytes(Path.Combine("rom", "CM1100.DAT"));
        ProcessDialogRange(1, 145);
        File.WriteAllBytes(Path.Combine("rom", "CM1100.DAT.mod2"), _cm1100);

        PrintChars();

        // === 读取 SLPS_025.42, 后续修改全部在内存中进行 ===
        var slps = File.ReadAllBytes(Path.Combine("rom", "SLPS_025.42"));

        // === 小字库构建 ===
        Console.WriteLine("\n--- Building Small Font ---");
        var charMap = SmallFontBuilder.Build(
            Path.Combine(Directory.GetCurrentDirectory(), "rom_text_zh_CN.json"),
            Path.Combine("rom", "CM1200.DAT"),
            Path.Combine("rom", "S.F"),
            Path.Combine("rom", "CM1200.DAT.mod"),
            config.ValidStage);

        RomTextWriter.WriteRomText(
            slps,
            Path.Combine(Directory.GetCurrentDirectory(), "rom_text_zh_CN.json"),
            charMap,
            config.ValidStage);

        var loadSmallBin = ExtraCodeBuilder.GetSmallLoadCodeBinary(
            charMap.Count, config.SdkPath);
        Console.WriteLine($"load_small.bin: {loadSmallBin.Length} bytes");

        // === 大字库构建 ===
        var fontBin = ExtraCodeBuilder.GetFontCodeBinary(config.SdkPath);
        var count = CharCodeToIndex(Chars.MaxBy(pair => (ushort)((pair.Value[0] << 8) | pair.Value[1])).Value) + 1;
        var fontBinStart = (count * 28 + 3) / 4 * 4;
        var smallLoadStart = ((fontBinStart + fontBin.Length) + 3) / 4 * 4;
        var finalLen = smallLoadStart + loadSmallBin.Length;
        var fontBitmaps = new byte[finalLen];
        var fontBitmap = new byte[28];
        foreach (var pair in Chars)
        {
            var index = CharCodeToIndex(pair.Value);
            if (index >= count)
            {
                throw new ApplicationException("index is larger than max, should not happen");
            }
            GenFontBitmap.GenerateFontBitmap(pair.Key, fontBitmap);
            Buffer.BlockCopy(fontBitmap, 0, fontBitmaps, index * 28, 28);
        }
        Buffer.BlockCopy(fontBin, 0, fontBitmaps, fontBinStart, fontBin.Length);
        Buffer.BlockCopy(loadSmallBin, 0, fontBitmaps, smallLoadStart, loadSmallBin.Length);
        File.WriteAllBytes(Path.Combine("rom", "chinese.fnt"), fontBitmaps);

        // === 修改 SLPS_025.42 (load.s + JAL patches) ===
        CodeModifier.ModifyCode(slps, (uint)(0x800D1000u + fontBinStart), fontBitmaps.Length, config.SdkPath,
            (uint)(0x800D1000u + smallLoadStart));

        // === 写入最终 SLPS_025.42.mod2 ===
        File.WriteAllBytes(Path.Combine("rom", "SLPS_025.42.mod2"), slps);
        
        var mkpsxiso = Path.Combine(config.SdkPath, "bin", "mkpsxiso.exe");
        CommandRunner.RunCommand(mkpsxiso, ".\\rom2.xml -y -o .\\output\\Summon_Night_Chinese.bin -c .\\output\\Summon_Night_Chinese.cue");
    }

    private static int CharCodeToIndex(byte[] arr)
    {
        if(arr[0] < 0x88)
        {
            return (arr[0] - 0x85) * 256 + arr[1];
        }
        return (arr[0] - 0x99) * 256 + arr[1] + 256 * 3;
    }

    private static void LoadTranslations(Config config, string jsonPath)
    {
        if (!File.Exists(jsonPath))
        {
            Console.WriteLine($"Warning: {jsonPath} not found.");
            return;
        }

        var jsonText = File.ReadAllText(jsonPath);
        var items = JsonSerializer.Deserialize<List<TranslationItem>>(jsonText);
        if (items == null) return;

        foreach (var item in items)
        {
            if (!config.ValidStage.Contains(item.Stage))
            {
                continue;
            }

            var parts = item.Key.Split('-');
            if (parts.Length == 2 && int.TryParse(parts[0], out var id1) && int.TryParse(parts[1], out var id2))
            {
                Hash[(id1, id2)] = item.Translation;
            }
        }
    }

    private static void ProcessDialogRange(int startId, int endId)
    {
        for (var i = startId; i <= endId; i++)
        {
            ConvertDialogContents(i);
        }
    }

    private static void PrintChars()
    {
        Console.WriteLine("Chars:");
        foreach (var kvp in Chars)
        {
            var bytes = kvp.Value;
            Console.WriteLine($"{kvp.Key} => {bytes[0]:X2} {bytes[1]:X2}");
        }
    }

    private static byte[] GetNextCharId()
    {
        if (_charIndex >= 2560)
        {
            throw new InvalidOperationException("too much characters");
        }

        var c = _charIndex;
        _charIndex += 1;
        if (c < 256 * 3)
        {
            return new[] { (byte)(c / 256 + 0x85), (byte)(c % 256) };
        }

        c -= 256 * 3;
        return new[] { (byte)(c / 256 + 0x99), (byte)(c % 256) };
    }

    private static byte[] GetSubcontent(int id, out int contentStart, out int contentLen)
    {
        var baseOffset = 0x10 + id * 4;
        var offset = ReadUShort(_cm1100, baseOffset);
        var len = ReadUShort(_cm1100, baseOffset + 2);
        contentStart = offset * 0x800;
        contentLen = len * 0x800;
        var contents = new byte[contentLen];
        Buffer.BlockCopy(_cm1100, contentStart, contents, 0, contentLen);
        return contents;
    }

    private static void ConvertDialogContents(int id)
    {
        var contents = GetSubcontent(id + 0x29, out var contentStart, out var contentLen);
        var len = ReadUShort(contents, 0);
        var indices = new ushort[len];
        for (var i = 0; i < len; i++)
        {
            indices[i] = ReadUShort(contents, i * 2);
        }

        var strs = new List<byte[]>();

        for (var i = 0; i < indices.Length; i++)
        {
            var start = indices[i];
            var str = new List<byte>();
            var index = 0;
            while (true)
            {
                var b0 = contents[start * 2 + index];
                var b1 = contents[start * 2 + index + 1];
                if (b0 == 0x00 && b1 == 0x00)
                {
                    break;
                }

                str.Add(b0);
                str.Add(b1);
                index += 2;
            }

            if (Hash.TryGetValue((id, i), out var replacement))
            {
                str.Clear();
                foreach (var ch in replacement)
                {
                    if (ch == '@')
                    {
                        str.Add(0x40);
                        str.Add(0x00);
                        continue;
                    }

                    if (ch == 'n')
                    {
                        str.Add(0x6E);
                        str.Add(0x00);
                        continue;
                    }

                    if (!Chars.TryGetValue(ch, out var mapped))
                    {
                        mapped = GetNextCharId();
                        Chars[ch] = mapped;
                    }

                    str.Add(mapped[0]);
                    str.Add(mapped[1]);
                }
            }

            strs.Add(str.ToArray());
        }

        var strStart = indices[0];
        var newContents = new List<byte>();
        foreach (var str in strs)
        {
            newContents.AddRange(PackUShort(strStart));
            strStart += (ushort)(str.Length / 2 + 1);
        }

        foreach (var str in strs)
        {
            newContents.AddRange(str);
            newContents.Add(0x00);
            newContents.Add(0x00);
        }

        if (newContents.Count > contentLen)
        {
            throw new InvalidOperationException($"new content has larger size {id}");
        }

        while (newContents.Count < contentLen)
        {
            newContents.Add(0x00);
        }
        
        Buffer.BlockCopy(newContents.ToArray(), 0, _cm1100, contentStart, newContents.Count);
    }

    private static ushort ReadUShort(byte[] data, int offset)
    {
        return (ushort)(data[offset] | (data[offset + 1] << 8));
    }

    private static byte[] PackUShort(ushort value)
    {
        return new[] { (byte)(value & 0xFF), (byte)((value >> 8) & 0xFF) };
    }
}
