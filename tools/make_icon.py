#!/usr/bin/env python3
"""Re-letter the DotStrip app icon.

The icon is the panel itself: an 11x11 lattice of round dots over a dark amber
vertical gradient, inside a glossy rounded tile, with one 5x7 glyph lit up. The
glyph art comes from the app's own PixelFontData, so the letter on the icon is
drawn by exactly the same hand as the letters on the board.

Redrawing the whole tile would mean reproducing the rim bevel and the squircle,
which is guesswork. Instead this renders only the lattice *face* twice -- once
with the letter that is in the artwork today, once with the letter we want --
and applies the difference to the existing PNGs. Everything the two renderings
agree on (the rim, the alpha, the background gradient, every dot outside the
glyph) cancels out and survives byte-identical, so any error in the model below
is confined to the dots that actually change.

The constants were measured off icon_512x512@2x.png; `--verify` re-renders the
current letter and reports how far the model lands from the real artwork.

The artwork currently shows a D, so the old letter to pass is D:

    python3 tools/make_icon.py D E          # relight the icon, D -> E
    python3 tools/make_icon.py D --verify   # check the model, write nothing
"""

import argparse
import pathlib
import re
import sys

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
ICONSET = ROOT / "DotStrip/Assets.xcassets/AppIcon.appiconset"
MASTER = ICONSET / "icon_512x512@2x.png"
DOCS_ICON = ROOT / "docs/icon.png"
FONT_DATA = ROOT / "DotStrip/PixelFontData.swift"

# --- geometry, in pixels at the 1024 master size ---------------------------
S = 1024
LATTICE = 11             # dots across, and down
PITCH = 79.543           # centre-to-centre
FIRST = 113.78           # centre of lattice index 0
RADIUS = 33.8            # dot radius
EDGE = 0.9               # width of the dot's soft edge
GLYPH_ROW0, GLYPH_COL0 = 2, 3     # where the 5x7 glyph sits in the lattice

# --- colour, measured per lattice row (the tile is lit from the top) -------
# Unlit dots are flat; one colour each, for lattice rows 0..10.
UNLIT = np.array([
    [51.1, 40.7, 24.2], [48.3, 38.3, 22.4], [45.9, 37.0, 21.5],
    [44.1, 35.4, 20.6], [42.0, 33.7, 19.8], [39.1, 31.9, 19.3],
    [36.4, 29.8, 18.0], [33.7, 27.4, 16.3], [30.6, 24.8, 15.1],
    [27.5, 22.4, 13.3], [24.9, 20.6, 12.3],
])

# A lit dot is a radial gradient: red holds flat while green and blue fall off
# towards the rim, which is what makes the centre read as the hot part of the
# LED. Centre and rim colour, for glyph rows 0..6.
LIT_CENTRE = np.array([
    [244.2, 209.4, 145.4], [237.4, 202.9, 140.6], [228.0, 196.0, 135.8],
    [218.7, 187.6, 131.1], [207.5, 178.0, 124.2], [195.5, 167.0, 117.5],
    [181.9, 155.7, 108.8],
])
LIT_RIM = np.array([        # sampled at d = 31, just inside the soft edge
    [243.8, 185.5, 79.8], [236.7, 180.6, 78.3], [228.4, 174.2, 75.8],
    [218.5, 166.6, 73.0], [207.3, 158.2, 69.6], [194.8, 148.7, 65.6],
    [181.7, 138.5, 61.5],
])

# How far the centre colour has travelled to the rim colour, at d = 0..31. The
# ramp eases in near the middle and then runs straight, and is the same curve
# for every row and both channels, so it is stored once and scaled.
RADIAL = np.array([
    0.0000, 0.0004, 0.0110, 0.0215, 0.0379, 0.0576, 0.0870, 0.1162,
    0.1506, 0.1852, 0.2200, 0.2570, 0.2918, 0.3284, 0.3642, 0.4017,
    0.4402, 0.4780, 0.5142, 0.5522, 0.5896, 0.6271, 0.6653, 0.7023,
    0.7402, 0.7777, 0.8147, 0.8523, 0.8884, 0.9272, 0.9628, 1.0000,
])

# The background only shows in the gaps, and cancels in the difference; it is
# here so the antialiased dot edges blend against the right colour.
BG_TOP, BG_BOT = np.array([35.0, 30.0, 24.0]), np.array([11.0, 9.0, 7.0])

# Lit dots spill a soft amber glow onto the gaps and their unlit neighbours.
GLOW_SIGMA = 32.0
GLOW_AMP = np.array([84.73, 61.44, 15.57])

# The model reproduces the real artwork to about 2.4 rms over the tile's
# interior; anything much worse means the letter we were told is drawn is not
# the letter that is drawn.
BASELINE_RMS_LIMIT = 6.0


def read_glyph(letter):
    """Pull a letter's art out of PixelFontData.swift, top 7 (capital) rows."""
    pattern = re.compile(r'^\s*"(.)"\s*:\s*\[(.*)\],\s*$')
    for line in FONT_DATA.read_text().splitlines():
        m = pattern.match(line)
        if m and m.group(1) == letter:
            rows = re.findall(r'"([.#]*)"', m.group(2))
            if len(rows) < 7:
                sys.exit(f"glyph {letter!r} has only {len(rows)} rows")
            return rows[:7]
    sys.exit(f"no glyph for {letter!r} in {FONT_DATA}")


def blur(a, sigma):
    """Separable Gaussian blur, zero-padded so nothing wraps around."""
    pad = int(4 * sigma) + 1
    ap = np.pad(a, pad)
    m = ap.shape[0]
    k = np.arange(m) - m // 2
    g = np.exp(-0.5 * (k / sigma) ** 2)
    g /= g.sum()
    G = np.fft.rfft(np.fft.ifftshift(g))
    out = np.fft.irfft(np.fft.rfft(ap, axis=1) * G[None, :], n=m, axis=1)
    out = np.fft.irfft(np.fft.rfft(out, axis=0) * G[:, None], n=m, axis=0)
    return out[pad:pad + a.shape[0], pad:pad + a.shape[1]]


def radial_ramp(d):
    """RADIAL, linearly extrapolated past d = 31 to cover the soft edge."""
    tail = RADIAL[-1] + (RADIAL[-1] - RADIAL[-2]) * (d - (len(RADIAL) - 1))
    return np.where(d <= len(RADIAL) - 1, np.interp(d, np.arange(len(RADIAL)), RADIAL), tail)


def render_face(glyph):
    """The lattice face for one glyph: (rgb, lit coverage), both float."""
    y, x = np.mgrid[0:S, 0:S].astype(float)
    face = BG_TOP + (BG_BOT - BG_TOP) * (y / S)[..., None]
    lit_cov = np.zeros((S, S))

    for row in range(LATTICE):
        cy = FIRST + PITCH * row
        for col in range(LATTICE):
            cx = FIRST + PITCH * col
            lo_y, hi_y = int(cy - RADIUS - 2), int(cy + RADIUS + 3)
            lo_x, hi_x = int(cx - RADIUS - 2), int(cx + RADIUS + 3)
            lo_y, lo_x = max(lo_y, 0), max(lo_x, 0)
            hi_y, hi_x = min(hi_y, S), min(hi_x, S)
            if hi_y <= lo_y or hi_x <= lo_x:
                continue

            sl = (slice(lo_y, hi_y), slice(lo_x, hi_x))
            d = np.hypot(x[sl] - cx, y[sl] - cy)
            cov = np.clip((RADIUS + EDGE / 2 - d) / EDGE, 0, 1)

            gr, gc = row - GLYPH_ROW0, col - GLYPH_COL0
            if 0 <= gr < 7 and 0 <= gc < 5 and glyph[gr][gc] == "#":
                t = radial_ramp(d)[..., None]
                colour = LIT_CENTRE[gr] + (LIT_RIM[gr] - LIT_CENTRE[gr]) * t
                lit_cov[sl] = np.maximum(lit_cov[sl], cov)
            else:
                colour = UNLIT[row]

            face[sl] = face[sl] * (1 - cov[..., None]) + colour * cov[..., None]

    face += blur(lit_cov, GLOW_SIGMA)[..., None] * GLOW_AMP * (1 - lit_cov)[..., None]
    return face, lit_cov


def box_down(a, n):
    """Area-average 1024 -> n. Every icon size divides 1024 exactly."""
    f = a.shape[0] // n
    return a.reshape(n, f, n, f, a.shape[2]).mean(axis=(1, 3))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("old", help="letter currently lit in the artwork")
    ap.add_argument("new", nargs="?", help="letter to light instead")
    ap.add_argument("--verify", action="store_true",
                    help="report how well the model reproduces the current icon")
    args = ap.parse_args()
    if not args.verify and args.new is None:
        ap.error("give the letter to light, or pass --verify")

    master = np.array(Image.open(MASTER).convert("RGBA")).astype(float)
    old_face, old_lit = render_face(read_glyph(args.old))

    resid = master[..., :3] - old_face
    # skip the rim, which the model deliberately does not draw: keep only
    # pixels well inside the opaque tile
    inner = blur((master[..., 3] > 254).astype(float), 12) > 0.9995
    rms = float(np.sqrt((resid[inner] ** 2).mean()))

    if args.verify:
        print(f"interior residual: mean {resid[inner].mean(axis=0).round(2)}  "
              f"max |err| {np.abs(resid[inner]).max():.1f}  rms {rms:.2f}")
        on = inner & (old_lit > 0.99)
        print(f"  inside lit dots: max |err| {np.abs(resid[on]).max():.1f}")
        return

    # The difference is only meaningful if `old` really is what is drawn. A
    # wrong letter here -- or a second run of the same command -- would apply
    # the delta on top of the wrong baseline and quietly wreck the artwork.
    if rms > BASELINE_RMS_LIMIT:
        sys.exit(f"the artwork does not look like {args.old!r} "
                 f"(residual rms {rms:.1f} > {BASELINE_RMS_LIMIT}); "
                 f"nothing written")

    new_face, _ = render_face(read_glyph(args.new))
    delta = new_face - old_face
    print(f"delta: max |change| {np.abs(delta).max():.1f}, "
          f"pixels touched {(np.abs(delta).max(axis=2) > 0.5).sum()}")

    targets = sorted(ICONSET.glob("*.png")) + [DOCS_ICON]
    for path in targets:
        im = Image.open(path)
        arr = np.array(im.convert("RGBA")).astype(float)
        n = arr.shape[0]
        arr[..., :3] = np.clip(arr[..., :3] + box_down(delta, n), 0, 255)
        out = Image.fromarray(arr.round().astype(np.uint8), "RGBA")
        info = {k: v for k, v in im.info.items() if k in ("exif", "srgb")}
        out.save(path, **info)
        print(f"  wrote {path.relative_to(ROOT)} ({n}px)")


if __name__ == "__main__":
    main()
