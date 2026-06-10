import re
from pathlib import Path
from PIL import Image

CHAR_NAMES_DIR = Path("romhack/pic_output/char_names")
PATTERN = re.compile(r"char_(\d+)_(sub[23])_(part_\d+)\.gif")


def compare(fa, wa, ha, fb, wb, hb):
    """Return winning index (0 for a, 1 for b), or -1 for ambiguous."""
    if wa > wb and ha > hb:
        return 0
    if wb > wa and hb > ha:
        return 1
    if wa == wb and ha == hb:
        return 0
    if wa == wb:
        return 0 if ha > hb else 1
    if ha == hb:
        return 0 if wa > wb else 1
    return -1


def main():
    files = sorted(CHAR_NAMES_DIR.glob("*.gif"))
    if not files:
        print("No files found.")
        return

    groups: dict[str, list[tuple[Path, int, int]]] = {}
    for f in files:
        m = PATTERN.match(f.name)
        if not m:
            print(f"  SKIP: {f.name}")
            continue
        char_id = m.group(1)
        with Image.open(f) as img:
            w, h = img.size
        groups.setdefault(char_id, []).append((f, w, h))

    kept = 0
    deleted = 0
    singles = 0
    errors = []

    for char_id, items in sorted(groups.items(), key=lambda x: int(x[0])):
        items.sort(key=lambda x: (-(x[1] * x[2]), x[0].name))
        if len(items) == 1:
            singles += 1
            continue

        best = items[0]
        for other in items[1:]:
            result = compare(best[0], best[1], best[2], other[0], other[1], other[2])
            if result == 0:
                print(f"  {other[0].name} -> DEL (keep {best[0].name})")
                other[0].unlink()
                deleted += 1
            elif result == 1:
                print(f"  {best[0].name} -> DEL (keep {other[0].name})")
                best[0].unlink()
                deleted += 1
                kept -= 1
                best = other
            else:
                msg = (
                    f"  AMBIGUOUS char_{char_id}: "
                    f"{best[0].stem}={best[1]}x{best[2]} vs {other[0].stem}={other[1]}x{other[2]}"
                )
                print(msg)
                errors.append(msg)
        kept += 1

    print(f"\nKept: {kept}, Deleted: {deleted}, Singles: {singles}")
    if errors:
        print(f"Errors ({len(errors)}):")
        for e in errors:
            print(e)


if __name__ == "__main__":
    main()
