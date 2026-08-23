# One-off: dump full character TIM textures from CM3000.DAT as GIFs.
# Subcontents 0x89..0xCC hold char sprites: flat index 0/1 = texture TIMs.
# Output: romhack/pic_output/chars_full/char_{i}_tex{0|1}.gif
import os
import struct

from PIL import Image

ROM_PATH = os.path.join("romhack", "rom", "CM3000.DAT")
OUT_DIR = os.path.join("romhack", "pic_output", "chars_full")

SUB_BASE = 0x89
SUB_COUNT = 0x44


def read_u16(data, off):
    return data[off] | (data[off + 1] << 8)


def get_subcontent(data, sub_id):
    base = 0x10 + sub_id * 4
    offset = read_u16(data, base) * 0x800
    length = read_u16(data, base + 2) * 0x800
    return data[offset:offset + length]


def flat_offset(blob, index):
    """Absolute byte offset of flat-table entry, or None if absent."""
    entry_count = read_u16(blob, 0)
    if index >= entry_count:
        return None
    cur = struct.unpack_from("<I", blob, 4 + index * 4)[0] & 0xFFFFFF
    return cur or None


def parse_tim(blob, tim_off):
    """Returns (P-mode Image) or None, mirroring RipTool.ParseTim."""
    if tim_off < 0 or tim_off + 16 > len(blob):
        return None
    clut_rel = struct.unpack_from("<i", blob, tim_off + 4)[0]
    pix_rel = struct.unpack_from("<i", blob, tim_off + 8)[0]

    clut_w = read_u16(blob, tim_off + clut_rel)
    clut_h = read_u16(blob, tim_off + clut_rel + 2)
    is4bpp = clut_w != 256
    count = clut_w * clut_h

    palette = []
    transparent = []
    for i in range(count):
        c = read_u16(blob, tim_off + clut_rel + 4 + i * 2)
        r = (c & 0x1F) << 3
        g = ((c >> 5) & 0x1F) << 3
        b = ((c >> 10) & 0x1F) << 3
        palette.append((r, g, b))
        transparent.append(c == 0)

    pix_w = read_u16(blob, tim_off + pix_rel)  # 16-bit words per row
    pix_h = read_u16(blob, tim_off + pix_rel + 2)
    row_bytes = pix_w * 2
    width = row_bytes * 2 if is4bpp else row_bytes
    height = pix_h
    start = tim_off + pix_rel + 4

    pixels = bytearray(width * height)
    for y in range(height):
        row = start + y * row_bytes
        if is4bpp:
            for x in range(row_bytes):
                v = blob[row + x]
                pixels[y * width + x * 2] = v & 0xF
                pixels[y * width + x * 2 + 1] = v >> 4
        else:
            pixels[y * width:(y + 1) * width] = blob[row:row + width]

    # Remap every transparent CLUT slot to index 0 so GIF keeps one
    # transparent color instead of black boxes.
    for i, p in enumerate(pixels):
        if transparent[p]:
            pixels[i] = 0

    img = Image.frombytes("P", (width, height), bytes(pixels))
    flat = [c for rgb in palette for c in rgb]
    while len(flat) < 256 * 3:
        flat.append(0)
    img.putpalette(flat)
    return img


def main():
    with open(ROM_PATH, "rb") as f:
        data = f.read()
    os.makedirs(OUT_DIR, exist_ok=True)

    saved = skipped = 0
    for i in range(SUB_COUNT):
        dd = get_subcontent(data, SUB_BASE + i)
        for tex_idx in (0, 1):
            off = flat_offset(dd, tex_idx)
            name = f"char_{i}_tex{tex_idx}.gif"
            if off is None:
                skipped += 1
                continue
            img = parse_tim(dd, off)
            if img is None:
                skipped += 1
                print(f"  {name}: bad TIM @0x{off:X}, skipped")
                continue
            path = os.path.join(OUT_DIR, name)
            img.save(path, format="GIF", transparency=0)
            saved += 1
            print(f"  {name}: {img.width}x{img.height}")

    print(f"\nDone. saved={saved} skipped={skipped} -> {OUT_DIR}")


if __name__ == "__main__":
    main()
