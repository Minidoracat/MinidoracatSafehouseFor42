"""地契圖示（8 級）：封蠟地契，使用者 2026-10-13 從四個候選選 A。

在 repo 根目錄執行：py -3 scripts/icons/build_deed_icons.py
輸出 MOD/MinidoracatSafehouseFor42/Contents/mods/MinidoracatSafehouseFor42/42/media/textures/Item_MinidoracatSafehouseDeed<N>.png
（物品腳本 Icon = MinidoracatSafehouseDeed<N>）。規格照原版：32×32、透明底、內容約 28×28 置中、1 px 深色外框。
每張都檢查：32×32 RGBA、alpha 只有 0／255、不超過 24 色。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from pix import BOLD, Icon, glyph_size, luma, tier  # noqa: E402

OUT = os.path.join(HERE, "..", "..", "MOD", "MinidoracatSafehouseFor42", "Contents", "mods", "MinidoracatSafehouseFor42",
                   "42", "media", "textures")
MAX_COLORS = 24

PARCH = {"p": (226, 204, 152), "pl": (243, 230, 196), "pd": (190, 164, 112), "pf": (170, 142, 92)}
INK = (107, 74, 46)
HOUSE = ["....#....", "...###...", "..#####..", ".#######.", "#########", ".#######.", ".###.###.", ".###.###."]
DARK_DIGIT = 0.65    # 比這亮的等級色（金、青）配近黑數字，其餘配白字


def deed(n):
    """三摺羊皮紙、上方小屋徽記，右下角等級色封蠟與緞帶，蠟上是等級數字。"""
    t = tier(n)
    light = luma(t["t"]) >= DARK_DIGIT
    ic = Icon({**PARCH, "ink": INK, "t": t["t"], "tl": t["tl"], "td": t["td"], "tdd": t["tdd"],
               "dg": (40, 30, 22) if light else (250, 246, 236)})
    ic.frame(-12, dx=-2.0, dy=-0.5)
    ic.rect(3.5, 0.5, 22.5, 26.5, "p")
    for y in (9.0, 17.5):                 # 摺痕
        ic.rect(3.5, y, 22.5, y + 1.0, "pd")
        ic.rect(3.5, y + 1.0, 22.5, y + 2.0, "pl")
    for y in (12.5, 15.0):                # 文字線
        ic.rect(6.5, y, 15.5, y + 1.0, "pf")
    ic.frame(0)
    ic.line(15.5, 21, 13.0, 27.6, 2.6, "td")   # 封蠟下的緞帶
    ic.line(21.5, 21, 24.0, 27.6, 2.6, "td")
    ic.ellipse(18.6, 18.4, 7.9, 7.6, "tdd")
    ic.ellipse(18.6, 18.4, 6.9, 6.6, "t")
    ic.down()
    ic.edges("p", hi="pl", lo="pd")
    ic.glyph(HOUSE, 7, 2, "ink")
    for x, y in ((14, 13), (15, 12), (16, 12), (13, 14), (13, 15), (17, 12)):   # 蠟的反光
        if ic.get(x, y) == ic.idx["t"]:
            ic.put(x, y, "tl")
    rows = BOLD[n]
    gw, gh = glyph_size(rows)
    ic.glyph(rows, 19 - gw // 2, 19 - gh // 2, "dg", shadow=None if light else "tdd")
    return ic.image()


def check(img, label):
    assert img.size == (32, 32) and img.mode == "RGBA", label
    assert set(img.getchannel("A").tobytes()) <= {0, 255}, f"{label}: alpha not binary"
    n = sum(1 for _, p in img.getcolors(1024) if p[3])
    assert n <= MAX_COLORS, f"{label}: {n} colours"


def main():
    for n in range(1, 9):
        img = deed(n)
        check(img, f"Deed{n}")
        img.save(os.path.join(OUT, f"Item_MinidoracatSafehouseDeed{n}.png"))
    print("8 deed icons ->", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
