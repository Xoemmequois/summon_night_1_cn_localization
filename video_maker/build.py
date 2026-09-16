"""Build a modified Summon Night (JP) ISO.

The opening dialogue is written into romhack/zh_CN_translated.json (overwriting
the original prologue lines), then romhack_csharp.exe rebuilds the fonts and
writes ALL dialog text.  Python only patches the command script (portrait /
expression / voice) and swaps the voice audio.

Run from anywhere:  python video_maker2/build.py
Outputs: video_maker/output/Summon_Night_video.bin (+ .cue)
"""
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from vmtools import dialog, iso, xa
from vmtools.common import sub_range

ROMHACK = os.path.join(HERE, "romhack")            # C# working directory
ROMHACK_EXE = os.path.join(HERE, "romhack_csharp", "romhack_csharp.exe")
ROM = os.path.join(ROMHACK, "rom")
BUILD = os.path.join(HERE, "build")
OUT = os.path.join(HERE, "output")
TRANSLATIONS = os.path.join(ROMHACK, "zh_CN_translated.json")
SDK = json.load(open(os.path.join(ROMHACK, "config.json"), encoding="utf-8"))["SDKPath"]
STAGE = 3


def run_csharp():
    print("[romhack_csharp] running...")
    subprocess.run([ROMHACK_EXE], cwd=ROMHACK, check=True)
    # romhack_csharp's own output dir (font maps, its own ISO) is not used by us;
    # it is regenerated on the next run, so clear it to save ~630 MB.
    out_dir = os.path.join(ROMHACK, "output")
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir, ignore_errors=True)
        os.makedirs(out_dir, exist_ok=True)
        print("[romhack_csharp] cleared romhack/output/")


def parse_rom2xml(path):
    txt = open(path, encoding="utf-8").read()
    return [(name, os.path.normpath(os.path.join(ROMHACK, src)))
            for name, src in re.findall(r'<file\s+name="([^"]+)"\s+source="([^"]+)"', txt)]


def write_opening_text(turns):
    """Write the opening lines into zh_CN_translated.json starting at 0001-0001."""
    with open(TRANSLATIONS, encoding="utf-8") as f:
        items = json.load(f)
    by_key = {it["key"]: it for it in items}

    updates = {}
    idx = 1
    for t in turns:
        t["indices"] = []
        for line in t["lines"]:
            key = f"0001-{idx:04d}"
            updates[key] = line
            t["indices"].append(idx)
            idx += 1
    for key, text in updates.items():
        if key in by_key:
            by_key[key]["translation"] = text
            by_key[key]["stage"] = STAGE
        else:
            items.append({"key": key, "original": "", "translation": text,
                          "stage": STAGE})
    with open(TRANSLATIONS, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=1)
    print(f"[text] wrote {len(updates)} entries into zh_CN_translated.json: "
          f"{sorted(updates)}")


def main():
    os.makedirs(BUILD, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    cfg = json.load(open(os.path.join(HERE, "dialogue.json"), encoding="utf-8"))
    # voices are auto-assigned from slot 5 upwards (original voices are discarded)
    voice_id = 5
    turns = []
    for ln in cfg["lines"]:
        sp = cfg["speakers"][ln["speaker"]]
        vid = None
        if ln.get("voice"):
            vid = voice_id
            voice_id += 1
        turns.append({"side": sp["side"], "char_id": sp["char_id"],
                      "expr": ln.get("expr", 0), "lines": dialog.wrap_text(ln["text"]),
                      "voice_id": vid, "voice": ln.get("voice")})

    # ---- 1. write the opening text into zh_CN_translated.json ----------------
    write_opening_text(turns)

    # ---- 2. let romhack_csharp rebuild fonts + all text -----------------------
    run_csharp()

    # ---- 3. patch the opening commands (portrait / expression / voice) --------
    cm1100 = bytearray(open(os.path.join(ROM, "CM1100.DAT.mod2"), "rb").read())
    cmd_off, cmd_len = sub_range(cm1100, dialog.CMD_SUB)
    cmd = bytearray(cm1100[cmd_off:cmd_off + cmd_len])
    dialog.patch_opening(cmd, turns)
    cm1100[cmd_off:cmd_off + cmd_len] = cmd
    print(f"[script] patched {len(turns)} opening block(s): "
          f"{[(t['side'], t['char_id'], t['expr'], t['voice_id']) for t in turns]}")

    # ---- 4. voices ------------------------------------------------------------
    cm5100 = open(os.path.join(ROM, "CM5100.DAT"), "rb").read()
    cm5000 = open(os.path.join(ROM, "CM5000.DAT"), "rb").read()
    done = set()
    for t in turns:
        if not t["voice"] or t["voice_id"] in done:
            continue
        done.add(t["voice_id"])
        pcm = xa.resample_to_18900(os.path.join(HERE, t["voice"]), HERE)
        cm5100, cm5000, start, end = xa.patch_voice(cm5100, cm5000, t["voice_id"],
                                                    xa.encode_pcm(pcm))
        print(f"[voice] id {t['voice_id']} <- {t['voice']} : sectors @ {start}..{end}")

    outs = {
        "CM1100.DAT": bytes(cm1100),
        "CM5000.DAT": cm5000,
        "CM5100.DAT": cm5100,
    }
    for name, data in outs.items():
        with open(os.path.join(BUILD, name), "wb") as f:
            f.write(data)

    # ---- 5. repack the ISO ----------------------------------------------------
    files = []
    for name, src in parse_rom2xml(os.path.join(ROMHACK, "rom2.xml")):
        if name in outs:
            files.append((name, os.path.join(BUILD, name),
                          "mixed" if name == "CM5100.DAT" else "data"))
        else:
            mixed = name.startswith(("CM51", "CM52", "CM53"))
            files.append((name, src, "mixed" if mixed else "data"))
    binp, cuep = iso.build_iso(SDK, HERE, os.path.join(HERE, "video_iso.xml"),
                               "Summon_Night_video.bin", "Summon_Night_video.cue",
                               os.path.join(ROM, "license_data.dat"), files)
    print(f"[iso] {binp}")


if __name__ == "__main__":
    main()
