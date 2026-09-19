#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

FULL_WIDTH_SPACE = "　"


def find_overlong_translations(path: Path):
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    offenders = []
    for item in data:
        key = item.get("key", "")
        text = item.get("translation", "")
        if not isinstance(text, str):
            continue
        if not text:
            continue
        if text.startswith(FULL_WIDTH_SPACE):
            continue
        if len(text) > 10:
            offenders.append((key, len(text), text))

    return offenders


def main():
    parser = argparse.ArgumentParser(
        description="检查 translation 中所有不以全角空格开头且超过 10 字的条目。"
    )
    parser.add_argument(
        "file",
        nargs="?",
        default="zh_CN_translated.json",
        help="JSON 文件路径，默认是当前目录下的 zh_CN_translated.json",
    )
    args = parser.parse_args()

    file_path = Path(args.file)
    if not file_path.exists():
        raise FileNotFoundError(f"找不到文件: {file_path}")

    offenders = find_overlong_translations(file_path)

    if not offenders:
        print(f"检查完成：{file_path} 中没有发现“不以全角空格开头且长度 > 10”的条目。")
        return 0

    print(f"检查完成：共发现 {len(offenders)} 条异常。")
    for key, length, text in offenders:
        print(f"{key} | length={length} | {text}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
