#!/usr/bin/env python3
"""Regenerate the checked-in iOS/watchOS AppIcon catalogs. Requires Pillow."""
from io import BytesIO
import json
from pathlib import Path

from PIL import Image, ImageDraw, PngImagePlugin

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024
SUPERSAMPLE = 4
BACKGROUND = (17, 25, 23)
FOREGROUND = (140, 240, 197)


def icon_png():
    """Keep the waveform inside the circular watchOS mask; let the OS mask edges."""
    image = Image.new("RGB", (SIZE * SUPERSAMPLE, SIZE * SUPERSAMPLE), BACKGROUND)
    draw = ImageDraw.Draw(image)
    bar_width = 60
    gap = 32
    heights = (164, 280, 416, 560, 416, 280, 164)
    left = (SIZE - (len(heights) * bar_width + (len(heights) - 1) * gap)) // 2
    for index, height in enumerate(heights):
        x = left + index * (bar_width + gap)
        y = (SIZE - height) // 2
        draw.rounded_rectangle(
            tuple(value * SUPERSAMPLE for value in (x, y, x + bar_width, y + height)),
            radius=bar_width * SUPERSAMPLE // 2,
            fill=FOREGROUND,
        )
    image = image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    metadata = PngImagePlugin.PngInfo()
    metadata.add(b"sRGB", b"\x00")
    output = BytesIO()
    image.save(output, format="PNG", pnginfo=metadata, compress_level=9)
    return output.getvalue()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def main():
    png = icon_png()
    for folder, platform in (("Phone", "ios"), ("Watch", "watchos")):
        catalog = ROOT / folder / "Assets.xcassets"
        app_icon = catalog / "AppIcon.appiconset"
        app_icon.mkdir(parents=True, exist_ok=True)
        write_json(catalog / "Contents.json", {"info": {"author": "xcode", "version": 1}})
        write_json(app_icon / "Contents.json", {
            "images": [{
                "filename": "AppIcon-1024.png",
                "idiom": "universal",
                "platform": platform,
                "size": "1024x1024",
            }],
            "info": {"author": "xcode", "version": 1},
        })
        (app_icon / "AppIcon-1024.png").write_bytes(png)
    print("Generated opaque 1024px iOS and watchOS AppIcon catalogs.")


if __name__ == "__main__":
    main()
