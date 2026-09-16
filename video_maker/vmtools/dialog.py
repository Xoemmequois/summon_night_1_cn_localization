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
# A prologue is a sequence of blocks, each ending with 2012 (wait-for-confirm).
# (first block's portrait PC, the trailing 0026 PC)
PROLOGUES = [
    (0x15C3, 0x168C),   # P0
    (0x1696, 0x1760),   # P1
    (0x176A, 0x1926),   # P2
    (0x1930, 0x19F5),   # P3
]
MAX_LINE_CHARS = 10
NOP = 0x000B


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


def _word(cmd, pc):
    return u16(cmd, CMD_HEADER + pc * 2)


def parse_prologue(cmd, start_pc, end_pc):
    """Split a prologue into blocks; record each block's command PCs."""
    blocks = []
    block = {"start": start_pc, "portrait": None, "portrait_op": 0x2002,
             "box": None, "voice": None, "text": []}
    pc = start_pc
    while pc < end_pc:
        op = _word(cmd, pc)
        if op == 0x2012:
            block["end"] = pc + 1
            blocks.append(block)
            block = {"start": pc + 1, "portrait": None, "portrait_op": 0x2002,
                     "box": None, "voice": None, "text": []}
        elif op in (0x2001, 0x2002):
            block["portrait"], block["portrait_op"] = pc, op
        elif op == 0x2010:
            block["box"] = pc
        elif op == 0x2019:
            block["voice"] = pc
        elif op == 0x2013:
            block["text"].append((pc, _word(cmd, pc + 1)))
        pc += 1
    return blocks


def prologue_blocks(cmd):
    """All four prologues' blocks: [[block, ...] per prologue]."""
    return [parse_prologue(cmd, s, e) for s, e in PROLOGUES]


def prologue_text_map(blocks):
    """{(turn_index, slot): [dialog string indices]} across the four prologues."""
    out = {}
    for pro in blocks:
        for ti, blk in enumerate(pro):
            for slot, (_pc, idx) in enumerate(blk["text"]):
                out.setdefault((ti, slot), set()).add(idx)
    return {k: sorted(v) for k, v in out.items()}


def patch_opening(cmd, turns):
    """turns: [{side, char_id, expr, indices, voice_id or None}] -> patch all prologues.

    Each turn's box lines are pointed at the given dialog string indices; extra
    text slots in the block are NOP-padded.
    """
    blocks = prologue_blocks(cmd)
    for ti, t in enumerate(turns):
        for pro in blocks:
            if ti >= len(pro):
                continue
            b = pro[ti]
            if b["portrait"] is not None:
                patch_words(cmd, b["portrait"],
                            [0x2002 if t["side"] == "right" else 0x2001,
                             t["char_id"], t["expr"]])
            if b["box"] is not None:
                orig2, orig3 = _word(cmd, b["box"] + 2), _word(cmd, b["box"] + 3)
                patch_words(cmd, b["box"],
                            [0x2010, 1 if t["side"] == "right" else 0, orig2, orig3])
            if b["voice"] is not None:
                if t.get("voice_id") is not None:
                    patch_words(cmd, b["voice"], [0x2019, t["voice_id"]])
                else:
                    patch_words(cmd, b["voice"], [NOP, NOP])
            for slot, (pc, _idx) in enumerate(b["text"]):
                if slot < len(t["indices"]):
                    patch_words(cmd, pc, [0x2013, t["indices"][slot]])
                else:
                    patch_words(cmd, pc, [NOP, NOP])
    return blocks


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
