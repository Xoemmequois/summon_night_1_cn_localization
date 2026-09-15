#!/usr/bin/env python3
"""Extract all Summon Night dialogue voices to WAV.

Dialogue voice playback is driven by script command 0x2019
(Command2019_PlayVoice? @ 0x8001ffb4), which calls FUN_80031478(voice_id):

    voice_id < 10000  -> CM5100.DAT voice table, index = voice_id
    voice_id >= 10000 -> CM5200.DAT voice table, index = voice_id - 10000

Both index tables live inside CM5000.DAT; each entry is 4 bytes:

    u16 start_sector   (low 5 bits = XA channel / 0..31)
    u16 end_sector     (same channel in its low 5 bits, inclusive)

Audio is CD-XA ADPCM, mono / 18900 Hz / 4-bit, stored as a 32-channel
interleaved stream (one 32-sector cycle per channel sweep).  A voice occupies
the sectors start, start+32, start+64, ... end.

romhack/rom/CM51xx.DAT is dumpsxiso output where every 2352-byte Mode2 sector
became a 2336-byte block: 8-byte XA subheader + 2324 bytes user data + 4-byte
EDC.  Only the first 2304 bytes of user data (18 x 128-byte sound groups) are
ADPCM.

Decode follows psx-spx / the bit-exact CD-XA layout: each 128-byte sound group
holds 8 sound units of 28 samples; unit u's parameter byte is at u (u<4) or
u+4 (u>=4); sample j of unit u is nibble (u&1) of byte 16 + j*4 + (u>>1).
"""

from __future__ import annotations

import argparse
import array
import json
import struct
import sys
import wave
from pathlib import Path

# --- disc geometry ---------------------------------------------------------

SECTOR_IN_DAT = 2336          # dumpsxiso block size
SUBHEADER_LEN = 8             # CD-XA subheader (4 fields + mirrored copy)
AUDIO_LEN = 18 * 128          # 2304 bytes of ADPCM sound groups per sector
SOUND_GROUP = 128
SAMPLES_PER_UNIT = 28
UNITS_PER_GROUP = 8
SAMPLES_PER_SECTOR = 18 * UNITS_PER_GROUP * SAMPLES_PER_UNIT  # 4032
SAMPLE_RATE = 18900
CHANNELS_IN_STREAM = 32

# CD-XA ADPCM 4-bit predictor coefficients (1/64 fixed point)
POS_TABLE = (0, 60, 115, 98)
NEG_TABLE = (0, 0, -52, -55)

# --- voice tables inside CM5000.DAT ----------------------------------------

# name, table offset, count-field offset, audio file name, base disc LBA
TABLES = (
    ("CM5100", 0x804, 0x800, "CM5100.DAT", 43518),
    ("CM5200", 0x8004, 0x8000, "CM5200.DAT", 190014),
)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ROM_DIR = REPO_ROOT / "romhack" / "rom"
DEFAULT_OUT_DIR = REPO_ROOT / "voices"


def decode_group(group: bytes, prev1: int, prev2: int, out: array.array) -> tuple[int, int]:
    """Decode one 128-byte 4-bit mono sound group (224 samples)."""
    for unit in range(UNITS_PER_GROUP):
        param = group[unit if unit < 4 else unit + 4]
        shift_field = param & 0x0F
        if shift_field > 12:            # reserved values behave like 9
            shift_field = 9
        filt = (param >> 4) & 0x03      # only 4 XA filters exist
        shift = 12 - shift_field
        f0 = POS_TABLE[filt]
        f1 = NEG_TABLE[filt]

        byte_index = 16 + (unit >> 1)
        low_nibble = (unit & 1) == 0
        for _ in range(SAMPLES_PER_UNIT):
            byte = group[byte_index]
            nib = (byte & 0x0F) if low_nibble else ((byte >> 4) & 0x0F)
            t = nib - 16 if nib >= 8 else nib
            s = (t << shift) + ((prev1 * f0 + prev2 * f1 + 32) >> 6)
            if s > 32767:
                s = 32767
            elif s < -32768:
                s = -32768
            out.append(s)
            prev2 = prev1
            prev1 = s
            byte_index += 4
    return prev1, prev2


def decode_voice(data: bytes, start: int, end: int, channel: int,
                 expect_file: bytes = b"", warn=print) -> array.array:
    """Decode one voice spanning interleaved sectors [start..end] step 32."""
    samples = array.array("h")
    prev1 = 0
    prev2 = 0
    for sector in range(start, end + 1, CHANNELS_IN_STREAM):
        base = sector * SECTOR_IN_DAT
        block = data[base:base + SECTOR_IN_DAT]
        if len(block) < SUBHEADER_LEN + AUDIO_LEN:
            warn(f"  truncated sector {sector}")
            break
        if block[1] != channel:
            warn(f"  channel mismatch at sector {sector}: "
                 f"got {block[1]}, expected {channel}")
        if expect_file and block[0] != expect_file[0]:
            warn(f"  file number mismatch at sector {sector}: got {block[0]}")
        audio = block[SUBHEADER_LEN:SUBHEADER_LEN + AUDIO_LEN]
        for g in range(18):
            off = g * SOUND_GROUP
            prev1, prev2 = decode_group(audio[off:off + SOUND_GROUP], prev1, prev2, samples)
    return samples


def read_table(cm5000: bytes, table_off: int, count_off: int):
    count = struct.unpack_from("<I", cm5000, count_off)[0]
    entries = []
    for i in range(count):
        start, end = struct.unpack_from("<HH", cm5000, table_off + i * 4)
        entries.append((start, end))
    return count, entries


def write_wav(path: Path, samples: array.array) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(samples.tobytes())


def parse_ints(text: str) -> set[int]:
    return {int(x, 0) for x in text.replace(",", " ").split()}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rom-dir", type=Path, default=DEFAULT_ROM_DIR,
                    help="directory holding CM5000/CM5100/CM5200.DAT (default: romhack/rom)")
    ap.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR,
                    help="output directory for WAV files (default: voices)")
    ap.add_argument("--ids", default="", help="only extract these voice ids (comma/space separated)")
    ap.add_argument("--dry-run", action="store_true", help="list voices without decoding")
    args = ap.parse_args()

    cm5000_path = args.rom_dir / "CM5000.DAT"
    if not cm5000_path.is_file():
        print(f"error: {cm5000_path} not found (run the rip pipeline first)", file=sys.stderr)
        return 1
    cm5000 = cm5000_path.read_bytes()

    only = parse_ints(args.ids) if args.ids else None
    if not args.dry_run:
        args.out_dir.mkdir(parents=True, exist_ok=True)

    manifest = []
    total_samples = 0
    extracted = 0
    skipped = 0

    for name, table_off, count_off, dat_name, base_lba in TABLES:
        count, entries = read_table(cm5000, table_off, count_off)
        dat_path = args.rom_dir / dat_name
        max_end = max((e[1] for e in entries if e[1]), default=0)
        if args.dry_run:
            data = b""
        else:
            data = dat_path.read_bytes()
            if len(data) // SECTOR_IN_DAT < max_end:
                print(f"warning: {dat_name} shorter than table implies", file=sys.stderr)

        id_base = 0 if name == "CM5100" else 10000
        print(f"{name}: {count} table entries (voice ids {id_base}..{id_base + count - 1})")

        for index, (start, end) in enumerate(entries):
            voice_id = id_base + index
            if start == 0 and end == 0:
                skipped += 1
                continue
            if only is not None and voice_id not in only:
                continue
            channel = start & 0x1F
            if end < start:
                print(f"  skip id {voice_id}: end<start ({start},{end})", file=sys.stderr)
                skipped += 1
                continue
            if (end - start) % CHANNELS_IN_STREAM:
                print(f"  skip id {voice_id}: misaligned ({start},{end})", file=sys.stderr)
                skipped += 1
                continue

            sectors = (end - start) // CHANNELS_IN_STREAM + 1
            if args.dry_run:
                print(f"  {voice_id:>6}  ch={channel:>2}  sectors={sectors:>4}  "
                      f"start={start}")
                continue

            samples = decode_voice(data, start, end, channel,
                                   warn=lambda m, i=voice_id: print(f"  id {i}:{m}", file=sys.stderr))
            out_name = f"{name}_{voice_id:04d}.wav"
            write_wav(args.out_dir / out_name, samples)
            total_samples += len(samples)
            extracted += 1
            manifest.append({
                "id": voice_id,
                "source": name,
                "file": out_name,
                "channel": channel,
                "start_sector": start,
                "end_sector": end,
                "sectors": sectors,
                "samples": len(samples),
                "duration_sec": round(len(samples) / SAMPLE_RATE, 3),
            })

    if args.dry_run:
        return 0

    manifest.sort(key=lambda m: m["id"])
    (args.out_dir / "voices.json").write_text(
        json.dumps({"sample_rate": SAMPLE_RATE, "channels": 1, "voices": manifest},
                   ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\nextracted {extracted} voices, skipped {skipped}")
    print(f"total audio: {total_samples / SAMPLE_RATE / 60:.1f} min ({total_samples / SAMPLE_RATE:.0f} s)")
    print(f"output: {args.out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
