import sys
from pathlib import Path
from PIL import Image


def gif_to_act(gif_path: Path, act_path: Path | None = None):
    if act_path is None:
        act_path = gif_path.with_suffix(".act")

    with Image.open(gif_path) as img:
        img = img.convert("RGB")
        palette = img.getpalette()

        if palette is None:
            print(f"Error: {gif_path.name} has no palette")
            return

    colors = palette[:768]
    if len(colors) < 768:
        colors += [0] * (768 - len(colors))

    act_path.write_bytes(bytes(colors))
    print(f"Saved: {act_path}")


def main():
    if len(sys.argv) < 2:
        print("Usage: python gif_to_act.py <input.gif> [output.act]")
        return

    in_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2]) if len(sys.argv) > 2 else None

    if not in_path.exists():
        print(f"Error: {in_path} not found")
        return

    gif_to_act(in_path, out_path)


if __name__ == "__main__":
    main()
