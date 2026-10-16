#!/usr/bin/env python3
"""Regenerate bundled manual-test assets with librsvg, ImageMagick and Typst."""

from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent
IMAGES = ROOT / "images"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def board(width=640, height=400, title="IMAGE TOOLS", transparent=False):
    """Use simple SVG primitives supported by both librsvg and ImageMagick MSVG."""
    background = "" if transparent else '<rect width="640" height="400" fill="#f8fafc"/>'
    tiles = "".join(
        f'<rect x="{x}" y="{y}" width="274" height="104" rx="8" fill="{color}"/>'
        f'<text x="{x + 18}" y="{y + 39}" fill="{ink}" font-size="20">{label}</text>'
        for x, y, color, ink, label in (
            (36, 100, "#e74c3c", "white", "TOP LEFT / RED"),
            (330, 100, "#27ae60", "white", "TOP RIGHT / GREEN"),
            (36, 220, "#2980b9", "white", "BOTTOM LEFT / BLUE"),
            (330, 220, "#f1c40f", "#172033", "BOTTOM RIGHT"),
        )
    )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 640 400">{background}'
        '<g font-family="DejaVu Sans, sans-serif" fill="#172033">'
        f'<text x="36" y="52" font-size="30" font-weight="bold">{title}</text>'
        '<text x="36" y="78" font-size="16">Color, orientation and aspect-ratio sample</text>'
        f'{tiles}<circle cx="320" cy="212" r="40" fill="white" stroke="#172033" stroke-width="3"/>'
        '<path d="M296 212 H344 M320 188 V236" stroke="#172033" stroke-width="3"/>'
        '<text x="36" y="365" font-size="18">01 / image-tools.nvim / manual testing</text>'
        '</g></svg>\n'
    )


def main():
    for tool in ("magick", "rsvg-convert", "typst"):
        if not shutil.which(tool):
            raise SystemExit(f"Required for regeneration: {tool}")
    IMAGES.mkdir(exist_ok=True)
    svg = IMAGES / "sample.svg"
    svg.write_text(board(), encoding="utf-8")
    png = IMAGES / "sample.png"
    run("rsvg-convert", "--output", png, svg)
    run("magick", png, "-depth", "8", "-strip", png)
    for extension in ("jpg", "jpeg", "webp", "avif", "heic", "bmp", "tif", "tiff"):
        options = ["-compress", "LZW"] if extension in ("tif", "tiff") else []
        run("magick", png, "-strip", *options, IMAGES / f"sample.{extension}")

    with tempfile.TemporaryDirectory(prefix="image-tools-examples-") as directory:
        temporary = Path(directory)
        second_svg = temporary / "second.svg"
        second_svg.write_text(board(title="FRAME TWO"), encoding="utf-8")
        second = temporary / "second.png"
        run("rsvg-convert", "--output", second, second_svg)
        run("magick", "-delay", "80", png, second, "-loop", "0", IMAGES / "sample.gif")

        alpha_svg = temporary / "alpha.svg"
        alpha_svg.write_text(board(transparent=True), encoding="utf-8")
        alpha_png = temporary / "alpha.png"
        run("rsvg-convert", "--output", alpha_png, alpha_svg)
        run("magick", alpha_png, "-depth", "8", "-strip", IMAGES / "transparent.png")

    # Preserve the content's aspect ratio and extend the canvas for pan/zoom checks.
    for filename, size in (("wide.png", "1600x400"), ("tall.png", "640x1600")):
        run("magick", png, "-background", "#cbd5e1", "-gravity", "center", "-extent", size,
            "-strip", IMAGES / filename)
    shutil.copyfile(png, IMAGES / "sample space 中文.png")
    run("typst", "compile", "--creation-timestamp", "0", ROOT / "sample.typ", ROOT / "sample.pdf")


if __name__ == "__main__":
    main()
