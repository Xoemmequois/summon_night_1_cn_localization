import json
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
SOURCE_PATH = SCRIPT_DIR / "rom_text.json"
TARGET_PATH = SCRIPT_DIR / "rom_text_zh_CN.json"

TRANSLATIONS = {
    # 名称输入字符表（不可翻译，保留空翻译）
    "NameTable-Hiragana-0x7F568": "",
    "NameTable-Katakana-0x7F630": "",
    "NameTable-Symbols-0x7F6F8": "",
    "NameTable-Kanji-0x7F7C0": "",
    # 提示文字（各槽位按原长度拆分，拼接后为完整句子）
    "Hint-0-Slot0-0x5410": "奖励点数还有剩",
    "Hint-0-Slot1-0x5404": "余",
    "Hint-1-Slot0-0x5428": "经验值不足",
    "Hint-2-Slot0-0x5448": "可以升级的人",
    "Hint-2-Slot1-0x543C": "不存在",
    "Hint-3-Slot0-0x546C": "不能再升级",
    "Hint-3-Slot1-0x5460": "了",
    "Hint-4-Slot0-0x5490": "没有可以装备的",
    "Hint-4-Slot1-0x5484": "武器",
    "Hint-5-Slot0-0x54A8": "没有可以装备的",
    "Hint-5-Slot1-0x5484": "防具",
    "Hint-6-Slot0-0x54D4": "没有可以装备的",
    "Hint-6-Slot1-0x54C0": "饰品",
    "Hint-7-Slot0-0x54F8": "没有可以装备的",
    "Hint-7-Slot1-0x54EC": "石头",
    "Hint-8-Slot0-0x5510": "没有物",
    "Hint-8-Slot1-0x88244": "品",
    "Hint-9-Slot0-0x5528": "可装备的武器没有",
    "Hint-9-Slot1-0x5484": "出售",
    "Hint-10-Slot0-0x5540": "可装备的防具没有",
    "Hint-10-Slot1-0x5484": "出售",
    "Hint-11-Slot0-0x54D4": "可装备的饰品没有",
    "Hint-11-Slot1-0x5558": "出售",
    "Hint-12-Slot0-0x5764": "金钱不足",
    "Hint-13-Slot0-0x5778": "已经持有许多",
    "Hint-14-Slot0-0x578C": "没有出售武器",
    "Hint-15-Slot0-0x57A4": "没有出售防具",
    "Hint-16-Slot0-0x57BC": "没有出售饰",
    "Hint-16-Slot1-0x88254": "品",
    "Hint-18-Slot0-0x57D4": "没有出售物",
    "Hint-18-Slot1-0x8825C": "品",
    "Hint-19-Slot0-0x57EC": "没有可卖的武",
    "Hint-19-Slot1-0x88264": "器",
    "Hint-20-Slot0-0x5804": "没有可卖的防",
    "Hint-20-Slot1-0x88264": "具",
    "Hint-21-Slot0-0x5828": "没有可卖的饰",
    "Hint-21-Slot1-0x581C": "品",
    "Hint-23-Slot0-0x5840": "没有可卖的物",
    "Hint-23-Slot1-0x88254": "品",
    # 未引用文本
    "Unreferenced-0x4A84": "隼人",
    "Unreferenced-0x4A90": "搭档",
    "Unreferenced-0x4D04": "召唤之夜",
    "Unreferenced-0x4D14": "存档已损坏",
    "Unreferenced-0x4D2C": "新建存档",
    "Unreferenced-0x4D38": "有可用存档位",
    "Unreferenced-0x4D50": "将覆盖存档",
    "Unreferenced-0x4D7C": "召唤之夜　存档",
    "Unreferenced-0x5160": "ＨＡＹＡＴＯ",
    "Unreferenced-0x5170": "隼人",
    "Unreferenced-0x517C": "隼人",
    "Unreferenced-0x5188": "ＴＯＨＹＡ",
    "Unreferenced-0x5198": "冬也",
    "Unreferenced-0x51A4": "冬也",
    "Unreferenced-0x51B0": "ＮＡＴＵＭＩ",
    "Unreferenced-0x51C0": "夏美",
    "Unreferenced-0x51CC": "夏美",
    "Unreferenced-0x51D8": "ＡＹＡ",
    "Unreferenced-0x51E4": "新太郎",
    "Unreferenced-0x51F0": "弘和",
    "Unreferenced-0x51FC": "奇诺皮",
    "Unreferenced-0x5208": "大叔",
    "Unreferenced-0x5214": "班普雷石",
    "Unreferenced-0x5220": "支线剧情",
    "Unreferenced-0x5230": "隐藏角色",
    "Unreferenced-0x5240": "奇姆奇姆",
    "Unreferenced-0x524C": "魔王！",
    "Unreferenced-0x5258": "埃尔戈之王",
    "Unreferenced-0x556C": "卸下装备",
    "Unreferenced-0x5A50": "没有",
}


def main():
    with open(SOURCE_PATH, "r", encoding="utf-8") as f:
        source = json.load(f)
    with open(TARGET_PATH, "r", encoding="utf-8") as f:
        target = json.load(f)

    target_keys = {item["key"] for item in target}
    missing = [item for item in source if item["key"] not in target_keys]

    assert len(missing) == 73, f"expected 73 missing, got {len(missing)}"

    additions = []
    for item in missing:
        key = item["key"]
        trans = TRANSLATIONS.get(key)
        assert trans is not None, f"missing translation for {key}"
        orig_chars = len(item["original"])
        if len(trans) > orig_chars:
            raise ValueError(
                f"{key}: translation {len(trans)} chars > original {orig_chars} chars"
            )
        additions.append(
            {
                "key": key,
                "original": item["original"],
                "translation": trans,
                "stage": 3,
            }
        )

    target.extend(additions)

    raw = json.dumps(target, ensure_ascii=False, indent=2)
    raw = raw.replace("\n", "\r\n")
    TARGET_PATH.write_bytes(raw.encode("utf-8"))

    print(f"Added {len(additions)} entries, total now {len(target)}")
    for a in additions:
        print(f"  {a['key']}: {a['translation']}")


if __name__ == "__main__":
    main()
