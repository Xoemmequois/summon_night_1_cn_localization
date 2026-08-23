# One-off: locate the mapscreen_titles TIM (CM2000.DAT subcontent 1, flat 0x11),
# then search ALL of CM2000.DAT for other blocks whose pixel data is byte-identical.
import os
import struct

PATH = os.path.join("romhack", "rom", "CM2000.DAT")
SUB_ID = 1
FLAT_IDX = 0x11


def read_u16(d, o):
    return d[o] | (d[o + 1] << 8)


def subcontent_ranges(data):
    """All (id, start, end) of the sector-indexed container."""
    out = []
    i = 0
    while True:
        base = 0x10 + i * 4
        if base + 4 > len(data):
            break
        off = read_u16(data, base)
        ln = read_u16(data, base + 2)
        if off == 0 or ln == 0:
            i += 1
            continue
        start, end = off * 0x800, (off + ln) * 0x800
        if end > len(data):
            break
        out.append((i, start, end))
        i += 1
    return out


def main():
    data = open(PATH, "rb").read()
    ranges = subcontent_ranges(data)

    # --- locate the TIM ---
    s1 = next(s for s in ranges if s[0] == SUB_ID)
    sub = data[s1[1]:s1[2]]
    entry_count = read_u16(sub, 0)
    tim_off = struct.unpack_from("<I", sub, 4 + FLAT_IDX * 4)[0] & 0xFFFFFF
    clut_rel = struct.unpack_from("<i", sub, tim_off + 4)[0]
    pix_rel = struct.unpack_from("<i", sub, tim_off + 8)[0]

    clut_w = read_u16(sub, tim_off + clut_rel)
    clut_h = read_u16(sub, tim_off + clut_rel + 2)
    is4bpp = clut_w != 256
    pix_w = read_u16(sub, tim_off + pix_rel)   # words per row
    pix_h = read_u16(sub, tim_off + pix_rel + 2)
    row_bytes = pix_w * 2                      # bytes per row on disk
    pix_size = row_bytes * pix_h
    pix_pos_in_sub = tim_off + pix_rel + 4
    pix_abs = s1[1] + pix_pos_in_sub
    pix = data[pix_abs:pix_abs + pix_size]

    print(f"source TIM: subcontent={SUB_ID} flat=0x{FLAT_IDX:X}")
    print(f"  CLUT {clut_w}x{clut_h} ({'4bpp' if is4bpp else '8bpp'}), "
          f"PIX {pix_w}words x {pix_h}rows -> disk {row_bytes}x{pix_h} = {pix_size} bytes")
    print(f"  pixel data @ file offset 0x{pix_abs:X} "
          f"(subcontent {SUB_ID} +0x{pix_pos_in_sub:X})")

    # --- exact-byte search over the whole file ---
    hits = []
    pos = data.find(pix)
    while pos != -1:
        hits.append(pos)
        pos = data.find(pix, pos + 1)

    def describe(pos):
        owners = [f"id={i}[+0x{pos - st:X}]" for i, st, en in ranges if st <= pos < en]
        return ", ".join(owners) if owners else "<no subcontent>"

    print(f"\nexact matches of full pixel block ({len(pix)} bytes): {len(hits)}")
    for h in hits:
        tag = " <- SOURCE" if h == pix_abs else ""
        print(f"  0x{h:X}: {describe(h)}{tag}")

    if len(hits) <= 1:
        # no duplicates: probe with shorter prefixes to spot near-duplicates
        for n in (512, 128, 32):
            needle = pix[:n]
            hits2 = []
            p = data.find(needle)
            while p != -1:
                hits2.append(p)
                p = data.find(needle, p + 1)
            extra = [h for h in hits2 if h != pix_abs]
            print(f"\nprobe prefix {n} bytes: {len(hits2)} total, "
                  f"{len(extra)} elsewhere")
            for h in extra[:20]:
                print(f"  0x{h:X}: {describe(h)}")


if __name__ == "__main__":
    main()
