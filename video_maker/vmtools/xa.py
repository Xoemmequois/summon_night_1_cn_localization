"""XA-ADPCM (4-bit mono, 18900 Hz) encode/decode + CM5100/CM5000 voice patching.

The bit layout matches voices/tools/build_voice_dataset.py (the project's decoder):
one 128-byte "super group" = 8 sub-streams x 28 samples.
  headers: bytes 0..3 (units 0..3), 8..11 (units 4..7)
  data:    bytes 16..127, byte 16+4k+u holds unit(2u) low / unit(2u+1) high nibble
Each 2336-byte sector = 8-byte subheader + 2304 bytes audio (18 super groups = 4032 samples).
"""
import os
import struct
import subprocess

SECTOR = 2336
SUBHDR = 8
AUDIO = 18 * 128
GROUP = 128
SAMPLES_PER_GROUP = 8 * 28
POS = (0, 60, 115, 98)
NEG = (0, 0, -52, -55)
SR = 18900
CM5000_TABLE_CM5100 = 0x0804


# ----------------------------------------------------------------------------- decode
def decode_group(g, prev1, prev2, out):
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


def decode_voice(data, start, end):
    out = []
    p1 = p2 = 0
    for sec in range(start, end + 1, 32):
        base = sec * SECTOR
        blk = data[base:base + SECTOR]
        if len(blk) < SUBHDR + AUDIO:
            break
        audio = blk[SUBHDR:SUBHDR + AUDIO]
        for g in range(18):
            o = g * GROUP
            p1, p2 = decode_group(audio[o:o + GROUP], p1, p2, out)
    return out


# ----------------------------------------------------------------------------- encode
def _encode_unit(samples, p1, p2):
    """Return (header, 28 nibbles, p1, p2) picking the best (filter, shift)."""
    best = None
    for filt in range(4):
        f0, f1 = POS[filt], NEG[filt]
        for shift in range(0, 13):
            prev1, prev2 = p1, p2
            nibs = []
            err = 0
            for s in samples:
                pred = (prev1 * f0 + prev2 * f1 + 32) >> 6
                t = s - pred
                n = (t + (1 << (shift - 1))) >> shift if shift else t
                if n > 7:
                    n = 7
                elif n < -8:
                    n = -8
                rec = (n << shift) + pred
                rec = 32767 if rec > 32767 else (-32768 if rec < -32768 else rec)
                nibs.append(n & 0xF)
                err += (s - rec) ** 2
                prev2, prev1 = prev1, rec
            if best is None or err < best[0]:
                best = (err, (filt << 4) | (12 - shift), nibs, prev1, prev2)
    return best[1], best[2], best[3], best[4]


def encode_group(samples224, p1, p2):
    """samples224: 224 samples -> 128 bytes + updated predictors."""
    g = bytearray(GROUP)
    units = []
    for u in range(8):
        hdr, nibs, p1, p2 = _encode_unit(samples224[u * 28:(u + 1) * 28], p1, p2)
        units.append((hdr, nibs))
    for u in range(8):
        g[u if u < 4 else u + 4] = units[u][0]
    for k in range(28):
        for pair in range(4):
            lo = units[pair * 2][1][k]
            hi = units[pair * 2 + 1][1][k]
            g[16 + 4 * k + pair] = (hi << 4) | lo
    return bytes(g), p1, p2


def encode_pcm(pcm):
    """pcm: list/array of int16 -> raw audio bytes (18*128 per sector)."""
    p1 = p2 = 0
    out = bytearray()
    n = len(pcm)
    total = (n + SAMPLES_PER_GROUP - 1) // SAMPLES_PER_GROUP
    for gi in range(total):
        chunk = list(pcm[gi * SAMPLES_PER_GROUP:(gi + 1) * SAMPLES_PER_GROUP])
        chunk += [0] * (SAMPLES_PER_GROUP - len(chunk))
        blk, p1, p2 = encode_group(chunk, p1, p2)
        out += blk
    return bytes(out)


# ----------------------------------------------------------------------------- sectors
def build_xa_sector(channel, payload2304):
    """Build one raw 2336-byte Mode2 Form2 XA sector."""
    assert len(payload2304) == AUDIO
    sub = bytes([1, channel & 0x1F, 0x64, 0x04]) * 2
    body = payload2304 + b"\x00" * (SECTOR - SUBHDR - AUDIO - 4)
    edc = struct.pack("<I", 0)          # XA Form2: EDC often left zero; game ignores it
    return sub + body + edc


def resample_to_18900(wav_path, workdir, ffmpeg="ffmpeg"):
    raw = os.path.join(workdir, "output", "voice_18900.raw")
    subprocess.run([ffmpeg, "-y", "-i", wav_path, "-ac", "1", "-ar", str(SR),
                    "-f", "s16le", raw], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(raw, "rb") as f:
        b = f.read()
    return list(struct.unpack("<%dh" % (len(b) // 2), b))


# ----------------------------------------------------------------------------- patch
def patch_voice(cm5100, cm5000, voice_id, raw_audio):
    """Append the encoded audio to CM5100 and point the CM5000 table entry at it.

    raw_audio: encoded XA bytes (padded to whole 2304-byte sectors).
    Returns (cm5100, cm5000, start, end).
    """
    if len(raw_audio) % AUDIO:
        raw_audio = raw_audio + b"\x00" * (AUDIO - len(raw_audio) % AUDIO)
    n_audio_sectors = len(raw_audio) // AUDIO
    file_sectors = len(cm5100) // SECTOR
    start = ((file_sectors + 31) // 32) * 32     # next 32-aligned sector -> channel 0
    channel = start & 0x1F
    end = start + 32 * (n_audio_sectors - 1) + channel

    total_sectors = 32 * n_audio_sectors
    out = bytearray(cm5100)
    out += b"\x00" * (total_sectors * SECTOR)
    for i in range(n_audio_sectors):
        sec = start + 32 * i
        payload = raw_audio[i * AUDIO:(i + 1) * AUDIO]
        out[sec * SECTOR:(sec + 1) * SECTOR] = build_xa_sector(channel, payload)
    # fill the 31 other lanes of each cycle with silent XA sectors on their own channels
    for i in range(n_audio_sectors):
        for c in range(32):
            if c == channel:
                continue
            sec = start + 32 * i + c
            out[sec * SECTOR:(sec + 1) * SECTOR] = build_xa_sector(c, b"\x00" * AUDIO)

    cm5 = bytearray(cm5000)
    base = CM5000_TABLE_CM5100 + voice_id * 4
    struct.pack_into("<HH", cm5, base, start, end)
    return bytes(out), bytes(cm5), start, end
