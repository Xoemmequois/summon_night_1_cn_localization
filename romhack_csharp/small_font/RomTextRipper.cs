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
            // 原有扫描区间
            (0x800, 0x4457),       // Range1: 0x80010000-0x80013C57
            (0x87C50, 0x8828F),    // Range2: 0x80097450-0x80097A8F
            
            // 遗漏区间 (存档/UI文字、角色名、商店提示)
            (0x4A84, 0x4A9F),      // 角色名: ハヤト, ぱぁとなぁ (2串)
            (0x4D04, 0x4D8F),      // 存档提示: サモンナイト, データが壊れています等 (~6串)
            (0x5160, 0x52C0),      // 属性/类型名: ＨＡＹＡＴＯ, はやと等 (~25串)
            (0x5400, 0x5580),      // 技能说明 (~25串)
            (0x5764, 0x5858),      // 商店提示: 所持金が足りません, 売れるxxx等 (~10串)
            (0x5A50, 0x5A5E),      // 商店残串: ありません
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

        var referencedAddresses = new HashSet<int>();
        var resultItems = RipArrays(romData, allExtracted, referencedAddresses);
        RipNameTables(romData, resultItems, referencedAddresses);
        RipHintTable(romData, resultItems, referencedAddresses);

        // After all processing, check for truly unreferenced strings
        Console.WriteLine("\n--- Strings NOT referenced by arrays ---");
        foreach (var item in allExtracted)
        {
            if (!referencedAddresses.Contains(item.Address))
            {
                resultItems.Add(new RomTextRipper.ParatranzItem { Key = $"Unreferenced-0x{item.Address:X}", Original = item.Text });
                Console.WriteLine($"[Unreferenced][0x{item.Address:X}] {item.Text}");
            }
        }

        var jsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
        };
        File.WriteAllText("rom_text.json", JsonSerializer.Serialize(resultItems, jsonOptions));
        Console.WriteLine("\nDone! Text exported to rom_text.json");
    }

    private List<ParatranzItem> RipArrays(byte[] romData, List<(int Address, string Text)> allExtracted,
        HashSet<int> referencedAddresses)
    {
        var result = new List<ParatranzItem>();
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

            var (name, nameOffset) = GetStringAtMemAddr(romData, nameAddr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc1, desc1Offset) = GetStringAtMemAddr(romData, desc1Addr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc2, desc2Offset) = GetStringAtMemAddr(romData, desc2Addr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc3, desc3Offset) = GetStringAtMemAddr(romData, desc3Addr, referencedAddresses, extractedAddresses, externalReferences);

            if (!string.IsNullOrEmpty(name)) result.Add(new ParatranzItem { Key = $"Equip-{i}-Name-0x{nameOffset:X}", Original = name });
            if (!string.IsNullOrEmpty(desc1)) result.Add(new ParatranzItem { Key = $"Equip-{i}-Desc1-0x{desc1Offset:X}", Original = desc1 });
            if (!string.IsNullOrEmpty(desc2)) result.Add(new ParatranzItem { Key = $"Equip-{i}-Desc2-0x{desc2Offset:X}", Original = desc2 });
            if (!string.IsNullOrEmpty(desc3)) result.Add(new ParatranzItem { Key = $"Equip-{i}-Desc3-0x{desc3Offset:X}", Original = desc3 });

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

            var (name, nameOffset) = GetStringAtMemAddr(romData, nameAddr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc1, desc1Offset) = GetStringAtMemAddr(romData, desc1Addr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc2, desc2Offset) = GetStringAtMemAddr(romData, desc2Addr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc3, desc3Offset) = GetStringAtMemAddr(romData, desc3Addr, referencedAddresses, extractedAddresses, externalReferences);

            if (!string.IsNullOrEmpty(name)) result.Add(new ParatranzItem { Key = $"Item-{i}-Name-0x{nameOffset:X}", Original = name });
            if (!string.IsNullOrEmpty(desc1)) result.Add(new ParatranzItem { Key = $"Item-{i}-Desc1-0x{desc1Offset:X}", Original = desc1 });
            if (!string.IsNullOrEmpty(desc2)) result.Add(new ParatranzItem { Key = $"Item-{i}-Desc2-0x{desc2Offset:X}", Original = desc2 });
            if (!string.IsNullOrEmpty(desc3)) result.Add(new ParatranzItem { Key = $"Item-{i}-Desc3-0x{desc3Offset:X}", Original = desc3 });

            Console.WriteLine($"Item {i}: Name={name}, Desc1={desc1}, Desc2={desc2}, Desc3={desc3}");
        }

        Console.WriteLine("\n--- Enemy Skill Names (0x7CEEC) ---");
        // 敌人技能名称指针数组：0x7ceec至0x7d148，每个指针4字节
        for (int i = 0; i < (0x7D148 - 0x7CEEC) / 4; i++)
        {
            int entryStart = 0x7CEEC + i * 4;
            uint nameAddr = BitConverter.ToUInt32(romData, entryStart);
            var (name, nameOffset) = GetStringAtMemAddr(romData, nameAddr, referencedAddresses, extractedAddresses, externalReferences);
            if (!string.IsNullOrEmpty(name)) result.Add(new ParatranzItem { Key = $"EnemySkill-{i}-0x{nameOffset:X}", Original = name });
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

            var (name, nameOffset) = GetStringAtMemAddr(romData, nameAddr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc1, desc1Offset) = GetStringAtMemAddr(romData, desc1Addr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc2, desc2Offset) = GetStringAtMemAddr(romData, desc2Addr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc3, desc3Offset) = GetStringAtMemAddr(romData, desc3Addr, referencedAddresses, extractedAddresses, externalReferences);

            if (!string.IsNullOrEmpty(name)) result.Add(new ParatranzItem { Key = $"Magic-{i}-Name-0x{nameOffset:X}", Original = name });
            if (!string.IsNullOrEmpty(desc1)) result.Add(new ParatranzItem { Key = $"Magic-{i}-Desc1-0x{desc1Offset:X}", Original = desc1 });
            if (!string.IsNullOrEmpty(desc2)) result.Add(new ParatranzItem { Key = $"Magic-{i}-Desc2-0x{desc2Offset:X}", Original = desc2 });
            if (!string.IsNullOrEmpty(desc3)) result.Add(new ParatranzItem { Key = $"Magic-{i}-Desc3-0x{desc3Offset:X}", Original = desc3 });

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

            var (name, nameOffset) = GetStringAtMemAddr(romData, nameAddr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc1, desc1Offset) = GetStringAtMemAddr(romData, desc1Addr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc2, desc2Offset) = GetStringAtMemAddr(romData, desc2Addr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc3, desc3Offset) = GetStringAtMemAddr(romData, desc3Addr, referencedAddresses, extractedAddresses, externalReferences);

            if (!string.IsNullOrEmpty(name)) result.Add(new ParatranzItem { Key = $"Skill-{i}-Name-0x{nameOffset:X}", Original = name });
            if (!string.IsNullOrEmpty(desc1)) result.Add(new ParatranzItem { Key = $"Skill-{i}-Desc1-0x{desc1Offset:X}", Original = desc1 });
            if (!string.IsNullOrEmpty(desc2)) result.Add(new ParatranzItem { Key = $"Skill-{i}-Desc2-0x{desc2Offset:X}", Original = desc2 });
            if (!string.IsNullOrEmpty(desc3)) result.Add(new ParatranzItem { Key = $"Skill-{i}-Desc3-0x{desc3Offset:X}", Original = desc3 });

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

            var (desc1, desc1Offset) = GetStringAtMemAddr(romData, desc1Addr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc2, desc2Offset) = GetStringAtMemAddr(romData, desc2Addr, referencedAddresses, extractedAddresses, externalReferences);
            var (desc3, desc3Offset) = GetStringAtMemAddr(romData, desc3Addr, referencedAddresses, extractedAddresses, externalReferences);

            if (!string.IsNullOrEmpty(desc1)) result.Add(new ParatranzItem { Key = $"Unknown-{i}-Desc1-0x{desc1Offset:X}", Original = desc1 });
            if (!string.IsNullOrEmpty(desc2)) result.Add(new ParatranzItem { Key = $"Unknown-{i}-Desc2-0x{desc2Offset:X}", Original = desc2 });
            if (!string.IsNullOrEmpty(desc3)) result.Add(new ParatranzItem { Key = $"Unknown-{i}-Desc3-0x{desc3Offset:X}", Original = desc3 });

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

    private (string Text, int Address) GetStringAtMemAddr(byte[] romData, uint memAddr, HashSet<int> referencedAddresses, HashSet<int> extractedAddresses, List<(int Address, string Text)> externalReferences)
    {
        if (memAddr == 0 || memAddr == 0x8009771C) return ("", 0);
        long fileOffsetLong = memAddr + 0x800 - 0x80010000;
        int fileOffset = (int)fileOffsetLong;
        if (fileOffset < 0 || fileOffset >= romData.Length) return ($"(Invalid Addr: 0x{memAddr:X})", 0);
        
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
            return (text, fileOffset);
        }
        
        return ($"(Not recognized at 0x{fileOffset:X})", fileOffset);
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

    private void RipNameTables(byte[] romData, List<ParatranzItem> result, HashSet<int> referencedAddresses)
    {
        // 起名字符映射表 (内存地址 → 文件偏移)
        var tables = new (string Name, int FileOffset, int ByteCount)[]
        {
            ("NameTable-Hiragana", 0x7F568, 198),
            ("NameTable-Katakana", 0x7F630, 198),
            ("NameTable-Symbols",  0x7F6F8, 198),
            ("NameTable-Kanji",    0x7F7C0, 198),
        };

        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var sjis = Encoding.GetEncoding("shift_jis");

        Console.WriteLine("\n--- Naming Character Tables ---");
        foreach (var tbl in tables)
        {
            if (tbl.FileOffset + tbl.ByteCount > romData.Length)
            {
                Console.WriteLine($"  {tbl.Name}: out of bounds");
                continue;
            }

            byte[] bytes = new byte[tbl.ByteCount];
            Array.Copy(romData, tbl.FileOffset, bytes, 0, tbl.ByteCount);
            string text = sjis.GetString(bytes);
            result.Add(new ParatranzItem { Key = $"{tbl.Name}-0x{tbl.FileOffset:X}", Original = text });
            referencedAddresses.Add(tbl.FileOffset);
            Console.WriteLine($"  [{tbl.Name}] {text.Substring(0, Math.Min(40, text.Length))}...");
        }
    }

    private void RipHintTable(byte[] romData, List<ParatranzItem> result, HashSet<int> referencedAddresses)
    {
        // 提示文字表: 内存 0x8008EC20, 文件偏移 0x7F420
        // 每 3 个字符串指针拼成一句话 (Slot0 + Slot1 + Slot2)
        // 空槽标记: 0x80097A40
        const int tableFileOff = 0x7F420;
        const int charMapStart = 0x7F568;
        const uint emptyMarker = 0x80097A40;
        int group = 0;
        int entryCount = (charMapStart - tableFileOff) / 4;
        var seenOffsets = new HashSet<int>();

        Console.WriteLine("\n--- Hint Table (0x8008EC20) ---");

        for (int i = 0; i < entryCount;)
        {
            uint e0 = BitConverter.ToUInt32(romData, tableFileOff + i * 4);
            if (e0 == 0) { i++; continue; }

            // 嵌套表指针: 指向 0x8008EBF0~0x8008EC2F 区间 (4个基组)
            if (e0 >= 0x8008EBF0 && e0 <= 0x8008EC2F)
            {
                int subOff = MemToFile(e0);
                if (!seenOffsets.Contains(subOff) && subOff + 12 <= romData.Length)
                {
                    seenOffsets.Add(subOff);
                    uint s0 = BitConverter.ToUInt32(romData, subOff);
                    uint s1 = BitConverter.ToUInt32(romData, subOff + 4);
                    uint s2 = BitConverter.ToUInt32(romData, subOff + 8);
                    if (s0 != 0)
                        EmitHintGroup(romData, result, ref group, s0, s1, s2, referencedAddresses);
                }
                i++;
                continue;
            }

            // 跳过指向内联区域 (0x8008EC30+) 的嵌套指针——它们指向已由下方内联三元组覆盖的内容
            if (e0 >= 0x8008EC30 && e0 <= 0x8008ED60)
            {
                i++;
                continue;
            }

            // 内联三元组: 连续 3 项
            if (i + 2 < entryCount)
            {
                uint s0 = e0;
                uint s1 = BitConverter.ToUInt32(romData, tableFileOff + (i + 1) * 4);
                uint s2 = BitConverter.ToUInt32(romData, tableFileOff + (i + 2) * 4);

                if (IsHintStringAddr(s0, emptyMarker) ||
                    IsHintStringAddr(s1, emptyMarker) ||
                    IsHintStringAddr(s2, emptyMarker))
                {
                    // 跳过全空组
                    if (s0 != emptyMarker || s1 != emptyMarker || s2 != emptyMarker)
                        EmitHintGroup(romData, result, ref group, s0, s1, s2, referencedAddresses);
                    i += 3;
                    continue;
                }
            }
            i++;
        }
    }

    private bool IsHintStringAddr(uint addr, uint emptyMarker)
    {
        if (addr == emptyMarker) return true;
        // 字符串地址范围: 0x80014xxx~0x80015xxx (技能提示) 或 0x80097xxx (Range2 边界后缀)
        return (addr >= 0x80014000 && addr <= 0x80016000) ||
               (addr >= 0x80097000 && addr <= 0x80098000);
    }

    private int MemToFile(uint memAddr)
    {
        return (int)(memAddr + 0x800 - 0x80010000);
    }

    private string ReadSjisAt(byte[] romData, uint memAddr)
    {
        const uint emptyMarker = 0x80097A40;
        if (memAddr == 0 || memAddr == emptyMarker) return "";

        int fileOff = MemToFile(memAddr);
        if (fileOff < 0 || fileOff + 2 > romData.Length) return "";

        var bytes = new List<byte>();
        int pos = fileOff;
        while (pos + 1 < romData.Length)
        {
            if (romData[pos] == 0 && romData[pos + 1] == 0) break;
            bytes.Add(romData[pos]);
            bytes.Add(romData[pos + 1]);
            pos += 2;
        }

        if (bytes.Count == 0) return "";
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var enc = Encoding.GetEncoding("shift_jis");
        return enc.GetString(bytes.ToArray());
    }

    private void EmitHintGroup(byte[] romData, List<ParatranzItem> result,
        ref int group, uint s0, uint s1, uint s2, HashSet<int> referencedAddresses)
    {
        string t0 = ReadSjisAt(romData, s0);
        string t1 = ReadSjisAt(romData, s1);
        string t2 = ReadSjisAt(romData, s2);

        int off0 = s0 == 0 || s0 == 0x80097A40 ? 0 : MemToFile(s0);
        int off1 = s1 == 0 || s1 == 0x80097A40 ? 0 : MemToFile(s1);
        int off2 = s2 == 0 || s2 == 0x80097A40 ? 0 : MemToFile(s2);

        if (!string.IsNullOrEmpty(t0)) { result.Add(new ParatranzItem { Key = $"Hint-{group}-Slot0-0x{off0:X}", Original = t0 }); referencedAddresses.Add(off0); }
        if (!string.IsNullOrEmpty(t1)) { result.Add(new ParatranzItem { Key = $"Hint-{group}-Slot1-0x{off1:X}", Original = t1 }); referencedAddresses.Add(off1); }
        if (!string.IsNullOrEmpty(t2)) { result.Add(new ParatranzItem { Key = $"Hint-{group}-Slot2-0x{off2:X}", Original = t2 }); referencedAddresses.Add(off2); }

        if (!string.IsNullOrEmpty(t0) || !string.IsNullOrEmpty(t1) || !string.IsNullOrEmpty(t2))
        {
            Console.WriteLine($"Hint {group}: [{t0}] + [{t1}] + [{t2}] = {t0}{t1}{t2}");
        }
        group++;
    }

    private bool IsLegalSjis(byte b1, byte b2)
    {
        return ((b1 >= 0x81 && b1 <= 0x9F) || (b1 >= 0xE0 && b1 <= 0xFC)) &&
               ((b2 >= 0x40 && b2 <= 0x7E) || (b2 >= 0x80 && b2 <= 0xFC));
    }
}
