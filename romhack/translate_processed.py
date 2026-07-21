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
from datetime import datetime
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

import requests

SCRIPT_DIR = Path(__file__).parent
ROOT_DIR = SCRIPT_DIR.parent
CONFIG_PATH = SCRIPT_DIR / "config.json"
INPUT_DIR = ROOT_DIR / "ruby_tools" / "opencode_generated" / "processed"
CACHE_PATH = SCRIPT_DIR / "translation_cache.json"
GLOSSARY_PATH = ROOT_DIR / "专有名词.txt"
LOG_DIR = ROOT_DIR / "logs"
FULLWIDTH_SPACE = "\u3000"

API_URL = "https://openrouter.ai/api/v1/chat/completions"
MODEL = "deepseek/deepseek-v4-flash"
MAX_RETRIES = 3
MAX_WORKERS = 4
GROUPS_PER_BATCH = 40
UNIFY_BATCH = 50

LOG_PATH = None
LOG_LOCK = threading.Lock()

SYSTEM_PROMPT = """\
你是一个专业的日语游戏翻译。你正在翻译PS1游戏《サモンナイト》（召唤之夜）的对话脚本。

翻译流程（重要——每组都按此流程处理）：
Step 1 合并：将本组内所有 TEXT 行的日文内容合并成完整的一句话。
Step 2 翻译：将合并后的整句翻译为自然、口语化的中文。
Step 3 拆分：根据原文的行数，将中文译文拆分成同样数量的行，严格遵守以下拆分规则。

拆分优先级规则（编号越小优先级越高）：
① 长度约束：如果原文某行不超过10个字符，对应译文行也不得超过10个字符。
② 标点约束：原文中没有逗号的地方，译文中也不应出现逗号「，」。
   但日文顿号「、」可翻译为中文逗号「，」。
③ 禁止行首标点：逗号、句号、省略号、问号、感叹号等标点符号不得出现在译文行的开头。
④ 语义对齐：尽量使每行译文与对应原文行的含义一致。

拆分示例：
原文（3行）：
  でも、どうして
  急に中止になんて
  なったのかな？

Step 1 合并 → "でも、どうして急に中止になんてなったのかな？"
Step 2 翻译 → "不过，为什么突然就取消了呢？"

Step 3 拆分（原文3行 → 译文3行）：
  行1 "不过，为什么"（6字符≤10 ✓ 对应原文行1"でも、どうして"7字符，① ✓）
  行2 "突然就取消"  （5字符≤10 ✓ 无逗号，原文行2"急に中止になんて"也无逗号，② ✓）
  行3 "了呢？"      （4字符≤10 ✓ 行首无标点，③ ✓）
  - 日文顿号「、」→ 中文逗号「，」保留在行1（② ✓）
  - 所有行均无行首标点（③ ✓），各行含义与原文行对齐（④ ✓）

如果原文只有1行，则跳过Step 1和Step 3，直接翻译即可。

输出格式：
- 每一组以 `===GROUP===` 开始，以 `===END===` 结束
- 每一组可能有一行 `SPEAKER: 说话人信息`，表示说话人及其画面位置（left=左边/right=右边）
- 日文原文以 `TEXT:XXXX | 日文` 的格式给出
- 你需要输出 `TEXT:XXXX | 中文翻译` 的格式（每行独立，拆分后的各行按顺序对应输出）
- TEXT:XXXX 是内部标识符，绝对不要修改

翻译要求：
- 翻译要口语化、自然，符合游戏对话风格
- @n 是游戏内的名字替换控制符，翻译时原样保留
- 不要修改任何标识符
- 原文如果没有句号（。），翻译也不要添加句号
- 日文的「・・・」统一翻译为中文省略号「……」
- 只输出翻译结果，不要加任何额外说明或解释"""

UNIFY_SYSTEM_PROMPT = """\
你是一个专业的游戏翻译校正人员。以下是同一句日文在游戏不同上下文中被翻译成了不同版本。
每个冲突条目会展示其所在的完整对话组上下文，标记 <UNIFY> 的行是需要你统一处理的条目。
同一 text_id 在所有 group 中出现时，必须使用完全相同的中文译文。

你必须严格输出JSON，为每个group输出其所有条目的完整译文：
{"groups": [{"entries": [{"text_id": "0048", "translation": "为什么就不办了呢？"}, {"text_id": "0049", "translation": "是啊"}]}, {"entries": [{"text_id": "0048", "translation": "为什么就不办了呢？"}, {"text_id": "0150", "translation": "嗯"}]}]}
只输出JSON，不要加任何其他文字。"""

GLOSSARY = ""


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


def load_glossary():
    global GLOSSARY
    if GLOSSARY_PATH.exists():
        with open(GLOSSARY_PATH, "r", encoding="utf-8") as f:
            GLOSSARY = f.read().strip()
    return GLOSSARY


def init_log():
    global LOG_PATH
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    LOG_PATH = LOG_DIR / f"translate_{ts}.log"


def log_write(label, content):
    if LOG_PATH is None:
        return
    with LOG_LOCK:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"\n{'='*60}\n")
            f.write(f"=== {label} ===\n")
            f.write(f"{'='*60}\n")
            f.write(content)
            f.write("\n")


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
        if re.match(r"^--- Group .* ---G?$", line):
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
            if in_original:
                current_original.append(line)
            continue

        m = re.match(r"^([+-])(\[FID:[0-9A-Fa-f]+, TEXT:([0-9A-Fa-f]+)\])[ \t]*(.*)", line)
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
        m = re.search(r"FID:([0-9A-Fa-f]+)\b.*TEXT:([0-9A-Fa-f]+)", full_tag)
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
    system = SYSTEM_PROMPT
    if GLOSSARY:
        system = "专有名词翻译参考：\n" + GLOSSARY + "\n\n" + SYSTEM_PROMPT
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": prompt},
        ],
        "max_tokens": 100000,
        "temperature": 0.3,
    }

    for attempt in range(MAX_RETRIES):
        try:
            log_write(f"REQUEST {desc}", f"System:\n{system}\n\nPrompt:\n{prompt}")
            resp = session.post(API_URL, json=payload, timeout=180)
            resp.raise_for_status()
            data = resp.json()
            content = data["choices"][0]["message"]["content"]
            content = content.strip()
            if content.startswith("```"):
                content = re.sub(r"^```[^\n]*\n?", "", content)
                content = re.sub(r"\n?```$", "", content)
            log_write(f"RESPONSE {desc}", content)
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
    Overflow spills forward to next slot only (never backfills earlier lines).
    If overflow can't fit by the last slot, append '【超出】' marker."""
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

        if orig.startswith(FULLWIDTH_SPACE):
            leading = len(orig) - len(orig.lstrip(FULLWIDTH_SPACE))
            trans = trans.lstrip(FULLWIDTH_SPACE)
            trans = FULLWIDTH_SPACE * leading + trans

        if len(orig) <= 10 and len(trans) > 10:
            overflow = trans[10:]
            trans = trans[:10]

        result.append(trans)

    # Forward-only: push overflow into extra tagged slots
    while overflow and len(result) < len(tagged_entries):
        take = overflow[:10]
        overflow = overflow[10:]
        result.append(take)

    # If overflow still remains, mark it
    if overflow:
        if len(result) < len(tagged_entries):
            result.append(overflow + "【超出】")
        elif result:
            result[-1] = result[-1] + overflow + "【超出】"

    while len(result) < len(tagged_entries):
        result.append("")

    return result[:len(tagged_entries)]


def unify_translations(name, groups, cache, cache_lock, proxy_url, api_key):
    """Find TEXT entries translated differently across groups and unify via LLM.
    Conflict TEXT IDs are partitioned into clusters by co-occurrence:
    IDs that appear together in any group go into the same cluster.
    Each cluster gets its own independent LLM request."""
    text_index = {}
    group_data = []

    for header, is_g, original_lines, tagged_entries in groups:
        if is_g or not tagged_entries:
            continue
        text_key = get_cache_key(tagged_entries)
        translations = cache.get(text_key, {})
        group_data.append((text_key, header, original_lines, tagged_entries, translations))
        for idx, (marker, full_tag, text_num, existing) in enumerate(tagged_entries):
            trans = translations.get(text_num, "")
            if not trans:
                continue
            if text_num not in text_index:
                text_index[text_num] = {"jp": original_lines[idx] if idx < len(original_lines) else "",
                                        "text_keys": set(), "variants": {}}
            text_index[text_num]["text_keys"].add(text_key)
            text_index[text_num]["variants"][trans] = True

    conflicts = {tn: info for tn, info in text_index.items() if len(info["variants"]) > 1}
    if not conflicts:
        return

    print(f"  [{name}] Unifying {len(conflicts)} conflicting TEXT entries...")

    # Partition conflicting TEXT IDs into clusters by co-occurrence.
    # Two TEXT IDs belong to the same cluster if they appear together in any group.
    all_conflict_tns = set(conflicts.keys())
    adjacency = {}
    for tn in all_conflict_tns:
        adjacency[tn] = set()

    for _, _, _, tagged_entries, _ in group_data:
        group_conflict_tns = [tn for _, _, tn, _ in tagged_entries if tn in all_conflict_tns]
        for i in range(len(group_conflict_tns)):
            for j in range(i + 1, len(group_conflict_tns)):
                a, b = group_conflict_tns[i], group_conflict_tns[j]
                adjacency[a].add(b)
                adjacency[b].add(a)

    visited = set()
    clusters = []
    for tn in sorted(all_conflict_tns):
        if tn in visited:
            continue
        component = set()
        queue = [tn]
        while queue:
            node = queue.pop(0)
            if node in visited:
                continue
            visited.add(node)
            component.add(node)
            for neighbor in adjacency[node]:
                if neighbor not in visited:
                    queue.append(neighbor)
        clusters.append(component)

    print(f"  [{name}] {len(clusters)} conflict cluster(s)")

    unified = {}
    session = requests.Session()
    if proxy_url:
        session.proxies = {"http": proxy_url, "https": proxy_url}
    session.headers["Authorization"] = f"Bearer {api_key}"

    for cluster_idx, cluster_tns in enumerate(clusters):
        # Build fresh group index from current cache (picks up updates from prev clusters)
        group_by_key = {}
        for header, is_g, original_lines, tagged_entries in groups:
            if is_g or not tagged_entries:
                continue
            text_key = get_cache_key(tagged_entries)
            translations = cache.get(text_key, {})
            group_by_key[text_key] = (header, original_lines, tagged_entries, translations)

        # Collect groups that contain any TEXT ID from this cluster
        involved_keys = []
        for tk, (gh, gol, gt, gtr) in group_by_key.items():
            for _, _, tn, _ in gt:
                if tn in cluster_tns and gtr.get(tn, ""):
                    involved_keys.append(tk)
                    break

        if not involved_keys:
            continue

        # Find shared TEXT IDs across these groups (mark as UNIFY)
        key_texts = {}
        for tk in involved_keys:
            if tk not in group_by_key:
                continue
            _, _, gt, _ = group_by_key[tk]
            key_texts[tk] = {tn for _, _, tn, _ in gt}
        shared_text_ids = set()
        all_keys = list(key_texts.keys())
        for a in range(len(all_keys)):
            for b in range(a + 1, len(all_keys)):
                shared_text_ids.update(key_texts[all_keys[a]] & key_texts[all_keys[b]])

        unify_ids = shared_text_ids | cluster_tns

        # Build prompt: full group content
        lines = []
        group_idx = 0
        for tk in involved_keys:
            if tk not in group_by_key:
                continue
            gh, gol, gt, gtr = group_by_key[tk]
            group_idx += 1
            lines.append(f"\n=== GROUP {group_idx} ===")
            speaker_m = re.findall(r"\[(left|right):([^\]]+)\]", gh)
            if speaker_m:
                speakers = "，".join(f"{pos}({nm})" for pos, nm in speaker_m)
                lines.append(f"SPEAKER: {speakers}")
            for idx, (mk, ft, tn, ex) in enumerate(gt):
                jp = gol[idx] if idx < len(gol) else ""
                t = gtr.get(tn, "")
                mark = " <UNIFY>" if tn in unify_ids else ""
                lines.append(f"TEXT:{tn} | {t}{mark} | 日文: {jp}")

        prompt = "\n".join(lines)

        tns_label = ",".join(sorted(cluster_tns))
        desc = f"[{name}] unify cluster {cluster_idx + 1}/{len(clusters)} ({tns_label})"
        print(f"  {desc} ({len(involved_keys)} groups)")

        try:
            system = "专有名词翻译参考：\n" + GLOSSARY + "\n\n" + UNIFY_SYSTEM_PROMPT if GLOSSARY else UNIFY_SYSTEM_PROMPT
            payload = {
                "model": MODEL,
                "messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": prompt},
                ],
                "max_tokens": 100000,
                "temperature": 0.3,
                "response_format": {"type": "json_object"},
            }
            log_write(f"REQUEST {desc}", f"System:\n{system}\n\nPrompt:\n{prompt}")
            resp = session.post(API_URL, json=payload, timeout=180)
            resp.raise_for_status()
            data = resp.json()
            content = data["choices"][0]["message"]["content"]
            content = content.strip()
            log_write(f"RESPONSE {desc}", content)
            if content.startswith("```"):
                content = re.sub(r"^```[^\n]*\n?", "", content)
                content = re.sub(r"\n?```$", "", content)

            result = json.loads(content)
            resp_groups = result.get("groups", [])
            # Apply: each group's entries map text_id -> translation
            for gi, g in enumerate(resp_groups):
                if gi >= len(involved_keys):
                    break
                tk = involved_keys[gi]
                for item in g.get("entries", []):
                    unified[(tk, item["text_id"].upper())] = item["translation"]
        except Exception as e:
            print(f"  [{name}] Unify cluster {cluster_idx + 1} failed: {e}")
            continue

    if unified:
        with cache_lock:
            for (text_key, text_num), unified_trans in unified.items():
                if text_key in cache:
                    cache[text_key][text_num] = unified_trans
            save_cache(cache)
        print(f"  [{name}] Unified {len(unified)} TEXT entries")


def process_file(filepath, cache, cache_lock, proxy_url, api_key):
    name = filepath.name

    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    groups = parse_processed_content(content)

    # Collect non-G groups that have tagged entries
    non_g = []
    g_count = 0
    no_tag = 0
    for header, is_g, original_lines, tagged_entries in groups:
        if is_g:
            g_count += 1
        elif not tagged_entries:
            no_tag += 1
        else:
            text_key = get_cache_key(tagged_entries)
            non_g.append((text_key, header, original_lines, tagged_entries))

    if not non_g:
        print(f"  [{name}] Total groups: {len(groups)}, G: {g_count}, "
              f"no-tag: {no_tag}, non-G-with-tag: {len(non_g)}")
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

    unify_translations(name, groups, cache, cache_lock, proxy_url, api_key)

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
    glossary = load_glossary()
    init_log()
    print(f"Loaded {len(cache)} cached group translations")
    if glossary:
        print(f"Loaded glossary: {len(glossary.split(chr(10)))} terms")
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
