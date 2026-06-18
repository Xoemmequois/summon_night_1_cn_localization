import json
import re
import os
import sys
import time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

import requests

SCRIPT_DIR = Path(__file__).parent
CONFIG_PATH = SCRIPT_DIR / "config.json"
CHAR_NAMES_PATH = SCRIPT_DIR / "char_names_translated.json"
INPUT_DIR = SCRIPT_DIR.parent / "ruby_tools" / "opencode_generated" / "output_full"
OUTPUT_DIR = SCRIPT_DIR.parent / "ruby_tools" / "opencode_generated" / "translations"
PROGRESS_PATH = OUTPUT_DIR / ".progress.json"

API_URL = "https://openrouter.ai/api/v1/chat/completions"
MODEL = "google/gemini-2.5-flash-lite"
MAX_RETRIES = 3
GROUPS_PER_CHUNK = 80
MAX_WORKERS = 4

SYSTEM_PROMPT = """\
你是一个专业的日语游戏翻译。你正在翻译PS1游戏《サモンナイト》（召唤之夜）的对话脚本。

文件格式说明：
- 这些对话脚本是通过广度优先搜索（BFS）从游戏的脚本命令系统中提取出来的。
- 同一个位置因为不同的if条件（如主人公性别、性格选择）会说不同的话，这些变体会连续排列在一起。
  例如Group 11/12/13/14可能是同一句话的4个变体（俺/僕/あたし/わたし），意思相同只是人称不同。
- 每个Group的 [left:角色名] 或 [right:角色名] 表示说话人及其在画面中的位置。
- [FID:XX, TEXT:XXXX] 是内部索引标记，翻译时必须原样保留。
- @n 是游戏内的名字替换控制符，翻译时保留原样。
- 空行分隔不同的Group，保持原样。

翻译要求：
- 只翻译日文对话文本为中文，保留所有格式标记不变。
- Group头部行 (--- Group N [...] ---) 完全保持原样，不要修改。
- [FID:XX, TEXT:XXXX] 标记保持原样，只翻译标记后面的日文文本。
- 翻译要符合游戏对话的口语化风格，保持角色个性。
- 对于同一句话的不同人称变体，翻译也要体现出对应的语气差异。
- 直接输出翻译后的完整内容，不要加任何额外说明。"""


def load_config():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def load_char_names():
    with open(CHAR_NAMES_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)
    mapping = {}
    for dec_id, info in data.items():
        hex_id = format(int(dec_id), "04X")
        jp = info.get("japanese", "")
        cn = info.get("chinese", "")
        label = cn if cn else (jp if jp else f"角色{dec_id}")
        mapping[hex_id] = label
    return mapping


def replace_char_ids(text, char_map):
    def replacer(m):
        hex_id = m.group(1).upper()
        if hex_id in char_map:
            return char_map[hex_id]
        return m.group(0)
    return re.sub(r"char_([0-9a-fA-F]{4})", replacer, text)


def split_into_chunks(text, max_groups=GROUPS_PER_CHUNK):
    lines = text.split("\n")
    chunks = []
    current_chunk = []
    group_count = 0

    for line in lines:
        if line.startswith("--- Group "):
            if group_count > 0 and group_count % max_groups == 0:
                while current_chunk and current_chunk[-1].strip() == "":
                    current_chunk.pop()
                chunks.append("\n".join(current_chunk))
                current_chunk = []
            group_count += 1
        current_chunk.append(line)

    if current_chunk:
        while current_chunk and current_chunk[-1].strip() == "":
            current_chunk.pop()
        chunks.append("\n".join(current_chunk))

    return chunks


def call_api(session, text_chunk):
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": text_chunk},
        ],
        "max_tokens": 16384,
        "temperature": 0.3,
    }

    for attempt in range(MAX_RETRIES):
        try:
            resp = session.post(API_URL, json=payload, timeout=120)
            resp.raise_for_status()
            data = resp.json()
            content = data["choices"][0]["message"]["content"]
            content = content.strip()
            if content.startswith("```"):
                content = re.sub(r"^```[^\n]*\n?", "", content)
                content = re.sub(r"\n?```$", "", content)
            return content
        except Exception as e:
            print(f"    Attempt {attempt + 1} failed: {e}")
            if attempt >= MAX_RETRIES - 1:
                raise
            time.sleep(2 ** attempt * 2)
    return None


def load_progress():
    if PROGRESS_PATH.exists():
        try:
            with open(PROGRESS_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_progress(progress):
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with open(PROGRESS_PATH, "w", encoding="utf-8") as f:
        json.dump(progress, f, ensure_ascii=False, indent=2)


def translate_file(session, filepath, char_map, progress):
    name = filepath.name
    output_path = OUTPUT_DIR / name

    if name in progress and progress[name] == "done":
        if output_path.exists():
            return True

    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    replaced = replace_char_ids(content, char_map)
    chunks = split_into_chunks(replaced)
    total_chunks = len(chunks)

    chunk_progress_key = f"{name}_chunks"
    done_chunks = progress.get(chunk_progress_key, {})
    translated_parts = []

    for i, chunk in enumerate(chunks):
        chunk_key = str(i)
        if chunk_key in done_chunks:
            translated_parts.append(done_chunks[chunk_key])
            print(f"  [{name}] Chunk {i + 1}/{total_chunks} (cached)")
            continue

        print(f"  [{name}] Chunk {i + 1}/{total_chunks} translating...")
        try:
            result = call_api(session, chunk)
            if result:
                translated_parts.append(result)
                done_chunks[chunk_key] = result
                progress[chunk_progress_key] = done_chunks
                save_progress(progress)
            else:
                print(f"  [{name}] Chunk {i + 1} returned empty!")
                translated_parts.append(chunk)
        except Exception as e:
            print(f"  [{name}] Chunk {i + 1} FAILED: {e}")
            translated_parts.append(chunk)

    final = "\n\n".join(translated_parts) + "\n"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(final)

    progress[name] = "done"
    save_progress(progress)
    print(f"  [{name}] Done ({total_chunks} chunks)")
    return True


def main():
    config = load_config()
    api_key = config.get("OpenRouterKey", "")
    proxy_url = config.get("OpenRouterProxy", "")

    if not api_key:
        print("ERROR: OpenRouterKey not found in config.json")
        sys.exit(1)

    char_map = load_char_names()
    print(f"Loaded {len(char_map)} character name mappings")

    files = sorted(INPUT_DIR.glob("script*_fid*.txt"))
    if not files:
        print(f"No script files found in {INPUT_DIR}")
        sys.exit(1)

    progress = load_progress()
    remaining = [f for f in files if f.name not in progress or progress[f.name] != "done"]
    print(f"Total files: {len(files)}, Already done: {len(files) - len(remaining)}, Remaining: {len(remaining)}")

    if not remaining:
        print("All files translated!")
        return

    session = requests.Session()
    if proxy_url:
        session.proxies = {"http": proxy_url, "https": proxy_url}
    session.headers["Authorization"] = f"Bearer {api_key}"

    for i, filepath in enumerate(remaining):
        print(f"\n[{i + 1}/{len(remaining)}] Processing {filepath.name}...")
        translate_file(session, filepath, char_map, progress)

    done_count = sum(1 for f in files if f.name in progress and progress[f.name] == "done")
    print(f"\nComplete. {done_count}/{len(files)} files translated.")
    print(f"Output directory: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
