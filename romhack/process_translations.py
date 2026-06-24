import json
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
ORIG_DIR = SCRIPT_DIR.parent / "ruby_tools" / "opencode_generated" / "output_full"
TRANS_DIR = SCRIPT_DIR.parent / "ruby_tools" / "opencode_generated" / "translations"
OUTPUT_DIR = SCRIPT_DIR.parent / "ruby_tools" / "opencode_generated" / "processed"

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

        if orig.startswith(FULLWIDTH_SPACE) and not current.startswith(FULLWIDTH_SPACE):
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


def load_g_groups(path):
    g = {}
    cur_num = None
    cur_lines = None
    is_g = False
    for line in path.read_text(encoding="utf-8").split("\n"):
        if line.startswith("--- Group "):
            if cur_num is not None and is_g:
                while cur_lines and cur_lines[-1].strip() == "":
                    cur_lines.pop()
                g[cur_num] = cur_lines
            m = re.search(r"Group (\d+)", line)
            cur_num = int(m.group(1)) if m else None
            cur_lines = [line]
            is_g = line.rstrip().endswith("G")
        elif cur_num is not None:
            cur_lines.append(line)
    if cur_num is not None and is_g:
        while cur_lines and cur_lines[-1].strip() == "":
            cur_lines.pop()
        g[cur_num] = cur_lines
    return g


def process_file(orig_path, trans_path, out_path):
    with open(orig_path, "r", encoding="utf-8") as f:
        orig_groups = parse_groups(f.read())
    with open(trans_path, "r", encoding="utf-8") as f:
        trans_groups = parse_groups(f.read())

    orig_map = {}
    for g in orig_groups:
        m = re.search(r"Group (\d+)", g["header"])
        if m:
            orig_map[int(m.group(1))] = g

    old_g = load_g_groups(out_path) if out_path.exists() else {}

    blocks = []
    seen_tags = set()

    for tg in trans_groups:
        m = re.search(r"Group (\d+)", tg["header"])
        group_num = int(m.group(1)) if m else -1

        if group_num in old_g:
            block = list(old_g[group_num])
            for ln in block:
                tm = re.match(r"^[+-]?(\[FID:[^\]]+\])", ln)
                if tm:
                    seen_tags.add(tm.group(1))
            blocks.append(block)
            continue

        og = orig_map.get(group_num)

        block = [tg["header"]]

        if og:
            orig_tags = [l["tag"] for l in og["lines"]]
            orig_texts = [l["text"] for l in og["lines"]]
            orig_tag_set = set(t for t in orig_tags if t)

            trans_tag_map = {}
            for l in tg["lines"]:
                if l["tag"]:
                    if l["tag"] not in orig_tag_set:
                        raise ValueError(
                            f"Group {group_num}: tag {l['tag']} in translation not found in original"
                        )
                    trans_tag_map[l["tag"]] = l["text"]

            trans_texts = [trans_tag_map.get(tag, "") for tag in orig_tags]

            for text in orig_texts:
                block.append(text)

            processed = process_texts(orig_texts, trans_texts)

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
        else:
            for l in tg["lines"]:
                if l["tag"]:
                    marker = "+" if l["tag"] not in seen_tags else "-"
                    seen_tags.add(l["tag"])
                    block.append(f"{marker}{l['tag']} {l['text']}")
                else:
                    block.append(l["text"])

        blocks.append(block)

    output_lines = []
    for block in blocks:
        output_lines.extend(block)
        output_lines.append("")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(output_lines))


def main():
    trans_files = sorted(TRANS_DIR.glob("script*_fid*.txt"))
    if not trans_files:
        print(f"No translated files found in {TRANS_DIR}")
        sys.exit(1)

    print(f"Found {len(trans_files)} translated files")
    processed = 0

    for tf in trans_files:
        orig_path = ORIG_DIR / tf.name
        out_path = OUTPUT_DIR / tf.name

        if not orig_path.exists():
            print(f"  SKIP {tf.name}: original not found")
            continue

        try:
            process_file(orig_path, tf, out_path)
            processed += 1
            print(f"  OK: {tf.name}")
        except Exception as e:
            print(f"  ERR: {tf.name} ({e})")

    print(f"\nDone. {processed}/{len(trans_files)} files processed.")
    print(f"Output: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
