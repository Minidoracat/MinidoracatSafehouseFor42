"""Tiny pixel-icon toolkit: shapes at 8x supersampling into a palette-index canvas, majority-vote down to 28 px
(binary alpha, no blended colours), crisp native-pixel overlays (digits), then a 1 px #1c1a18 outline (MaxFilter)."""
import math

from PIL import Image, ImageDraw, ImageFilter

S = 8          # supersampling factor
N = 28         # content size (vanilla: ~28x28 centred in 32x32)
OUTLINE = (28, 26, 24)

# Hand-placed digits: 6x8, 2 px strokes.
BOLD = {
    1: ["..##..", ".###..", "####..", "..##..", "..##..", "..##..", "..##..", "######"],
    2: [".####.", "##..##", "....##", "...##.", "..##..", ".##...", "##....", "######"],
    3: ["#####.", "....##", "....##", ".####.", "....##", "....##", "....##", "#####."],
    4: ["...##.", "..###.", ".####.", "##.##.", "######", "...##.", "...##.", "...##."],
    5: ["######", "##....", "##....", "#####.", "....##", "....##", "##..##", ".####."],
    6: ["..###.", ".##...", "##....", "#####.", "##..##", "##..##", "##..##", ".####."],
    7: ["######", "....##", "....##", "...##.", "..##..", "..##..", "..##..", "..##.."],
    8: [".####.", "##..##", "##..##", ".####.", "##..##", "##..##", "##..##", ".####."],
}

# Tier ramp (common -> rare): grey, green, blue, purple, red, orange, gold, diamond cyan.
TIER_HEX = ["#9aa1ab", "#4caf50", "#3b7ddd", "#9157d6", "#d6453d", "#ee8a2a", "#e9c23b", "#3fd6e6"]


def hex2rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def shade(rgb, f):
    """f<1 darker (multiply), f>1 lighter (towards white)."""
    if f <= 1:
        return tuple(int(c * f) for c in rgb)
    t = f - 1
    return tuple(int(c + (255 - c) * t) for c in rgb)


def luma(rgb):
    r, g, b = rgb
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255


def tier(n):
    mid = hex2rgb(TIER_HEX[n - 1])
    return {"t": mid, "tl": shade(mid, 1.35), "td": shade(mid, 0.62), "tdd": shade(mid, 0.4)}


class Icon:
    def __init__(self, colors):
        self.names = ["_"] + list(colors)
        self.rgb = [(0, 0, 0)] + [colors[k] for k in colors]
        self.idx = {k: i for i, k in enumerate(self.names)}
        self.hi = Image.new("L", (N * S, N * S), 0)
        self.d = ImageDraw.Draw(self.hi)
        self.T = lambda x, y: (x, y)
        self.px = None

    def add(self, name, rgb):
        if name not in self.idx:
            self.idx[name] = len(self.names)
            self.names.append(name)
            self.rgb.append(rgb)

    # --- transform: rotate local coords by `deg` about (cx, cy), then translate by (dx, dy)
    def frame(self, deg=0.0, cx=14.0, cy=14.0, dx=0.0, dy=0.0):
        a = math.radians(deg)
        ca, sa = math.cos(a), math.sin(a)
        self.T = lambda x, y: (cx + (x - cx) * ca - (y - cy) * sa + dx, cy + (x - cx) * sa + (y - cy) * ca + dy)

    # --- hi-res shapes (unit = one output pixel)
    def poly(self, pts, c):
        self.d.polygon([tuple(v * S for v in self.T(x, y)) for x, y in pts], fill=self.idx[c])

    def rect(self, x0, y0, x1, y1, c):
        self.poly([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], c)

    def ellipse(self, cx, cy, rx, ry, c, n=48):
        self.poly([(cx + rx * math.cos(2 * math.pi * i / n), cy + ry * math.sin(2 * math.pi * i / n)) for i in range(n)], c)

    def line(self, x0, y0, x1, y1, w, c):
        L = math.hypot(x1 - x0, y1 - y0) or 1
        nx, ny = -(y1 - y0) / L * w / 2, (x1 - x0) / L * w / 2
        self.poly([(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)], c)

    # --- 8x -> 28 px majority vote; transparent wins at >= 50 % (binary alpha)
    def down(self):
        src = self.hi.tobytes()
        W = N * S
        self.px = []
        for cy in range(N):
            row = []
            for cx in range(N):
                cnt = [0] * len(self.names)
                for y in range(cy * S, cy * S + S):
                    for v in src[y * W + cx * S:y * W + cx * S + S]:
                        cnt[v] += 1
                clear = cnt[0] * 2 >= S * S
                row.append(0 if clear else max(range(1, len(cnt)), key=lambda i: (cnt[i], -i)))
            self.px.append(row)
        return self

    # --- native pixel helpers (after down)
    def get(self, x, y):
        return self.px[y][x] if 0 <= x < N and 0 <= y < N else 0

    def put(self, x, y, c):
        if 0 <= x < N and 0 <= y < N:
            self.px[y][x] = self.idx[c]

    def edges(self, body, hi=None, lo=None):
        """Outer-edge lighting of colour `body`: hi where top/left touches transparency, lo where bottom/right does."""
        b = self.idx[body]
        src = [r[:] for r in self.px]
        g = lambda x, y: src[y][x] if 0 <= x < N and 0 <= y < N else 0
        for y in range(N):
            for x in range(N):
                if src[y][x] != b:
                    continue
                if lo and (g(x, y + 1) == 0 or g(x + 1, y) == 0):
                    self.px[y][x] = self.idx[lo]
                elif hi and (g(x, y - 1) == 0 or g(x - 1, y) == 0):
                    self.px[y][x] = self.idx[hi]

    def glyph(self, rows, x, y, fg, ring=None, shadow=None):
        """Stamp a bitmap glyph with its top-left at native (x, y). ring: 8-neighbour border colour; shadow: +1,+1 drop."""
        on = {(x + i, y + j) for j, r in enumerate(rows) for i, ch in enumerate(r) if ch == "#"}
        if ring:
            for (u, v) in on:
                for du in (-1, 0, 1):
                    for dv in (-1, 0, 1):
                        if (u + du, v + dv) not in on:
                            self.put(u + du, v + dv, ring)
        if shadow:
            for (u, v) in on:
                if (u + 1, v + 1) not in on:
                    self.put(u + 1, v + 1, shadow)
        for (u, v) in on:
            self.put(u, v, fg)

    def image(self):
        """32x32 RGBA: content centred, 1 px outline."""
        content = Image.new("RGBA", (N, N))
        content.putdata([self.rgb[i] + (255 if i else 0,) for r in self.px for i in r])
        out = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
        out.paste(content, (2, 2))
        alpha = out.getchannel("A")
        ring = Image.eval(alpha.filter(ImageFilter.MaxFilter(3)), lambda v: 255 if v else 0)
        base = Image.new("RGBA", (32, 32), OUTLINE + (0,))
        base.putalpha(ring)
        base.alpha_composite(out)
        return base


def glyph_size(rows):
    return len(rows[0]), len(rows)
