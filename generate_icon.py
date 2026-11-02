"""Rebuild assets/icon.ico as a proper multi-resolution icon.

The old file held a single 256x256 PNG-compressed frame. Windows renders a
shortcut/taskbar icon from the 16/32/48 frames, and with none of those present
the shell fell back to a generic icon. System.Drawing.Icon could not even
decode the file ("Requested range extends past the end of the array").

Small sizes use the crescent-and-pause mark, the part that stays legible at a
glance; large sizes use the full artwork.

Run:  python generate_icon.py
"""
import os
from PIL import Image

BASE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(BASE, "assets", "icon.png")
DEST = os.path.join(BASE, "assets", "icon.ico")

SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]

src = Image.open(SRC).convert("RGBA")
W, H = src.size

# The crescent-and-pause mark sits in the upper middle of the artwork.
mark = src.crop((int(W * 0.35), int(H * 0.19), int(W * 0.71), int(H * 0.55)))

frames = []
for size in SIZES:
    base = mark if size[0] <= 48 else src
    # square crop so nothing is squashed
    w, h = base.size
    if w > h:
        left = (w - h) // 2
        base = base.crop((left, 0, left + h, h))
    elif h > w:
        top = (h - w) // 2
        base = base.crop((0, top, w, top + w))
    frame = base.resize(size, Image.LANCZOS)
    frames.append(frame)
    print(f"  frame {size[0]:>3}x{size[0]:<3} <- {'mark' if size[0] <= 48 else 'full'}")

frames[-1].save(
    DEST,
    format="ICO",
    sizes=SIZES,
    append_images=frames[:-1],
    # BMP frames, not PNG: the Windows shell is happy with either, but
    # System.Drawing.Icon cannot decode PNG-compressed frames at all and
    # renders them as noise.
    bitmap_format="bmp",
)

with Image.open(DEST) as ico:
    print(f"\nwrote {DEST} ({os.path.getsize(DEST)} bytes)")
    print("  ico sizes:", sorted(ico.ico.sizes()))
print("  decodes OK")
