# Ruby Tools 脚本说明

## 目录

- `opencode_generated/` — 本目录，新编写的分析工具
- `ruby_tools/` — 原始破解工具集（旧版）

---

## opencode_generated/ — 新版分析工具

### `analyze_script3.rb`
**核心 VM 模拟器。** 实现一个 PS1 游戏 "Summon Night" 脚本字节码的符号执行引擎。

功能：
- 双变量表追踪 (A82C4 + A82C8)，根据 Ghidra 反编译验证
- RegByteB (CalcFlags) 精确模拟，不再盲目 fork 所有分支
- 从 PC=127（主 switch）启动，模拟脚本 1 初始化后的状态
- 对外部变量 (0x19/0x1B/0x1D/0x93) 的 0x0027 switch 做分支探索
- 输出带元数据的对话组文件

用法：
```
ruby analyze_script3.rb [id]    # 分析指定脚本，默认 id=3
```

关键类：
- `VMState` — 执行上下文（PC, 变量表, 栈, 标志位）
- `ExecManager` — worklist 调度器，管理路径探索
- `handle_XXXX` — 各指令的精确实现

### `batch_analyze.rb`
**批量分析器。** 遍历所有可达脚本 (1-40)，输出汇总统计。

用法：
```
ruby batch_analyze.rb
```

输出：每个脚本的命令数、2013数、组数、文本ID数、对话文件列表、耗时。

### `generate_outputs.rb`
**生成分组对话文件。** 对每个脚本重新分析，输出到 `output/` 目录。

输出格式（纯文本，组间空行分隔）：
```
script01_fid01.txt
script01_fid02.txt
...
```

### `generate_full_report.rb`
**生成完整报告。** 对每个脚本重新分析，输出到 `output_full/` 目录。

输出格式（带元数据）：
```
--- Group 1 ---
[FID:0D, TEXT:0001] 朝ご飯、どうだった？
[FID:0D, TEXT:0002] たいしたもの作れなく
[FID:0D, TEXT:0003] て、ごめんね

--- Group 2 ---
...
```

同时输出覆盖率报告：每个对话文件中已覆盖/缺失的字符串。

### `compare_all.rb`
**新旧脚本对比工具。** 对比旧版 `group_dialogs.rb` 和新版 `analyze_script3.rb` 的分析结果。

对比指标：
- 输出行数
- 唯一文本行
- 对话组数
- 对话文件数
- 文本重叠率

### `compare_outputs.rb`
**文本级输出对比。** 对 id=1 和 id=2 做逐行文本 diff。

### `check_coverage.rb`
**覆盖率检查 v1。** 检查每个对话文件中哪些字符串被脚本引用但未被分析发现。

### `check_coverage2.rb`
**覆盖率检查 v2。** 直接对比对话文件中的所有字符串 vs 分析输出中的所有字符串，统计覆盖率。

---

## ruby_tools/ — 原始破解工具

### `commands_parse_tools.rb`
**指令解析基础库。** 被所有脚本引用。

功能：
- `$pcOffset` — 每个 opcode 对应的指令长度
- `Command` 类 — 指令数据结构 (index, code, params)
- `parse_commands(fn)` — 从 .DAT 二进制文件解析指令流
- `getCommandOffset()` — 处理 0x000A / 0x0027 / 0x2028 等变长指令

### `group_commands.rb`
**早期控制流分析。** 通过 CFG (Control Flow Graph) 静态分析指令块。

功能：
- `DisjointSet` — 并查集数据结构
- `process2(fn)` — 构建跳转目标索引，按基本块分组
- 输出 `#{fn}_dialogs.json`

局限性：
- 不追踪变量值，不模拟执行
- 不对 0x0027 switch 做变量解析
- 已被 `group_dialogs.rb` 取代

### `group_dialogs.rb`
**旧版对话提取器。** 符号执行 VM，遍历脚本路径提取对话文本。

功能：
- `Context` / `Route` / `RouteManager` 三件套
- 单变量表追踪 (仅 A82C4)
- 从 PC=127 启动，硬编码 F8=3, F9=0xA
- `parse_dialog_contents(id)` — 解析 Shift-JIS 对话文本

局限性：
- 不追踪 RegByteB，盲目 fork 0x0020/21/22 导致大量假路径
- 单变量表，不支持 mode==4 的 A82C8 表
- 0x0022 语义实现错误
- 不探索外部变量分支

### `format_commands.rb`
**指令格式化器。** 将二进制指令文件转换为可读文本。

用法：
```
ruby format_commands.rb
```

输出：`CM1100.DAT_X_commands.txt`，格式 `offset: opcode params...`

### `get_all_command_files.rb`
**可达脚本发现器。** 从脚本 1 开始，递归追踪所有 0x002C 引用。

输出：
- 可达脚本 ID 列表
- 引用的对话文件 ID 列表
- 常用变量 ID 交集

### `get_assigned_variable_ids.rb`
**变量统计器。** 统计脚本中被赋值和引用的变量 ID。

### `dialog_content_parse_tools.rb`
**对话内容解析器。** 解析 `CM1100.DAT_{id+0x29}` 文件中的 Shift-JIS 字符串。

### `extract.rb`
**DAT 分割器。** 将 `CM1100.DAT` 大文件按索引表分割为 `_0`, `_1`, ... 子文件。

### `extract-text.rb`
**文本提取器。** 从 `CM1100.DAT_42` 中直接提取 Shift-JIS 字符串。

### `compare.rb` / `compare_test.rb`
**对比工具。** 对比 `actor0.txt` 和 `actor3.txt` 中的角色数据差异。

### `search_binary.rb`
**二进制搜索器。** 在文件中搜索 MIPS 指令模式。

### `find_unused_mem.rb`
**内存空隙分析。** 分析 `memory_mark` 文件，找出连续空字节区域。

---

## 关键文件映射

| 文件 | 作用 |
|------|------|
| `CM1100.DAT` | 主数据包，包含所有命令和对话 |
| `CM1100.DAT_{id}` | 分割后的单独命令脚本 (id=1~40) |
| `CM1100.DAT_{id+0x29}` | 对话文本文件 (id 对应 0x002F 参数) |
| `CM1100.DAT_X_commands.txt` | 格式化后的指令文本（可读） |

## 指令参考

详见项目根目录的：
- `指令分析.txt` — 完整指令集说明
- `0027指令说明.txt` — 0x0027 (switch-on-var) 详解

## Ghidra 关键函数

| 函数 | 地址 | 作用 |
|------|------|------|
| `ExecuteCommand` | 80019e28 | 主调度循环 |
| `ExecuteCommandWithContextId` | 80019e88 | 分上下文执行 |
| `InitializeCommandSystem` | 80019c7c | 初始化变量表 |
| `Command0027_JumpToOffset` | 8001aefc | 0x0027 精确实现 |
| `Command0010_AssignImmediate` | 8001a768 | 变量赋值 |
| `Command0005_CheckEqual` | 8001a648 | 比较并设置 RegByteB |
| `Command0003_CheckVariableZero` | 8001a59c | 检查变量是否为零 |
| `Command002C_SetupCommandsListToLoad` | 8001b234 | 设置子脚本加载 |
| `Command002D_LoadCommandsList` | 8001b3c4 | 实际加载子脚本 |
