#!/usr/bin/env python3
"""Builds docs/readme/ from build/readme-renders/ (made by `render.sh readme`).

Animations: the numbered PNG frames become looping GIFs with one shared palette, so colors never shimmer between
frames. Pure magenta (#FF00FF) outside the rounded panel becomes transparent. Stills are copied as PNG, reduced to
256 colors when that keeps them sharp and makes them smaller.

Needs Pillow (`python3 -m pip install pillow`). Development tooling only; nothing here ships in the app.
"""
import pathlib
import shutil
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "build/readme-renders"
DEST = ROOT / "docs/readme"
KEY = (255, 0, 255)


def gif(frames_dir: pathlib.Path, out: pathlib.Path) -> None:
    fps = float((frames_dir / "fps.txt").read_text())
    frames = [Image.open(p).convert("RGB") for p in sorted(frames_dir.glob("[0-9][0-9][0-9].png"))]
    # One palette for every frame, from a strip of samples.
    samples = frames[:: max(1, len(frames) // 24)]
    w, h = frames[0].size
    strip = Image.new("RGB", (w, h * len(samples)))
    for i, f in enumerate(samples):
        strip.paste(f, (0, h * i))
    palette = strip.quantize(colors=255, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    pal = (palette.getpalette() + [0] * 768)[: 255 * 3] + list(KEY)
    palette.putpalette(pal)
    clear = 255  # the key color always gets its own entry, even when the corners are only a few pixels
    quantized = []
    for f in frames:
        q = f.quantize(palette=palette, dither=Image.Dither.NONE)
        indices = bytearray(q.tobytes())
        for i, pixel in enumerate(f.getdata()):
            if pixel == KEY:
                indices[i] = clear
        q = Image.frombytes("P", f.size, bytes(indices))
        q.putpalette(pal)
        quantized.append(q)
    # After the first frame, pixels that didn't change become transparent ("keep what's there"), which GIF's LZW
    # packs far smaller. The key color is never drawn on top of art, so it's safe to reuse as that marker.
    encoded = [quantized[0]]
    for previous, frame in zip(quantized, quantized[1:]):
        before, now = previous.tobytes(), bytearray(frame.tobytes())
        for i in range(len(now)):
            if now[i] == before[i]:
                now[i] = clear
        delta = Image.frombytes("P", frame.size, bytes(now))
        delta.putpalette(pal)
        encoded.append(delta)
    frame_ms = 10 * round(100 / fps)  # GIF delays are in hundredths of a second
    encoded[0].save(out, save_all=True, append_images=encoded[1:], duration=frame_ms, loop=0,
                    optimize=False, disposal=1, transparency=clear)
    verify(out, quantized, frame_ms, clear)


def verify(out: pathlib.Path, expected: list, frame_ms: int, clear: int) -> None:
    """Decodes the GIF and checks each frame matches its source, outside the transparent corners. Pillow merges
    repeated frames into longer ones, so frames are matched by time."""
    key_mask = expected[0].tobytes()
    with Image.open(out) as gif_image:
        elapsed = 0
        for n in range(gif_image.n_frames):
            gif_image.seek(n)
            want = expected[round(elapsed / frame_ms)].convert("RGB").tobytes()
            got = gif_image.convert("RGB").tobytes()
            for i in range(0, len(want), 3 * 997):  # a sparse sample keeps this quick
                if key_mask[i // 3] != clear and got[i:i + 3] != want[i:i + 3]:
                    raise SystemExit(f"{out.name}: frame {n} differs at pixel {i // 3}")
            elapsed += gif_image.info["duration"]
        if round(elapsed / frame_ms) != len(expected):
            raise SystemExit(f"{out.name}: {elapsed} ms for {len(expected)} frames")


def still(src: pathlib.Path, out: pathlib.Path) -> None:
    image = Image.open(src).convert("RGBA")
    reduced = image.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    reduced.save(out, optimize=True)
    lossless = out.with_suffix(".tmp.png")
    image.save(lossless, optimize=True)
    # Keep the 256-color version only when it is clearly smaller; the pixel art itself has few colors.
    if lossless.stat().st_size < out.stat().st_size * 1.3:
        shutil.move(lossless, out)
    else:
        lossless.unlink()


def main() -> int:
    if not SRC.is_dir():
        print(f"No {SRC}; run scripts/design-harness/render.sh readme first.", file=sys.stderr)
        return 1
    DEST.mkdir(parents=True, exist_ok=True)
    for frames_dir in sorted((SRC / "frames").iterdir()):
        if frames_dir.is_dir():
            gif(frames_dir, DEST / f"{frames_dir.name}.gif")
    for png in sorted(SRC.glob("*.png")):
        still(png, DEST / png.name)
    total = 0
    for f in sorted(DEST.iterdir()):
        size = f.stat().st_size
        total += size
        with Image.open(f) as image:
            print(f"{f.relative_to(ROOT)}  {image.size[0]}x{image.size[1]}  {size / 1024:.0f} KB")
    print(f"total {total / 1024 / 1024:.2f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
