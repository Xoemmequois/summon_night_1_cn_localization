import json
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
SOURCE_PATH = SCRIPT_DIR / "rom_text.json"
TARGET_PATH = SCRIPT_DIR / "rom_text_zh_CN.json"


def main():
    with open(SOURCE_PATH, "r", encoding="utf-8") as f:
        source = json.load(f)
    with open(TARGET_PATH, "r", encoding="utf-8") as f:
        target = json.load(f)

    originals = {item["key"]: item["original"] for item in source}

    target_keys = {item["key"] for item in target}
    source_keys = set(originals)

    missing_in_target = sorted(source_keys - target_keys)
    extra_in_target = sorted(target_keys - source_keys)
    if extra_in_target:
        print(f"WARN: {len(extra_in_target)} key(s) in {TARGET_PATH.name} not in {SOURCE_PATH.name}:")
        for k in extra_in_target:
            print(f"  {k}")

    updated = 0
    for item in target:
        key = item["key"]
        if key in originals and item.get("original") != originals[key]:
            item["original"] = originals[key]
            updated += 1

    raw = json.dumps(target, ensure_ascii=False, indent=2)
    raw = raw.replace("\n", "\r\n")
    TARGET_PATH.write_bytes(raw.encode("utf-8"))

    print(f"Updated original for {updated}/{len(target)} entries")
    print(f"Written to {TARGET_PATH}")
    if missing_in_target:
        print(f"NOTE: {len(missing_in_target)} key(s) in {SOURCE_PATH.name} missing from {TARGET_PATH.name} (left untouched)")


if __name__ == "__main__":
    main()
