"""Draws the app icon: a 90s retro sunset that's also a record player. The striped sun is the
record (grooves, a spindle) with a chrome tonearm resting on it, over a neon grid horizon.
Usage: make_icon.py <output.png>   (needs Pillow; writes a 1024x1024 PNG with no transparency)"""
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 4  # drawn at 4x and scaled down, for smooth edges
W = 1024 * S


def px(v):
    return int(round(v * S))


def rgb(h):
    return ((h >> 16) & 255, (h >> 8) & 255, h & 255)


def gradient(size, stops):
    """Vertical gradient through (position 0..1, colour) stops."""
    w, h = size
    col = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                f = (t - p0) / max(p1 - p0, 1e-9)
                col.putpixel((0, y), tuple(int(a + (b - a) * f) for a, b in zip(rgb(c0), rgb(c1))))
                break
    return col.resize((w, h))


def glow(img, shape, colour, blur, strength):
    """Add a soft coloured light in the shape of a mask."""
    m = shape.filter(ImageFilter.GaussianBlur(px(blur))).point(lambda v: int(v * strength))
    return Image.composite(Image.new("RGB", img.size, rgb(colour)), img, m)


HORIZON = 700

# Sky: deep indigo to violet to hot pink at the horizon
img = gradient((W, W), [(0, 0x120A2E), (0.42, 0x3B1263), (0.66, 0xB0246E), (HORIZON / 1024, 0xFF5E7A),
                        (HORIZON / 1024 + 0.001, 0x16072E), (1, 0x0A0418)])

# The sun / record
cx, cy, r = 470, 470, 300
disc = Image.new("L", (W, W), 0)
ImageDraw.Draw(disc).ellipse([px(cx - r), px(cy - r), px(cx + r), px(cy + r)], fill=255)
# it sets behind the horizon
ImageDraw.Draw(disc).rectangle([0, px(HORIZON - 4), W, W], fill=0)
img = glow(img, disc, 0xFF4F8B, 70, 0.55)

sun = gradient((W, W), [(0, 0xFFE76A), ((cy - r) / 1024, 0xFFE76A), (cy / 1024, 0xFFA23A),
                        ((cy + r) / 1024, 0xFF3D7F), (1, 0xFF3D7F)])
# Retro stripe cuts across the lower half, thicker towards the bottom
cuts = Image.new("L", (W, W), 255)
d = ImageDraw.Draw(cuts)
y, gap = cy + 40, 8
while y < cy + r:
    d.rectangle([0, px(y), W, px(y + gap)], fill=0)
    y += gap + 30 - gap * 0.6
    gap += 5
sun_mask = ImageChops.multiply(disc, cuts)
img = Image.composite(sun, img, sun_mask)

# Faint grooves, a centre label and the spindle: it's a record
grooves = Image.new("L", (W, W), 0)
g = ImageDraw.Draw(grooves)
for gr in range(r - 22, 96, -18):
    g.ellipse([px(cx - gr), px(cy - gr), px(cx + gr), px(cy + gr)], outline=60, width=px(2.5))
grooves = ImageChops.multiply(grooves, sun_mask)
img = Image.composite(Image.new("RGB", (W, W), rgb(0xB0246E)), img, grooves)
draw = ImageDraw.Draw(img)
draw.ellipse([px(cx - 82), px(cy - 82), px(cx + 82), px(cy + 82)], fill=rgb(0xFF7A45))
draw.ellipse([px(cx - 82), px(cy - 82), px(cx + 82), px(cy + 82)], outline=rgb(0xFFD15C), width=px(5))
draw.ellipse([px(cx - 15), px(cy - 15), px(cx + 15), px(cy + 15)], fill=rgb(0x1A0B33))

# Neon grid floor below the horizon
vx = 512
floor_lines = Image.new("L", (W, W), 0)
fl = ImageDraw.Draw(floor_lines)
for i in range(-14, 15):
    fl.line([(px(vx + i * 26), px(HORIZON)), (px(vx + i * 150), px(1024))], fill=255, width=px(3))
z = 1.0
for _ in range(9):
    yy = HORIZON + (1024 - HORIZON) * (z ** 2.2)
    fl.line([(0, px(yy)), (W, px(yy))], fill=255, width=px(3))
    z -= 0.11
below = Image.new("L", (W, W), 0)
ImageDraw.Draw(below).rectangle([0, px(HORIZON), W, W], fill=255)
floor_lines = ImageChops.multiply(floor_lines, below)
img = glow(img, floor_lines, 0xFF3DCB, 6, 0.9)
img = Image.composite(Image.new("RGB", (W, W), rgb(0xFF6BD9)), img, floor_lines)
# the horizon line itself, glowing cyan
hz = Image.new("L", (W, W), 0)
ImageDraw.Draw(hz).rectangle([0, px(HORIZON - 3), W, px(HORIZON + 3)], fill=255)
img = glow(img, hz, 0x3DE0FF, 14, 1.0)
img = Image.composite(Image.new("RGB", (W, W), rgb(0xB8F4FF)), img, hz)

# Tonearm: pivot at the top right, arm down to a headshell resting on the record's edge
arm = Image.new("L", (W, W), 0)
a = ImageDraw.Draw(arm)
pivot = (846, 214)
elbow = (826, 500)
head = (676, 606)
a.line([px(pivot[0]), px(pivot[1]), px(elbow[0]), px(elbow[1])], fill=255, width=px(22))
a.line([px(elbow[0]), px(elbow[1]), px(head[0]), px(head[1])], fill=255, width=px(22))
a.ellipse([px(elbow[0] - 11), px(elbow[1] - 11), px(elbow[0] + 11), px(elbow[1] + 11)], fill=255)
# headshell: a short, wider block at the end
hs = Image.new("L", (W, W), 0)
ImageDraw.Draw(hs).polygon([(px(x), px(y)) for x, y in [(666, 578), (716, 616), (686, 654), (636, 616)]], fill=255)
arm = ImageChops.lighter(arm, hs)
shadow = arm.filter(ImageFilter.GaussianBlur(px(10)))
img = Image.composite(Image.new("RGB", (W, W), rgb(0x12062A)),
                      img, ImageChops.offset(shadow, px(10), px(14)).point(lambda v: int(v * 0.7)))
chrome = gradient((W, W), [(0, 0xFFFFFF), (0.5, 0xE4D8FF), (1, 0xB9A6E8)])
img = Image.composite(chrome, img, arm)
draw = ImageDraw.Draw(img)
# pivot base and counterweight
draw.ellipse([px(pivot[0] - 54), px(pivot[1] - 54), px(pivot[0] + 54), px(pivot[1] + 54)], fill=rgb(0x2A1550))
draw.ellipse([px(pivot[0] - 54), px(pivot[1] - 54), px(pivot[0] + 54), px(pivot[1] + 54)],
             outline=rgb(0xE4D8FF), width=px(6))
draw.ellipse([px(pivot[0] - 20), px(pivot[1] - 20), px(pivot[0] + 20), px(pivot[1] + 20)], fill=rgb(0xE4D8FF))
draw.line([px(pivot[0]), px(pivot[1] - 50), px(pivot[0]), px(pivot[1] - 80)], fill=rgb(0xE4D8FF), width=px(14))
draw.rounded_rectangle([px(pivot[0] - 26), px(pivot[1] - 120), px(pivot[0] + 26), px(pivot[1] - 76)],
                       px(10), fill=rgb(0xC9B8F2))

img = img.resize((1024, 1024), Image.LANCZOS)
img.save(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png", optimize=True)
