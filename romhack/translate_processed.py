"""
translate_processed.py — Translate non-G groups in processed dialogue files.

Reads, translates, and writes back files in processed/ directory in-place.
Translates Japanese original text to Chinese for groups not ending with "G",
filling translations after [FID:...] brackets.

Features:
- Skips groups with ---G suffix (already translated).
- Line-length constraint: if original line ≤10 chars, translation ≤10 chars.
- Multi-threaded (one thread per file).
- Batch LLM requests with context (speaker info, group header).
- Auto-retry missing translations until LLM fails twice consecutively.
- Translation cache keyed by FID + TEXT-number sequence (not group ID).
- Use --file to process a single file.
"""

import argparse
import json
import re
import sys
import time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

import requests

SCRIPT_DIR = Path(__file__).parent
CONFIG_PATH = SCRIPT_DIR / "config.json"
INPUT_DIR = SCRIPT_DIR.parent / "ruby_tools" / "opencode_generated" / "processed"
CACHE_PATH = SCRIPT_DIR / "translation_cache.json"
FULLWIDTH_SPACE = "\u3000"

API_URL = "https://openrouter.ai/api/v1/chat/completions"
MODEL = "deepseek/deepseek-v4-flash"
MAX_RETRIES = 3
MAX_WORKERS = 4
GROUPS_PER_BATCH = 40

SYSTEM_PROMPT = """\
你是一个专业的日语游戏翻译。你正在翻译PS1游戏《サモンナイト》（召唤之夜）的对话脚本。

输出格式：
- 每一组以 `===GROUP===` 开始
- 每一组可能有一行 `SPEAKER: 说话人信息`，表示当前是谁在说话及其在画面中的位置（left=左边/right=右边）
- 日文原文以 `TEXT:XXXX | 日文` 的格式给出
- 你需要输出 `TEXT:XXXX | 中文翻译` 的格式
- 每一组以 `===END===` 结束
- TEXT:XXXX 是内部标识符，绝对不要修改

翻译要求：
- 只翻译日文为中文，翻译要口语化、自然，符合游戏对话风格
- @n 是游戏内的名字替换控制符，翻译时原样保留
- 不要修改任何标识符
- 只输出翻译结果，不要加任何额外说明或解释"""


def load_config():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def load_cache():
    if CACHE_PATH.exists():
        try:
            with open(CACHE_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_cache(cache):
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(CACHE_PATH, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=2)


def parse_processed_content(content):
    """Parse processed file content into groups."""
    groups = []
    current_header = None
    current_is_g = False
    current_original = []
    current_tagged = []
    in_original = True

    for line in content.split("\n"):
        if line.startswith("--- Group "):
            if current_header is not None:
                groups.append((current_header, current_is_g,
                               current_original, current_tagged))
            current_header = line
            current_is_g = line.rstrip().endswith("G")
            current_original = []
            current_tagged = []
            in_original = True
            continue

        if current_header is None:
            continue

        if not line.strip():
            continue

        m = re.match(r"^([+-])(\[FID:\d+, TEXT:([0-9A-Fa-f]+)\])[ \t]*(.*)", line)
        if m:
            in_original = False
            existing = m.group(4).rstrip(" \t")
            current_tagged.append((m.group(1), m.group(2),
                                   m.group(3).upper(), existing))
        elif in_original:
            current_original.append(line)

    if current_header is not None:
        groups.append((current_header, current_is_g,
                       current_original, current_tagged))

    return groups


def get_cache_key(tagged_entries):
    """Build cache key from FID + TEXT-number sequence to avoid cross-file collisions."""
    parts = []
    for marker, full_tag, text_num, existing in tagged_entries:
        m = re.search(r"FID:(\d+)\b.*TEXT:([0-9A-Fa-f]+)", full_tag)
        if m:
            parts.append(f"F{m.group(1)}_T{m.group(2)}")
        else:
            parts.append(text_num)
    return ",".join(parts)


def build_prompt(batch):
    """Build LLM translation prompt for a batch of groups."""
    lines = []
    for text_key, header, original_lines, tagged_entries in batch:
        lines.append("===GROUP===")
        speaker_m = re.findall(r"\[(left|right):([^\]]+)\]", header)
        if speaker_m:
            speakers = "，".join(f"{pos}({name})" for pos, name in speaker_m)
            lines.append(f"SPEAKER: {speakers}")
        for i, (marker, full_tag, text_num, existing) in enumerate(tagged_entries):
            jp = original_lines[i] if i < len(original_lines) else ""
            lines.append(f"TEXT:{text_num} | {jp}")
        lines.append("===END===")
    return "\n".join(lines)


def call_api(session, prompt, desc=""):
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "max_tokens": 16384,
        "temperature": 0.3,
    }

    for attempt in range(MAX_RETRIES):
        try:
            resp = session.post(API_URL, json=payload, timeout=180)
            resp.raise_for_status()
            data = resp.json()
            content = data["choices"][0]["message"]["content"]
            content = content.strip()
            if content.startswith("```"):
                content = re.sub(r"^```[^\n]*\n?", "", content)
                content = re.sub(r"\n?```$", "", content)
            return content
        except Exception as e:
            print(f"    {desc} Attempt {attempt + 1} failed: {e}")
            if attempt >= MAX_RETRIES - 1:
                raise
            time.sleep(2 ** attempt * 2)
    return None


def parse_response(response_text, expected_keys):
    """Parse LLM response into {text_key: {text_num: translation}}.
    Matches groups by order to expected_keys."""
    results = {}
    key_idx = 0
    current_trans = {}
    in_group = False

    for line in response_text.split("\n"):
        line = line.strip()
        if not line:
            continue

        if line == "===GROUP===":
            if current_trans and 0 < key_idx <= len(expected_keys):
                results[expected_keys[key_idx - 1]] = current_trans
            current_trans = {}
            in_group = True
            continue

        if line == "===END===":
            if current_trans and key_idx < len(expected_keys):
                results[expected_keys[key_idx]] = current_trans
                key_idx += 1
            current_trans = {}
            in_group = False
            continue

        if in_group:
            m = re.match(r"TEXT:([0-9A-Fa-f]+)\s*\|\s*(.*)", line)
            if m:
                current_trans[m.group(1).upper()] = m.group(2).strip()

    if current_trans and key_idx < len(expected_keys):
        results[expected_keys[key_idx]] = current_trans

    return results


def translate_batch(session, full_batch, desc=""):
    """Translate groups with retry for missing entries.
    Stops after 2 consecutive LLM responses with no new translations."""
    all_results = {}
    consecutive_empty = 0
    remaining = list(full_batch)

    while remaining and consecutive_empty < 2:
        prompt = build_prompt(remaining)
        expected_keys = [r[0] for r in remaining]

        try:
            response = call_api(session, prompt, desc)
        except Exception:
            break

        if not response:
            break

        new_results = parse_response(response, expected_keys)

        added = 0
        for key, trans in new_results.items():
            if key not in all_results:
                all_results[key] = {}
            for tn, t in trans.items():
                if t and (tn not in all_results[key] or not all_results[key][tn]):
                    all_results[key][tn] = t
                    added += 1

        if added == 0:
            consecutive_empty += 1
        else:
            consecutive_empty = 0

        # Find still-missing tagged entries per group
        missing = []
        for text_key, header, original_lines, tagged_entries in full_batch:
            existing_trans = all_results.get(text_key, {})
            still = []
            still_orig = []
            for idx, (m, ft, tn, e) in enumerate(tagged_entries):
                if tn not in existing_trans or not existing_trans[tn]:
                    still.append((m, ft, tn, e))
                    still_orig.append(
                        original_lines[idx]
                        if idx < len(original_lines) else "")
            if still:
                missing.append((text_key, header, still_orig, still))

        if not missing:
            break
        remaining = missing

    return all_results


def apply_line_length(original_lines, translations, tagged_entries):
    """Enforce ≤10-char-per-line rule for original lines ≤10 chars long.
    Overflow spills to the next tag slot."""
    ordered = []
    for marker, full_tag, text_num, existing in tagged_entries:
        ordered.append(translations.get(text_num, ""))

    result = []
    overflow = ""

    for i, orig in enumerate(original_lines):
        trans = ordered[i] if i < len(ordered) else ""
        if overflow:
            trans = overflow + trans
            overflow = ""

        if orig.startswith(FULLWIDTH_SPACE) and not trans.startswith(FULLWIDTH_SPACE):
            trans = FULLWIDTH_SPACE + trans

        if len(orig) <= 10 and len(trans) > 10:
            overflow = trans[10:]
            trans = trans[:10]

        result.append(trans)

    # Try to absorb overflow into remaining short-line slots
    while overflow and len(result) < len(original_lines):
        result.append("")
    for i in range(len(result)):
        if not overflow:
            break
        if len(original_lines[i]) <= 10 and len(result[i]) < 10:
            space = 10 - len(result[i])
            take = min(space, len(overflow))
            result[i] += overflow[:take]
            overflow = overflow[take:]

    while len(result) < len(tagged_entries):
        result.append("")

    return result[:len(tagged_entries)]


def process_file(filepath, cache, cache_lock, proxy_url, api_key):
    name = filepath.name

    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    groups = parse_processed_content(content)

    # Collect non-G groups that have tagged entries
    non_g = []
    for header, is_g, original_lines, tagged_entries in groups:
        if not is_g and tagged_entries:
            text_key = get_cache_key(tagged_entries)
            non_g.append((text_key, header, original_lines, tagged_entries))

    if not non_g:
        print(f"  [{name}] No non-G groups to translate")
        return

    # Check cache
    new_to_translate = []
    cache_hits = 0
    for item in non_g:
        if item[0] in cache:
            cache_hits += 1
        else:
            new_to_translate.append(item)

    print(f"  [{name}] {len(non_g)} non-G groups: "
          f"{cache_hits} cached, {len(new_to_translate)} to translate")

    if new_to_translate:
        session = requests.Session()
        if proxy_url:
            session.proxies = {"http": proxy_url, "https": proxy_url}
        session.headers["Authorization"] = f"Bearer {api_key}"

        new_results = {}

        for i in range(0, len(new_to_translate), GROUPS_PER_BATCH):
            batch = new_to_translate[i:i + GROUPS_PER_BATCH]
            desc = f"[{name}] batch {i // GROUPS_PER_BATCH + 1}/"
            desc += f"{(len(new_to_translate) + GROUPS_PER_BATCH - 1) // GROUPS_PER_BATCH}"
            print(f"  {desc} ({len(batch)} groups)...")
            try:
                results = translate_batch(session, batch, desc)
                new_results.update(results)
            except Exception as e:
                print(f"  {desc} FAILED: {e}")

        with cache_lock:
            cache.update(new_results)
            save_cache(cache)

    # Build output file
    output_lines = []
    for header, is_g, original_lines, tagged_entries in groups:
        output_lines.append(header)

        for ol in original_lines:
            output_lines.append(ol)

        if not is_g and tagged_entries:
            text_key = get_cache_key(tagged_entries)
            translations = cache.get(text_key, {})
            if translations:
                final = apply_line_length(original_lines, translations,
                                          tagged_entries)
                for i, (marker, full_tag, text_num, existing) in enumerate(tagged_entries):
                    t = final[i] if i < len(final) else ""
                    output_lines.append(f"{marker}{full_tag} {t}")
            else:
                for marker, full_tag, text_num, existing in tagged_entries:
                    output_lines.append(f"{marker}{full_tag} ")
        else:
            for marker, full_tag, text_num, existing in tagged_entries:
                if existing:
                    output_lines.append(f"{marker}{full_tag} {existing}")
                else:
                    output_lines.append(f"{marker}{full_tag} ")

        output_lines.append("")

    with open(filepath, "w", encoding="utf-8") as f:
        f.write("\n".join(output_lines))

    print(f"  [{name}] Done")


def main():
    parser = argparse.ArgumentParser(description="Translate non-G groups in processed dialogue files")
    parser.add_argument("--file", "-f", help="Process only a single file (e.g. script01_fid06.txt)")
    args = parser.parse_args()

    config = load_config()
    api_key = config.get("OpenRouterKey", "")
    proxy_url = config.get("OpenRouterProxy", "")

    if not api_key:
        print("ERROR: OpenRouterKey not found in config.json")
        sys.exit(1)

    if args.file:
        filepath = INPUT_DIR / args.file
        if not filepath.exists():
            print(f"ERROR: File not found: {filepath}")
            sys.exit(1)
        files = [filepath]
    else:
        if not INPUT_DIR.exists():
            print(f"ERROR: Input directory not found: {INPUT_DIR}")
            sys.exit(1)
        files = sorted(INPUT_DIR.glob("script*_fid*.txt"))
        if not files:
            files = sorted(INPUT_DIR.glob("*.txt"))
        if not files:
            print(f"No files found in {INPUT_DIR}")
            sys.exit(1)

    cache = load_cache()
    print(f"Loaded {len(cache)} cached group translations")
    print(f"Total files: {len(files)}")
    print(f"Max workers: {MAX_WORKERS}\n")

    cache_lock = threading.Lock()

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {}
        for filepath in files:
            future = executor.submit(
                process_file, filepath, cache,
                cache_lock, proxy_url, api_key)
            futures[future] = filepath.name

        for future in as_completed(futures):
            name = futures[future]
            try:
                future.result()
            except Exception as e:
                print(f"  [{name}] FAILED: {e}")

    print(f"\nComplete. {len(files)} files processed.")
    print(f"Cache:  {CACHE_PATH}")


if __name__ == "__main__":
    main()
