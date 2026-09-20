"""CM1100.DAT patching: opening dialogue commands + dialog text.

Command script = subcontent 1; commands start at byte 12 (6-word header), so
byte offset = 12 + PC*2. Dialog text = subcontent 0x2A, same layout as
romhack_csharp's ConvertDialogContents: word[0]=count, word[i]=offset of string i,
string 0 starts at word `count`.
"""
import struct

from .common import u16, put_u16

CMD_SUB = 1
CMD_HEADER = 12
DLG_SUB = 0x2A

# The opening branches by protagonist (switch on var 0x1D at PC 0x15A4):
#   P0 -> 0x15BA, P1 -> 0x168D, P2 -> 0x1761, P3 -> 0x1927
# Each route's prologue body is regenerated in place; the pairs below are
# (first command PC, trailing 0026 PC) and the rest is NOP-padded.
PROLOGUES = [
    (0x15C3, 0x168C),   # P0
    (0x1696, 0x1760),   # P1
    (0x176A, 0x1926),   # P2
    (0x1930, 0x19F5),   # P3
]
MAX_LINE_CHARS = 10
NOP = 0x000B
HIDE_DIALOG = 0x2011        # Command2011_HideDialogBg -> closes the dialog box


def wrap_text(text, max_chars=MAX_LINE_CHARS):
    """Split text into <=max_chars box lines; an explicit '\\n' wins."""
    if "\n" in text:
        return text.split("\n")
    if len(text) <= max_chars:
        return [text]
    n = (len(text) + max_chars - 1) // max_chars
    size = (len(text) + n - 1) // n
    return [text[i:i + size] for i in range(0, len(text), size)]


# --------------------------------------------------------------------------- commands
def patch_words(cmd, pc, words):
    o = CMD_HEADER + pc * 2
    for i, w in enumerate(words):
        put_u16(cmd, o + i * 2, w)


def build_opening(turns):
    """Generate the opening command words (one turn = one speaker + its box lines).

    A portrait is loaded (2001/2002, which plays its enter animation) only the
    first time a character appears; later expression changes use 2004 (left) /
    2005 (right), which swap the face without sliding the portrait in again.
    """
    words = []
    shown = {}                                   # side -> (char_id, expr)
    for i, t in enumerate(turns):
        if i > 0:
            words.append(HIDE_DIALOG)            # hide the previous box
        side = t["side"]
        prev = shown.get(side)
        if prev is None or prev[0] != t["char_id"]:
            words += [0x2002 if side == "right" else 0x2001,
                      t["char_id"], t["expr"]]
            shown[side] = (t["char_id"], t["expr"])
        elif prev[1] != t["expr"]:
            words += [0x2005 if side == "right" else 0x2004, t["expr"]]
            shown[side] = (t["char_id"], t["expr"])
        # 2010: param1 = box side (0 = right / left speaker, 1 = left / right
        # speaker), param2 = appear animation, param3 = arrow (0 = points left)
        pos = 1 if side == "right" else 0
        words += [0x2010, pos, pos, pos]
        if t.get("voice_id") is not None:
            words += [0x2019, t["voice_id"]]
        for idx in t["indices"]:
            words += [0x2013, idx]
        words.append(0x2012)                     # wait for confirm
    words.append(HIDE_DIALOG)                    # close the box after the last line
    return words


def place_opening(cmd, words):
    """Write the generated opening into all four prologues, NOP-padding to the 0026."""
    for start_pc, end_pc in PROLOGUES:
        if len(words) > end_pc - start_pc:
            raise RuntimeError(
                f"opening needs {len(words)} words but prologue "
                f"0x{start_pc:X}-0x{end_pc:X} has only {end_pc - start_pc}")
        patch_words(cmd, start_pc, words)
        for pc in range(start_pc + len(words), end_pc):
            patch_words(cmd, pc, [NOP])


# --------------------------------------------------------------------------- dialog
def parse_strings(content):
    count = u16(content, 0)
    out = []
    for i in range(count):
        o = u16(content, i * 2) * 2
        buf = bytearray()
        while o + 1 < len(content):
            b0, b1 = content[o], content[o + 1]
            if b0 == 0 and b1 == 0:
                break
            if b0 == 0x40 and b1 == 0x00:
                buf += bytes([0x40])
                o += 6
                continue
            buf += bytes([b0, b1])
            o += 2
        out.append(bytes(buf))
    return out


def pack_strings(strings, content_len):
    out = bytearray()
    start = len(strings)
    for s in strings:
        out += struct.pack("<H", start)
        start += len(s) // 2 + 1
    for s in strings:
        out += s + b"\x00\x00"
    if len(out) > content_len:
        raise RuntimeError(f"dialog content overflow: {len(out)} > {content_len}")
    out += b"\x00" * (content_len - len(out))
    return bytes(out)


def set_strings(content, updates, appended):
    """updates: {index: bytes}; appended: list[bytes] -> new indices at the end."""
    strings = parse_strings(content)
    for i, b in updates.items():
        strings[i] = b
    new_indices = {}
    for b in appended:
        new_indices[len(strings)] = b
        strings.append(b)
    return pack_strings(strings, len(content)), new_indices
