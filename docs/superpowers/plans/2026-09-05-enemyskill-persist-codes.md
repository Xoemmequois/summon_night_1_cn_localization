# EnemySkill 存档编码持久化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 每次生成汉化 ROM 时将 EnemySkill 字符的小字库编码写入 `romhack/rom_text_presist_codes.json`，下次构建尽量复用相同编码，保证旧存档不乱码。

**Architecture:** 新增 `PersistCodeStore`（JSON 读写 + SJIS↔mapIndex 换算 + 校验）；`SmallFontBuilder.Build` 的分配逻辑重构为四阶段（共享预钉 → 共享游标 → 自有预钉 → 自有游标），`Program.cs` 在 Build 前加载、Build 后按 `EnemySkill-*` 条目合并写回。规格见 `docs/superpowers/specs/2026-09-05-enemyskill-persist-codes-design.md`。

**Tech Stack:** C# .NET 8, System.Text.Json, System.Drawing（仅既有字形渲染）。

**测试说明:** 本仓库无单元测试基础设施（sln 中无测试项目，AGENTS.md 未规定测试框架）。按已批准 spec 的验证方式：每个任务用 `dotnet build` 验证编译，功能验证用两次完整管线运行（幂等性检查）。这是对严格 TDD 的有意偏离，依据代码库现状与用户批准的 spec。

**背景知识（给零上下文的执行者）:**
- 小字库编码：CM1200.DAT subcontent 8 的 map 表把 SJIS 码映射到字形索引。`mapIndex → SJIS`：`lead = 0x81 + mapIndex/0xC0`（低字节），`trail = 0x40 + mapIndex%0xC0`（高字节）。分配范围 mapIndex [524, 4607]；共享区 [768, 1343]（code 0x8540-0x87FF，须与大字库一致）。
- 槽位"空闲" = 原始（未修改的）CM1200.DAT 中该 map 条目为 0，且本次构建未占用。原始 ROM 每次构建都相同，因此上次分配走的槽位这次必然仍空闲。
- 游戏存档只保存 SJIS 编码字节，运行时经 map 表解析字形，所以只需保证 **字符 → SJIS 编码** 稳定，字形索引（glyphIdx）变化无影响。
- 工作目录约定：C# 构建命令在 `romhack_csharp/`（sln 所在目录）；管线运行在 `romhack/`（config.json 与 rom/ 所在目录）。

---

## 文件结构

| 操作 | 文件 | 职责 |
|------|------|------|
| 新建 | `romhack_csharp/small_font/PersistCodeStore.cs` | JSON 读写、编码解析校验、SjisToMapIndex 换算 |
| 修改 | `romhack_csharp/small_font/SmallFontBuilder.cs` | Build 增加 persistedCodes 参数，四阶段分配 |
| 修改 | `romhack_csharp/romhack_csharp/Program.cs` | Build 前 Load、Build 后按 EnemySkill 条目 Save |
| 修改 | `AGENTS.md` | 文档：新文件与管线说明 |
| 生成+提交 | `romhack/rom_text_presist_codes.json` | 首次管线运行生成，纳入 git |

---

### Task 1: PersistCodeStore 辅助类

**Files:**
- Create: `romhack_csharp/small_font/PersistCodeStore.cs`

- [ ] **Step 1: 创建 PersistCodeStore.cs，完整内容如下**

```csharp
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
```

- [ ] **Step 2: 编译验证**

Run (workdir `romhack_csharp/`): `dotnet build romhack_csharp.sln`
Expected: `Build succeeded`

- [ ] **Step 3: Commit**

```bash
git add romhack_csharp/small_font/PersistCodeStore.cs
git commit -m "feat: add PersistCodeStore for save-persistent char codes"
```

---

### Task 2: SmallFontBuilder 四阶段分配

**Files:**
- Modify: `romhack_csharp/small_font/SmallFontBuilder.cs`（Build 方法整体替换；删除不再使用的 `IsFreeSharedSlot`；`Encode12x12Glyph` 与 `IndexToSjis` 不动）

- [ ] **Step 1: 用以下内容整体替换 Build 方法**（原 24-147 行），并在文件中删除 `IsFreeSharedSlot` 私有方法（原 149-156 行）

```csharp
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
                $"PersistCodes: warning - '{ch}' previous code 0x{prevSjis:X4} (mapIndex {prevIdx}) " +
                $"cannot be kept, reassigned to 0x{IndexToSjis(newIdx):X4} (mapIndex {newIdx}). " +
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
```

关键行为说明（供执行者核对）:
- `persistedCodes` 为 null/空时，四个阶段退化为原有游标行为，输出与改造前完全一致。
- 预钉失败（区域不符或槽位被占）仅警告并交由游标兜底，绝不阻断构建。
- 共享字符预钉要求 prev 落在共享区；自有字符预钉允许任意 [524,4607]（含共享区空闲位）。

- [ ] **Step 2: 编译验证**

Run (workdir `romhack_csharp/`): `dotnet build romhack_csharp.sln`
Expected: `Build succeeded`

- [ ] **Step 3: Commit**

```bash
git add romhack_csharp/small_font/SmallFontBuilder.cs
git commit -m "feat: four-phase map allocation with persisted-code pinning in SmallFontBuilder"
```

---

### Task 3: Program.cs 接线

**Files:**
- Modify: `romhack_csharp/romhack_csharp/Program.cs`（Build 调用处 + 新增私有方法）

- [ ] **Step 1: 替换 "--- Building Small Font ---" 区块**（原 38-46 行）为：

```csharp
        // === 小字库构建（提前: 共享字符编码须先于大字库分配固定）===
        Console.WriteLine("\n--- Building Small Font ---");
        var persistCodesPath = Path.Combine(Directory.GetCurrentDirectory(), "rom_text_presist_codes.json");
        var persistedCodes = PersistCodeStore.Load(persistCodesPath);
        var charMap = SmallFontBuilder.Build(
            Path.Combine(Directory.GetCurrentDirectory(), "rom_text_zh_CN.json"),
            Path.Combine("rom", "CM1200.DAT"),
            Path.Combine("rom", "S.F"),
            Path.Combine("rom", "CM1200.DAT.mod"),
            config.ValidStage,
            sharedChars,
            persistedCodes);
        SaveEnemySkillPersistCodes(persistCodesPath, persistedCodes, charMap, config.ValidStage);
```

- [ ] **Step 2: 在 `PinSharedChars` 方法之后新增私有方法**

```csharp
    private static void SaveEnemySkillPersistCodes(
        string path,
        IReadOnlyDictionary<char, ushort> oldCodes,
        Dictionary<char, (ushort Sjis, ushort Index)> charMap,
        List<int> validStages)
    {
        var json = File.ReadAllText(Path.Combine(Directory.GetCurrentDirectory(), "rom_text_zh_CN.json"));
        var items = JsonSerializer.Deserialize<List<TranslationItem>>(json) ?? new();
        var chars = new HashSet<char>();
        foreach (var item in items)
        {
            if (!item.Key.StartsWith("EnemySkill-", StringComparison.Ordinal)) continue;
            if (!validStages.Contains(item.Stage)) continue;
            if (string.IsNullOrEmpty(item.Translation)) continue;
            foreach (var ch in item.Translation)
            {
                if (ch == '@' || ch == 'n') continue;
                chars.Add(ch);
            }
        }

        PersistCodeStore.Save(path, oldCodes, chars, charMap);
    }
```

说明: `PersistCodeStore` 经已有的 `using small_font;`（Program.cs:4）可见；`TranslationItem` 经 `using SummonNightLib;` 可见。Build 若抛异常则 Save 不会执行，JSON 只在构建成功后更新。

- [ ] **Step 3: 编译验证**

Run (workdir `romhack_csharp/`): `dotnet build romhack_csharp.sln`
Expected: `Build succeeded`

- [ ] **Step 4: Commit**

```bash
git add romhack_csharp/romhack_csharp/Program.cs
git commit -m "feat: load/save persist codes around SmallFontBuilder build"
```

---

### Task 4: 更新 AGENTS.md 文档

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Pipeline Overview 的 Build 段第 2 步**，把:

```
  2. SmallFontBuilder: assign shared chars (region 0x8540+) then own chars → S.F + CM1200.DAT.mod
```

改为:

```
  2. SmallFontBuilder: pin persisted EnemySkill codes (rom_text_presist_codes.json), assign shared
     chars (region 0x8540+) then own chars → S.F + CM1200.DAT.mod; write codes back to
     rom_text_presist_codes.json
```

- [ ] **Step 2: Conventions & Gotchas 末尾追加一条**:

```
- **Save-persistent char codes**: `romhack/rom_text_presist_codes.json` (committed) records
  char → small-font SJIS for EnemySkill names, which the game copies into save files. Codes are
  kept stable across builds; forced changes (e.g. char moved into shared_text.txt) print a
  `PersistCodes: warning` and continue.
```

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "docs: document rom_text_presist_codes.json in AGENTS.md"
```

---

### Task 5: 首次管线运行（生成 JSON）

**Files:**
- Create (generated): `romhack/rom_text_presist_codes.json`

- [ ] **Step 1: 完整构建一次**

Run (workdir `romhack/`): `dotnet run --project ..\romhack_csharp`
Expected 日志关键行（N 为 ValidStage 过滤后的 EnemySkill 唯一字符数，全 stage 3 时 N=334）:
- `PersistCodes: rom_text_presist_codes.json not found (first build), no pinning`
- `PersistCodes: kept 0, changed 0`
- `PersistCodes: wrote N entries (N current) -> rom_text_presist_codes.json`
- `FontMapVerifier OK: ...`
- mkpsxiso 正常产出 `output/Summon_Night_Chinese.bin`

注意: 首次运行无持久化编码，分配结果应与改造前一致（行为保持性由 `FontMapVerifier` 通过佐证）。

- [ ] **Step 2: 检查生成的 JSON**

Run (workdir `romhack/`): `Get-Content rom_text_presist_codes.json -TotalCount 5`
Expected: 形如 `{ "魔": "0x8..." }` 的扁平 char → "0xXXXX" 映射（控制台可能因代码页显示乱码，属正常）。

- [ ] **Step 3: Commit 生成的 JSON**

```bash
git add romhack/rom_text_presist_codes.json
git commit -m "feat: persist EnemySkill char codes (initial baseline)"
```

---

### Task 6: 幂等性验证（第二次运行）

- [ ] **Step 1: 记录当前 JSON 哈希并再次完整构建**

Run (workdir `romhack/`):

```powershell
$before = (Get-FileHash rom_text_presist_codes.json).Hash
dotnet run --project ..\romhack_csharp
$after = (Get-FileHash rom_text_presist_codes.json).Hash
"hash equal: $($before -eq $after)"
```

Expected 日志关键行:
- `PersistCodes: loaded N entries from rom_text_presist_codes.json`
- `PersistCodes: kept N, changed 0`
- `hash equal: True`

- [ ] **Step 2: 若 changed > 0，逐条检查 warning 原因并修正后再跑**（预期不会发生；出现则说明存在 bug，回到 Task 2 排查四阶段逻辑）

- [ ] **Step 3: 最终确认**

Run (workdir `romhack/`): `git status --short`
Expected: 无未预期的未跟踪/修改文件（rom/、output/、pic_output* 均已 gitignore）。

---

## Self-Review 记录

1. **Spec 覆盖**: JSON 格式（Task 1 Save/Load）✓；四阶段分配与警告（Task 2）✓；shared→own 保持编码（Task 2 阶段 3 允许共享区槽位）✓；合并保留陈旧条目（Task 1 Save）✓；Program.cs 接线（Task 3）✓；验证 1-4（Task 5/6 + FontMapVerifier）✓。
2. **占位符扫描**: 无 TBD/TODO；所有代码步骤含完整代码。
3. **类型一致性**: `PersistCodeStore.Load` 返回 `Dictionary<char, ushort>`，`Build` 参数为 `IReadOnlyDictionary<char, ushort>?`，`Save` 接收 `IReadOnlyDictionary<char, ushort>` + `Dictionary<char, (ushort Sjis, ushort Index)>`（与 `SmallFontBuilder.Build` 返回类型一致）；`SjisToMapIndex` 在 Task 1 定义、Task 2 使用，签名一致。

## 执行偏差记录

- Task 3 中 AGENTS.md 记载的管线运行命令 `dotnet run --project ..\romhack_csharp` 实际不可用（该路径是解决方案目录，无 csproj），改用 `dotnet run --project ..\romhack_csharp\romhack_csharp`。
- 执行中发现计划代码的 JSON 值使用内部 ushort 形式（lead 在低字节，如 `0x6F85`），与 spec 要求的 `chinese_font_map.json` 记法（lead 在高字节，如 `0x856F`）不一致。已在 `PersistCodeStore` 增加 `ToDisplayCode`（I/O 边界字节交换，自逆）修复：Save 写显示记法、Load 解析显示记法、SmallFontBuilder 警告同步使用显示记法。首次生成的 lead-low 记法 JSON 已删除并重新生成（分配确定性不变）。已验证：二次运行 `kept 334, changed 0`，JSON 哈希不变。
