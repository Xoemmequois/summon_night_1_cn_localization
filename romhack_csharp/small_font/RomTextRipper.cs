using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using SummonNightLib;

namespace romhack_csharp;

public class RomTextRipper
{
    public void Rip()
    {
        string romPath = Path.Combine("rom", "SLPS_025.42");
        if (!File.Exists(romPath))
        {
            Console.WriteLine($"Error: {romPath} not found.");
            return;
        }

        byte[] romData = File.ReadAllBytes(romPath);
        
        var ranges = new (int Start, int End)[]
        {
            (0x800, 0x4457),
            (0x87C50, 0x8828F)
        };

        var allExtracted = new List<(int Address, string Text)>();
        foreach (var range in ranges)
        {
            Console.WriteLine($"--- Ripping range 0x{range.Start:X} - 0x{range.End:X} ---");
            var strings = ExtractStrings(romData, range.Start, range.End);
            allExtracted.AddRange(strings);

            foreach (var item in strings)
            {
                Console.WriteLine($"[0x{item.Address:X}] {item.Text}");
            }
        }

        var resultItems = RipArrays(romData, allExtracted);

        var jsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
        };
        File.WriteAllText("rom_text_zh_CN.json", JsonSerializer.Serialize(resultItems, jsonOptions));
        Console.WriteLine("\nDone! Text exported to rom_text_zh_CN.json");
    }

    private List<ParatranzItem> RipArrays(byte[] romData, List<(int Address, string Text)> allExtracted)
    {
        var result = new List<ParatranzItem>();
        var referencedAddresses = new HashSet<int>();
        var extractedAddresses = new HashSet<int>(allExtracted.Select(x => x.Address));
        var externalReferences = new List<(int Address, string Text)>();
        
        Console.WriteLine("\n--- Equipment Info Array (0x8A1E0) ---");
        // 装备信息数组：0x8A1E0开始，项大小0x24，0偏移名称，0x18, 0x1c, 0x20描述，大小265
        for (int i = 0; i < 265; i++)
        {
            int entryStart = 0x7A1E0 + i * 0x24;
            uint nameAddr = BitConverter.ToUInt32(romData, entryStart + 0);
            uint desc1Addr = BitConverter.ToUInt32(romData, entryStart + 0x18);
            uint desc2Addr = BitConverter.ToUInt32(romData, entryStart + 0x1C);
            uint desc3Addr = BitConverter.ToUInt32(romData, entryStart + 0x20);

            string name = GetStringAtMemAddr(romData, nameAddr, referencedAddresses, extractedAddresses, externalReferences);
            string desc1 = GetStringAtMemAddr(romData, desc1Addr, referencedAddresses, extractedAddresses, externalReferences);
            string desc2 = GetStringAtMemAddr(romData, desc2Addr, referencedAddresses, extractedAddresses, externalReferences);
            string desc3 = GetStringAtMemAddr(romData, desc3Addr, referencedAddresses, extractedAddresses, externalReferences);

            if (!string.IsNullOrEmpty(name)) result.Add(new ParatranzItem { Key = $"Equip-{i}-Name", Original = name });
            if (!string.IsNullOrEmpty(desc1)) result.Add(new ParatranzItem { Key = $"Equip-{i}-Desc1", Original = desc1 });
            if (!string.IsNullOrEmpty(desc2)) result.Add(new ParatranzItem { Key = $"Equip-{i}-Desc2", Original = desc2 });
            if (!string.IsNullOrEmpty(desc3)) result.Add(new ParatranzItem { Key = $"Equip-{i}-Desc3", Original = desc3 });

            Console.WriteLine($"Equip {i}: Name={name}, Desc1={desc1}, Desc2={desc2}, Desc3={desc3}");
        }

        Console.WriteLine("\n--- Item Info Array (0x8C724) ---");
        // 物品信息数组：0x8C724开始，项大小0x14，0偏移名称，0x8, 0xc, 0x10描述。
        for (int i = 0; i < 25; i++)
        {
            int entryStart = 0x7C724 + i * 0x14;
            if (entryStart + 0x14 > romData.Length) break;

            uint nameAddr = BitConverter.ToUInt32(romData, entryStart + 0);
            uint desc1Addr = BitConverter.ToUInt32(romData, entryStart + 0x8);
            uint desc2Addr = BitConverter.ToUInt32(romData, entryStart + 0xC);
            uint desc3Addr = BitConverter.ToUInt32(romData, entryStart + 0x10);

            string name = GetStringAtMemAddr(romData, nameAddr, referencedAddresses, extractedAddresses, externalReferences);
            string desc1 = GetStringAtMemAddr(romData, desc1Addr, referencedAddresses, extractedAddresses, externalReferences);
            string desc2 = GetStringAtMemAddr(romData, desc2Addr, referencedAddresses, extractedAddresses, externalReferences);
            string desc3 = GetStringAtMemAddr(romData, desc3Addr, referencedAddresses, extractedAddresses, externalReferences);

            if (!string.IsNullOrEmpty(name)) result.Add(new ParatranzItem { Key = $"Item-{i}-Name", Original = name });
            if (!string.IsNullOrEmpty(desc1)) result.Add(new ParatranzItem { Key = $"Item-{i}-Desc1", Original = desc1 });
            if (!string.IsNullOrEmpty(desc2)) result.Add(new ParatranzItem { Key = $"Item-{i}-Desc2", Original = desc2 });
            if (!string.IsNullOrEmpty(desc3)) result.Add(new ParatranzItem { Key = $"Item-{i}-Desc3", Original = desc3 });

            Console.WriteLine($"Item {i}: Name={name}, Desc1={desc1}, Desc2={desc2}, Desc3={desc3}");
        }

        Console.WriteLine("\n--- Enemy Skill Names (0x7CEEC) ---");
        // 敌人技能名称指针数组：0x7ceec至0x7d148，每个指针4字节
        for (int i = 0; i < (0x7D148 - 0x7CEEC) / 4; i++)
        {
            int entryStart = 0x7CEEC + i * 4;
            uint nameAddr = BitConverter.ToUInt32(romData, entryStart);
            string name = GetStringAtMemAddr(romData, nameAddr, referencedAddresses, extractedAddresses, externalReferences);
            if (!string.IsNullOrEmpty(name)) result.Add(new ParatranzItem { Key = $"EnemySkill-{i}", Original = name });
            Console.WriteLine($"Enemy Skill {i}: Name={name}");
        }

        Console.WriteLine("\n--- Magic Info Array (0x7D524) ---");
        // 魔法信息数组：0x7D524开始，长度为8，每个元素大小为0x14，第一个4字节是名称的指针地址。后三个4字节指针是描述的地址。
        for (int i = 0; i < 8; i++)
        {
            int entryStart = 0x7D524 + i * 0x14;
            uint nameAddr = BitConverter.ToUInt32(romData, entryStart + 0);
            uint desc1Addr = BitConverter.ToUInt32(romData, entryStart + 0x8);
            uint desc2Addr = BitConverter.ToUInt32(romData, entryStart + 0xC);
            uint desc3Addr = BitConverter.ToUInt32(romData, entryStart + 0x10);

            string name = GetStringAtMemAddr(romData, nameAddr, referencedAddresses, extractedAddresses, externalReferences);
            string desc1 = GetStringAtMemAddr(romData, desc1Addr, referencedAddresses, extractedAddresses, externalReferences);
            string desc2 = GetStringAtMemAddr(romData, desc2Addr, referencedAddresses, extractedAddresses, externalReferences);
            string desc3 = GetStringAtMemAddr(romData, desc3Addr, referencedAddresses, extractedAddresses, externalReferences);

            if (!string.IsNullOrEmpty(name)) result.Add(new ParatranzItem { Key = $"Magic-{i}-Name", Original = name });
            if (!string.IsNullOrEmpty(desc1)) result.Add(new ParatranzItem { Key = $"Magic-{i}-Desc1", Original = desc1 });
            if (!string.IsNullOrEmpty(desc2)) result.Add(new ParatranzItem { Key = $"Magic-{i}-Desc2", Original = desc2 });
            if (!string.IsNullOrEmpty(desc3)) result.Add(new ParatranzItem { Key = $"Magic-{i}-Desc3", Original = desc3 });

            Console.WriteLine($"Magic {i}: Name={name}, Desc1={desc1}, Desc2={desc2}, Desc3={desc3}");
        }

        Console.WriteLine("\n--- State Array (0x7D5C4) ---");
        // 状态数组：0x7D5C4开始，结构同魔法信息，长度为40。
        for (int i = 0; i < 40; i++)
        {
            int entryStart = 0x7D5C4 + i * 0x14;
            uint nameAddr = BitConverter.ToUInt32(romData, entryStart + 0);
            uint desc1Addr = BitConverter.ToUInt32(romData, entryStart + 0x8);
            uint desc2Addr = BitConverter.ToUInt32(romData, entryStart + 0xC);
            uint desc3Addr = BitConverter.ToUInt32(romData, entryStart + 0x10);

            string name = GetStringAtMemAddr(romData, nameAddr, referencedAddresses, extractedAddresses, externalReferences);
            string desc1 = GetStringAtMemAddr(romData, desc1Addr, referencedAddresses, extractedAddresses, externalReferences);
            string desc2 = GetStringAtMemAddr(romData, desc2Addr, referencedAddresses, extractedAddresses, externalReferences);
            string desc3 = GetStringAtMemAddr(romData, desc3Addr, referencedAddresses, extractedAddresses, externalReferences);

            if (!string.IsNullOrEmpty(name)) result.Add(new ParatranzItem { Key = $"Skill-{i}-Name", Original = name });
            if (!string.IsNullOrEmpty(desc1)) result.Add(new ParatranzItem { Key = $"Skill-{i}-Desc1", Original = desc1 });
            if (!string.IsNullOrEmpty(desc2)) result.Add(new ParatranzItem { Key = $"Skill-{i}-Desc2", Original = desc2 });
            if (!string.IsNullOrEmpty(desc3)) result.Add(new ParatranzItem { Key = $"Skill-{i}-Desc3", Original = desc3 });

            Console.WriteLine($"Skill {i}: Name={name}, Desc1={desc1}, Desc2={desc2}, Desc3={desc3}");
        }

        Console.WriteLine("\n--- Unknown Description Array (0x7C99C) ---");
        // 未知的描述信息数组：0x7C99C开始，数组长度56，每个元素大小为0x18，最后三个4字节指针为描述字符串的指针。
        for (int i = 0; i < 56; i++)
        {
            int entryStart = 0x7C99C + i * 0x18;
            uint desc1Addr = BitConverter.ToUInt32(romData, entryStart + 0x0C);
            uint desc2Addr = BitConverter.ToUInt32(romData, entryStart + 0x10);
            uint desc3Addr = BitConverter.ToUInt32(romData, entryStart + 0x14);

            string desc1 = GetStringAtMemAddr(romData, desc1Addr, referencedAddresses, extractedAddresses, externalReferences);
            string desc2 = GetStringAtMemAddr(romData, desc2Addr, referencedAddresses, extractedAddresses, externalReferences);
            string desc3 = GetStringAtMemAddr(romData, desc3Addr, referencedAddresses, extractedAddresses, externalReferences);

            if (!string.IsNullOrEmpty(desc1)) result.Add(new ParatranzItem { Key = $"Unknown-{i}-Desc1", Original = desc1 });
            if (!string.IsNullOrEmpty(desc2)) result.Add(new ParatranzItem { Key = $"Unknown-{i}-Desc2", Original = desc2 });
            if (!string.IsNullOrEmpty(desc3)) result.Add(new ParatranzItem { Key = $"Unknown-{i}-Desc3", Original = desc3 });

            Console.WriteLine($"Unknown {i}: Desc1={desc1}, Desc2={desc2}, Desc3={desc3}");
        }

        if (externalReferences.Count > 0)
        {
            Console.WriteLine("\n--- References NOT in extracted ranges ---");
            var uniqueExternals = externalReferences.DistinctBy(x => x.Address).OrderBy(x => x.Address);
            foreach (var item in uniqueExternals)
            {
                result.Add(new ParatranzItem { Key = $"External-0x{item.Address:X}", Original = item.Text });
                Console.WriteLine($"[External][0x{item.Address:X}] {item.Text}");
            }
        }

        Console.WriteLine("\n--- Strings NOT referenced by arrays ---");
        foreach (var item in allExtracted)
        {
            if (!referencedAddresses.Contains(item.Address))
            {
                result.Add(new ParatranzItem { Key = $"Unreferenced-0x{item.Address:X}", Original = item.Text });
                Console.WriteLine($"[Unreferenced][0x{item.Address:X}] {item.Text}");
            }
        }

        return result;
    }

    public class ParatranzItem
    {
        public string key { get; set; } = "";
        public string original { get; set; } = "";
        public string translation { get; set; } = "";

        [JsonIgnore]
        public string Key { get => key; set => key = value; }
        [JsonIgnore]
        public string Original { get => original; set => original = value; }
        [JsonIgnore]
        public string Translation { get => translation; set => translation = value; }
    }

    private string GetStringAtMemAddr(byte[] romData, uint memAddr, HashSet<int> referencedAddresses, HashSet<int> extractedAddresses, List<(int Address, string Text)> externalReferences)
    {
        if (memAddr == 0 || memAddr == 0x8009771C) return "";
        long fileOffsetLong = memAddr + 0x800 - 0x80010000;
        int fileOffset = (int)fileOffsetLong;
        if (fileOffset < 0 || fileOffset >= romData.Length) return $"(Invalid Addr: 0x{memAddr:X})";
        
        referencedAddresses.Add(fileOffset);
        
        // 提取该偏移处的字符串
        var result = ExtractStrings(romData, fileOffset, Math.Min(fileOffset + 512, romData.Length)); // 假设字符串最长512
        if (result.Count > 0 && result[0].Address == fileOffset)
        {
            string text = result[0].Text;
            if (!extractedAddresses.Contains(fileOffset))
            {
                externalReferences.Add((fileOffset, text));
            }
            return text;
        }
        
        return $"(Not recognized at 0x{fileOffset:X})";
    }

    public List<(int Address, string Text)> ExtractStrings(byte[] data, int start, int end)
    {
        var results = new List<(int Address, string Text)>();
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var sjis = Encoding.GetEncoding("shift_jis");

        int current = start;
        while (current <= end - 1) // 需要至少两个字节
        {
            // 检查是否是结尾 \0 (双字节 0x00 0x00)
            if (data[current] == 0x00 && data[current + 1] == 0x00)
            {
                current += 2;
                continue;
            }

            int stringStart = current;
            var strBytes = new List<byte>();
            bool hasValidContent = false;

            while (current <= end - 1)
            {
                byte b0 = data[current];
                byte b1 = data[current + 1];

                if (b0 == 0x00 && b1 == 0x00)
                {
                    current += 2;
                    break;
                }

                // 特殊逻辑：遇到 0x40, 0x00 序列，则用 @ 代替
                if (b0 == 0x40 && b1 == 0x00)
                {
                    strBytes.Add((byte)'@');
                    hasValidContent = true;
                    current += 2;

                    // 同时下一个字符如果是 0x__，0x00 的形式，则删去第二个字符的第二个 byte 的 0x00，改为仅有第一个 byte 的 ASCII 编码
                    if (current <= end - 1 && data[current + 1] == 0x00)
                    {
                        strBytes.Add(data[current]);
                        current += 2;
                    }
                }
                else
                {
                    if (IsLegalSjis(b0, b1))
                    {
                        hasValidContent = true;
                    }
                    strBytes.Add(b0);
                    strBytes.Add(b1);
                    current += 2;
                }
            }

            if (strBytes.Count > 0 && hasValidContent)
            {
                results.Add((stringStart, sjis.GetString(strBytes.ToArray())));
            }
        }

        return results;
    }

    private bool IsLegalSjis(byte b1, byte b2)
    {
        return ((b1 >= 0x81 && b1 <= 0x9F) || (b1 >= 0xE0 && b1 <= 0xFC)) &&
               ((b2 >= 0x40 && b2 <= 0x7E) || (b2 >= 0x80 && b2 <= 0xFC));
    }
}
