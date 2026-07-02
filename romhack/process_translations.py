import json
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
ORIG_DIR = SCRIPT_DIR.parent / "ruby_tools" / "opencode_generated" / "output_full"
OUTPUT_DIR = SCRIPT_DIR.parent / "ruby_tools" / "opencode_generated" / "processed"
CHAR_NAMES_PATH = SCRIPT_DIR / "char_names_translated.json"

FULLWIDTH_SPACE = "\u3000"
LINE_TAG_RE = re.compile(r"^(\[FID:[^\]]+\]) (.*)")


def parse_groups(content):
    groups = []
    current = None

    for line in content.split("\n"):
        if line.startswith("--- Group "):
            if current:
                groups.append(current)
            current = {"header": line, "lines": []}
        elif current is not None:
            if not line.strip():
                continue
            m = LINE_TAG_RE.match(line)
            if m:
                current["lines"].append({"tag": m.group(1), "text": m.group(2)})
            else:
                current["lines"].append({"tag": "", "text": line})

    if current:
        groups.append(current)
    return groups


def process_texts(orig_texts, trans_texts):
    queue = list(trans_texts)
    result = []

    for orig in orig_texts:
        if not queue:
            break

        current = queue.pop(0)
        orig_len = len(orig)

        if orig.startswith(FULLWIDTH_SPACE) and current and not current.startswith(FULLWIDTH_SPACE):
            current = FULLWIDTH_SPACE + current

        if orig_len > 10:
            result.append(current)
        elif orig_len == 10:
            while len(current) < 10 and queue:
                current += queue.pop(0)
            if len(current) > 10:
                queue.insert(0, current[10:])
                current = current[:10]
            result.append(current)
        else:
            if len(current) > 10:
                queue.insert(0, current[10:])
                current = current[:10]
            result.append(current)

    while queue:
        text = queue.pop(0)
        while len(text) > 10:
            result.append(text[:10])
            text = text[10:]
        if text:
            result.append(text)

    return result


def load_g_translations(path):
    results = []
    cur_ids = set()
    cur_map = {}
    cur_header = None
    is_g = False

    for line in path.read_text(encoding="utf-8").split("\n"):
        if re.match(r"^--- Group .* ---G?$", line):
            if cur_header is not None and is_g:
                results.append((cur_ids, cur_header, cur_map))
            cur_header = line
            cur_ids = set()
            cur_map = {}
            is_g = line.rstrip().endswith("G")
        elif is_g:
            tm = re.match(r"^[+-](\[FID:[^\]]+\]) (.*)", line)
            if tm:
                tag = tm.group(1)
                cur_map[tag] = tm.group(2)
                m = re.search(r"TEXT:([0-9A-Fa-f]+)", tag)
                if m:
                    cur_ids.add(m.group(1))

    if cur_header is not None and is_g:
        results.append((cur_ids, cur_header, cur_map))
    return results


def load_char_names():
    with open(CHAR_NAMES_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)
    mapping = {}
    for dec_id, info in data.items():
        hex_id = format(int(dec_id), "04X")
        jp = info.get("japanese", "")
        cn = info.get("chinese", "")
        label = cn if cn else (jp if jp else f"角色{dec_id}")
        mapping[hex_id] = label
    return mapping


def replace_char_ids(text, char_map):
    def replacer(m):
        hex_id = m.group(1).upper()
        if hex_id in char_map:
            return char_map[hex_id]
        return m.group(0)
    return re.sub(r"char_([0-9a-fA-F]{4})", replacer, text)


def process_file(orig_path, out_path, char_map):
    with open(orig_path, "r", encoding="utf-8") as f:
        content = replace_char_ids(f.read(), char_map)
        orig_groups = parse_groups(content)

    preserved = []
    if out_path.exists():
        preserved = load_g_translations(out_path)

    # FIRST PASS: process all groups with empty translations (leave blank)
    blocks = []
    seen_tags = set()

    for og in orig_groups:
        m = re.search(r"Group (\d+)", og["header"])
        group_num = int(m.group(1)) if m else -1

        orig_tags = [l["tag"] for l in og["lines"]]
        orig_texts = [l["text"] for l in og["lines"]]

        block = [og["header"]]

        for text in orig_texts:
            block.append(text)

        empty_trans = [""] * len(orig_texts)
        processed = process_texts(orig_texts, empty_trans)

        while len(processed) < len(orig_tags):
            processed.append("")

        for i, text in enumerate(processed):
            tag = orig_tags[i] if i < len(orig_tags) else orig_tags[-1] if orig_tags else ""
            if tag:
                marker = "+" if tag not in seen_tags else "-"
                seen_tags.add(tag)
                block.append(f"{marker}{tag} {text}")
            else:
                block.append(text)

        blocks.append(block)

    # SECOND PASS: override G-groups with preserved translations, matched by TEXT IDs
    if preserved:
        used = set()
        for block in blocks:
            block_ids = set()
            for ln in block:
                m = re.match(r"^[+-]\[FID:[0-9A-F]+, TEXT:([0-9A-Fa-f]+)\]", ln)
                if m:
                    block_ids.add(m.group(1))

            for pi, (pref_ids, pheader, pmap) in enumerate(preserved):
                if pi in used:
                    continue
                if block_ids == pref_ids:
                    used.add(pi)
                    if not block[0].rstrip().endswith("G"):
                        block[0] = block[0].rstrip() + "G"
                    for j, ln in enumerate(block):
                        tm = re.match(r"^([+-])(\[FID:[^\]]+\]) (.*)", ln)
                        if tm and tm.group(2) in pmap:
                            block[j] = f"{tm.group(1)}{tm.group(2)} {pmap[tm.group(2)]}"
                    break

    # THIRD: remove all-duplicate groups (except G-groups, always preserved)
    filtered = []
    for block in blocks:
        is_g = block[0].rstrip().endswith("G")
        markers = [ln[0] for ln in block if ln and ln[0] in ("+", "-") and "[FID:" in ln]
        if not is_g and markers and all(m == "-" for m in markers):
            continue
        filtered.append(block)

    # FOURTH: dedup consecutive identical TEXT IDs within each group
    for block in filtered:
        i = 1
        while i < len(block) - 1:
            cur_m = re.match(r"^[+-]\[FID:[0-9A-F]+, TEXT:([0-9A-Fa-f]+)\]", block[i])
            next_m = re.match(r"^[+-]\[FID:[0-9A-F]+, TEXT:([0-9A-Fa-f]+)\]", block[i + 1])
            if cur_m and next_m and cur_m.group(1) == next_m.group(1) and cur_m.group(1) != "0000":
                block.pop(i + 1)
            else:
                i += 1

    output_lines = []
    for block in filtered:
        block[0] = re.sub(r"Group \d+", "Group", block[0])
        output_lines.extend(block)
        output_lines.append("")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(output_lines))


def main():
    char_map = load_char_names()
    print(f"Loaded {len(char_map)} character name mappings")

    orig_files = sorted(ORIG_DIR.glob("script*_fid*.txt"))
    if not orig_files:
        print(f"No original files found in {ORIG_DIR}")
        sys.exit(1)

    print(f"Found {len(orig_files)} original files")
    processed = 0

    for of in orig_files:
        out_path = OUTPUT_DIR / of.name

        try:
            process_file(of, out_path, char_map)
            processed += 1
            print(f"  OK: {of.name}")
        except Exception as e:
            print(f"  ERR: {of.name} ({e})")

    print(f"\nDone. {processed}/{len(orig_files)} files processed.")
    print(f"Output: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
