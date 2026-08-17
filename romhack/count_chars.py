import json
import sys
from collections import Counter

OUT = "char_count.txt"

with open("zh_CN_translated.json", encoding="utf-8") as f:
    data = json.load(f)

counts = Counter()
total_chars = 0
translated_items = 0

for item in data:
    t = item.get("translation") or ""
    if t:
        translated_items += 1
    for ch in t:
        counts[ch] += 1
        total_chars += 1

rows = [(ch, n) for ch, n in counts.items()]
rows.sort(key=lambda x: (x[1], x[0]))

lines = []
lines.append(f"total_items={len(data)} translated_items={translated_items} total_chars={total_chars} unique_chars={len(counts)}")
lines.append(f"{'count':>6}  char  codepoint")
for ch, n in rows:
    disp = "\\n" if ch == "\n" else ch
    lines.append(f"{n:6d}  {disp}  U+{ord(ch):04X}")

with open(OUT, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

print(f"done: {len(rows)} unique chars -> {OUT}")
print(f"total_items={len(data)} translated={translated_items} chars={total_chars} unique={len(counts)}")
print("top 10:")
for ch, n in rows[-10:]:
    disp = "\\n" if ch == "\n" else ch
    print(f"  {n:6d}  {disp}")