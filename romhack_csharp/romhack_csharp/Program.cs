using romhack_csharp;
using System.Text.Json;
using SummonNightLib;
using small_font;

internal static class Program
{
    private static readonly Dictionary<(int, int), string> Hash = new();
    private static readonly Dictionary<char, byte[]> Chars = new();
    private static readonly SortedDictionary<string, int[]> FidFirst64 = new();
    private static byte[] _cm1100 = Array.Empty<byte>();
    private static int _charIndex;

    private const uint LargeFontRamBase = 0x800D1000u;
    private const uint LargeFontRamEnd = 0x800E0000u;

    private static void Main(string[] args)
    {
        var config = Config.Load(Path.Combine(Directory.GetCurrentDirectory(), "config.json"));
        
        if (args.Contains("--rip") || !Directory.Exists("rom"))
        {
            new GameTextRipper(config).Rip();
            RipTool.Run(config.OpenRouterKey, config.OpenRouterProxy);
            new RomTextRipper().Rip();
            return;
        }

        LoadTranslations(config, "zh_CN_translated.json");
        Console.WriteLine($"Hash entries: {Hash.Count}");

        _cm1100 = File.ReadAllBytes(Path.Combine("rom", "CM1100.DAT"));
        ProcessDialogRange(1, 145);
        File.WriteAllBytes(Path.Combine("rom", "CM1100.DAT.mod2"), _cm1100);
        WriteFidFirst64Json();

        PrintChars();
        WriteCharMapJson();

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
        if (LargeFontRamBase + (uint)finalLen > LargeFontRamEnd)
        {
            var glyphBytes = LargeFontRamEnd - LargeFontRamBase - (uint)(finalLen - fontBinStart);
            throw new InvalidOperationException(
                $"chinese.fnt 过大: {finalLen} 字节 (0x{finalLen:X}), 装载区间 0x{LargeFontRamBase:X}-0x{LargeFontRamBase + (uint)finalLen:X} " +
                $"超过上限 0x{LargeFontRamEnd:X}. 可用 {LargeFontRamEnd - LargeFontRamBase} 字节, " +
                $"扣除代码段 {finalLen - fontBinStart} 字节后字形区上限 {glyphBytes} 字节, " +
                $"最多 {glyphBytes / 28} 字 (28B/字)");
        }
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

        // === 修改 CMXXXX.DAT (图片翻译回写) ===
        ImageWriteBack.Apply("pic_output", "pic_output_translated", "rom");

        Console.WriteLine("\n=== Generating image previews ===");
        ImagePreview.Generate("pic_output", "pic_output_translated", "rom", "pic_output_preview");
        
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

    private static void WriteCharMapJson()
    {
        var map = new SortedDictionary<string, string>();
        foreach (var pair in Chars)
        {
            map[$"0x{(pair.Value[0] << 8) | pair.Value[1]:X4}"] = pair.Key.ToString();
        }

        var json = JsonSerializer.Serialize(map, new JsonSerializerOptions { WriteIndented = true });
        Directory.CreateDirectory("output");
        File.WriteAllText(Path.Combine("output", "chinese_font_map.json"), json);
        Console.WriteLine($"Font map written: {map.Count} entries -> output/chinese_font_map.json");
    }

    private static void WriteFidFirst64Json()
    {
        var json = JsonSerializer.Serialize(FidFirst64, new JsonSerializerOptions { WriteIndented = true });
        Directory.CreateDirectory("output");
        File.WriteAllText(Path.Combine("output", "fid_first64.json"), json);
        Console.WriteLine($"FID first-64-byte map written: {FidFirst64.Count} entries -> output/fid_first64.json");
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

                // @ control char spans 3 units (6 bytes): 0x4000, param1, param2.
                // Preserve all 3 units so untranslated strings round-trip exactly.
                if (b0 == 0x40 && b1 == 0x00)
                {
                    str.Add(contents[start * 2 + index]);
                    str.Add(contents[start * 2 + index + 1]);
                    index += 2;
                    str.Add(contents[start * 2 + index]);
                    str.Add(contents[start * 2 + index + 1]);
                    index += 2;
                }
            }

            if (Hash.TryGetValue((id, i), out var replacement))
            {
                str.Clear();
                for (var ci = 0; ci < replacement.Length; ci++)
                {
                    var ch = replacement[ci];
                    if (ch == '@')
                    {
                        str.Add(0x40);
                        str.Add(0x00);
                        // @ control spans 3 units. "@n" must be written back as
                        // 40 00 6E 00 00 00 (the trailing 00 00 is the 3rd control unit).
                        if (ci + 1 < replacement.Length && replacement[ci + 1] == 'n')
                        {
                            str.Add(0x6E);
                            str.Add(0x00);
                            str.Add(0x00);
                            str.Add(0x00);
                            ci++;
                        }
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

        var fidBytes = newContents.Take(64).ToArray();
        FidFirst64[id.ToString()] = Array.ConvertAll(fidBytes, b => (int)b);

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
