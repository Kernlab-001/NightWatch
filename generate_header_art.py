"""Build assets/header-art.png from the README hero banner.

The dialogs draw their header band as a near-black strip with one saturated
orange accent. A full-colour photograph of the banner would put teal and
navy in the middle of that strip, so the banner is not pasted in as it is:
the scene is re-graded into the app's own palette.

What comes out is a 210x70 RGBA strip - the mug, the book and the steam from
the banner, mapped onto a black -> orange -> warm-white ramp. Both edges fade
out, so the strip dissolves into the band instead of ending on a hard
rectangle, and the right-hand fade leaves the status chip on clean black.

The C# side draws this at the right-hand end of the header band. If the file
is missing the band paints exactly as it did before, so the UI never depends
on this asset existing.

Run:  python generate_header_art.py
"""
import os
from PIL import Image

BASE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(BASE, "assets", "banner-hero.png")
DEST = os.path.join(BASE, "assets", "header-art.png")

# The header band is 70px tall; this is how wide the art sits inside it.
BAND_H = 70
ART_W = 210

# The banner's scene: the mug, the rising steam and the open book, down to
# the table surface. 800x320, a 2.5:1 slice of the 16:9 original - wide
# enough that the mug and book sit small inside the strip instead of
# filling it.
CROP = (360, 320, 1160, 640)

# The overall strength of the strip. The band is 70px tall and sits right
# next to the wordmark, so the art has to read as a glow behind the UI
# rather than as a second logo.
STRENGTH = 0.68

# The app's palette: Theme.BgDeep, a deeper orange in the mid-tones, and
# Theme.Cyan (the one saturated orange) reserved for the brightest pixels.
# Nothing in the strip reaches white: a white-hot highlight in a 70px band
# next to white text reads as a rendering fault, not as artwork.
SHADOW = (11, 11, 13)
MIDTONE = (122, 46, 10)
ACCENT = (249, 115, 22)


def ramp(t):
    """Black -> deep orange -> the accent orange, for a luminance of 0..1."""
    t = min(1.0, max(0.0, t))
    if t < 0.72:
        u = t / 0.72
        return tuple(round(SHADOW[i] + (MIDTONE[i] - SHADOW[i]) * u) for i in range(3))
    u = (t - 0.72) / 0.28
    return tuple(round(MIDTONE[i] + (ACCENT[i] - MIDTONE[i]) * u) for i in range(3))


def smoothstep(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def main():
    if not os.path.exists(SRC):
        raise SystemExit("missing source: %s" % SRC)

    src = Image.open(SRC).convert("RGB")
    crop = src.crop(CROP).resize((ART_W, BAND_H), Image.LANCZOS)

    art = Image.new("RGBA", (ART_W, BAND_H))
    px_src = crop.load()
    px_art = art.load()

    for y in range(BAND_H):
        for x in range(ART_W):
            r, g, b = px_src[x, y]
            lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0

            # Warmth: teal pixels have b >= r, so they score zero and fall
            # away to black. Only the amber-lit side of the scene survives.
            warm = max(0.0, min(1.0, (r - b) / 55.0))

            # A hard gamma keeps the mid-tones dark; without it the whole
            # strip sits at half brightness and fights the header text.
            t = lum ** 1.6 * (0.18 + 0.82 * warm)
            rr, gg, bb = ramp(t)

            # Fade in from the left over the first fifth, and fade out to
            # nothing over the last half, so the strip has no visible edges.
            left = smoothstep(x / (ART_W * 0.20))
            right = smoothstep((ART_W - x) / (ART_W * 0.50))
            px_art[x, y] = (rr, gg, bb, round(255 * STRENGTH * left * right))

    art.save(DEST, format="PNG")
    print("wrote %s (%d bytes)" % (DEST, os.path.getsize(DEST)))
    print("  crop %s -> %dx%d" % (str(CROP), ART_W, BAND_H))


if __name__ == "__main__":
    main()
