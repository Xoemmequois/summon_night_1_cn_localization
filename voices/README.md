# voices/ — 角色语音与 TTS 训练清单

从《サモンナイト》ROM 提取的角色语音、用于 GPT-SoVITS 的训练清单，以及从 ROM
**提取 / 重建**音频的工具。

---

## 目录结构

```
voices/
├── README.md
├── .gitignore                  （忽略 *.wav、.venv、*.npz、__pycache__）
├── .venv/                      numpy + faster-whisper（工具用；可删，用 pip 重装）
├── tools/
│   ├── script_parser.py            CM1100 命令脚本解析器（被下面两个工具共用）
│   ├── build_voice_dataset.py      从 ROM 直接提取某角色的语音数据集
│   └── rebuild_wavs.py             仅凭训练清单 + ROM 重建 wav
├── dataset/リブレ/
│   └── list_matched_clean.txt      ★ 训练清单（141 行，文本 100% 来自游戏脚本原文）
└── check_script36_ribre/           已人工确认的 22 条结局夜会话（wav；默认不入库，即清单里的 CM5102_23xx）
```

> `.wav` 不在仓库里常驻：用 `rebuild_wavs.py` 从 ROM 重建（秒级，实测与原始文件字节一致）。

---

## ★ 训练清单 `dataset/リブレ/list_matched_clean.txt`

格式：`文件名|リブレ|ja|文本`（只存文件名，不含任何机器路径）。

| 项目 | 值 |
|---|---|
| 条数 / 时长 | **141 条 / 518 秒 ≈ 8.6 分钟** |
| 目标音频规格 | 32 kHz / 16-bit / mono（由 `rebuild_wavs.py` 生成） |
| 语言 / 说话人字段 | `ja` / `リブレ` |
| 文本来源 | **CM1100 脚本原文**（ASR 仅用于检索定位，不作为最终文本） |
| 前后处理 | 去首尾静音（-42 dB，留 30 ms）、重采样 32 kHz、去重 |

**已知限制**
- 约 20 条是极短句（如 `あ、うん`、`ごめんなさい`），停顿占比高，时长与字数对不上属正常。
- 情绪偏剧情对话；`CM5102_23xx`（结局夜会话）是同一场戏、情绪较集中。
- 音源是 4-bit XA-ADPCM（≈电话级音质）。

---

## 工具一览

| 工具 | 作用 |
|---|---|
| `build_voice_dataset.py` | **从 ROM 提取**某角色的语音数据集（bank + 控制流感知地判定说话人，去静音 / 32 kHz / 去重） |
| `rebuild_wavs.py` | **从训练清单重建** wav（文件名已含 bank + voice id，无需其它索引文件）；可顺带生成绝对路径清单 |
| `script_parser.py` | CM1100 命令脚本解析器（共用） |

---

## 用法 1：重建音频（训练前必做）

```powershell
voices/.venv/Scripts/python voices/tools/rebuild_wavs.py --list voices/dataset/リブレ/list_matched_clean.txt --out voices/dataset/リブレ --abs-list voices/dataset/リブレ/list_abs.txt
```

- `--out`：wav 输出目录（可与清单同目录）
- `--abs-list`：可选，同时输出一份**绝对路径版清单**（GPT-SoVITS 需要真实路径）
- 实测 **141/141 与原始 wav 字节一致**
- 前提：`romhack/rom/CM5000.DAT` + `CM5100/5101/5102.DAT`（或原始 ISO）已解包

---

## 用法 2：从 ROM 提取其他角色

```powershell
voices/.venv/Scripts/python voices/tools/build_voice_dataset.py --character ガゼル
voices/.venv/Scripts/python voices/tools/build_voice_dataset.py --character ガゼル --dry-run
```

输出到 `voices/dataset/<角色>/`：`*.wav`、`metadata.csv`（元数据账本）、
`list.txt` / `list_raw.txt`（**文本未经校正，别直接用于训练**）。

> 可用角色名见 `romhack/char_names_translated.json`（`ソル` `キール` `カシス` `クラレット` `ガゼル` …）。
> 注：本目录只保留"提取 + 重建"工具；把脚本台词**校正为与音频一致**的一遍性流程
> （whisper 比对 + 模糊匹配回原文）产出的结果已经固化在 `list_matched_clean.txt` 里。
>
> **语音库归属**：莉普蕾的提取结果里，人工试听确认有 3 条并非她的声音——
> `CM5100_0505`、`CM5101_1052`、`CM5101_1053`。它们不在训练清单中（训练清单是人工确认后的结果；
> `build_voice_dataset.py` 只负责提取，不做这类过滤）。

---

## 用 GPT-SoVITS 训练

### 1. 准备数据
在本机重建 wav（用法 1，带 `--abs-list`），然后把 `*.wav` + `list_abs.txt` 拷到训练机。
若在训练机上有 ROM 数据，也可以直接在那里跑“用法 1”。

### 2. 环境
较新的 NVIDIA 架构需要配 CUDA 12.8+ 的 PyTorch（旧版 torch 可能识别不到新卡）。

```powershell
python -m venv <venv>
<venv>\Scripts\pip install -r <GPT-SoVITS>\requirements.txt
<venv>\Scripts\pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu128
# 必须输出 True + 卡名
<venv>\Scripts\python -c "import torch;print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

### 3. 训练流程
1. **训练集格式化**：指定 `list_abs.txt`、实验名（如 `ribre`）、语言 `ja` → 生成 `logs/ribre/`。
2. **提取特征**：文本 SSL 特征 / 语义 token / HuBERT 特征（一键三连）。
   *已切好单句，跳过 slicer；文本已校对，跳过 ASR。*
3. **训练**：SoVITS batch 2–4、epoch 8–15；GPT batch 2–4、epoch 10–20（按实际情况调整 batch）。
4. **推理**：用生成的 `s2G*.pth` + `s1*.ckpt`；参考音频建议用
   `check_script36_ribre/` 里的片段（3–8 s，已人工确认是莉普蕾）。

### 4. 空间
| 项目 | 占用 |
|---|---|
| torch(cu128) + 依赖 | 6–10 GB |
| GPT-SoVITS 底模 | 3–5 GB |
| `logs/<exp>/` 特征 + 检查点 | 1–4 GB（旧 ckpt 可删） |
| 数据集 | ~40 MB |
| **建议预留 / 最终成品** | **20 GB / 成品 0.5–1.5 GB** |

> 环境、底模与 `logs` 建议放在空间充足的分区（合计预留约 20 GB）。

---

## 背景：数据是怎么来的

1. **语音库分 bank**：脚本指令 `0x2019` 按 bank 取音频，bank 由当前脚本号决定——
   `script id ≤14 → CM5100`，`15–27 → CM5101`，`≥28 → CM5102`，`voice id ≥10000 → CM5200`；
   索引表在 `CM5000.DAT`。忽略 bank 会让约一半的脚本归属自相矛盾。
2. **音频格式**：CD-XA ADPCM，mono / 18900 Hz / 4-bit，32 扇区为一轮交织；一条语音占
   `start, start+32, … end`。
3. **说话人判定**：沿脚本控制流跟踪 `0x2001/0x2002`（左右立绘）与 `0x2010`（对话框方向）。
4. **文本**：`0x2013` 的 id 索引到 `0x002F` 载入的对话子内容；本清单的文本已用 ASR 反查校正为脚本原文。
