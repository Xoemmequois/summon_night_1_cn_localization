# AGENTS.md — Summon Night (PS1) Reverse Engineering & Chinese Localization

## Project

PS1 "Summon Night" reverse engineering + Chinese localization romhack, focusing on text extraction, font replacement, and ROM patching.

## Architecture

- **Analysis**: `ghidra-mcp` for MIPS disassembly of `SLPS_025.42`. PCSX-Redux Lua scripts (`pcsx-redux-lua/`) for dynamic tracing of GPU LoadImage, command execution, and callstacks. Ruby tools in `ruby_tools/` are for VM simulation analysis only — **not for builds**.
- **Build/Mod**: C# .NET 8 solution in `romhack_csharp/` — the canonical toolchain. **`romhack/*.rb` Ruby scripts are DEPRECATED.** All new build work goes in C#.

## Prerequisites

- `romhack/config.json` — loaded at runtime by the C# toolchain. Defines `SdkPath`, `GamePath`, `ValidStage`, OpenRouter credentials. Place your own — **do not commit** (contains API key).
- `ghidra-mcp` — primary tool for analyzing `SLPS_025.42` binary.
- PSn00bSDK at the path in `config.json.SdkPath` — provides `mipsel-none-elf-gcc`, `dumpsxiso`, `mkpsxiso`.

## Key Commands

```powershell
# Extract text + images only (CWD: romhack/)
dotnet run --project ..\romhack_csharp -- --rip

# Full build: translate → build fonts → patch ROM → repack ISO
# Requires zh_CN_translated.json and rom_text_zh_CN.json with translations filled in
dotnet run --project ..\romhack_csharp

# Ruby VM analysis (legacy — analysis only, CWD: ruby_tools/opencode_generated/)
ruby analyze_script3.rb [script_id]      # default id=3
ruby batch_analyze.rb                    # all reachable scripts 1-40

# Extract all dialogue voices (CWD: repo root)
python tools/extract_voices.py            # CM5100+CM5200 -> voices/*.wav + voices.json
python tools/extract_voices.py --dry-run  # list voices without decoding
python tools/extract_voices.py --ids 0,1  # subset
```

## Summon Night File Formats

### Sector-Indexed Container (CM1100.DAT, CM1200.DAT, CM2000.DAT, CM3000.DAT)

All `.DAT` files use the same top-level format. Sub-content is read via `ExtractUtil.GetSubcontent(data, id)`:

```
Offset  Size  Field
0x00    16    Header (game-specific, varies per file)
0x10    N×4   Index table: array of (ushort sector_offset, ushort sector_count)
              Byte offset  = sector_offset × 0x800
              Byte length  = sector_count × 0x800
```

All multi-byte values are **little-endian 16-bit** (`data[i] | data[i+1] << 8`).

### Dialogue Text Format (CM1100.DAT subcontents id+0x29, IDs 1–145)

Each subcontent stores dialogue strings for one script:

```
Offset  Size    Field
0x00    N×2     ushort[N] string_offsets   — word-offsets (÷2), NOT byte offsets.
                offsets[0] = N: doubles as string count (since first string
                immediately follows the index table at byte N×2).

Then:           raw strings — Shift-JIS, each terminated by 0x00 0x00.
                Actual byte position of string[i] = offsets[i] × 2.
```

Control characters: `@` (unit `0x4000`) spans **3 units** (6 bytes): `0x4000` + param1 + param2.
`@n` is stored as `40 00 6E 00 00 00` — the trailing `00 00` is a control param, NOT the string
terminator. During rip, `@n` → `\x40\x6E` and reading continues past the `00 00`. During build,
`@` → `0x4000`, `n` → `0x6E00`, and the 3rd unit `00 00` must be written back.

Chinese characters use custom encoding:
- `0x85xx` → index `(b0 - 0x85) × 256 + b1` (0–767)
- `0x99xx` → index `(b0 - 0x99) × 256 + b1 + 768` (768+)
- Max 2560 characters (0x85xx × 3 + 0x99xx × 7)

### Shared Font Region (shared_text.txt)

Characters listed in `romhack/shared_text.txt` (UTF-8, duplicates allowed, next to
`zh_CN_translated.json`; missing file = build error) must render correctly through BOTH the
large-font and small-font renderers, so both fonts assign them identical codes:

- Shared code region: `0x8540`–`0x87FF` (full linear `IndexToSjis` trails, no SJIS domain limits).
- Small-font side: linear inverse of `IndexToSjis` → mapIndex 768 (`0x8540`) … 1343 (`0x87FF`);
  candidates already occupied in the original CM1200 map table are skipped. Allocated FIRST by
  `SmallFontBuilder.Build`, own chars resume scanning at MapIndexStart=524 afterwards.
- Big-font side: `Program.PinSharedChars` pins these codes into `Chars` before CM1100 conversion;
  `GetNextCharId` skips reserved indices (gaps stay blank glyphs — shared chars keep their
  position even when few other chars exist).
- Outputs: `output/chinese_font_map.json` (big) + `output/small_font_map.json` (small);
  `FontMapVerifier.Verify` fails the build if any shared char's codes differ across maps.
- Non-shared codes may legitimately exist in both maps with different chars — each font only
  renders its own text streams; verifier reports this as an informational notice.

### Script Command Format (CM1100.DAT_{id} files)

Extracted command script files. Parsed by `commands_parse_tools.rb:315`:

```
Header:   6 ushorts (12 bytes) — unknown/padding, skipped
Body:     Sequence of commands in little-endian 16-bit words:
          [ushort opcode] [ushort params...]

Total instruction length depends on opcode (see $pcOffset hash):
  Fixed-length:  e.g. 0x0010 → 3 words (opcode + immediate + var_id)
  Variadic:
    0x000A → complex loop parser (instr000A)
    0x0027 → switch-on-variable; followed by jump targets as ushort[]
              terminated by 0x0000. Total 5 bytes + 2*jump_table words.
    0x2028 → first param determines total length (instr2028)
  Unknown → defaults to length 1 (opcode only)
```

The opcode table is split into three ranges: `0x00xx` (basic ops), `0x10xx` (extended), `0x20xx` (dialog/sprite ops). Key opcodes:
- `0x0027`: switch on variable (mode=2 → table at `*0x800A82C4`, mode=4 → table at `*0x800A82C8`)
- `0x002F`: load dialog text (param = subcontent index − 0x29)
- `0x002C/0x002D`: sub-script load (scripts 1–40)
- `0x2013`: add dialog line
- `0x2019`: play dialogue voice (1 param = voice id). See "Dialogue Voice Format" below.
- `0x0020/0x0021/0x0022`: conditional branch on RegByteA/RegByteB flags

### Dialogue Voice Format (0x2019 → CM5100.DAT / CM5200.DAT)

`Command2019_PlayVoice?` @ `0x8001ffb4` calls `FUN_80031478(voice_id)`:

- `voice_id < 10000` → **CM5100.DAT**, index = `voice_id` (2552 voices, ids 0–2551)
- `voice_id ≥ 10000` → **CM5200.DAT**, index = `voice_id − 10000` (56 voices, ids 10000–10055)

Voice index tables live in **CM5000.DAT** (u32 count, then 4-byte entries):

```
CM5100: count @ 0x800  (=2552), entries @ 0x804, base disc LBA 43518
CM5200: count @ 0x8000 (=56),   entries @ 0x8004, base disc LBA 190014
Entry:  u16 start_sector   (low 5 bits = XA channel, 0–31)
        u16 end_sector     (same channel bits, inclusive)
```

Audio is **CD-XA ADPCM, mono / 18900 Hz / 4-bit**, stored as a 32-channel
interleaved stream (one channel per sector, 32-sector cycle). A voice occupies
sectors `start, start+32, … end` → `(end − start)/32 + 1` sectors × 0.21333 s.
The decoder must keep the ADPCM predictor history across all sectors of a voice.

`dumpsxiso` output (`rom/CM51xx.DAT`) is 2336 bytes/sector:
`8-byte XA subheader + 2324 B Mode2 user data + 4 B EDC`; only the first
2304 B (18 × 128-byte sound groups) are ADPCM. Extractor: `tools/extract_voices.py`.

### Flat Offset-Indexed Collection (GetSubContentOffset)

Used within subcontent blobs to locate nested sub-blobs (pic_extract, `RipTool.cs:159`):

```
Offset +0x00:  ushort  entry_count
Offset +0x04:  int32[entry_count]  absolute byte offsets (lower 24 bits, & 0xFFFFFF)
               Offset = 0x00000000 → empty/non-existent entry.

Size of entry[i]:
  Find next non-zero offset[j] (j > i): size = offsets[j] − offsets[i]
  If no next non-zero:                  size = subcontent.Length − offsets[i]
```

Applied in:
- CM3000 character portraits (subcontents 0x89–0xCC): indices 0/1 = texture TIMs, 2/3 = animation sprites
- CM2000 subcontent 7 (shop): indices 5, 6, 8 = shop TIM images
- CM2000 subcontent 12 (map): indices 0..N = map background TIM images

### TIM Format (PSX Texture Image — CM2000, CM3000)

```
TIM Header (16 bytes from offset):
  +0x00: uint32  tag/magic (ignored)
  +0x04: int32   clut_offset (relative to TIM start)
  +0x08: int32   pix_offset  (relative to TIM start)

CLUT (at offset + clut_offset):
  +0x00: uint16   width (entries count; ==256 → 8bpp, else → 4bpp)
  +0x02: uint16   height
  +0x04: uint16[] RGB555 entries: R=bits[0:4]<<3, G=bits[5:9]<<3, B=bits[10:14]<<3
         Entry 0 → A=0 (transparent), others A=255.

Pixel data (at offset + pix_offset):
  +0x00: uint16   width (in 16-bit words; actual = words × 2)
  +0x02: uint16   height
  +0x04: byte[]   indexed pixels: pix_width bytes per row × pix_height rows
         4bpp: each byte = 2 pixels (lo nibble then hi nibble)
         8bpp: each byte = 1 pixel
```

### Animation Sprite Blob (CM3000 character portraits)

```
Blob Header (16 bytes):
  +0x00: uint32  flags
  +0x04: int32   anim_data_offset  (relative to blob start)
  +0x08: int32   frame_data_offset
  +0x0C: int32   part_rect_offset

PartRect block:
  +0x00: uint32           count
  +0x04: PartRect[count]  each 4 bytes: {byte U, V, W, H}

FrameData block:
  +0x00: uint32                    count
  +0x04: uint16[count]             entry offsets
  Entry: +0x00: byte  part_count
         +0x04: FramePart[part_count]:
                +0x00: byte   flags (bit 2 = has scaleX/Y)
                +0x01: byte   rect_index
                +0x02: byte   local_x
                +0x03: byte   local_y
                +0x04: uint32 attr (bits 0-1 = texture: 0=bmp0, 1=bmp1)
                +0x08: ushort? scale_x, scale_y (if flags & 0x04) → 12 bytes, else 8

AnimData block:
  +0x00: uint32                    count
  +0x04: uint16[count]             entry offsets
  Entry: +0x00: uint16 frame_count
         +0x04: uint32[frame_count]:
                bits[0:6]   = frame_data_index
                bits[7:12]  = duration
                bits[13:21] = offset_x (sign-extended from bit 21)
                bits[23:31] = offset_y
```

### 12×12 Small Font Glyph (S.F file — 18 bytes per glyph)

12 rows of 12 bits, swizzled: 3 ushorts encode 4 rows, repeated 3 times.

```
output[0]  = ((row0[3:0] << 4) | (row1[11:8]))
output[1]  = (row0[11:4])
output[2]  = (row2[11:4])
output[3]  = (row1[7:0])
output[4]  = (row3[7:0])
output[5]  = ((row2[3:0] << 4) | (row3[11:8]))
— same pattern for rows 4–7 and 8–11
```

Bit 11 = leftmost pixel. Row stored as ushort (`0x800 >> x`).

S.F file layout: 6-byte padding (GlyphIndexBase=0x3BB, first glyph at memory `0x801B1006`), then N × 18 bytes.

CM1200 font map (subcontent 8): entries at `0x28E0 + index×2` (indices 524–4607). Entry=0 = free slot. SJIS for new characters: `lead=0x81+mapIndex/0xC0`, `trail=0x40+mapIndex%0xC0`.

### 14×14 Large Font Glyph (chinese.fnt — 28 bytes per glyph)

```
14 rows × 2 bytes each (15 bits per row + 1px left padding).
byteIndex = y × 2 + (1 − bitIndex/8)
bitMask   = 1 << (bitIndex % 8)
bitIndex  = 15 − (x + 1)   // x+1 accounts for left padding
```

chinese.fnt layout: `[N × 28-byte glyphs (4-byte aligned)] + [font.s compiled code] + [load_small.s compiled code]`.

## romhack_csharp Solution

All projects under `romhack_csharp/`, working directory is `romhack/`.

| Project | Type | Purpose |
|---------|------|---------|
| `romhack_csharp` | EXE (.NET 8) | Pipeline orchestrator: rip text/images, build fonts, patch ROM, repack ISO |
| `SummonNightLib` | Library (.NET 8) | `TranslationItem` + `ExtractUtil` (.DAT reader) |
| `small_font` | Library (.NET 8-windows) | SLPS_025.42 embedded text + 12×12 small font |
| `pic_extract` | Library (.NET 8-windows) | Image extraction from CM2000/CM3000, AI classification, map name writeback |

**Source files:**

| File | Role |
|------|------|
| `romhack_csharp/romhack_csharp/Program.cs` | Main entry — full rip/build pipeline |
| `romhack_csharp/romhack_csharp/romhack_csharp/Config.cs` | Loads `config.json` from CWD |
| `romhack_csharp/romhack_csharp/GameTextRipper.cs` | CM1100 dialogue → `zh_CN.json` |
| `romhack_csharp/romhack_csharp/GenFontBitmap.cs` | 14×14 glyph rendering (SimSun via GDI+) |
| `romhack_csharp/romhack_csharp/CodeModifier.cs` | Write load code + patch JAL in SLPS_025.42 |
| `romhack_csharp/romhack_csharp/JalCodeModifier.cs` | MIPS JAL instruction patcher (opcode 0x03) |
| `romhack_csharp/romhack_csharp/ExtraCodeBuilder.cs` | Compiles load.s/load_small.s/font.s via mipsel-gcc |
| `SummonNightLib/ExtractUtil.cs` | `GetSubcontent(data, id)` + `ReadUShort` |
| `SummonNightLib/TranslationItem.cs` | `{key, original, translation, stage}` model |
| `small_font/RomTextRipper.cs` | SLPS_025.42 embedded text → `rom_text.json` |
| `small_font/SmallFontBuilder.cs` | 12×12 glyphs, CM1200 map patch, S.F output |
| `small_font/RomTextWriter.cs` | Write translated text back to SLPS_025.42 in-place |
| `pic_extract/RipTool.cs` | TIM parser, animation blob parser, char/map/shop ripper |
| `pic_extract/CharNameClassifier.cs` | OpenRouter Gemini AI: text vs non-text classification |
| `pic_extract/CharNameDedup.cs` | Deduplicate char name images by size comparison |
| `pic_extract/PreviewMapname.cs` | Preview + diff images for translated map names |
| `pic_extract/WriteBackMapname.cs` | Write translated map name pixels → CM3000.DAT |

### Pipeline Overview

```
--rip flag (or no rom/ dir):
  1. dumpsxiso: ISO → rom/
  2. GameTextRipper: CM1100.DAT → zh_CN.json
  3. RomTextRipper: SLPS_025.42 → rom_text.json
  4. RipTool: CM3000.DAT → pic_output/chars/*.gif + mapnames/*.gif
  5. RipTool: CM2000.DAT → pic_output/shop/*.gif + map/*.gif
  6. CharNameClassifier → AI classifies text images
  7. CharNameDedup → removes duplicates

Build (default):
  1. Load zh_CN_translated.json + shared_text.txt + rom_text_zh_CN.json
  2. SmallFontBuilder: pin persisted EnemySkill codes (rom_text_presist_codes.json), assign shared
     chars (region 0x8540+) then own chars → S.F + CM1200.DAT.mod; write codes back to
     rom_text_presist_codes.json
  3. RomTextWriter: write translations → SLPS_025.42
  4. PinSharedChars + Process CM1100 dialogues → allocate char codes → CM1100.DAT.mod2
  5. Write chinese_font_map.json + small_font_map.json; FontMapVerifier cross-checks them
  6. GenFontBitmap: render 14×14 glyphs → chinese.fnt
  7. CodeModifier: inject load code + JAL patches → SLPS_025.42.mod2
  8. WriteBackMapname: translated GIFs → CM3000.DAT.mod2
  9. mkpsxiso: build final Chinese ISO
```

## Game VM Reference (for ghidra-mcp analysis)

- `ExecuteCommand` at `0x80019e28` — main dispatch loop.
- Two variable tables: `*0x800A82C4 = 0x800EF000` (mode 2), `*0x800A82C8` (mode 4).
- Opcode `0x0027` = switch-on-variable (see `0027指令说明.txt`).
- Script IDs: 1–40 (loaded via 0x002C/0x002D). Dialog file ID = script ID + 0x29.

**SLPS_025.42 key memory regions:**

| File Offset | Memory Address | Content |
|-------------|---------------|---------|
| `0x7A1E0` | `0x800899E0` | Equipment array — 265 entries × 0x24 (name + 3 desc ptrs) |
| `0x7C724` | `0x8008BF24` | Item array — 25 entries × 0x14 (name + 3 desc ptrs) |
| `0x7CEEC` | `0x8008C6EC` | Enemy skill name pointers |
| `0x7D524` | `0x8008CD24` | Magic array — 8 entries × 0x14 (name + 3 desc ptrs) |
| `0x7D5C4` | `0x8008CDC4` | State/Skill array — 40 entries × 0x14 |
| `0x7C99C` | `0x8008C19C` | Unknown desc array — 56 entries × 0x18 |
| `0x7F420` | `0x8008EC20` | Hint table — triple-string hint groups |
| `0x7F568` | `0x8008ED68` | Naming tables: Hiragana, Katakana, Symbols, Kanji (198 bytes each) |
| `0x85EFC` | — | Load code injection site (≤0x54 bytes, JAL → `0x800956FC`) |
| `0x80036738` | — | Font function JAL redirect |

## Key Reference Documents

| File | Covers |
|------|--------|
| `指令分析.txt` | Complete opcode listing (235 lines) |
| `0027指令说明.txt` | 0x0027 switch-on-variable: mode, var_id, jump table format |
| `文字内存地址分析.txt` | Text rendering call chain, control characters, memory layout |
| `从GPU Draw文字分析.txt` | GPU draw-call text rendering: LoadImage → GP0 DMA pipeline |
| `黑屏开关分析.txt` | Black screen vs dialog display state switching |
| `战斗跳过解析.txt` | Battle skip: character data at `0x8009D3A8`, 0x30 bytes/unit |
| `地图界面文字.txt` | Map interface: CM2000 sector mapping, LoadImage callstacks |
| `商店界面UI.txt` | Shop UI: CM2000 offset 0xC7, LoadImage, command 0x2074 |
| `图片分析_INCOMPLETE.txt` | Sprite image pool (8 slots), blob format overview |
| `小字库分析.txt` | Small font: CM1200 ROM layout (offset 0xCC000), equip/item arrays |
| `CM5200分析.txt` | CM5200 header linkage via CM5000 |
| `TEXT RAM-TO-VRAM HOW GP0 IS WRITTEN.txt` | GP0 command → DMA texture transfer flow |
| `ruby_tools/opencode_generated/README.md` | Ruby analysis tool docs |

## Conventions & Gotchas

- **romhack/ Ruby scripts are DEPRECATED** for builds. All build work in `romhack_csharp/`.
- **CWD** for build: `romhack/` (where `config.json` and `rom/` directory live).
- **Modified output files** use `.mod2` suffix (not `.mod`). Squashes conflicts with legacy Ruby.
- **Do not commit**: `romhack/config.json` (API key), `romhack/rom/`, `romhack/output/`, `romhack/pic_output/`, `romhack/exported_glyphs/`.
- **PSX addr → file offset**: `addr − 0x80010000 + 0x800`.
- **Encoding**: Japanese game text = Shift-JIS. Chinese output = custom `0x85xx`/`0x99xx`.
- **All .DAT files**: little-endian 16-bit values. Always use `ReadUShort`.
- **Variadic opcodes**: `0x000A`, `0x0027`, `0x2028`. Static `$pcOffset` table handles the rest.
- **Script IDs**: 1–40. Dialog subcontent ID = script ID + 0x29.
- **4bpp vs 8bpp**: CLUT width = 256 → 8bpp; anything else → 4bpp.
- **Word-offsets in dialogue**: `indices[i]` is a word-offset — multiply by 2 for byte position.
- **Save-persistent char codes**: `romhack/rom_text_presist_codes.json` (committed) records
  char → small-font SJIS for EnemySkill names, which the game copies into save files. Codes are
  kept stable across builds; forced changes (e.g. char moved into shared_text.txt) print a
  `PersistCodes: warning` and continue.
