#!/usr/bin/env python3
"""Extract the captain's hand-drawn artwork onto a transparent background.

Source (~/Downloads/captain-logo.png) is a soft radial-glow gray background
with lighter gray line-art on top - not usable as an icon as-is, and not
separable by a flat luminance threshold, since the glow's own brighter
center would get picked up as "icon" right along with the real line art.

Instead this subtracts a heavily blurred copy of the image from itself (a
large-radius Gaussian, so the glow washes out into its own blur) and
thresholds that residual: the line art survives because it is consistently
brighter than its *immediate* surroundings, glow or no glow. A median filter
then drops isolated speckle without eroding the (thin) linework, a light
blur anti-aliases the stencil edges, and the result is cropped to a square
bounding box and downsampled to 256x256.

Output is a black-on-transparent PNG - the RGB value doesn't matter for a
macOS template image, only the alpha channel does. `CaptainIcon.swift`
embeds this PNG as a base64 literal (see that file's header for why: no
Assets.xcassets/actool in this CLT-only build, and SwiftPM's `Bundle.module`
accessor for an *executable* target is documented elsewhere in this repo as
unreliable across build layouts).

Usage: python3 native/scripts/extract-captain-icon.py <src.png> <out.png>
"""
import sys

from PIL import Image, ImageChops, ImageFilter

BLUR_RADIUS = 45
THRESHOLD = 14
TARGET_SIZE = 256
PAD_FRACTION = 0.12


def extract(src_path: str, out_path: str) -> None:
    src = Image.open(src_path).convert("L")
    blurred = src.filter(ImageFilter.GaussianBlur(radius=BLUR_RADIUS))
    diff = ImageChops.subtract(src, blurred, scale=1.0, offset=128)

    mask = diff.point(lambda p: 255 if p > 128 + THRESHOLD else 0)
    mask = mask.filter(ImageFilter.MedianFilter(3))
    mask_aa = mask.filter(ImageFilter.GaussianBlur(radius=1.0))

    bbox = mask.getbbox()
    if bbox is None:
        raise SystemExit("no line art found above threshold - check THRESHOLD/BLUR_RADIUS")

    left, top, right, bottom = bbox
    pad = int(max(right - left, bottom - top) * PAD_FRACTION)
    left = max(0, left - pad)
    top = max(0, top - pad)
    right = min(mask.width, right + pad)
    bottom = min(mask.height, bottom + pad)

    side = max(right - left, bottom - top)
    cx, cy = (left + right) // 2, (top + bottom) // 2
    half = side // 2
    left, top = max(0, cx - half), max(0, cy - half)
    right, bottom = left + side, top + side

    alpha = mask_aa.crop((left, top, right, bottom)).resize((TARGET_SIZE, TARGET_SIZE), Image.LANCZOS)

    black = Image.new("RGBA", (TARGET_SIZE, TARGET_SIZE), (20, 20, 20, 255))
    transparent = Image.new("RGBA", (TARGET_SIZE, TARGET_SIZE), (0, 0, 0, 0))
    rgba = Image.composite(black, transparent, alpha)
    rgba.putalpha(alpha)
    rgba.save(out_path)

    alphas = [p[3] for p in rgba.getdata()]
    nonzero = sum(1 for a in alphas if a > 10)
    print(f"wrote {out_path}: {nonzero}/{len(alphas)} px with alpha > 10 "
          f"(min={min(alphas)}, max={max(alphas)}, mean={sum(alphas)/len(alphas):.2f})")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} <src.png> <out.png>")
    extract(sys.argv[1], sys.argv[2])
