"""
verify_translate.py
Verification script for translate_processed.py translation flow.
Re-runs the translation on test_fid19.txt using recorded LLM responses
from the log file. Does NOT make real API calls.
Only handles initial translation (初翻); outputs the Unify Prompt.
"""

import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

import translate_processed as tp

# Override paths for test file
LOG_PATH = ROOT / "logs" / "translate_20260706_112449.log"
TEST_FILE = ROOT / "ruby_tools" / "opencode_generated" / "processed" / "test_fid19.txt"


# --- Log Parser: Extract LLM mock responses ---

def parse_log_responses(log_path: Path):
    """
    Parse translate log to extract prompt->response mappings for non-unify requests.
    Also extracts the unify prompt block for later output.
    Returns: (mock_db: dict[str, str], unify_prompt: str | None)
    """
    with open(log_path, "r", encoding="utf-8") as f:
        content = f.read()

    content = content.replace('\r\n', '\n')

    # Each section: \n==...==\n=== TYPE desc ===\n==...==\n<content>
    # Content ends at the \n before the next section's separator
    header_pattern = r'\n(={10,})\n=== (REQUEST|RESPONSE) (.*?) ===\n\1\n'
    all_headers = list(re.finditer(header_pattern, content))
    all_headers.append(None)  # sentinel

    prompts = []
    responses = []
    unify_prompt_text = None

    for i in range(len(all_headers) - 1):
        m = all_headers[i]
        next_m = all_headers[i + 1]
        block_type = m.group(2)
        desc = m.group(3).strip()
        is_unify = 'unify' in desc.lower()

        content_start = m.end()
        if next_m:
            content_end = next_m.start() + 1  # include the \n before next separator
            block_content = content[content_start:content_end].strip()
        else:
            block_content = content[content_start:].strip()

        if block_type == 'REQUEST':
            pm = re.search(r'Prompt:\n(.*)', block_content, re.DOTALL)
            if pm:
                prompt_text = pm.group(1).strip()
                if is_unify:
                    unify_prompt_text = prompt_text
                else:
                    prompts.append((desc, prompt_text))

        elif block_type == 'RESPONSE':
            if not is_unify:
                responses.append((desc, block_content))

    # Pair prompts and responses by order
    mock_db = {}
    for (p_desc, prompt), (r_desc, response) in zip(prompts, responses):
        mock_db[prompt] = response

    return mock_db, unify_prompt_text


# --- Mock call_api: returns recorded responses ---

def make_mock_call_api(mock_db: dict):
    """
    Factory that returns a mock call_api function.
    Matches by prompt text content equality.
    Falls back to matching by TEXT IDs if exact match fails.
    """
    # Build TEXT-ID based fallback lookup
    textid_index = {}
    for prompt, response in mock_db.items():
        ids = frozenset(re.findall(r'TEXT:([0-9A-Fa-f]+)', prompt))
        textid_index[ids] = response

    def mock_call_api(session, prompt, desc=""):
        # Try exact match first
        if prompt in mock_db:
            print(f"  [MOCK] {desc}: exact prompt match -> returning recorded response")
            return mock_db[prompt]

        # Try TEXT ID match
        ids = frozenset(re.findall(r'TEXT:([0-9A-Fa-f]+)', prompt))
        if ids in textid_index:
            response = textid_index[ids]
            # Verify it parses correctly for these groups
            expected_keys_in_prompt = []
            for section in prompt.split("===GROUP===")[1:]:
                if "===END===" in section:
                    part = section.split("===END===")[0]
                    tns = re.findall(r'TEXT:([0-9A-Fa-f]+)', part)
                    if tns:
                        expected_keys_in_prompt.append(part.strip())
            print(f"  [MOCK] {desc}: TEXT-ID match -> returning recorded response")
            return response

        raise RuntimeError(f"No mock response for prompt: {desc}")

    return mock_call_api


# --- Populate test_fid19.txt from log data ---

def populate_test_file_from_real_file(source_file: Path, test_file: Path):
    """
    Copy source processed file, strip G suffix and translations, write as test file.
    This ensures groups are in the exact same order as originally processed.
    """
    with open(source_file, "r", encoding="utf-8") as f:
        content = f.read()

    content = content.replace('\r\n', '\n')

    # Parse groups
    groups = tp.parse_processed_content(content)

    output_lines = []
    for header, is_g, original_lines, tagged_entries in groups:
        # Strip G suffix
        clean_header = header.rstrip()
        if clean_header.endswith("G"):
            clean_header = clean_header[:-1]

        output_lines.append(clean_header)
        for ol in original_lines:
            output_lines.append(ol)
        for marker, full_tag, text_num, existing in tagged_entries:
            # Always use + prefix, empty translation
            output_lines.append(f"+{full_tag} ")
        output_lines.append("")

    test_file.parent.mkdir(parents=True, exist_ok=True)
    with open(test_file, "w", encoding="utf-8") as f:
        f.write("\n".join(output_lines))

    print(f"[SETUP] Populated {test_file} with {len(groups)} groups from {source_file.name}")
    return test_file


# --- Generate Unify Prompt (without calling LLM) ---

def generate_unify_prompt(groups, cache):
    """
    Replicates the new cluster-based unify prompt generation logic.
    Each conflict cluster gets its own prompt.
    Returns: (prompts_by_cluster: dict, summary: str)
    """
    text_index = {}
    group_data = []

    for header, is_g, original_lines, tagged_entries in groups:
        if is_g or not tagged_entries:
            continue
        text_key = tp.get_cache_key(tagged_entries)
        translations = cache.get(text_key, {})
        group_data.append((text_key, header, original_lines, tagged_entries, translations))
        for idx, (marker, full_tag, text_num, existing) in enumerate(tagged_entries):
            trans = translations.get(text_num, "")
            if not trans:
                continue
            if text_num not in text_index:
                text_index[text_num] = {
                    "jp": original_lines[idx] if idx < len(original_lines) else "",
                    "text_keys": set(),
                    "variants": {},
                }
            text_index[text_num]["text_keys"].add(text_key)
            text_index[text_num]["variants"][trans] = True

    conflicts = {tn: info for tn, info in text_index.items() if len(info["variants"]) > 1}
    if not conflicts:
        return {}, "No conflicts found for unification."

    # Partition conflict TNs into clusters by co-occurrence
    all_conflict_tns = set(conflicts.keys())
    adjacency = {tn: set() for tn in all_conflict_tns}

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

    group_by_key = {}
    for tk, gh, gol, gt, gtr in group_data:
        group_by_key[tk] = (gh, gol, gt, gtr)

    prompts_by_cluster = {}

    for cluster_idx, cluster_tns in enumerate(clusters):
        # Collect groups containing any TN from this cluster
        involved_keys = []
        for tk, (gh, gol, gt, gtr) in group_by_key.items():
            for _, _, tn, _ in gt:
                if tn in cluster_tns and gtr.get(tn, ""):
                    involved_keys.append(tk)
                    break

        if not involved_keys:
            continue

        # Find shared TEXT IDs across these groups
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

        # Build prompt
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

        tns_label = ",".join(sorted(cluster_tns))
        prompt = "\n".join(lines)
        prompts_by_cluster[tns_label] = prompt

    return prompts_by_cluster, f"{len(conflicts)} conflicts → {len(clusters)} clusters"


# --- Main verification flow ---

def main():
    print("=" * 60)
    print("VERIFY TRANSLATE — Replay translation flow")
    print("=" * 60)

    # Step 1: Parse log for mock responses
    print("\n[1] Parsing log for mock responses...")
    mock_db, unify_prompt_from_log = parse_log_responses(LOG_PATH)
    print(f"    Found {len(mock_db)} prompt->response pairs")

    # Step 2: Populate test file from the real script06_fid19.txt (strip G + translations)
    print("\n[2] Populating test_fid19.txt from script06_fid19.txt...")
    source_file = TEST_FILE.parent / "script06_fid19.txt"
    populate_test_file_from_real_file(source_file, TEST_FILE)

    # Step 3: Read and parse test file
    print("\n[3] Reading and parsing test file...")
    with open(TEST_FILE, "r", encoding="utf-8") as f:
        content = f.read()
    groups = tp.parse_processed_content(content)
    print(f"    Total groups: {len(groups)}")

    # Step 4: Collect non-G groups
    non_g = []
    g_count = 0
    for header, is_g, original_lines, tagged_entries in groups:
        if is_g:
            g_count += 1
        elif tagged_entries:
            text_key = tp.get_cache_key(tagged_entries)
            non_g.append((text_key, header, original_lines, tagged_entries))
    print(f"    G groups: {g_count}, Non-G with tags: {len(non_g)}")

    # Step 5: Mock translate_batch with recorded responses
    print("\n[4] Running initial translation with mock LLM responses...")
    mock_call_api_fn = make_mock_call_api(mock_db)

    # Monkey-patch call_api
    original_call_api = tp.call_api
    tp.call_api = mock_call_api_fn

    # Use an empty cache (fresh translation)
    cache = {}
    new_results = {}

    try:
        GROUPS_PER_BATCH = 40
        session = None  # Not needed for mock

        for i in range(0, len(non_g), GROUPS_PER_BATCH):
            batch = non_g[i:i + GROUPS_PER_BATCH]
            batch_num = i // GROUPS_PER_BATCH + 1
            total_batches = (len(non_g) + GROUPS_PER_BATCH - 1) // GROUPS_PER_BATCH
            desc = f"batch {batch_num}/{total_batches}"
            print(f"    {desc} ({len(batch)} groups)...")

            results = tp.translate_batch(session, batch, desc)
            new_results.update(results)
            print(f"    -> Got {len(results)} group translations")

    finally:
        tp.call_api = original_call_api

    # Fill cache with results
    cache.update(new_results)
    print(f"    Total cached translations: {len(cache)} groups")

    # Step 6: Apply translations to test file
    print("\n[5] Applying translations to test file...")
    output_lines = []
    for header, is_g, original_lines, tagged_entries in groups:
        output_lines.append(header)
        for ol in original_lines:
            output_lines.append(ol)

        if not is_g and tagged_entries:
            text_key = tp.get_cache_key(tagged_entries)
            translations = cache.get(text_key, {})
            if translations:
                final = tp.apply_line_length(original_lines, translations, tagged_entries)
                for i, (marker, full_tag, text_num, existing) in enumerate(tagged_entries):
                    t = final[i] if i < len(final) else ""
                    output_lines.append(f"{marker}{full_tag} {t}")
            else:
                for marker, full_tag, text_num, existing in tagged_entries:
                    output_lines.append(f"{marker}{full_tag} ")
        else:
            for marker, full_tag, text_num, existing in tagged_entries:
                output_lines.append(f"{marker}{full_tag} ")

        output_lines.append("")

    output_path = TEST_FILE.with_suffix(".verified.txt")
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(output_lines))
    print(f"    Written to {output_path}")

    # Step 7: Generate and output Unify Prompts (one per cluster)
    print("\n" + "=" * 60)
    print("[6] Generating Unify Prompts (no LLM call)...")
    prompts_by_cluster, summary = generate_unify_prompt(groups, cache)

    if not prompts_by_cluster:
        print(f"    {summary}")
    else:
        print(f"    {summary}")
        for tns_label, unify_prompt in prompts_by_cluster.items():
            cluster_slug = tns_label.replace(",", "_")
            unify_prompt_path = TEST_FILE.with_suffix(f".unify_{cluster_slug}.txt")
            with open(unify_prompt_path, "w", encoding="utf-8") as f:
                f.write(unify_prompt)
            print(f"\n--- Cluster [{tns_label}] ({unify_prompt.count('=== GROUP ')} groups) -> {unify_prompt_path.name}")

        # Compare total groups/markers with log's combined prompt
        if unify_prompt_from_log:
            total_gen_groups = sum(p.count("=== GROUP ") for p in prompts_by_cluster.values())
            total_gen_unify = sum(p.count("<UNIFY>") for p in prompts_by_cluster.values())
            log_groups = unify_prompt_from_log.count("=== GROUP ")
            log_unify = unify_prompt_from_log.count("<UNIFY>")
            print(f"\n[COMPARISON] Combined vs log:")
            print(f"    Groups: generated={total_gen_groups}, log={log_groups}")
            print(f"    <UNIFY> markers: generated={total_gen_unify}, log={log_unify}")

    print("\n" + "=" * 60)
    print("VERIFICATION COMPLETE")
    print("=" * 60)


if __name__ == "__main__":
    main()
