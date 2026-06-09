import os
import base64
import json
import time
import shutil
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import requests

API_KEY = "sk-or-v1-"  # <-- 替换为你的 key

CHARS_DIR = Path("romhack/pic_output/chars")
OUTPUT_DIR = Path("romhack/pic_output/char_names")
PROGRESS_FILE = Path("romhack/pic_output/char_names/.progress.json")
PROXY = "http://127.0.0.1:7890"
API_URL = "https://openrouter.ai/api/v1/chat/completions"
MODEL = "google/gemini-2.5-flash-lite"
WORKERS = 8


def load_progress():
    if PROGRESS_FILE.exists():
        with open(PROGRESS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_progress(progress):
    PROGRESS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(PROGRESS_FILE, "w", encoding="utf-8") as f:
        json.dump(progress, f, ensure_ascii=False, indent=2)


def is_text_image(image_path, api_key):
    with open(image_path, "rb") as f:
        image_data = base64.b64encode(f.read()).decode("utf-8")

    payload = {
        "model": MODEL,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": (
                            "この画像に日本語の文字（ひらがな・カタカナ・漢字）が"
                            "含まれていますか？YES か NO だけで答えてください。"
                        ),
                    },
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": f"data:image/gif;base64,{image_data}"
                        },
                    },
                ],
            }
        ],
        "max_tokens": 5,
        "temperature": 0,
    }

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    proxies = {"http": PROXY, "https": PROXY}

    for attempt in range(3):
        try:
            resp = requests.post(
                API_URL, json=payload, headers=headers, proxies=proxies, timeout=60
            )
            resp.raise_for_status()
            result = resp.json()
            answer = result["choices"][0]["message"]["content"].strip().upper()
            return "YES" in answer
        except Exception as e:
            if attempt < 2:
                time.sleep(2**attempt)
            else:
                raise e


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    api_key = API_KEY
    progress = load_progress()
    print(f"Loaded progress: {len(progress)} images already checked")

    image_files = sorted(CHARS_DIR.glob("*.gif"))
    remaining = [f for f in image_files if f.name not in progress]
    print(f"Total: {len(image_files)}, Remaining: {len(remaining)}")

    if not remaining:
        print("All done!")
        return

    text_count = sum(1 for v in progress.values() if v)
    save_every = 10

    def process_one(f):
        try:
            result = is_text_image(f, api_key)
            progress[f.name] = result
            return f, result, None
        except Exception as e:
            progress[f.name] = False
            return f, False, str(e)

    with ThreadPoolExecutor(max_workers=WORKERS) as executor:
        futures = {executor.submit(process_one, f): f for f in remaining}

        for i, future in enumerate(as_completed(futures), 1):
            f, is_text, error = future.result()
            label = "TEXT" if is_text else ("ERR" if error else "  -")
            detail = f" ({error})" if error else ""
            print(f"[{i}/{len(remaining)}] {label}: {f.name}{detail}")

            if is_text:
                shutil.copy2(f, OUTPUT_DIR / f.name)
                text_count += 1

            if i % save_every == 0:
                save_progress(progress)

    save_progress(progress)
    final_text = sum(1 for v in progress.values() if v)
    print(f"\nDone. Text images found: {final_text}/{len(image_files)}")


if __name__ == "__main__":
    main()
