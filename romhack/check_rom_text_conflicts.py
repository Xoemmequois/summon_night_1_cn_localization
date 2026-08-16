import json
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
TARGET_PATH = SCRIPT_DIR / "rom_text_zh_CN.json"


def addr_of(key: str):
    # 取 key 中最后一个 "-0xXXXX" 段作为 ROM 文件偏移
    parts = key.split("-0x")
    if len(parts) < 2:
        return None
    try:
        return int(parts[-1], 16)
    except ValueError:
        return None


def main():
    with open(TARGET_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)

    by_addr = {}
    for item in data:
        addr = addr_of(item["key"])
        if addr is None:
            continue
        by_addr.setdefault(addr, []).append(item)

    conflicts = []
    empty_vs_translated = []
    for addr, items in sorted(by_addr.items()):
        if len(items) < 2:
            continue
        non_empty = {i["translation"] for i in items if i.get("translation")}
        if len(non_empty) > 1:
            conflicts.append((addr, items))
        elif non_empty and any(not i.get("translation") for i in items):
            empty_vs_translated.append((addr, items))

    print(f"Total entries: {len(data)}")
    print(f"Shared addresses (>=2 entries): {sum(1 for v in by_addr.values() if len(v) >= 2)}")
    print(f"Conflicts (same addr, different non-empty translations): {len(conflicts)}")
    for addr, items in conflicts:
        print(f"\n  [0x{addr:X}] {len(items)} entries, {len({i['translation'] for i in items})} distinct translations:")
        for i in items:
            print(f"    {i['key']}: {i.get('stage')} | {i['translation']}")
    print(f"\nEmpty-vs-translated (same addr, one empty one not): {len(empty_vs_translated)}")
    for addr, items in empty_vs_translated:
        print(f"\n  [0x{addr:X}]")
        for i in items:
            print(f"    {i['key']}: {i.get('stage')} | {i['translation'] or '(empty)'}")


if __name__ == "__main__":
    main()
