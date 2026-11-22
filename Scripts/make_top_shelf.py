#!/usr/bin/env python3
"""Fork-only: draws the Top Shelf images (what the home screen shows while the app is focused).

The cloud logo and a "CloudFixed" wordmark on the left, a glowing controller on the right, on
a night-blue background with an ambient cyan/violet glow and a few speed lines. Needs Pillow and
the Montserrat variable font (github.com/google/fonts, ofl/montserrat):

    python3 Scripts/make_top_shelf.py /path/to/Montserrat[wght].ttf
"""
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "CloudNow/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
LOGO = BRAND / "App Icon - App Store.imagestack/Front.imagestacklayer/Content.imageset/icon_1280x768.png"

H = 1440                     # drawn at the @2x size
BG_TOP, BG_BOTTOM = (12, 20, 46), (4, 6, 16)
CYAN, BLUE, VIOLET = (20, 220, 255), (40, 110, 255), (150, 70, 255)
SHELL, SHADE, DARK = (240, 243, 250), (206, 212, 228), (24, 28, 40)
FACE = [(63, 201, 176), (229, 83, 107), (127, 164, 232), (217, 138, 217)]


def background(width):
    gradient = Image.new("RGB", (1, H))
    for y in range(H):
        t = y / (H - 1)
        gradient.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)))
    image = gradient.resize((width, H))
    # Ambient glows, drawn small and blurred.
    small = Image.new("RGB", (width // 8, H // 8))
    draw = ImageDraw.Draw(small)
    for (x, y), radius, colour in (((0.2, 0.5), 520, BLUE), ((0.3, 0.35), 300, CYAN), ((0.78, 0.55), 560, VIOLET),
                                   ((0.86, 0.3), 320, BLUE)):
        cx, cy, r = x * width / 8, y * H / 8, radius / 8
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=colour)
    glow = small.filter(ImageFilter.GaussianBlur(60)).resize((width, H), Image.BICUBIC).point(lambda v: v * 0.42)
    image = ImageChops.add(image, glow)
    # Speed lines streaking from the wordmark towards the controller.
    lines = Image.new("L", (width, H), 0)
    draw = ImageDraw.Draw(lines)
    for i, (y, start, length) in enumerate(((0.3, 0.5, 0.3), (0.38, 0.56, 0.22), (0.66, 0.52, 0.27), (0.73, 0.6, 0.18),
                                             (0.8, 0.47, 0.2))):
        x0, x1 = start * width, (start + length) * width
        for step in range(40):   # fade in, then out
            t0, t1 = step / 40, (step + 1) / 40
            alpha = round(90 * (1 - abs(t0 * 2 - 1)) * (0.6 if i % 2 else 1))
            draw.line((x0 + (x1 - x0) * t0, y * H, x0 + (x1 - x0) * t1, y * H), fill=alpha, width=4)
    lines = lines.filter(ImageFilter.GaussianBlur(1.5))
    image.paste(Image.new("RGB", image.size, (150, 190, 255)), (0, 0), lines)
    return image


def controller(image, box):
    """A PS5-style controller filling `box` (x0, y0, x1, y1), with a glow under it."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0

    def at(u, v):
        return round(x0 + u * w), round(y0 + v * h)

    mask = Image.new("L", image.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((*at(0.06, 0.04), *at(0.94, 0.6)), round(0.2 * h), fill=255)
    draw.ellipse((*at(0.22, 0.4), *at(0.78, 0.72)), fill=255)
    for side in (-1, 1):
        top, bottom = at(0.5 + side * 0.3, 0.3), at(0.5 + side * 0.39, 0.86)
        width = round(0.3 * h)
        draw.line((top, bottom), fill=255, width=width)
        for cx, cy in (top, bottom):
            draw.ellipse((cx - width / 2, cy - width / 2, cx + width / 2, cy + width / 2), fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(1))

    halo = mask.filter(ImageFilter.GaussianBlur(90)).point(lambda v: v * 0.7)
    image.paste(Image.new("RGB", image.size, (110, 120, 255)), (0, 0), halo)

    shell = Image.new("RGB", image.size, SHELL)
    draw = ImageDraw.Draw(shell)

    def circle(u, v, radius, fill):
        cx, cy = at(u, v)
        r = radius * h
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=fill)

    draw.rounded_rectangle((*at(0.33, 0.02), *at(0.67, 0.36)), round(0.07 * h), fill=SHADE)
    for u in (0.315, 0.67):
        draw.rounded_rectangle((*at(u, 0.05), *at(u + 0.015, 0.3)), round(0.01 * h), fill=CYAN)
    cx, cy = at(0.2, 0.27)
    arm, thick = 0.12 * h, 0.055 * h
    draw.rounded_rectangle((cx - arm, cy - thick, cx + arm, cy + thick), round(0.015 * h), fill=DARK)
    draw.rounded_rectangle((cx - thick, cy - arm, cx + thick, cy + arm), round(0.015 * h), fill=DARK)
    for (du, dv), colour in zip(((0, -0.11), (0.065, 0), (0, 0.11), (-0.065, 0)), FACE):
        circle(0.8 + du, 0.27 + dv, 0.05, colour)
    for u in (0.36, 0.64):
        circle(u, 0.5, 0.1, DARK)
        circle(u, 0.5, 0.068, (58, 64, 84))
    circle(0.5, 0.44, 0.03, DARK)
    image.paste(shell, (0, 0), mask)


def wordmark(image, font_path, left, centre_y):
    """The cloud logo, "Cloud" in white and "Fixed" in a cyan-to-blue gradient, and a tagline."""
    logo = Image.open(LOGO).convert("RGBA")
    logo = logo.crop(logo.getbbox())
    logo_h = 360
    logo = logo.resize((round(logo.width * logo_h / logo.height), logo_h), Image.LANCZOS)
    glow = Image.new("RGB", image.size, CYAN)
    shadow = Image.new("L", image.size, 0)
    shadow.paste(logo.getchannel("A"), (left, centre_y - logo_h // 2 - 40))
    image.paste(glow, (0, 0), shadow.filter(ImageFilter.GaussianBlur(50)).point(lambda v: v * 0.5))
    image.paste(logo, (left, centre_y - logo_h // 2 - 40), logo)

    font = ImageFont.truetype(font_path, 250)
    font.set_variation_by_name("ExtraBold")
    small = ImageFont.truetype(font_path, 62)
    small.set_variation_by_name("SemiBold")
    draw = ImageDraw.Draw(image)
    x = left + logo.width + 70
    top = centre_y - 200
    draw.text((x, top), "Cloud", font=font, fill=(255, 255, 255))
    x_fixed = x + draw.textlength("Cloud", font=font)
    fixed_mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(fixed_mask).text((x_fixed, top), "Fixed", font=font, fill=255)
    box = fixed_mask.getbbox()
    gradient = Image.new("RGB", (box[2] - box[0], 1))
    for i in range(gradient.width):
        t = i / max(1, gradient.width - 1)
        gradient.putpixel((i, 0), tuple(round(a + (b - a) * t) for a, b in zip(CYAN, (90, 120, 255))))
    fill = Image.new("RGB", image.size)
    fill.paste(gradient.resize((gradient.width, box[3] - box[1])), box[:2])
    image.paste(fill, (0, 0), fixed_mask)

    tagline = "G E F O R C E   N O W   ·   O N   Y O U R   T V"
    draw.text((x + 8, top + 320), tagline, font=small, fill=(150, 170, 210))
    return x_fixed + draw.textlength("Fixed", font=font)


def render(width, font_path):
    image = background(width)
    # The standard image is narrower: everything moves in, the controller shrinks a little.
    left = round(width * 0.075)
    text_right = wordmark(image, font_path, left, round(H * 0.52))
    room = width * 0.95 - text_right
    ctl_w = min(1300, room - 120)
    ctl_x = text_right + (room - ctl_w) / 2 + 40
    ctl_h = ctl_w * 0.62
    controller(image, (ctl_x, H * 0.5 - ctl_h / 2, ctl_x + ctl_w, H * 0.5 + ctl_h / 2))
    return image


def main():
    font_path = sys.argv[1]
    for name, folder, width in (("top_shelf_wide", "Top Shelf Image Wide.imageset", 4640),
                                ("top_shelf", "Top Shelf Image.imageset", 3840)):
        image = render(width, font_path)
        out = BRAND / folder
        image.save(out / f"{name}_{width}x{H}.png", optimize=True)
        image.resize((width // 2, H // 2), Image.LANCZOS).save(out / f"{name}_{width // 2}x{H // 2}.png", optimize=True)


if __name__ == "__main__":
    main()
