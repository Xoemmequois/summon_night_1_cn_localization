# Summon Night (PS1) 汉化项目

本项目是对 PS1 游戏《Summon Night》进行逆向与中文本地化的 romhack 工程。
日常使用只需要仓库根目录的 **`build.bat`**：它会自动检查环境、解包原版 ISO、
提取文本与图片，并（在翻译完成后）重新生成中文字库、写回并打包成中文版 ISO。

> **关于本文档**：本 README 由 AI 生成，但已经过作者逐条核对，确认其内容就是作者想要表达的。
> 如果你看不太懂其中的技术内容，可以请 AI 帮忙 —— 建议使用带 harness 的工具（例如
> **TRAE**、**OPENCODE**、**DSH** 等），它们能帮你安装依赖、运行脚本；**workbuddy** 应该也可以。

更深入的技术细节（文件格式、内存地址、opcode 等）见 `AGENTS.md`；
对话文本的结构与注意事项（「行」/「组」、跨组复用、几个已知特殊情况）见
[`汉化对话.md`](汉化对话.md)。

---

## 一、环境要求

- Windows（字体渲染与图片处理依赖 Windows GDI+）
- .NET 8 SDK
- Python 3（用于把 `processed\` 下的译文写回 `zh_CN_translated.json`，见步骤 3）
- PSn00bSDK（提供 `dumpsxiso` / `mkpsxiso` / `mipsel-none-elf-gcc` 等）
- 原版《Summon Night》日版 ISO
- 系统需安装宋体（SimSun，Windows 自带），用于生成中文字形

---

## 二、快速开始：build.bat 全流程

### 步骤 0：克隆项目

```powershell
git clone <仓库地址>
cd summon_night_analysis
```

### 步骤 1：创建 config.json

`config.json` 不在版本库里，需要自己创建。把示例复制过去：

```powershell
copy romhack_csharp\config.json.sample romhack\config.json
```

然后编辑 `romhack\config.json`，填入 SDK 和原版 ISO 的路径：

```json
{
  "SDKPath": "C:\\path\\to\\PSn00bSDK-0.24-win32\\",
  "GamePath": "C:\\path\\to\\Summon Night (Japan).bin",
  "ValidStage": [3, 5],
  "OpenRouterKey": "",
  "OpenRouterProxy": ""
}
```

| 字段 | 说明 |
| --- | --- |
| `SDKPath` | PSn00bSDK 根目录，其 `bin\` 下要有 `dumpsxiso.exe`、`mkpsxiso.exe`、`mipsel-none-elf-gcc.exe` 等 |
| `GamePath` | 原版日版 ISO 的完整路径（RIP 时需要） |
| `ValidStage` | 只处理这些 stage 的文本 |
| `OpenRouterKey` | 可选。填了才会用 AI 判定哪些角色图片含文字；不填也能正常汉化 |
| `OpenRouterProxy` | 可选，访问 OpenRouter 的代理 |

> `config.json` 含 API Key，**不要提交到版本库**。

想先确认配置是否正确，可以运行 `build.bat -CheckOnly`（只检查，不 RIP、不编译、不执行）。

### 步骤 2：第一次运行 —— RIP（提取文本与图片）

双击 **`build.bat`**（或在 PowerShell 里运行 `.\build.ps1`）。

脚本会：检查 .NET 与 `config.json` → 编译 → 调用 `dumpsxiso` 解包 ISO、
提取文本与图片。**RIP 完成后会自动停止，不会继续封包**（这是有意设计）。

RIP 产物：

| 产物 | 内容 |
| --- | --- |
| `romhack\rom\` | 解包出来的游戏文件（`SLPS_025.42`、`CMxxxx.DAT` 等） |
| `romhack\zh_CN.json` | 对话框文本（待翻译） |
| `romhack\rom_text.json` | 菜单 / 道具 / 技能 / 提示等内嵌文本（待翻译） |
| `romhack\pic_output\` | 提取出的图片（`.gif` + 同名 `.act` + `.meta.json`） |
| `romhack\pic_output\char_names\` | 角色名图片；有 `OpenRouterKey` 时才用 AI 判定，否则按 `.progress.json` 恢复已判定结果 |

### 步骤 3：汉化文字（对话框）

> 对话文本的结构（「行」是最小单位、同一行会被多个组复用、几个已知特殊情况）
> 见 [`汉化对话.md`](汉化对话.md)。

对话框译文在 **`ruby_tools\opencode_generated\processed\`** 里维护：
每个 `scriptXX_fidYY.txt` 中，`--- Group … ---G` 表示**这个组已经汉化好**，
不带 `---G` 的组会被无视。把带 `---G` 区块里的 `+[FID:XXXX, TEXT:YYYY] 译文`
行填上中文（`FID` 就是 `zh_CN.json` 里 key 的前半段，`TEXT` 是后半段）。

填好后运行仓库根目录的 **`apply_text.bat`**（会先检查 Python），它会读取 `processed\`
下所有 `script*_fid*.txt`，把译文合并进 `romhack\zh_CN_translated.json`。

> 注意：`apply_translations.py` 只是把 `processed\` 转成 `zh_CN_translated.json`；
> **实际构建、写回 ROM 时读的是 `romhack\zh_CN_translated.json`**，而不是 `processed\`。
> 即：`processed\`（带 `---G` 的组）──apply_text.bat──▶ `zh_CN_translated.json` ──build.bat──▶ 写回。

等价的命令行方式：

```powershell
python romhack\apply_translations.py
```

**（不推荐）** 也可以直接编辑 `romhack\zh_CN.json` 并另存为 `zh_CN_translated.json`，
每条记录只填 `translation`（`key` / `original` / `stage` 原样保留）：

```json
{ "key": "0001-0000", "original": "原文", "translation": "译文", "stage": 3 }
```

> 之所以不推荐：下次运行 `apply_text.bat`（`apply_translations.py`）时，`processed\` 里
> 已汉化（带 `---G`）的内容会**覆盖** `zh_CN_translated.json` 中对应的条目，
> 直接手改的部分会被冲掉。请统一在 `processed\` 里维护译文。

注意：

- `@n` 是**玩家名字**的占位符，`@` 开头的都是游戏控制符，请原样保留、不要翻译或改动
- `translation` 留空会把该条原文清空（**不是**保留原文）
- `---G` 标记表示该组已汉化；不带 `---G` 的组会被 `apply_translations.py` 忽略
- 同一个 key 出现不同译文会直接报错，先解决冲突再重跑
- 对话框文本没有逐条长度限制，会把整段对话重新排版

### 步骤 4：汉化小字库（菜单 / 道具 / 技能 / 提示）

1. 把 `romhack\rom_text.json` 翻译后，另存为 `romhack\rom_text_zh_CN.json`
   （格式同上，key 形如 `"EnemySkill-3-0x1A2B"`、`"Equip-12-Name-0x..."`）。
2. 把必须**同时**出现在大小两套字库里的字符，写进 `romhack\shared_text.txt`
   （逐行或连续写，可用 `@` 分隔；文件缺失会直接报错）。

注意：**小字库的每条译文按字节不能超过原文长度**，否则报 `Translation too long`。

### 步骤 5：汉化图片

> 图片编辑的详细步骤（以 Photoshop 为例）见 [`汉化图片.md`](汉化图片.md)。

1. 把**想要汉化的图片**按相同相对路径放进 `romhack\pic_output_translated\`
   （目录结构和文件名与 `romhack\pic_output\` 保持一致；不需要翻译的图不用放）。
2. 用图片工具编辑这些 `.gif`，要求：
   - 保持 **8bpp 索引色 GIF**，尺寸与原图一致
   - 保持原有调色板与索引（索引不能超出原图位深，如 4bpp 图最大索引 15）
   - 同名 `.act` 可一起复制，供作图参考

### 步骤 6：第二次运行 —— 编译并导出

再次双击 **`build.bat`**（或 `.\build.ps1`）。

这次脚本会：编译 → 写回文本与小字库 → 生成中文大字库 `chinese.fnt` →
写回图片 → 生成预览 → 用 `mkpsxiso` 打包。产物：

| 产物 | 内容 |
| --- | --- |
| `romhack\output\Summon_Night_Chinese.bin` + `.cue` | **最终中文版 ISO**（用模拟器加载 `.cue` 即可测试） |
| `romhack\pic_output_preview\` | 翻译图片的预览，`*_diff.png` 白色表示未改动区域 |
| `romhack\output\chinese_font_map.json` / `small_font_map.json` | 字符编码表 |

### 可选的命令行参数

```powershell
build.bat -CheckOnly     # 只检查环境与文件，不 RIP、不编译、不执行
build.bat -SkipImages    # 只构建文本，跳过「翻译图片」目录检查
```

在 PowerShell 里等价写法：`.\build.ps1 -CheckOnly`、`.\build.ps1 -SkipImages`。

> `build.bat` 可以放在仓库根目录从任意位置双击运行（会自动定位 `romhack\` 和 `romhack_csharp\`），
> 结束后会停在窗口显示结果。

---

## 三、要翻译的文件一览

| 翻译对象 | 输入（RIP 产出） | 翻译后另存为 |
| --- | --- | --- |
| 对话框文字 | `ruby_tools\opencode_generated\processed\`（填 `+[FID:.., TEXT:..]` 行） | `romhack\zh_CN_translated.json`（用 `apply_text.bat` 生成） |
| 小字库 / 内嵌文字 | `romhack\rom_text.json` | `romhack\rom_text_zh_CN.json` |
| 两种字库共享字符 | — | `romhack\shared_text.txt` |
| 图片 | `romhack\pic_output\` | 想汉化的图，按相同路径放到 `romhack\pic_output_translated\` |

翻译完成后重新运行 `build.bat` 即可导出。中途报错时，按提示补齐文件或修正配置后重新运行即可。

---

## 四、常见问题

| 报错 / 现象 | 处理 |
| --- | --- |
| `Config file not found` | 没有在 `romhack\` 目录下运行，或没创建 `romhack\config.json` |
| `SDKPath 指向的目录不存在` / 缺少工具 | 检查 `config.json` 的 `SDKPath` 是否指向 PSn00bSDK 根目录 |
| `GamePath 指向的文件不存在` | 检查原版 ISO 路径 |
| `shared_text.txt not found` | 在 `romhack\` 目录补齐该文件 |
| `Translation too long` | `rom_text_zh_CN.json` 的译文比原文长（按字节），精简译文；对话框文本不受此限制 |
| `Character 'X' not in ... font map` | 译文里有小字库未包含的字符，通常是该文本没出现在 `rom_text_zh_CN.json` 的翻译里 |
| `S.F 过大` / `chinese.fnt 过大` | 新增汉字太多，超出字库容量；减少用字或把必要字符放进 `shared_text.txt` 统一规划 |
| `translated GIF is not 8bpp indexed` / `size mismatch` / `index out of range` | 翻译图片格式 / 尺寸 / 索引不符合原图，按「步骤 5」重做 |
| 第一次运行后没有 ISO | 正常。RIP 完成后脚本会停止，翻译后再次运行才会封包 |

---

## 五、手动命令（可选，等价于脚本）

如果需要手动执行，先进入 `romhack\` 目录：

```powershell
cd romhack

# 提取（RIP）
dotnet run --project ..\romhack_csharp\romhack_csharp -- --rip

# 构建并封包
dotnet run --project ..\romhack_csharp\romhack_csharp
```

---

## 六、工程结构（简要）

| 路径 | 说明 |
| --- | --- |
| `build.bat` / `build.ps1` | 一键脚本（检查环境 → 自动 RIP → 构建封包） |
| `apply_text.bat` / `apply_text.ps1` | 一键脚本（检查 Python → 合并 `processed\` 译文） |
| `romhack\` | 工作目录：`config.json`、解包文件、翻译文件、输出都在这里 |
| `romhack_csharp\romhack_csharp\` | 主程序：串联提取 / 构建全流程 |
| `romhack_csharp\SummonNightLib\` | 公共库：翻译条目模型、`.DAT` 读取 |
| `romhack_csharp\small_font\` | 小字库与 `SLPS_025.42` 内嵌文本处理 |
| `romhack_csharp\pic_extract\` | 图片提取、AI 分类、图片回写与预览 |
| `AGENTS.md` | 完整技术文档（格式、地址、命令） |
| `ghidra_scripts\` / `pcsx-redux-lua\` | 逆向分析用 |
| `ruby_tools\` | 旧的 Ruby 分析工具（构建已废弃，仅作分析参考） |
| `voices\` / `docs\` | 语音 TTS 数据集 / 设计文档 |

---

## 七、约定

- 构建统一使用 `romhack_csharp`（通过 `build.bat`），不要再用 `romhack\` 下的旧 Ruby 脚本做构建。
- 修改后的输出文件统一使用 `.mod2` 后缀。
- 不要提交：`config.json`（含 Key）、`rom\`、`output\`、`pic_output\`、`exported_glyphs\`。
