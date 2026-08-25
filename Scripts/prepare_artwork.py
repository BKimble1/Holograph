#!/usr/bin/env python3
"""Turn the source artwork in Art/ into the app's asset catalog images.

Sources (committed, and the only thing a designer needs to replace):
  Art/HoloIcon.png        the launcher mark — glow on near-black
  Art/IdleryWordmark.png  the Idlery wordmark — teal on white

Products:
  AppIcon.appiconset/AppIcon-1024.png   1024x1024, opaque (the App Store
                                        rejects icons with an alpha channel)
  LaunchLogo.imageset/LaunchLogo.png    the mark keyed to transparency so it
                                        sits on the launcher's own backdrop
  IdleryWordmark.imageset/*.png         the wordmark keyed to transparency in
                                        its own teal, at 1x/2x/3x

Run after changing anything in Art/:

    python3 Scripts/prepare_artwork.py
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image

Image.MAX_IMAGE_PIXELS = None

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "Art"
ASSETS = ROOT / "Holograph" / "Resources" / "Assets.xcassets"

APP_ICON_SIZE = 1024
LAUNCH_LOGO_SIZE = 1024
WORDMARK_1X_WIDTH = 220


def app_icon() -> None:
    """Square, opaque, no text — exactly what App Store Connect wants."""
    source = Image.open(ART / "HoloIcon.png").convert("RGB")
    icon = source.resize((APP_ICON_SIZE, APP_ICON_SIZE), Image.LANCZOS)
    destination = ASSETS / "AppIcon.appiconset" / "AppIcon-1024.png"
    destination.parent.mkdir(parents=True, exist_ok=True)
    icon.save(destination, optimize=True)
    print(f"app icon      {destination.relative_to(ROOT)} {icon.size} {icon.mode}")


def launch_logo() -> None:
    """Key the near-black ground out of the mark.

    The artwork is light drawn on black, so luminance is already a faithful
    coverage mask: taking it as alpha reproduces the glow over any backdrop
    without the square edge a blend mode would leave behind.
    """
    source = Image.open(ART / "HoloIcon.png").convert("RGB")
    source = source.resize((LAUNCH_LOGO_SIZE, LAUNCH_LOGO_SIZE), Image.LANCZOS)
    luminance = source.convert("L")
    # Lift the mask slightly so the faint outer glow survives, and floor the
    # near-black ground to fully transparent.
    alpha = luminance.point(lambda value: 0 if value < 10 else min(255, int(value * 1.25)))
    keyed = source.copy()
    keyed.putalpha(alpha)
    destination = ASSETS / "LaunchLogo.imageset" / "LaunchLogo.png"
    destination.parent.mkdir(parents=True, exist_ok=True)
    keyed.save(destination, optimize=True)
    print(f"launch logo   {destination.relative_to(ROOT)} {keyed.size} {keyed.mode}")


def wordmark() -> None:
    """Key the white paper out of the wordmark, keeping its own teal."""
    source = Image.open(ART / "IdleryWordmark.png").convert("RGB")

    # The ink is a single flat colour; find it from the most saturated pixels.
    thumbnail = source.resize((160, max(1, 160 * source.height // source.width)))
    pixels = [thumbnail.getpixel((x, y)) for y in range(thumbnail.height) for x in range(thumbnail.width)]
    darkest = min(pixels, key=lambda p: sum(p))
    ink_luminance = sum(darkest) / 3

    grey = source.convert("L")
    span = max(1.0, 255.0 - ink_luminance)
    alpha = grey.point(lambda value: max(0, min(255, int((255 - value) / span * 255))))

    keyed = Image.new("RGBA", source.size, darkest + (0,))
    keyed.putalpha(alpha)

    destination_dir = ASSETS / "IdleryWordmark.imageset"
    destination_dir.mkdir(parents=True, exist_ok=True)
    for scale in (1, 2, 3):
        width = WORDMARK_1X_WIDTH * scale
        height = max(1, round(width * keyed.height / keyed.width))
        resized = keyed.resize((width, height), Image.LANCZOS)
        name = f"IdleryWordmark@{scale}x.png" if scale > 1 else "IdleryWordmark.png"
        resized.save(destination_dir / name, optimize=True)
        print(f"wordmark {scale}x   {(destination_dir / name).relative_to(ROOT)} {resized.size} ink #{darkest[0]:02X}{darkest[1]:02X}{darkest[2]:02X}")


def contents(images: list[dict]) -> str:
    import json

    return json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n"


def write_contents() -> None:
    (ASSETS / "AppIcon.appiconset" / "Contents.json").write_text(
        contents([
            {
                "filename": "AppIcon-1024.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            }
        ])
    )
    (ASSETS / "LaunchLogo.imageset" / "Contents.json").write_text(
        # Single-scale: one high-resolution image, no unassigned slots.
        contents([{"filename": "LaunchLogo.png", "idiom": "universal"}])
    )
    (ASSETS / "IdleryWordmark.imageset" / "Contents.json").write_text(
        contents([
            {"filename": "IdleryWordmark.png", "idiom": "universal", "scale": "1x"},
            {"filename": "IdleryWordmark@2x.png", "idiom": "universal", "scale": "2x"},
            {"filename": "IdleryWordmark@3x.png", "idiom": "universal", "scale": "3x"},
        ])
    )
    print("wrote Contents.json for all three image sets")


def main() -> int:
    app_icon()
    launch_logo()
    wordmark()
    write_contents()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
