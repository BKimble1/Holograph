#!/usr/bin/env python3
"""Render the 1024x1024 launcher app icon.

Deep navy ground, one cyan/white portal tile floating over a pedestal of light.
No text, no alpha channel (the App Store rejects icons with transparency).

Usage: python3 Scripts/make_app_icon.py [output.png]
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
NAVY_CENTRE = (10, 32, 58)
NAVY_EDGE = (2, 7, 18)
CYAN = (92, 214, 255)
CYAN_SOFT = (46, 150, 214)
WHITE = (238, 251, 255)


def radial_background() -> Image.Image:
    image = Image.new("RGB", (SIZE, SIZE), NAVY_EDGE)
    pixels = image.load()
    centre = SIZE / 2
    max_distance = math.hypot(centre, centre)
    for y in range(SIZE):
        for x in range(SIZE):
            distance = math.hypot(x - centre, y - centre) / max_distance
            # Ease so the glow stays close to the middle.
            t = min(1.0, distance ** 1.35)
            pixels[x, y] = tuple(
                int(NAVY_CENTRE[i] + (NAVY_EDGE[i] - NAVY_CENTRE[i]) * t) for i in range(3)
            )
    return image


def add_glow(base: Image.Image, layer: Image.Image, blur: float, strength: float) -> Image.Image:
    glow = layer.filter(ImageFilter.GaussianBlur(blur))
    if strength != 1.0:
        alpha = glow.getchannel("A").point(lambda v: int(v * strength))
        glow.putalpha(alpha)
    return Image.alpha_composite(base, glow)


def rounded_rect(draw: ImageDraw.ImageDraw, box, radius, **kwargs) -> None:
    draw.rounded_rectangle(box, radius=radius, **kwargs)


def mask_for(box, radius) -> Image.Image:
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def build() -> Image.Image:
    canvas = radial_background().convert("RGBA")

    tile = 470
    left = (SIZE - tile) / 2
    top = (SIZE - tile) / 2 - 26
    box = (left, top, left + tile, top + tile)
    radius = tile * 0.235

    # Cyan bloom behind the tile.
    bloom = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rounded_rect(ImageDraw.Draw(bloom), box, radius, fill=CYAN + (150,))
    canvas = add_glow(canvas, bloom, blur=70, strength=0.85)

    # The glass face of the tile: brighter at the top, fading down the pane.
    face = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rounded_rect(ImageDraw.Draw(face), box, radius, fill=CYAN_SOFT + (255,))
    gradient = Image.new("L", (1, SIZE))
    for y in range(SIZE):
        t = (y - top) / tile
        t = min(1.0, max(0.0, t))
        gradient.putpixel((0, y), int(62 - 44 * t))
    face.putalpha(
        Image.composite(gradient.resize((SIZE, SIZE)), Image.new("L", (SIZE, SIZE), 0), face.getchannel("A"))
    )
    canvas = Image.alpha_composite(canvas, face)

    # A single diagonal highlight so the pane reads as glass.
    sheen = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(sheen).polygon(
        [
            (left - 40, top + tile * 0.52),
            (left + tile * 0.62, top - 40),
            (left + tile * 0.86, top - 40),
            (left - 40, top + tile * 0.80),
        ],
        fill=WHITE + (34,),
    )
    sheen.putalpha(
        Image.composite(sheen.getchannel("A"), Image.new("L", (SIZE, SIZE), 0), mask_for(box, radius))
    )
    canvas = Image.alpha_composite(canvas, sheen.filter(ImageFilter.GaussianBlur(8)))

    # Scan lines inside the tile.
    lines = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    lines_draw = ImageDraw.Draw(lines)
    y = top + 16
    while y < top + tile - 12:
        lines_draw.rectangle((left + 10, y, left + tile - 10, y + 2), fill=CYAN + (26,))
        y += 15
    lines.putalpha(
        Image.composite(lines.getchannel("A"), Image.new("L", (SIZE, SIZE), 0), mask_for(box, radius))
    )
    canvas = Image.alpha_composite(canvas, lines)

    # Illuminated edge: a wide soft cyan stroke under a crisp white one.
    outer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rounded_rect(ImageDraw.Draw(outer), box, radius, outline=CYAN + (255,), width=20)
    canvas = add_glow(canvas, outer, blur=18, strength=1.0)

    crisp = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rounded_rect(ImageDraw.Draw(crisp), box, radius, outline=WHITE + (245,), width=9)
    canvas = Image.alpha_composite(canvas, crisp)

    inset = 34
    inner_box = (box[0] + inset, box[1] + inset, box[2] - inset, box[3] - inset)
    inner = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rounded_rect(ImageDraw.Draw(inner), inner_box, radius * 0.78, outline=CYAN + (120,), width=4)
    canvas = Image.alpha_composite(canvas, inner)

    # Pedestal of light beneath the tile.
    pedestal = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    pedestal_draw = ImageDraw.Draw(pedestal)
    ellipse_width = tile * 1.16
    ellipse_height = tile * 0.15
    ellipse_top = box[3] + 34
    pedestal_draw.ellipse(
        (
            SIZE / 2 - ellipse_width / 2,
            ellipse_top,
            SIZE / 2 + ellipse_width / 2,
            ellipse_top + ellipse_height,
        ),
        fill=CYAN + (190,),
    )
    canvas = add_glow(canvas, pedestal, blur=26, strength=0.95)

    core = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(core).ellipse(
        (
            SIZE / 2 - ellipse_width * 0.26,
            ellipse_top + ellipse_height * 0.28,
            SIZE / 2 + ellipse_width * 0.26,
            ellipse_top + ellipse_height * 0.72,
        ),
        fill=WHITE + (200,),
    )
    canvas = add_glow(canvas, core, blur=10, strength=1.0)

    # Flatten: iOS app icons must be fully opaque.
    return Image.alpha_composite(Image.new("RGBA", (SIZE, SIZE), NAVY_EDGE + (255,)), canvas).convert("RGB")


def main() -> int:
    destination = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
        "IdleryLauncher/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    build().save(destination, format="PNG", optimize=True)
    print(f"wrote {destination} ({destination.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
