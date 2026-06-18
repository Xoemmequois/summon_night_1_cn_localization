import json
import base64
import re
import os
import sys
import time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests

SCRIPT_DIR = Path(__file__).parent
CONFIG_PATH = SCRIPT_DIR / "config.json"
CHAR_NAMES_DIR = SCRIPT_DIR / "pic_output" / "char_names"
OUTPUT_PATH = SCRIPT_DIR / "char_names_translated.json"
PROGRESS_PATH = SCRIPT_DIR / "pic_output" / "char_names" / ".ocr_progress.json"

API_URL = "https://openrouter.ai/api/v1/chat/completions"
MODEL = "google/gemini-2.5-flash-lite"
PROMPT = (
    "这张图片是一个日本PS1游戏中角色的名字。"
    "请识别图中的日文名字，并翻译成中文。\n"
    "请严格按照以下JSON格式回答，不要输出其他内容：\n"
    '{"japanese": "识别出的日文名", "chinese": "中文翻译"}'
)
MAX_WORKERS = 8
MAX_RETRIES = 3


def load_config():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def load_progress():
    if PROGRESS_PATH.exists():
        try:
            with open(PROGRESS_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_progress(progress):
    with open(PROGRESS_PATH, "w", encoding="utf-8") as f:
        json.dump(progress, f, ensure_ascii=False, indent=2)


def extract_char_id(filename):
    m = re.match(r"char_(\d+)", filename)
    return int(m.group(1)) if m else None


def call_api(session, image_path):
    image_bytes = image_path.read_bytes()
    b64 = base64.b64encode(image_bytes).decode("ascii")

    payload = {
        "model": MODEL,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": PROMPT},
                    {"type": "image_url", "image_url": {"url": f"data:image/gif;base64,{b64}"}},
                ],
            }
        ],
        "max_tokens": 200,
        "temperature": 0,
    }

    for attempt in range(MAX_RETRIES):
        try:
            resp = session.post(API_URL, json=payload, timeout=60)
            resp.raise_for_status()
            data = resp.json()
            content = data["choices"][0]["message"]["content"]
            content = content.strip()
            if content.startswith("```"):
                content = re.sub(r"^```(?:json)?\s*", "", content)
                content = re.sub(r"\s*```$", "", content)
            return json.loads(content)
        except Exception as e:
            if attempt >= MAX_RETRIES - 1:
                raise
            time.sleep(2 ** attempt)
    return None


def main():
    config = load_config()
    api_key = config.get("OpenRouterKey", "")
    proxy_url = config.get("OpenRouterProxy", "")

    if not api_key:
        print("ERROR: OpenRouterKey not found in config.json")
        sys.exit(1)

    gif_files = sorted(CHAR_NAMES_DIR.glob("*.gif"))
    if not gif_files:
        print("No gif files found in", CHAR_NAMES_DIR)
        sys.exit(1)

    char_map = {}
    for f in gif_files:
        cid = extract_char_id(f.name)
        if cid is not None:
            if cid not in char_map:
                char_map[cid] = f

    progress = load_progress()
    results = {}
    for cid_str, val in progress.items():
        results[int(cid_str)] = val

    remaining = {cid: path for cid, path in char_map.items() if cid not in results}
    print(f"Total char IDs: {len(char_map)}, Already done: {len(results)}, Remaining: {len(remaining)}")

    if not remaining:
        print("All done! Writing output...")
        write_output(results)
        return

    session = requests.Session()
    if proxy_url:
        session.proxies = {"http": proxy_url, "https": proxy_url}
    session.headers["Authorization"] = f"Bearer {api_key}"

    completed = 0
    total = len(remaining)
    lock = __import__("threading").Lock()

    def process(cid, path):
        nonlocal completed
        try:
            result = call_api(session, path)
            with lock:
                results[cid] = result
                progress[str(cid)] = result
                completed += 1
                print(f"[{completed}/{total}] char_{cid}: {result.get('japanese', '?')} -> {result.get('chinese', '?')}")
                if completed % 5 == 0:
                    save_progress(progress)
        except Exception as e:
            with lock:
                completed += 1
                print(f"[{completed}/{total}] char_{cid}: ERROR ({e})")

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {executor.submit(process, cid, path): cid for cid, path in remaining.items()}
        for f in as_completed(futures):
            pass

    save_progress(progress)
    write_output(results)


def write_output(results):
    output = {}
    for cid in sorted(results.keys()):
        val = results[cid]
        if val:
            output[str(cid)] = {
                "japanese": val.get("japanese", ""),
                "chinese": val.get("chinese", ""),
            }

    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    print(f"Written {len(output)} entries to {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
