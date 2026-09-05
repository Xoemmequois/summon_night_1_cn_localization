# EnemySkill 存档编码持久化（rom_text_presist_codes.json）设计

日期：2026-09-05
状态：已批准

## 背景与问题

`SLPS_025.42` 内嵌文本中的 EnemySkill 名称（151 条，`rom_text_zh_CN.json` 中 key 形如
`EnemySkill-{i}-0x{offset:X}`）会被游戏写入**存档**。这些名称使用小字库编码
（CM1200 map table，mapIndex → `IndexToSjis` 得到 SJIS 码）。当前
`SmallFontBuilder.Build` 用单调游标分配 mapIndex，字符集一旦变化（增删改翻译），
后续所有字符的编码都会移位，导致旧存档中的技能名变成乱码。

存档中只保存编码本身；运行时编码 → CM1200 map 表 → glyphIdx，因此**只需保证
字符 → SJIS 编码跨构建稳定**，glyphIdx 顺序变化无影响。

## 目标

每次生成汉化 ROM 时，把 EnemySkill 翻译涉及的字符的最终编码写入
`romhack/rom_text_presist_codes.json`（提交 git）；下次构建时读取该文件，
尽量把这些字符重新分配到相同编码。若因字符类别变化（如 own → shared）或槽位
被占导致编码必须改变，打印警告并继续。

## JSON 文件格式

`romhack/rom_text_presist_codes.json`，扁平 `字符 → SJIS 编码`：

```json
{
  "魔": "0x8540",
  "法": "0x8541"
}
```

- 值格式与 `chinese_font_map.json` 的 `"0xXXXX"` 风格一致（lead 为低字节）。
- 每次构建后重写：**当前** EnemySkill 翻译涉及的全部字符（Stage ∈ ValidStage，
  排除 `@`/`n`）的最新编码，与旧文件**合并**——旧文件中已不再出现的条目保留，
  字符将来回归时编码可恢复。

## 读取与钉扎（SmallFontBuilder.Build）

新增可选参数 `persistedCodes`（`IReadOnlyDictionary<char, ushort>`，char → SJIS）。
分配逻辑从单循环重构为四阶段：

1. **共享预钉**：sharedChars 中有持久化编码者——mapIndex ∈ [768,1343]（共享区）
   且槽位空闲（原始 CM1200 map 条目为 0 且未被本次构建占用，下同）→ 钉住；
   否则警告后退入游标分配。
2. **共享游标**：其余共享字符，现行逻辑不变（768 起单调扫描跳过占用）。
3. **自有预钉**：ownChars 中有持久化编码者——mapIndex ∈ [524,4607] 且此刻槽位
   空闲（允许落在共享区 [768,1343]，只要第 1、2 步没占掉）→ 钉住；否则警告。
4. **自有游标**：其余自有字符，现行逻辑不变（524 起扫描）。

- 全程用 `HashSet<int>` 记录已占用槽位，预钉与游标共用，防止碰撞。
- 钉成功的打印 kept；编码变化的打印警告（含原因与新编码）；最后输出汇总
  `PersistCodes: kept N, changed M`。
- 之后渲染字形、写 map 表、S.F、CM1200.mod 的流程不变（glyphIdx 仍按 charList
  位置分配）。

### 边界行为

| 场景 | 行为 |
|------|------|
| 首次构建（无 JSON） | 全部游标分配，结束时生成文件 |
| own → shared（类别改变） | 编码必须变 → 警告 + 游标重分配 |
| shared → own | 只要槽位空闲，编码尽量保持（不强制改变） |
| 持久化槽位被共享分配占掉 | 警告 + 游标重分配 |
| 字符不再出现 | 不分配；JSON 条目保留 |

## 辅助类 PersistCodeStore（small_font 项目）

- `Load(path)` → `Dictionary<char, ushort>`；文件不存在 → 空字典。
- JSON 整体损坏 → 抛异常（提交的状态文件，静默忽略会掩盖错误）；单条非法
  （mapIndex 不在 [524,4607]、同一编码被两个字符使用）→ 警告并跳过。
- 逆换算 `SjisToMapIndex(sjis) = (lead - 0x81) * 0xC0 + (trail - 0x40)`，
  其中 lead = sjis 低字节（0x81~0x99），trail = sjis 高字节。
- `Save(path, currentChars, charMap)` → 与旧文件合并后写回（UTF-8、缩进）。

## Program.cs 接线

```
Build 前:  var persisted = PersistCodeStore.Load("rom_text_presist_codes.json");
Build:     SmallFontBuilder.Build(..., sharedChars, persisted)
Build 后:  过滤 rom_text_zh_CN.json 中 key 以 "EnemySkill-" 开头、
           Stage ∈ ValidStage、translation 非空的条目，收集字符（排除 @/n），
           PersistCodeStore.Save(...) 合并写回
```

其余管线（RomTextWriter、FontMapVerifier、chinese.fnt、JAL patch、mkpsxiso）不动。

## 验证

1. 不改输入连续构建两次：第二次日志全部 kept，JSON 无 diff。
2. 某翻译加一个新字重建：EnemySkill 全部字符编码不变。
3. 把某 EnemySkill 字符加入 `shared_text.txt` 重建：出现警告、编码变化、JSON 更新。
4. 完整构建跑通 + `FontMapVerifier` 通过。
