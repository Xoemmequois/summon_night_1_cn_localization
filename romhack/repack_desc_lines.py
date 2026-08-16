import json
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
TARGET_PATH = SCRIPT_DIR / "rom_text_zh_CN.json"

# 散文描述按"填满10字再换行"重排；MP 行与空槽保持原样；共享地址保持一致。
REPACK = {
    # --- Magic ---
    "Magic-1-Desc1-0x4430": "能创造召唤魔法并为其",
    "Magic-1-Desc2-0x441C": "命名",
    "Magic-3-Desc1-0x43C0": "竭尽全力的应援能激励",
    "Magic-3-Desc2-0x43AC": "队友士气",
    "Magic-4-Desc1-0x4378": "忍者轻功，可越过高处",
    "Magic-4-Desc2-0x4360": "",
    "Magic-5-Desc1-0x432C": "以神秘眼光护身，梅特",
    "Magic-5-Desc2-0x4318": "拉尔族的能力",
    "Magic-6-Desc1-0x42F4": "对机鬼灵兽全属性术有",
    "Magic-6-Desc2-0x42E0": "抗性",
    "Magic-7-Desc1-0x42BC": "可使用机鬼灵兽全属性",
    "Magic-7-Desc2-0x88144": "",
    # --- Item ---
    "Item-18-Desc1-0x2B28": "所有的异常状态全恢复",
    "Item-18-Desc2-0x2B1C": "",
    "Item-19-Desc1-0x2B28": "所有的异常状态全恢复",
    "Item-19-Desc2-0x2AF8": "，并完全恢复ＨＰ",
    "Item-19-Desc3-0x88070": "",
    "Item-1-Desc1-0x2D9C": "发动「机械」属性召唤",
    "Item-1-Desc2-0x2D90": "",
    "Item-4-Desc1-0x2D0C": "发动「幻兽」属性召唤",
    "Item-4-Desc2-0x2D90": "",
    "Item-2-Desc1-0x2D64": "发动「鬼」属性召唤",
    "Item-2-Desc2-0x88078": "",
    "Item-3-Desc1-0x2D38": "发动「灵」属性召唤",
    "Item-3-Desc2-0x88078": "",
    "Item-5-Desc1-0x2CE0": "发动「无」属性召唤",
    "Item-5-Desc2-0x88078": "",
    "Item-20-Desc1-0x2AE0": "钓鱼饵料　恢复５ＨＰ",
    "Item-20-Desc2-0x2AD4": "",
    "Item-21-Desc1-0x2AE0": "钓鱼饵料　恢复５ＨＰ",
    "Item-21-Desc2-0x2AD4": "",
    "Item-22-Desc1-0x2AE0": "钓鱼饵料　恢复５ＨＰ",
    "Item-22-Desc2-0x2AD4": "",
    "Item-23-Desc1-0x2AE0": "钓鱼饵料　恢复５ＨＰ",
    "Item-23-Desc2-0x2AD4": "",
    "Item-24-Desc1-0x2AE0": "钓鱼饵料　恢复５ＨＰ",
    "Item-24-Desc2-0x2AD4": "",
    "Equip-228-Desc1-0x25B8": "ＨＰ最大值＋１０　Ｓ",
    "Equip-254-Desc2-0x21D0": "ＮＴ＋３　幸运－５",
    # --- Skill ---
    "Skill-2-Desc1-0x422C": "来自灵界萨普雷斯的召",
    "Skill-2-Desc2-0x4214": "唤术有抗性",
    "Skill-6-Desc1-0x422C": "来自灵界萨普雷斯的召",
    "Skill-6-Desc2-0x4184": "唤术可用",
    "Skill-10-Desc1-0x40C4": "熟练运用灵界萨普雷斯",
    "Skill-10-Desc2-0x40AC": "的召唤术的能力",
    "Skill-10-Desc3-0x88120": "",
    "Skill-11-Desc1-0x4080": "熟练运用幻兽界梅特尔",
    "Skill-11-Desc2-0x4068": "帕的召唤术的能力",
    "Skill-11-Desc3-0x405C": "",
    "Skill-12-Desc1-0x4044": "锐利目光让敌人难以靠",
    "Skill-12-Desc2-0x402C": "近　ＺＯＣ小",
    "Skill-20-Desc1-0x3E80": "牺牲其他行动攻击可连",
    "Skill-20-Desc2-0x3E68": "续进行两次的能力",
    "Skill-20-Desc3-0x405C": "",
    "Skill-21-Desc1-0x3E40": "牺牲其他行动移动可连",
    "Skill-21-Desc2-0x3E68": "续进行两次的能力",
    "Skill-21-Desc3-0x405C": "",
    "Skill-25-Desc1-0x3D54": "能将枪械装备于手臂上",
    "Skill-25-Desc2-0x405C": "",
    "Skill-13-Desc1-0x4014": "眼神和气势震慑靠近的",
    "Skill-13-Desc2-0x3FFC": "敌人　ＺＯＣ中",
    "Skill-13-Desc3-0x88108": "",
    # --- Skill-8/9/24: 0x88128 能力 并入上一槽 ---
    "Skill-8-Desc2-0x411C": "的召唤术的能力",
    "Skill-8-Desc3-0x88128": "",
    "Skill-9-Desc2-0x411C": "的召唤术的能力",
    "Skill-9-Desc3-0x88128": "",
    "Skill-24-Desc2-0x3D7C": "备枪械的能力",
    "Skill-24-Desc3-0x88128": "",
    # --- Skill-16/17: 0x3F48 器 并入上一槽 ---
    "Skill-16-Desc2-0x3F54": "术　可装备「投」武器",
    "Skill-16-Desc3-0x3F48": "",
    "Skill-17-Desc2-0x3F54": "术　可装备「投」武器",
    "Skill-17-Desc3-0x3F48": "",
    "Skill-14-Desc1-0x3FE4": "气场逼退敌人ＺＯＣ大",
    "Skill-14-Desc2-0x3FCC": "",
    "Skill-14-Desc3-0x880FC": "",
    "Skill-15-Desc1-0x3FA8": "注重反击的剑技　反击",
    "Skill-15-Desc2-0x3F90": "时攻击力ＵＰ",
    "Skill-18-Desc1-0x3F00": "凭借超凡的毅力，濒死",
    "Skill-18-Desc2-0x3EE8": "时无惩罚",
    "Skill-18-Desc3-0x880F0": "",
    "Skill-19-Desc1-0x3EC0": "陷入绝境之时会发挥超",
    "Skill-19-Desc2-0x3EA8": "越实力的力量",
    "Skill-22-Desc1-0x3E1C": "强烈的剑戟使对手方向",
    "Skill-22-Desc2-0x3E04": "感混乱",
    "Skill-23-Desc1-0x3DDC": "暗杀者惯用手段　背",
    "Skill-23-Desc2-0x3DC4": "后攻击威力更加强大",
    "Skill-23-Desc3-0x3DB8": "",
    "Skill-24-Desc1-0x3D94": "掌握枪械保养法并能装",
    "Skill-24-Desc2-0x3D7C": "备枪械的能力",
    "Skill-26-Desc1-0x3D30": "面对敌人的杀气也毫不",
    "Skill-26-Desc2-0x3D18": "畏惧　无视ＺＯＣ",
    "Skill-26-Desc3-0x3D0C": "",
    "Skill-27-Desc1-0x3CF4": "全方位无懈可击　",
    "Skill-27-Desc2-0x3CDC": "无方向惩罚",
    "Skill-27-Desc3-0x880F0": "",
    "Skill-28-Desc1-0x3CB0": "不受任何异常状态影响",
    "Skill-28-Desc2-0x3C98": "",
    "Skill-29-Desc1-0x3C6C": "攻击敌人造成精神冲击",
    "Skill-29-Desc2-0x3C54": "　对ＭＰ造成伤害",
    "Skill-29-Desc3-0x880D8": "",
    "Skill-30-Desc1-0x3C2C": "身体过于软绵绵物理伤",
    "Skill-30-Desc2-0x3C14": "害减半",
    "Skill-31-Desc1-0x3BF0": "以压倒之力与毫无破绽",
    "Skill-31-Desc2-0x3BD8": "的攻击不给对手反击",
    "Skill-31-Desc3-0x3BCC": "",
    "Skill-33-Desc1-0x3B84": "鬼界希尔坦之力发动的",
    "Skill-33-Desc2-0x3B74": "魔法攻击",
    "Skill-37-Desc1-0x3B0C": "魔王之力造成的强大魔",
    "Skill-37-Desc2-0x3AFC": "法攻击",
    "Skill-38-Desc1-0x3AE4": "魔王之力发动魔法攻击",
    "Skill-38-Desc2-0x880CC": "",
    # --- Unknown ---
    "Unknown-11-Desc1-0x303C": "小范围中威力的恢复＆",
    "Unknown-11-Desc2-0x3024": "异常状态恢复",
    "Unknown-14-Desc1-0x2FCC": "单体攻防上升",
    "Unknown-14-Desc2-0x88094": "",
    "Unknown-20-Desc1-0x2F44": "中范围状态异常回复",
    "Unknown-20-Desc2-0x8808C": "",
    # --- Hint 小碎片并入上一槽 ---
    "Hint-0-Slot0-0x5410": "奖励点数还有剩余",
    "Hint-0-Slot1-0x5404": "",
    "Hint-2-Slot0-0x5448": "可以升级的人不存在",
    "Hint-2-Slot1-0x543C": "",
    "Hint-3-Slot0-0x546C": "不能再升级了",
    "Hint-3-Slot1-0x5460": "",
}


def main():
    with open(TARGET_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)

    by_key = {item["key"]: item for item in data}
    missing = [k for k in REPACK if k not in by_key]
    if missing:
        raise KeyError(f"keys not found: {missing}")

    for key, trans in REPACK.items():
        item = by_key[key]
        if len(trans) > len(item["original"]):
            raise ValueError(
                f"{key}: translation {len(trans)} chars > original {len(item['original'])} chars"
            )
        item["translation"] = trans
        item.setdefault("stage", 3)

    raw = json.dumps(data, ensure_ascii=False, indent=2)
    raw = raw.replace("\n", "\r\n")
    TARGET_PATH.write_bytes(raw.encode("utf-8"))
    print(f"Repacked {len(REPACK)} entries")


if __name__ == "__main__":
    main()
