"""Shared helpers: little-endian access + Summon Night sector-indexed container."""
import struct


def u16(b, o):
    return b[o] | (b[o + 1] << 8)


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def put_u16(b, o, v):
    b[o] = v & 0xFF
    b[o + 1] = (v >> 8) & 0xFF


def put_u32(b, o, v):
    struct.pack_into("<I", b, o, v)


def sub_range(data, idx):
    """Return (byte_offset, byte_length) of subcontent `idx` in a CM*.DAT container."""
    base = 0x10 + idx * 4
    sect = u16(data, base)
    cnt = u16(data, base + 2)
    return sect * 0x800, cnt * 0x800


def sub(data, idx):
    off, ln = sub_range(data, idx)
    if ln == 0:
        return None
    return data[off:off + ln]
