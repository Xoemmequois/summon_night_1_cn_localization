#!/usr/bin/env python3
"""Rebuild the dataset .wav files from a training list.

A list line looks like `CM5100_0149.wav|リブレ|ja|どうしたの、ラミ？` -- the file
name already encodes the bank (CM5100/CM5101/CM5102/CM5200) and the voice id, so
the audio can be regenerated from the game data alone.  No metadata.csv needed.

    voices/.venv/Scripts/python voices/tools/rebuild_wavs.py \
        --list voices/dataset/リブレ/list_matched_clean.txt --out <dir>

Needs the extracted game data: romhack/rom/CM5000.DAT (voice index tables) and
romhack/rom/CM51xx.DAT (audio), i.e. run the rip pipeline first.
"""

from __future__ import annotations

import argparse
import importlib.util
import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent
VOICES = HERE.parent
REPO = VOICES.parent

_spec = importlib.util.spec_from_file_location("bvd", str(HERE / "build_voice_dataset.py"))
assert _spec is not None and _spec.loader is not None
bvd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bvd)

BY_NAME = {fname: idx for idx, (fname, _, _, _) in bvd.BANKS.items()}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True, help="output directory for rebuilt wavs")
    ap.add_argument("--abs-list", type=Path, default=None,
                    help="also write the list with absolute wav paths (for GPT-SoVITS)")
    ap.add_argument("--rom-dir", type=Path, default=REPO / "romhack" / "rom")
    args = ap.parse_args()

    cm5000 = (args.rom_dir / "CM5000.DAT").read_bytes()
    cache: dict[str, bytes] = {}
    args.out.mkdir(parents=True, exist_ok=True)

    lines = [l for l in args.list.read_text(encoding="utf-8").splitlines() if l.strip()]
    ok = skipped = 0
    built: list[str] = []
    for line in lines:
        name = line.split("|", 1)[0]
        stem = Path(name).stem                    # e.g. CM5100_0149
        bank = stem.split("_")[0] + ".DAT"
        if bank not in BY_NAME:
            print("  skip (unknown bank):", name)
            skipped += 1
            continue
        vid = int(stem.split("_")[1])
        fname, tbl_off, _base, first_id = bvd.BANKS[BY_NAME[bank]]
        data = cache.setdefault(fname, (args.rom_dir / fname).read_bytes())
        start, end = struct.unpack_from("<HH", cm5000, tbl_off + (vid - first_id) * 4)
        if start == 0 and end == 0:
            print("  skip (empty table entry):", name)
            skipped += 1
            continue
        x = bvd.decode_voice(data, start, end, start & 0x1F)
        x = bvd.resample_fft(bvd.trim_silence(x), bvd.SRC_SR, bvd.DST_SR)
        bvd.write_wav(args.out / name, x, bvd.DST_SR)
        built.append(line)
        ok += 1

    if args.abs_list:
        base = args.out.resolve()
        abs_lines = []
        for line in built:
            parts = line.split("|", 3)
            parts[0] = str(base / parts[0])
            abs_lines.append("|".join(parts))
        args.abs_list.write_text("\n".join(abs_lines), encoding="utf-8")
        print("wrote absolute-path list -> %s" % args.abs_list)

    print("rebuilt %d wavs -> %s (%d skipped)" % (ok, args.out, skipped))


if __name__ == "__main__":
    main()
