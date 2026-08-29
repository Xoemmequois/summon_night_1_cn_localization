import sys
from pathlib import Path
from PIL import Image, ImageSequence

BLACK_MAX = 5
MARK_COLOR = (255, 0, 0)      # 标注色：红
BACKGROUND_COLOR = (255, 255, 255)  # 背景：白


def find_black_pixels(path: Path) -> tuple[list[tuple[int, int]], int, tuple[int, int]]:
    """返回 ([黑色像素 (x, y) 各帧并集], 帧数, 图像尺寸)。RGB 每个通道都在 0~BLACK_MAX 内且非透明即算黑色"""
    positions: set[tuple[int, int]] = set()
    size = (0, 0)
    with Image.open(path) as img:
        frames = list(ImageSequence.Iterator(img))
        for frame in frames:
            rgba = frame.convert("RGBA")
            size = rgba.size
            data = rgba.tobytes()
            w = rgba.width
            for i in range(0, len(data), 4):
                # RGBA 字节序: R, G, B, A
                if (
                    data[i] <= BLACK_MAX
                    and data[i + 1] <= BLACK_MAX
                    and data[i + 2] <= BLACK_MAX
                    and data[i + 3] != 0
                ):
                    px = i // 4
                    positions.add((px % w, px // w))
        return list(positions), len(frames), size


def save_mark_gif(path: Path, out_path: Path, positions: list[tuple[int, int]], size: tuple[int, int]) -> None:
    """生成仅标注黑色像素位置的 GIF：白底 + 红色标记点"""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    mark = Image.new("RGB", size, BACKGROUND_COLOR)
    data = bytearray(mark.tobytes())
    w = size[0]
    for x, y in positions:
        idx = (y * w + x) * 3
        data[idx] = MARK_COLOR[0]
        data[idx + 1] = MARK_COLOR[1]
        data[idx + 2] = MARK_COLOR[2]
    Image.frombytes("RGB", size, bytes(data)).save(out_path, "GIF")


def main() -> None:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("pic_output_translated")
    mark_root = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("black_mark_output")
    if not root.is_dir():
        print(f"目录不存在: {root}")
        sys.exit(1)

    files = sorted(root.rglob("*.gif"))
    print(f"共 {len(files)} 个 GIF，检查非透明近黑像素 (RGB 各通道 <= {BLACK_MAX})...")

    found = 0
    for f in files:
        positions, frame_count, size = find_black_pixels(f)
        if not positions:
            continue
        found += 1
        rel = f.relative_to(root)
        out_path = mark_root / rel
        save_mark_gif(f, out_path, positions, size)
        print(f"{rel}  ({len(positions)} 个黑色像素, {frame_count} 帧) -> {out_path}")

    print(f"完成: {found} / {len(files)} 个 GIF 含非透明黑色像素，标注图已输出到 {mark_root}\\")


if __name__ == "__main__":
    main()
