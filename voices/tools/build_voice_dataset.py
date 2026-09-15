#!/usr/bin/env python3
"""Build a per-character voice dataset for TTS from the Summon Night ROM.

Key fact discovered from FUN_800312a8 / Command002C/002D: the voice id space is
*per bank*, and the bank is chosen by the id of the script currently loaded:

    script id <= 14        -> CM5100.DAT   (table @ CM5000 0x0804, base LBA 43518)
    15 <= script id <= 27  -> CM5101.DAT   (table @ CM5000 0x3004, base LBA 89918)
    script id >= 28        -> CM5102.DAT   (table @ CM5000 0x5804, base LBA 136446)
    voice id >= 10000      -> CM5200.DAT   (table @ CM5000 0x8004, base LBA 190014)

The scripts also carry the speaker (portrait command 0x2001/0x2002 + dialog-box
side 0x2010) and the line text (0x2013, indexed into the dialog subcontent
selected by 0x002F).  Combining both gives `(bank, voice_id) -> {speaker, text}`
which, with the bank fix, is 99% single-speaker.

This tool extracts one character's clips, trims edge silence, resamples to
32 kHz, dedupes, and writes a GPT-SoVITS style `list.txt` plus a review CSV.

Requires the numpy venv: voices/.venv/Scripts/python voices/tools/build_voice_dataset.py
"""

from __future__ import annotations

import argparse
import collections
import csv
import hashlib
import json
import struct
import wave
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent      # voices/tools
VOICES = HERE.parent                        # voices/
REPO = VOICES.parent                        # repository root
SRC_SR = 18900          # XA-ADPCM playback rate
DST_SR = 32000          # GPT-SoVITS expects 32 kHz
SECTOR_IN_DAT = 2336
SUBHEADER_LEN = 8
AUDIO_LEN = 18 * 128
SOUND_GROUP = 128
POS = (0, 60, 115, 98)
NEG = (0, 0, -52, -55)

# bank -> (filename, table offset in CM5000, base LBA, first voice id)
BANKS = {
    0: ("CM5100.DAT", 0x0804, 43518, 0),
    1: ("CM5101.DAT", 0x3004, 89918, 0),
    2: ("CM5102.DAT", 0x5804, 136446, 0),
    3: ("CM5200.DAT", 0x8004, 190014, 10000),   # ids start at 10000
}


# --------------------------------------------------------------------------
# container helpers
# --------------------------------------------------------------------------

def get_subcontent(data: bytes, idx: int) -> bytes:
    off = struct.unpack_from("<H", data, 0x10 + idx * 4)[0]
    cnt = struct.unpack_from("<H", data, 0x10 + idx * 4 + 2)[0]
    return data[off * 0x800:(off + cnt) * 0x800]


def parse_strings(d: bytes) -> list[str]:
    if len(d) < 2:
        return []
    n = struct.unpack_from("<H", d, 0)[0]
    out = []
    for i in range(min(n, len(d) // 2)):
        o = struct.unpack_from("<H", d, i * 2)[0] * 2
        e = d.find(b"\x00\x00", o) if o < len(d) else -1
        out.append(d[o:e].decode("shift_jis", "replace") if e >= 0 else "")
    return out


_WS = dict.fromkeys(map(ord, "\u3000 \t\r\n\u00a0"), None)


def normalize_text(t: str) -> str:
    """Strip non-spoken whitespace so the TTS frontend sees clean kana/kanji."""
    return t.translate(_WS).strip()


# --------------------------------------------------------------------------
# XA ADPCM decode (same as extract_voices.py)
# --------------------------------------------------------------------------

def _decode_group(g: bytes, prev1: int, prev2: int, out: list) -> tuple[int, int]:
    for unit in range(8):
        p = g[unit if unit < 4 else unit + 4]
        sf = p & 0x0F
        if sf > 12:
            sf = 9
        filt = (p >> 4) & 3
        shift = 12 - sf
        f0, f1 = POS[filt], NEG[filt]
        bi = 16 + (unit >> 1)
        low = (unit & 1) == 0
        for _ in range(28):
            b = g[bi]
            nib = (b & 0x0F) if low else ((b >> 4) & 0x0F)
            t = nib - 16 if nib >= 8 else nib
            s = (t << shift) + ((prev1 * f0 + prev2 * f1 + 32) >> 6)
            s = 32767 if s > 32767 else (-32768 if s < -32768 else s)
            out.append(s)
            prev2, prev1 = prev1, s
            bi += 4
    return prev1, prev2


def decode_voice(data: bytes, start: int, end: int, channel: int) -> np.ndarray:
    out: list[int] = []
    p1 = p2 = 0
    for sec in range(start, end + 1, 32):
        base = sec * SECTOR_IN_DAT
        blk = data[base:base + SECTOR_IN_DAT]
        if len(blk) < SUBHEADER_LEN + AUDIO_LEN:
            break
        audio = blk[SUBHEADER_LEN:SUBHEADER_LEN + AUDIO_LEN]
        for g in range(18):
            o = g * SOUND_GROUP
            p1, p2 = _decode_group(audio[o:o + SOUND_GROUP], p1, p2, out)
    return np.asarray(out, dtype=np.float32)


# --------------------------------------------------------------------------
# DSP
# --------------------------------------------------------------------------

def trim_silence(x: np.ndarray, sr: int = SRC_SR, frame_ms=10, thresh_db=-42.0,
                 pad_ms=30) -> np.ndarray:
    if x.size == 0:
        return x
    fl = max(1, sr * frame_ms // 1000)
    n = x.size // fl
    if n < 2:
        return x
    e = np.abs(x[:n * fl].reshape(n, fl)).max(axis=1)
    peak = e.max()
    if peak <= 0:
        return x[:0]
    thr = peak * (10 ** (thresh_db / 20))
    idx = np.where(e > thr)[0]
    if idx.size == 0:
        return x[:0]
    s = max(0, (idx[0] * fl) - sr * pad_ms // 1000)
    t = min(x.size, ((idx[-1] + 1) * fl) + sr * pad_ms // 1000)
    return x[s:t]


def resample_fft(x: np.ndarray, src: int, dst: int) -> np.ndarray:
    if x.size == 0 or src == dst:
        return x
    m = int(round(x.size * dst / src))
    if m < 2:
        return x[:0]
    spec = np.fft.rfft(x)
    out = np.zeros(m // 2 + 1, dtype=complex)
    k = min(len(spec), len(out))
    out[:k] = spec[:k]
    y = np.fft.irfft(out, n=m)
    return (y * (dst / src)).astype(np.float32)


def write_wav(path: Path, x: np.ndarray, sr: int) -> None:
    y = np.clip(np.round(x), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(y.tobytes())


# --------------------------------------------------------------------------
# script walk
# --------------------------------------------------------------------------

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import script_parser as cv            # provides parse_script()


def bank_of(script_id: int) -> int:
    if script_id <= 14:
        return 0
    if script_id <= 27:
        return 1
    return 2


def collect(exported: Path, cm1100: bytes, names: dict):
    """(bank, voice_id) -> {spk: Counter, scripts: set, texts: list}.

    Walks the script control flow (calls / jumps / branches) so that the
    portrait state, dialog-box side and dialog subcontent are correct -- a
    linear walk leaks subroutine state and mislabels speakers and text.
    """
    info = collections.defaultdict(lambda: {"spk": collections.Counter(),
                                            "scripts": set(), "texts": []})
    text_cache: dict[int, list[str]] = {}

    def strings_of(sub_id: int) -> list[str]:
        if sub_id not in text_cache:
            text_cache[sub_id] = parse_strings(get_subcontent(cm1100, sub_id))
        return text_cache[sub_id]

    def clean(c):
        return "PROTAG" if (0 <= c <= 7 or 12 <= c <= 15) else c

    def nm(v):
        if v is None:
            return None
        return "主人公" if v == "PROTAG" else (
            names.get(str(v), {}).get("japanese") or ("char%03d" % v))

    for sid in range(1, 41):
        p = exported / ("CM1100.DAT_%d" % sid)
        if not p.exists():
            continue
        b = bank_of(sid)
        default_sub = sid + 0x29
        cmds = cv.parse_script(p)
        # every dialog subcontent this script may load (default + 0x002F params)
        alt_subs = [default_sub] + [pp[0] + 0x29 for _, c, pp in cmds if c == 0x002F]
        d = {o: (c, pp) for o, c, pp in cmds}
        offs = sorted(d)
        pos = {o: i for i, o in enumerate(offs)}
        seen = set()
        work: list[tuple] = [(offs[0], None, None, None, default_sub, ())]
        steps = 0
        while work and steps < 2_000_000:
            off, left, right, speaker, dsub, stack = work.pop()
            while True:
                steps += 1
                if off not in d:
                    break
                key = (off, left, right, speaker, dsub, stack)
                if key in seen:
                    break
                seen.add(key)
                code, pp = d[off]
                nxt = None
                if code == 0x2001:
                    left = clean(pp[0])
                elif code == 0x2002:
                    right = clean(pp[0])
                elif code == 0x2009:
                    right = None
                elif code == 0x200A:
                    left = None
                elif code == 0x2010:
                    speaker = left if pp[0] == 0 else right
                elif code == 0x002F:
                    dsub = pp[0] + 0x29
                elif code == 0x2019:
                    i = pos[off]
                    tids = []
                    j = i + 1
                    while j < len(cmds) and cmds[j][1] in (0x2013, 0x2012, 0x2011):
                        if cmds[j][1] == 0x2013:
                            tids.append(cmds[j][2][0])
                        j += 1
                    texts = []
                    if tids:
                        for s in [dsub] + [x for x in alt_subs if x != dsub]:
                            a = strings_of(s)
                            if all(0 <= t < len(a) for t in tids):
                                texts = [a[t] for t in tids]
                                break
                    texts = [t for t in texts if not t.startswith("@")]
                    spk = nm(speaker)
                    if spk is not None:
                        e = info[(b, pp[0])]
                        e["spk"][spk] += 1
                        e["scripts"].add(sid)
                        if len("".join(texts)) > len("".join(e["texts"])):
                            e["texts"] = texts
                elif code == 0x0023:
                    nxt = pp[0]
                elif code == 0x0025:
                    work.append((pp[0], left, right, speaker, default_sub, stack))
                    nxt = offs[pos[off] + 1] if pos[off] + 1 < len(offs) else None
                elif code == 0x0026:
                    if stack:
                        ret, _, _, _, saved_sub, rest = stack[-1]
                        dsub = saved_sub
                        nxt = ret
                        stack = rest
                    else:
                        break
                elif code == 0x0027:
                    for t in pp[4:]:
                        if t:
                            work.append((t, left, right, speaker, dsub, stack))
                    break
                elif code in (0x0020, 0x0021, 0x0022, 0x0028):
                    work.append((pp[0], left, right, speaker, dsub, stack))
                    nxt = offs[pos[off] + 1] if pos[off] + 1 < len(offs) else None
                elif code == 0x001A:
                    work.append((pp[1], left, right, speaker, dsub, stack))
                    break
                if nxt is None:
                    i = pos[off]
                    nxt = offs[i + 1] if i + 1 < len(offs) else None
                if nxt is None:
                    break
                off = nxt
    return info


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--character", default="リブレ")
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--rom-dir", type=Path, default=REPO / "romhack" / "rom")
    ap.add_argument("--exported", type=Path, default=REPO / "exported")
    ap.add_argument("--names", type=Path,
                    default=REPO / "romhack" / "char_names_translated.json")
    ap.add_argument("--min-sec", type=float, default=1.0, help="drop clips shorter than this")
    args = ap.parse_args()

    names = json.load(open(args.names, encoding="utf-8"))
    cm1100 = (args.rom_dir / "CM1100.DAT").read_bytes()
    cm5000 = (args.rom_dir / "CM5000.DAT").read_bytes()
    info = collect(args.exported, cm1100, names)

    target = args.character
    keys = []
    for (b, vid), e in info.items():
        c = e["spk"]
        if len(c) == 1 and c.most_common(1)[0][0] == target:
            keys.append((b, vid, e))
    keys.sort(key=lambda k: (k[0], k[1]))
    print(f"{target}: {len(keys)} clips / "
          f"{sum(len(e['scripts']) for _, _, e in keys)} script refs")

    out = args.out or (VOICES / "dataset" / target)
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.wav"):      # drop stale output from previous runs
        old.unlink()
    cache: dict[int, bytes] = {}
    rows = []
    seen_hash: dict[str, str] = {}
    total = 0.0
    for b, vid, e in keys:
        fname = BANKS[b][0]
        if b not in cache:
            cache[b] = (args.rom_dir / fname).read_bytes()
        tbl_off, base, first_id = BANKS[b][1], BANKS[b][2], BANKS[b][3]
        start, end = struct.unpack_from("<HH", cm5000, tbl_off + (vid - first_id) * 4)
        if start == 0 and end == 0:
            continue
        ch = start & 0x1F
        raw = decode_voice(cache[b], start, end, ch)
        trimmed = trim_silence(raw)
        dur = len(trimmed) / SRC_SR
        text = normalize_text("".join(t for t in e["texts"] if not t.startswith("@")))
        flags = []
        if dur < 1.5:
            flags.append("short")
        if dur > 12:
            flags.append("long")
        if raw.size and len(trimmed) / raw.size < 0.5:
            flags.append("mostly_silence")
        if dur < args.min_sec:
            flags.append("dropped_short")
        if not text:
            flags.append("no_text")

        y = resample_fft(trimmed, SRC_SR, DST_SR)
        name = f"{fname.replace('.DAT','')}_{vid:04d}.wav"
        drop = "dropped_short" in flags
        if not drop:
            write_wav(out / name, y, DST_SR)
            total += dur

        h = hashlib.md5(np.round(trimmed[:SRC_SR * 8]).astype("<i2").tobytes()).hexdigest()
        dup = h in seen_hash
        if not dup:
            seen_hash[h] = name
        rows.append({
            "file": "" if drop else name,
            "bank": fname, "voice_id": vid, "channel": ch,
            "lba_start": base + start, "lba_end": base + end,
            "duration_sec": round(dur, 3),
            "rms": round(float(np.sqrt((trimmed ** 2).mean())) if trimmed.size else 0, 1),
            "peak": int(np.abs(trimmed).max()) if trimmed.size else 0,
            "duplicate_of": seen_hash[h] if dup else "",
            "scripts": ",".join(str(s) for s in sorted(e["scripts"])),
            "flags": ",".join(flags),
            "text": text,
        })

    # GPT-SoVITS .list  (wav|speaker|lang|text)
    list_lines = []
    for r in rows:
        if r["file"] and r["text"] and not r["duplicate_of"]:
            list_lines.append("%s|%s|ja|%s" % (r["file"], target, r["text"]))
    (out / "list.txt").write_text("\n".join(list_lines), encoding="utf-8")
    (out / "list_raw.txt").write_text(
        "\n".join("%s|%s|ja|%s" % (r["file"], target, r["text"])
                  for r in rows if r["file"] and r["text"]), encoding="utf-8")

    with open(out / "metadata.csv", "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    usable = [r for r in rows if r["file"] and not r["duplicate_of"] and r["text"]]
    flagged = [r for r in rows if r["flags"] or r["duplicate_of"]]
    print("wrote: %d wav, %.1fs (%0.1f min)" % (len(usable), total, total / 60))
    print("  list.txt      : %d lines (usable, deduped)" % len(list_lines))
    print("  metadata.csv  : %d rows" % len(rows))
    print("  flagged       : %d (short/dup/no_text/...)" % len(flagged))
    per_flag = collections.Counter(f for r in rows for f in r["flags"].split(",") if f)
    print("  flags:", dict(per_flag))
    print("output:", out)


if __name__ == "__main__":
    main()
