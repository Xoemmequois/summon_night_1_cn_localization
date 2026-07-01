import json
import re
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
PROCESSED_DIR = SCRIPT_DIR.parent / "ruby_tools" / "opencode_generated" / "processed"
ZH_CN_PATH = SCRIPT_DIR / "zh_CN.json"
OUTPUT_PATH = SCRIPT_DIR / "zh_CN_translated.json"

GROUP_RE = re.compile(r"^--- Group \d+ .+---G\s*$")
FID_TEXT_RE = re.compile(r"^[+-]?\[FID:([0-9A-Fa-f]+), TEXT:([0-9A-Fa-f]+)\] (.*)")


def collect_translations():
    trans = {}
    for path in sorted(PROCESSED_DIR.glob("script*_fid*.txt")):
        in_g_group = False
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if line.startswith("--- Group "):
                    in_g_group = bool(GROUP_RE.match(line))
                    continue
                if not in_g_group:
                    continue
                m = FID_TEXT_RE.match(line)
                if m:
                    fid = int(m.group(1), 16)
                    text_idx = int(m.group(2), 16)
                    key = f"{fid:04d}-{text_idx:04d}"
                    text = m.group(3)
                    if key in trans and trans[key] != text:
                        raise ValueError(
                            f"Conflicting translations for {key} in {path.name}:\n"
                            f"  existing: {trans[key]}\n"
                            f"  new:      {text}"
                        )
                    trans[key] = text
    return trans


def main():
    trans = collect_translations()
    print(f"Collected {len(trans)} translations from processed files")

    base_path = OUTPUT_PATH if OUTPUT_PATH.exists() else ZH_CN_PATH
    with open(base_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    updated = 0
    for item in data:
        if item["key"] in trans:
            item["translation"] = trans[item["key"]]
            item["stage"] = 3
            updated += 1

    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

    print(f"Updated {updated}/{len(data)} entries")
    print(f"Written to {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
