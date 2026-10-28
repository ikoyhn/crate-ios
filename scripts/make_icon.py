"""Draws the app icon: vinyl records standing in an amber crate, on Crate's warm charcoal.
Usage: make_icon.py <output.png>   (needs Pillow; writes a 1024x1024 PNG with no transparency)"""
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 4  # drawn at 4x and scaled down, for smooth edges
W = 1024 * S


def px(v):
    return int(v * S)


def rgb(h):
    return ((h >> 16) & 255, (h >> 8) & 255, h & 255)


def vertical_gradient(size, top, bottom):
    w, h = size
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        g.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return g.resize((w, h))


# Canvas: charcoal, a touch lighter at the top, with an amber glow behind the crate
img = vertical_gradient((W, W), rgb(0x232120), rgb(0x0E0E0E))
glow = Image.new("L", (W, W), 0)
ImageDraw.Draw(glow).ellipse([px(150), px(260), px(874), px(984)], fill=120)
glow = glow.filter(ImageFilter.GaussianBlur(px(150)))
img = Image.composite(Image.new("RGB", (W, W), rgb(0xF97316)), img, glow)

draw = ImageDraw.Draw(img)

# Records, back to front: dark vinyl with fine grooves and a warm label
records = [  # centre x, centre y, radius, label colour
    (352, 478, 212, 0xF59E0B),
    (672, 478, 212, 0xFB7185),
    (512, 400, 236, 0xF97316),
]
for cx, cy, r, label in records:
    shadow = Image.new("L", (W, W), 0)
    ImageDraw.Draw(shadow).ellipse([px(cx - r), px(cy - r + 14), px(cx + r), px(cy + r + 14)], fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(px(18)))
    img = Image.composite(Image.new("RGB", (W, W), (0, 0, 0)), img, shadow)
    draw = ImageDraw.Draw(img)
    draw.ellipse([px(cx - r), px(cy - r), px(cx + r), px(cy + r)], fill=rgb(0x0B0B0B))
    for gr in range(r - 14, 92, -16):  # grooves
        draw.ellipse([px(cx - gr), px(cy - gr), px(cx + gr), px(cy + gr)], outline=rgb(0x1E1E1E), width=px(2))
    # a soft sheen across the top left of the vinyl
    sheen = Image.new("L", (W, W), 0)
    ImageDraw.Draw(sheen).pieslice([px(cx - r + 10), px(cy - r + 10), px(cx + r - 10), px(cy + r - 10)],
                                   200, 250, fill=40)
    sheen = sheen.filter(ImageFilter.GaussianBlur(px(10)))
    img = Image.composite(Image.new("RGB", (W, W), (255, 255, 255)), img, sheen)
    draw = ImageDraw.Draw(img)
    lr = 74
    draw.ellipse([px(cx - lr), px(cy - lr), px(cx + lr), px(cy + lr)], fill=rgb(label))
    draw.ellipse([px(cx - 12), px(cy - 12), px(cx + 12), px(cy + 12)], fill=rgb(0x0B0B0B))

# Crate front: a soft shadow above it onto the records, then the amber box with slats and a handle
x0, y0, x1, y1, rad = 150, 572, 874, 892, 56
shadow = Image.new("L", (W, W), 0)
ImageDraw.Draw(shadow).rounded_rectangle([px(x0), px(y0 - 26), px(x1), px(y1)], px(rad), fill=170)
shadow = shadow.filter(ImageFilter.GaussianBlur(px(22)))
img = Image.composite(Image.new("RGB", (W, W), (0, 0, 0)), img, shadow)

box = vertical_gradient((px(x1 - x0), px(y1 - y0)), rgb(0xFB8A2E), rgb(0xE35A0B))
mask = Image.new("L", box.size, 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, box.size[0] - 1, box.size[1] - 1], px(rad), fill=255)
img.paste(box, (px(x0), px(y0)), mask)
draw = ImageDraw.Draw(img)

# top edge highlight, slat grooves, handle cut-out
draw.rounded_rectangle([px(x0 + 34), px(y0 + 10), px(x1 - 34), px(y0 + 20)], px(5), fill=rgb(0xFDA35C))
for sy in (750, 822):
    draw.rounded_rectangle([px(x0 + 40), px(sy), px(x1 - 40), px(sy + 10)], px(5), fill=rgb(0xC2470A))
draw.rounded_rectangle([px(422), px(626), px(602), px(682)], px(28), fill=rgb(0x2A1406))

img = img.resize((1024, 1024), Image.LANCZOS)
img.save(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png", optimize=True)
