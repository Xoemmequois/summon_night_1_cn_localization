import json
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
TARGET_PATH = SCRIPT_DIR / "rom_text_zh_CN.json"

# 同地址条目必须译文一致。这里给出每组统一的译文；
# 对个别非共享地址做微调，使整句含义不变。
UNIFY = {
    # --- 0x14EC 装备共享串: １　ＤＥＸ＋１ ---
    "Equip-257-Desc2-0x14EC": "１　ＤＥＸ＋１",
    # --- 0x223C 装备共享串: ＭＰ最大値＋１０　Ｉ（Ｉ 接 Desc2 的 ＮＴ） ---
    "Equip-254-Desc1-0x223C": "ＭＰ最大值＋１０　Ｉ",
    # --- 0x2DE8 / 0x2E00 广范围最强威力攻击魔法 ---
    "Unknown-35-Desc2-0x2DE8": "攻击魔法　　Ｍ",
    "Unknown-36-Desc2-0x2DE8": "攻击魔法　　Ｍ",
    "Unknown-37-Desc2-0x2DE8": "攻击魔法　　Ｍ",
    "Unknown-35-Desc1-0x2E00": "广范围最强威力",
    "Unknown-36-Desc1-0x2E00": "广范围最强威力",
    "Unknown-37-Desc1-0x2E00": "广范围最强威力",
    # --- 0x30FC 召唤属性单位 ---
    "Unknown-4-Desc2-0x30FC": "的单位",
    "Unknown-5-Desc2-0x30FC": "的单位",
    "Unknown-5-Desc1-0x30E4": "召唤机械属性",
    # --- 0x3180 中范围中威力攻击 ---
    "Unknown-16-Desc1-0x3180": "中范围中威力攻击",
    # --- 0x3E68 连续进行两次 ---
    "Skill-20-Desc2-0x3E68": "可连续进行两次",
    "Skill-21-Desc2-0x3E68": "可连续进行两次",
    "Skill-20-Desc1-0x3E80": "牺牲其他行动攻击",
    "Skill-21-Desc1-0x3E40": "牺牲其他行动移动",
    # --- 0x3F54 / 0x3F48 飞刀/手里剑投掷术 ---
    "Skill-16-Desc2-0x3F54": "术　可装备「投」武",
    "Skill-17-Desc2-0x3F54": "术　可装备「投」武",
    "Skill-16-Desc3-0x3F48": "器",
    "Skill-17-Desc3-0x3F48": "器",
    "Skill-16-Desc1-0x3F6C": "高超飞刀技",
    # --- 0x405C 的能力 ---
    "Skill-11-Desc3-0x405C": "的能力",
    "Skill-25-Desc2-0x405C": "的能力",
    "Skill-11-Desc2-0x4068": "幻兽界梅特尔帕召唤术",
    "Skill-25-Desc1-0x3D54": "将枪械装备于手臂上",
    # --- 0x411C / 0x88128 家系类: 熟练运用XXXX召唤术的能力 ---
    "Skill-8-Desc2-0x411C": "的召唤术的",
    "Skill-9-Desc2-0x411C": "的召唤术的",
    "Skill-8-Desc3-0x88128": "能力",
    "Skill-9-Desc3-0x88128": "能力",
    "Skill-24-Desc3-0x88128": "能力",
    "Skill-24-Desc2-0x3D7C": "并能装备枪械的",
    "Skill-8-Desc1-0x4134": "熟练运用机界罗雷拉尔",
    "Skill-9-Desc1-0x40F0": "熟练运用鬼界希尔坦",
    # --- Skill-10 家系·灵 ---
    "Skill-10-Desc1-0x40C4": "熟练运用灵",
    "Skill-10-Desc2-0x40AC": "界萨普雷斯的召唤术的",
    "Skill-10-Desc3-0x88120": "能力",
    # --- Skill-11 家系·兽 ---
    "Skill-11-Desc1-0x4080": "熟练运用幻",
    "Skill-11-Desc2-0x4068": "兽界梅特尔帕的召唤术",
    # --- 家系类名字统一 ---
    "Skill-10-Name-0x40DC": "召唤师家系　灵",
    "Skill-11-Name-0x4098": "召唤师家系　兽",
    # --- 0x41EC 来自幻兽界梅特尔帕 ---
    "Skill-3-Desc1-0x41EC": "来自幻兽界梅特尔帕",
    "Skill-7-Desc1-0x41EC": "来自幻兽界梅特尔帕",
    "Skill-7-Desc2-0x4160": "的召唤术可用",
    # --- 0x422C 来自灵界萨普雷斯的召唤术 ---
    "Skill-2-Desc1-0x422C": "来自灵界萨普雷斯的",
    "Skill-6-Desc1-0x422C": "来自灵界萨普雷斯的",
    "Skill-2-Desc2-0x4214": "召唤术有抗性",
    "Skill-6-Desc2-0x4184": "召唤术可用",
    # --- 0x4254 / 0x41B4 来自鬼界希尔坦 ---
    "Skill-1-Desc1-0x4254": "来自鬼界希尔坦",
    "Skill-5-Desc1-0x4254": "来自鬼界希尔坦",
    "Skill-5-Desc2-0x41B4": "的召唤术可使用",
    # --- 0x4294 来自机界罗雷拉尔 ---
    "Skill-0-Desc1-0x4294": "来自机界罗雷拉尔",
    "Skill-4-Desc1-0x4294": "来自机界罗雷拉尔",
    "Skill-4-Desc2-0x41B4": "的召唤术可使用",
    # --- 0x5484 hint 共享尾串：整句放进各槽位，共享尾用句号 ---
    "Hint-4-Slot1-0x5484": "。",
    "Hint-5-Slot1-0x5484": "。",
    "Hint-9-Slot1-0x5484": "。",
    "Hint-10-Slot1-0x5484": "。",
    "Hint-4-Slot0-0x5490": "没有可装备的武器",
    "Hint-5-Slot0-0x54A8": "没有可装备的防具",
    "Hint-9-Slot0-0x5528": "没有可装备的武器出售",
    "Hint-10-Slot0-0x5540": "没有可装备的防具出售",
    # --- 0x54D4 hint 共享串：没有可装备的饰品 ---
    "Hint-6-Slot0-0x54D4": "没有可装备的饰品",
    "Hint-11-Slot0-0x54D4": "没有可装备的饰品",
    "Hint-6-Slot1-0x54C0": "。",
    "Hint-11-Slot1-0x5558": "出售",
    # --- 0x880F0 无惩罚 ---
    "Skill-27-Desc3-0x880F0": "无惩罚",
    "Skill-27-Desc2-0x3CDC": "　方向",
}


def main():
    with open(TARGET_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)

    by_key = {item["key"]: item for item in data}
    missing = [k for k in UNIFY if k not in by_key]
    if missing:
        raise KeyError(f"keys not found: {missing}")

    for key, trans in UNIFY.items():
        item = by_key[key]
        orig_chars = len(item["original"])
        if len(trans) > orig_chars:
            raise ValueError(
                f"{key}: translation {len(trans)} chars > original {orig_chars} chars"
            )
        item["translation"] = trans
        item.setdefault("stage", 3)

    raw = json.dumps(data, ensure_ascii=False, indent=2)
    raw = raw.replace("\n", "\r\n")
    TARGET_PATH.write_bytes(raw.encode("utf-8"))
    print(f"Unified {len(UNIFY)} entries")


if __name__ == "__main__":
    main()
