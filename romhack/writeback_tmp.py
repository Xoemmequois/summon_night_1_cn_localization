import re
from pathlib import Path

BASE = Path(__file__).parent.parent / "ruby_tools" / "opencode_generated"
TMP = BASE / "processed" / "tmp.txt"
TARGET = BASE / "processed" / "script01_fid01.txt"

GROUP_RE = re.compile(r"^--- Group (\d+) ")
FID_RE = re.compile(r"^([+-])(\[FID:.*)")


def parse_groups(text):
    groups = {}
    current_num = None
    current_lines = []
    for line in text.splitlines():
        m = GROUP_RE.match(line)
        if m:
            if current_num is not None:
                groups[current_num] = current_lines
            current_num = int(m.group(1))
            current_lines = [line]
        elif current_num is not None:
            current_lines.append(line)
    if current_num is not None:
        groups[current_num] = current_lines
    return groups


with open(TMP, "r", encoding="utf-8") as f:
    tmp_groups = parse_groups(f.read())
with open(TARGET, "r", encoding="utf-8") as f:
    target_lines = f.read().splitlines()

target_groups = {}
group_order = []
current_num = None
current_start = None
for i, line in enumerate(target_lines):
    m = GROUP_RE.match(line)
    if m:
        if current_num is not None:
            target_groups[current_num] = (current_start, i)
        current_num = int(m.group(1))
        current_start = i
        group_order.append(current_num)
if current_num is not None:
    target_groups[current_num] = (current_start, len(target_lines))

out = []
replaced = 0
i = 0
while i < len(target_lines):
    m = GROUP_RE.match(target_lines[i])
    if m:
        gnum = int(m.group(1))
        start, end = target_groups[gnum]
        if gnum in tmp_groups:
            tgt_fid_lines = [l for l in target_lines[start:end] if FID_RE.match(l)]
            tmp_lines = tmp_groups[gnum]
            tmp_header = tmp_lines[0]
            tmp_non_fid = [l for l in tmp_lines[1:] if not re.match(r"^[+-]?\[FID:", l) and l.strip()]
            tmp_fid_raw = [l for l in tmp_lines[1:] if re.match(r"^[+-]?\[FID:", l)]
            tmp_fid = [re.sub(r"^[+-]", "", l) for l in tmp_fid_raw]

            out.append(tmp_header)
            for l in tmp_non_fid:
                out.append(l)
            for j, tf in enumerate(tmp_fid):
                marker = ""
                if j < len(tgt_fid_lines):
                    fm = FID_RE.match(tgt_fid_lines[j])
                    if fm:
                        marker = fm.group(1)
                out.append(marker + tf)
            for j in range(len(tmp_fid), len(tgt_fid_lines)):
                out.append(tgt_fid_lines[j])
            out.append("")
            replaced += 1
            i = end
            if i < len(target_lines) and target_lines[i].strip() == "":
                i += 1
        else:
            out.append(target_lines[i])
            i += 1
    else:
        out.append(target_lines[i])
        i += 1

with open(TARGET, "w", encoding="utf-8") as f:
    f.write("\n".join(out))

print(f"Updated {replaced} groups in {TARGET}")
