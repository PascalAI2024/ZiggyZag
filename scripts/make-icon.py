#!/usr/bin/env python3
"""Render docs/assets/ziggyzag-logo.svg into a multi-size Windows .ico.

Asset-build tooling only (Pillow + numpy at generation time) — it produces a
committed binary (assets/ziggyzag.ico); ZiggyZag itself keeps zero runtime
dependencies. The logo is a small set of geometric primitives, transcribed
here 1:1 from the SVG (viewBox 0 0 512 512) so the icon stays faithful to the
brand mark without needing an external SVG rasterizer.

Usage:  python scripts/make-icon.py
Output: assets/ziggyzag.ico  +  assets/ziggyzag-256.png (preview)
"""
from __future__ import annotations
import os
import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets")
S = 4                      # supersample factor
N = 512 * S                # working canvas (square, SVG viewBox is 512)


def hx(c: str):
    c = c.lstrip("#")
    return (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))


def sc(v: float) -> float:
    return v * S


def linear_gradient(p1, p2, stops):
    """RGB array (N,N,3) of a userSpaceOnUse linear gradient in 512-space."""
    x1, y1 = sc(p1[0]), sc(p1[1])
    x2, y2 = sc(p2[0]), sc(p2[1])
    ax, ay = x2 - x1, y2 - y1
    L2 = ax * ax + ay * ay
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float64)
    t = (((xx - x1) * ax) + ((yy - y1) * ay)) / L2
    t = np.clip(t, 0.0, 1.0)
    offs = [s[0] for s in stops]
    cols = np.array([hx(s[1]) for s in stops], dtype=np.float64)
    out = np.zeros((N, N, 3), dtype=np.float64)
    for ch in range(3):
        out[..., ch] = np.interp(t, offs, cols[:, ch])
    return out.astype(np.uint8)


def shape_mask(draw_fn):
    """L-mode mask produced by draw_fn(ImageDraw) at full opacity."""
    m = Image.new("L", (N, N), 0)
    draw_fn(ImageDraw.Draw(m))
    return m


def paste_solid(img, mask, color):
    layer = Image.new("RGBA", (N, N), color + (255,))
    img.paste(layer, (0, 0), mask)


def paste_gradient(img, mask, grad_rgb):
    layer = Image.fromarray(
        np.dstack([grad_rgb, np.full((N, N), 255, np.uint8)]), "RGBA"
    )
    img.paste(layer, (0, 0), mask)


def poly(pts):
    return [(sc(x), sc(y)) for x, y in pts]


def render() -> Image.Image:
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # 1. Rounded panel with diagonal gradient + border stroke.
    px, py, pw, ph, prx = 42, 54, 428, 404, 38
    panel_box = [sc(px), sc(py), sc(px + pw), sc(py + ph)]
    panel_mask = shape_mask(
        lambda d: d.rounded_rectangle(panel_box, radius=sc(prx), fill=255)
    )
    paste_gradient(
        img, panel_mask,
        linear_gradient((64, 40), (448, 472),
                        [(0.0, "#151A28"), (1.0, "#0C1018")]),
    )
    ImageDraw.Draw(img).rounded_rectangle(
        panel_box, radius=sc(prx), outline=hx("#2B3447") + (255,),
        width=int(sc(12)),
    )

    d = ImageDraw.Draw(img)

    # 2. Title bar.
    d.rounded_rectangle(
        [sc(76), sc(92), sc(76 + 360), sc(92 + 44)],
        radius=sc(12), fill=hx("#20283A") + (255,),
    )

    # 3. Traffic dots.
    for cx, col in ((106, "#FF6B6B"), (132, "#FFD166"), (158, "#35D0BA")):
        d.ellipse(
            [sc(cx - 8), sc(114 - 8), sc(cx + 8), sc(114 + 8)],
            fill=hx(col) + (255,),
        )

    # 4. The double-Z mark, gradient-filled.
    z_pts = [(138, 180), (354, 180), (228, 296), (366, 296), (366, 336),
             (150, 336), (276, 220), (138, 220), (138, 180)]
    z_mask = shape_mask(lambda dr: dr.polygon(poly(z_pts), fill=255))
    paste_gradient(
        img, z_mask,
        linear_gradient((134, 132), (384, 386),
                        [(0.0, "#F7A41D"), (0.52, "#35D0BA"), (1.0, "#8B5CF6")]),
    )

    d = ImageDraw.Draw(img)
    # 5. Two bars under the mark.
    d.rectangle([sc(156), sc(354), sc(356), sc(386)], fill=hx("#E8EDF7") + (255,))
    d.rectangle([sc(156), sc(404), sc(278), sc(424)], fill=hx("#657089") + (255,))

    # 6. Round-capped chevron prompt caret.
    cv = poly([(104, 352), (138, 386), (104, 420)])
    d.line(cv, fill=hx("#35D0BA") + (255,), width=int(sc(18)), joint="curve")
    r = sc(9)
    for x, y in cv:  # round caps + join
        d.ellipse([x - r, y - r, x + r, y + r], fill=hx("#35D0BA") + (255,))

    return img


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    master = render().resize((1024, 1024), Image.LANCZOS)
    preview = master.resize((256, 256), Image.LANCZOS)
    preview.save(os.path.join(OUT_DIR, "ziggyzag-256.png"))
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48),
             (64, 64), (128, 128), (256, 256)]
    master.save(os.path.join(OUT_DIR, "ziggyzag.ico"), format="ICO", sizes=sizes)
    print("wrote", os.path.join(OUT_DIR, "ziggyzag.ico"), "sizes", sizes)


if __name__ == "__main__":
    main()
