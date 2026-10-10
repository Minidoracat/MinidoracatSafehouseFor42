# -*- coding: utf-8 -*-
"""發版前驗證閘門：一次跑完全部靜態檢查，任一失敗以非零碼結束。

用法（repo 根目錄或任意位置）：
    python scripts/verify_mod.py

零設定：自動偵測 MOD/<folder>/Contents/mods/<folder>/42/。
涵蓋的檢查與其對應的實際事故（皆有反編譯出處，詳見 AGENTS.md 踩坑錄）：

  1. luac -p 語法        — 需要 PATH 有 luac；沒有則列為 SKIP 而非 PASS
 1b. 每個函式的累計 local — Debug 用固定 200 格記錄宣告；含離開作用域的變數，預算 190
  2. BOM / CRLF          — 有 BOM 或 CRLF 的翻譯檔會被引擎「靜默忽略」
  3. 翻譯鍵集一致          — 缺鍵的語系會顯示原始 key
  4. 裸 % 檢查           — 42.20.1 起 formatted() 遇裸 % 崩潰；只允許 %1-%9 與 %%
  5. Kahlua 禁用全域       — next/xpcall 不存在（BaseLib 未註冊），呼叫→
                           「Object tried to call nil」。luac 與標準 Lua 測試都攔不住
                           （語法合法、標準 Lua 有這些函式），只能靜態掃描
                           assert 不在此列：遊戲根目錄 stdlib.lua 以 Lua 定義，Kahlua 可用
  6. table.sort 禁用      — Kahlua 的 sort 是遞迴 quicksort（coroutine 堆疊上限 3000），
                           已排序輸入退化 O(n) 深度、數百筆即溢位；一律用迭代 merge sort
  7. MOD/ 樹雜物          — .omc/.claude/.gitnexus 目錄與 .gitkeep 檔；Workshop 整包上傳不看 .gitignore
 7b. mod.info 多值欄位語法 — require/incompatible/load order 只接受逗號且 key 緊貼 =
  8. 佔位符殘留            — {{TOKEN}} 漏替換
  9. Steam 描述位元組      — 各語言 ≤8000 UTF-8 bytes（中日文 3 bytes/字，容易低估）
 10. 沙盒選項翻譯配對       — 每個 option 要有 Sandbox_<translation> 標題＋ _tooltip＋分頁名
 11. CHANGELOG 洩漏掃描     — bullet 會被整段貼到公開的 Workshop 更新說明；掃基礎設施
                           樣式（/home/ 路徑、IP、SteamID64、ssh、主機名）當最後防線。
                           攻擊配方與玩家識別資訊機器認不出來，靠撰寫規則（AGENTS.md）
 12. craftRecipe 腳本       — module Base、必要欄位、輸入行 token、物品存在、OnTest／OnAddToMenu 函式存在
                           （OnAddToMenu 不得有點號）、每個 Translate 資料夾的 Recipes.json 都有配方名；
                           解析錯誤整條配方靜默消失、找不到 OnTest 直接放行、點號 OnAddToMenu 整條永遠被藏

新增檢查時：同步把對應的坑記進 AGENTS.md 踩坑錄，並依「踩坑進化協議」回流到
pz-mod-template（見 AGENTS.md）。
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

passed, failed, skipped = [], [], []

# 豁免清單（選用）：scripts/verify_ignore.txt，每行一個子字串樣式（# 開頭為註解）。
# 命中樣式的 finding 會列出但不計 FAIL——用於「已逐一查證屬合理例外」的殘留
# （例：翻譯包鏡像了來源 MOD 原文的裸 %）。每個樣式旁必須有註解說明查證依據。
IGNORE_PATTERNS = []
_ign = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify_ignore.txt")
if os.path.isfile(_ign):
    with open(_ign, encoding="utf-8") as _fh:
        for _line in _fh:
            _line = _line.strip()
            if _line and not _line.startswith("#"):
                IGNORE_PATTERNS.append(_line)


def ok(label):
    passed.append(label)
    print(f"  PASS  {label}")


def fail(label, details=None):
    details = details or []
    kept = [d for d in details if not any(p in d for p in IGNORE_PATTERNS)]
    waived = [d for d in details if any(p in d for p in IGNORE_PATTERNS)]
    for d in waived:
        print(f"  WAIVE {label}: {d}（verify_ignore.txt 豁免）")
    if not kept:
        if waived:
            ok(f"{label}（{len(waived)} 筆豁免）")
        else:
            ok(label)
        return
    failed.append(label)
    print(f"  FAIL  {label}")
    for d in kept:
        print(f"        {d}")


def skip(label, why):
    skipped.append(label)
    print(f"  SKIP  {label} — {why}")


def find_media():
    hits = []
    mod_root = os.path.join(REPO, "MOD")
    if os.path.isdir(mod_root):
        for folder in os.listdir(mod_root):
            p = os.path.join(mod_root, folder, "Contents", "mods")
            if not os.path.isdir(p):
                continue
            for inner in os.listdir(p):
                media = os.path.join(p, inner, "42", "media")
                if os.path.isdir(media):
                    hits.append(media)
    return hits


def iter_files(root, exts):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git",)]
        for name in files:
            if os.path.splitext(name)[1] in exts:
                yield os.path.join(base, name)


def lua_local_issues(listing):
    # 家族 190 預算；不能只看 main，也不能以同時活躍的 slots 取代累計 locals。
    # 照 MinidoracatEconomyFor42 scripts/verify_mod.py 第 1b 項移植（Kahlua FuncState.java:25-31、LexState.java:666-696）。
    summaries = re.findall(
        r"^(?:main|function) <([^\n]+)>[^\n]*\n[^\n]*?(\d+) locals?\b",
        listing, re.MULTILINE)
    if not summaries:
        return ["luac 未提供可辨識的函式摘要"]
    return [f"{source}: {count} locals（>190，Kahlua Debug 上限 200）"
            for source, count in summaries if int(count) > 190]


def self_test_lua_limits():
    compiler = shutil.which("luac")
    if not compiler:
        raise RuntimeError("local 邊界測試需要 luac")
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "local limits.lua")
        for name, count, nested, reject in (
                ("at-budget", 190, False, False),
                ("over-budget", 191, False, True),
                ("nested-expired-locals", 201, True, True)):
            source = "do local value = 1 end\n" * count
            if nested:
                source = "local function nested()\n" + source + "end\n"
            with open(path, "w", encoding="utf-8", newline="\n") as stream:
                stream.write(source)
            result = subprocess.run([compiler, "-p", "-l", path], capture_output=True,
                                    text=True, encoding="utf-8", errors="replace", check=True)
            if bool(lua_local_issues(result.stdout)) != reject:
                raise AssertionError(name)
    if not lua_local_issues(""):
        raise AssertionError("missing compiler summary must fail closed")
    print("PASS Lua local 邊界：190／191、內層函式的失效作用域、缺少編譯摘要")


if __name__ == "__main__" and "--self-test-lua-limits" in sys.argv:
    self_test_lua_limits()
    sys.exit(0)


MEDIA_DIRS = find_media()
if not MEDIA_DIRS:
    print("找不到 MOD/*/Contents/mods/*/42/media，中止")
    sys.exit(2)

LUA_FILES = [f for m in MEDIA_DIRS for f in iter_files(os.path.join(m, "lua"), {".lua"})
             if os.path.isdir(os.path.join(m, "lua"))]

# ---- 1. luac 語法＋1b. Kahlua local 預算 ----
luac = shutil.which("luac")
if not luac:
    skip("Lua 語法（luac -p）", "PATH 沒有 luac")
    skip("Kahlua local 預算（每個函式 ≤190）", "PATH 沒有 luac")
else:
    bad, bad_limits = [], []
    for f in LUA_FILES:
        r = subprocess.run([luac, "-p", "-l", f], capture_output=True,
                           text=True, encoding="utf-8", errors="replace")
        if r.returncode != 0:
            bad.append(r.stderr.strip().splitlines()[-1] if r.stderr else f)
            bad_limits.append(f"{os.path.relpath(f, REPO)}: 語法失敗，無法檢查 local 預算")
        else:
            bad_limits.extend(lua_local_issues(r.stdout))
    fail("Lua 語法（luac -p）", bad) if bad else ok(f"Lua 語法（luac -p，{len(LUA_FILES)} 檔）")
    fail("Kahlua local 預算（每個函式 ≤190）", bad_limits) if bad_limits \
        else ok("Kahlua local 預算（每個函式 ≤190）")

# ---- 2. BOM / CRLF ----
bad = []
for m in MEDIA_DIRS:
    for f in iter_files(m, {".lua", ".json", ".txt"}):
        with open(f, "rb") as fh:
            data = fh.read()
        rel = os.path.relpath(f, REPO)
        if data.startswith(b"\xef\xbb\xbf"):
            bad.append(f"BOM: {rel}")
        if b"\r" in data:
            bad.append(f"CRLF: {rel}")
fail("BOM / CRLF（42/media 下）", bad) if bad else ok("BOM / CRLF（42/media 下）")

# ---- 3+4. 翻譯鍵集一致 / 裸 % ----
# 裸 % 的判定分兩種模式：
#   嚴格（家族自製 MOD，語系含 EN 等四語）：只認引擎 Translator.formatted() 的 %1-%9 與 %%
#   寬容（翻譯包，語系 ⊆ {CH,CN}）：另接受 printf 指令（%s/%d/%.1f…）——第三方 MOD 常用
#     string.format(getText(...)) 消費譯文，這時保留 %d 才是對的，逸出反而弄壞
# 刻意不含 printf 旗標字元（-+空白#0）：含空白旗標會讓「50% done」的「% d」被解析成
# 合法指令而漏抓——翻譯實務上只會出現簡單的 %s/%d/%.1f，罕見旗標用法交給豁免清單
PRINTF_RE = re.compile(r"%\d*(?:\.\d+)?[sdifuxXcqgGeE]")


def find_bare_pct(value, tolerant):
    s = str(value)
    i = 0
    while i < len(s):
        if s[i] != "%":
            i += 1
            continue
        if i + 1 < len(s) and s[i + 1] in "123456789%":
            i += 2          # 消耗合法配對——lookahead 不消耗會把 "40%%" 誤報（踩過）
            continue
        if tolerant:
            mm = PRINTF_RE.match(s, i)
            if mm:
                i = mm.end()
                continue
        return True
    return False


for m in MEDIA_DIRS:
    troot = os.path.join(m, "lua", "shared", "Translate")
    if not os.path.isdir(troot):
        continue
    langs = sorted(d for d in os.listdir(troot) if os.path.isdir(os.path.join(troot, d)))
    tolerant = set(langs) <= {"CH", "CN"}   # 翻譯包偵測
    names = sorted({n for l in langs for n in os.listdir(os.path.join(troot, l)) if n.endswith(".json")})
    mismatch, badpct, broken = [], [], []
    for n in names:
        keysets = {}
        for l in langs:
            p = os.path.join(troot, l, n)
            if not os.path.isfile(p):
                mismatch.append(f"{n}: {l} 缺檔")
                continue
            try:
                with open(p, encoding="utf-8") as fh:
                    data = json.load(fh)
            except Exception as e:
                broken.append(f"{l}/{n}: {e}")
                continue
            keysets[l] = set(data)
            for k, v in data.items():
                if find_bare_pct(v, tolerant):
                    badpct.append(f"{l}/{n} 的 {k}")
        if len(keysets) > 1:
            base = next(iter(keysets.values()))
            for l, ks in keysets.items():
                if ks != base:
                    mismatch.append(f"{n}: {l} 鍵集不一致（差 {len(ks ^ base)} 鍵）")
    if broken:
        fail("翻譯 JSON 可解析", broken)
    else:
        ok("翻譯 JSON 可解析")
    fail("翻譯鍵集一致", mismatch) if mismatch else ok(f"翻譯鍵集一致（{'/'.join(langs)}）")
    pct_label = "翻譯值無裸 %（翻譯包模式：另接受 printf 指令）" if tolerant else "翻譯值無裸 %（僅 %1-%9 與 %%）"
    fail(pct_label, sorted(set(badpct))) if badpct else ok(pct_label)

# ---- 4b. Lua 字串字面值不得含非 ASCII ----
# 照 MinidoracatEconomyFor42 scripts/verify_mod.py 第 12 項移植。Kahlua 的 LexState 以 Reader 讀入 char 卻用 byte[] 存 token
# （LexState.java:70,178,194-199），任何 code point > 255 的字面值到執行期都是亂碼（家族 pitfalls.md「非 ASCII 字串字面值」）。
# Safehouse sh-mig-1011a 實踩：遷移候選報告的中文檔頭被截出單獨的 \r，operator 照抄成 selection 後整份被判 BAD_LINE。
# 玩家可見文字一律走 Translate/<LANG>/*.json；註解不受影響（先剝掉再掃）。
_LONG_COMMENT = re.compile(r"--\[(=*)\[.*?\]\1\]", re.DOTALL)
_LONG_STRING = re.compile(r"\[(=*)\[.*?\]\1\]", re.DOTALL)
_SHORT_STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'')
nonascii = []
for f in LUA_FILES:
    rel = os.path.relpath(f, REPO)
    with open(f, encoding="utf-8", errors="replace") as fh:
        src = fh.read()
    src = _LONG_COMMENT.sub(lambda mm: "\n" * mm.group().count("\n"), src)
    for mm in _LONG_STRING.finditer(src):
        if any(ord(ch) > 127 for ch in mm.group()):
            nonascii.append(f"{rel}:{src.count(chr(10), 0, mm.start()) + 1}: 長字串含非 ASCII")
    src = _LONG_STRING.sub(lambda mm: "\n" * mm.group().count("\n"), src)
    for lineno, line in enumerate(src.split("\n"), 1):
        code = line.split("--", 1)[0]
        for mm in _SHORT_STRING.finditer(code):
            if any(ord(ch) > 127 for ch in mm.group()):
                nonascii.append(f"{rel}:{lineno}: {mm.group()[:30]}")
fail("Lua 字串字面值純 ASCII（Kahlua 截斷）", nonascii) if nonascii \
    else ok(f"Lua 字串字面值純 ASCII（{len(LUA_FILES)} 檔）")

# ---- 5+6. Kahlua 禁用全域 / table.sort ----
FORBIDDEN = ("next", "xpcall")
# os 只有 time／date／difftime（OsLib.java:322-324）：os.clock 在 Kahlua 是 nil
FORBIDDEN_MEMBERS = ("os.clock",)
hits_forbidden, hits_sort = [], []
for f in LUA_FILES:
    rel = os.path.relpath(f, REPO)
    with open(f, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            code = line.split("--", 1)[0]
            for name in FORBIDDEN:
                for mm in re.finditer(rf"(?<![\w_:.]){name}\s*\(", code):
                    hits_forbidden.append(f"{rel}:{lineno} 用了 {name}()")
            if re.search(r"(?<![\w_])table\.sort\s*\(", code):
                hits_sort.append(f"{rel}:{lineno}")
            for name in FORBIDDEN_MEMBERS:
                if re.search(rf"(?<![\w_]){re.escape(name)}\s*\(", code):
                    hits_forbidden.append(f"{rel}:{lineno} 用了 {name}()")
fail("Kahlua 禁用全域（next/xpcall/os.clock）", hits_forbidden) if hits_forbidden \
    else ok("Kahlua 禁用全域（next/xpcall/os.clock）")
fail("無 table.sort（用迭代 sortSafe，見 AGENTS.md）", hits_sort) if hits_sort \
    else ok("無 table.sort")

# ---- 7. MOD/ 樹雜物 ----
# .gitkeep 也算雜物：引擎會把 MOD 樹內任何檔案列舉成 mod 資源（console 出現
# "overrides media/lua/client/.gitkeep"），且 Workshop 上傳整包不看 .gitignore。
# MOD/ 樹內空目錄不撐 .gitkeep，靠首個實檔建立（引擎對不存在的 lua 子目錄不報錯）。
junk = []
for base, dirs, files in os.walk(os.path.join(REPO, "MOD")):
    for d in list(dirs):
        if d in (".omc", ".claude", ".gitnexus"):
            junk.append(os.path.relpath(os.path.join(base, d), REPO))
            dirs.remove(d)
    for name in files:
        if name == ".gitkeep":
            junk.append(os.path.relpath(os.path.join(base, name), REPO))
fail("MOD/ 樹無雜物（AI 狀態目錄／.gitkeep）", junk) if junk \
    else ok("MOD/ 樹無雜物（AI 狀態目錄／.gitkeep）")

# ---- 7b. mod.info 多值欄位語法 ----
# ChooseGameInfo.java:224/226/228/230 用 contains("key=") 後直接 split(",")。
manifest_bad = []
multi_keys = ("require", "incompatible", "loadModAfter", "loadModBefore")
canonical_re = re.compile(
    r"^\s*(require|incompatible|loadModAfter|loadModBefore)=(.*)$")
for base, _, files in os.walk(os.path.join(REPO, "MOD")):
    if "mod.info" not in files:
        continue
    info = os.path.join(base, "mod.info")
    rel_info = os.path.relpath(info, REPO)
    with open(info, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            for key in multi_keys:
                marker = key + "="
                if marker in line:
                    match = canonical_re.match(line.rstrip("\r\n"))
                    if not match or match.group(1) != key:
                        manifest_bad.append(
                            f"{rel_info}:{lineno}: {key}= 前不得有註解或其他文字")
                        continue
                    value = match.group(2)
                    if "#" in value:
                        manifest_bad.append(
                            f"{rel_info}:{lineno}: mod.info 不支援 {key} 行尾註解")
                    if ";" in value:
                        manifest_bad.append(
                            f"{rel_info}:{lineno}: {key} 多值必須用逗號，不是分號")
                elif re.search(rf"{key}\s+=", line):
                    manifest_bad.append(
                        f"{rel_info}:{lineno}: {key}= 鍵名與等號間不得有空格")
fail("mod.info 多值欄位語法", manifest_bad) if manifest_bad \
    else ok("mod.info 多值欄位語法")

# ---- 8. 佔位符殘留 ----
tokens = []
SELF = os.path.abspath(__file__)   # 本檔 docstring 有 {{TOKEN}} 範例字樣，排除自己
for base, dirs, files in os.walk(REPO):
    dirs[:] = [d for d in dirs if d not in (".git", ".omc", ".claude", ".gitnexus", "__pycache__")]
    for name in files:
        p = os.path.join(base, name)
        if os.path.abspath(p) == SELF:
            continue
        try:
            with open(p, encoding="utf-8") as fh:
                text = fh.read()
        except (UnicodeDecodeError, OSError):
            continue
        for mm in re.finditer(r"\{\{[A-Z_]+\}\}", text):
            tokens.append(f"{os.path.relpath(p, REPO)}: {mm.group()}")
fail("無 {{TOKEN}} 佔位符殘留", tokens) if tokens else ok("無 {{TOKEN}} 佔位符殘留")

# ---- 9. Steam 描述位元組 ----
descs = [f for f in os.listdir(REPO) if f.startswith("STEAM_DESCRIPTION") and f.endswith(".md")]
over = []
for f in descs:
    size = os.path.getsize(os.path.join(REPO, f))
    if size > 8000:
        over.append(f"{f}: {size} bytes（上限 8000）")
if descs:
    fail("Steam 描述 ≤8000 bytes", over) if over else ok(f"Steam 描述 ≤8000 bytes（{len(descs)} 檔）")

# ---- 10. 沙盒選項翻譯配對 ----
for m in MEDIA_DIRS:
    sb = os.path.join(m, "sandbox-options.txt")
    if not os.path.isfile(sb):
        continue
    with open(sb, encoding="utf-8") as fh:
        txt = fh.read()
    opts = set(re.findall(r"translation\s*=\s*(\S+?)\s*,", txt))
    pages = set(re.findall(r"page\s*=\s*(\S+?)\s*,", txt))
    ch = os.path.join(m, "lua", "shared", "Translate", "CH", "Sandbox.json")
    if not os.path.isfile(ch):
        fail("沙盒選項翻譯配對", ["有 sandbox-options.txt 但無 CH/Sandbox.json"])
        continue
    with open(ch, encoding="utf-8") as fh:
        keys = set(json.load(fh))
    miss = [f"缺標題: Sandbox_{o}" for o in opts if f"Sandbox_{o}" not in keys]
    miss += [f"缺 tooltip: Sandbox_{o}_tooltip" for o in opts if f"Sandbox_{o}_tooltip" not in keys]
    miss += [f"缺分頁名: Sandbox_{p}" for p in pages if f"Sandbox_{p}" not in keys]
    fail("沙盒選項翻譯配對", miss) if miss else ok(f"沙盒選項翻譯配對（{len(opts)} 選項）")

# ---- 11. CHANGELOG 洩漏掃描 ----
LEAK_PATTERNS = [
    (re.compile(r"/home/\w+"), "Linux 家目錄路徑"),
    (re.compile(r"[A-Z]:\\Users\\"), "Windows 使用者路徑"),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "IPv4 位址"),
    (re.compile(r"\b7656\d{13}\b"), "SteamID64"),
    (re.compile(r"\bssh\b", re.IGNORECASE), "ssh 字樣"),
    (re.compile(r"pz-?server", re.IGNORECASE), "伺服器主機名"),
]
_cl = os.path.join(REPO, "CHANGELOG.md")
if os.path.isfile(_cl):
    leaks = []
    with open(_cl, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            for pat, desc in LEAK_PATTERNS:
                mm = pat.search(line)
                if mm:
                    leaks.append(f"CHANGELOG.md:{lineno} {desc}（{mm.group()[:40]}）")
    fail("CHANGELOG 無基礎設施洩漏樣式", leaks) if leaks else ok("CHANGELOG 無基礎設施洩漏樣式")

# ---- 翻譯字元：原版字型能顯示 ----
# 原版字型沒有退回機制：字碼超過該字型的最大字碼畫成「?」，範圍內但沒有字形就畫成空白（寬 0）。
# 依 TextManager 的規則找出各語言實際載入的 .fnt（EN/fonts.txt 疊上該語言的 fonts.txt；語言或字級資料夾
# 沒有該檔就退回 EN），取六種 UI 字型與各字級的交集；MOD 自帶 media/fonts 時以 MOD 的為準。
# CN 缺的漢字是原版字型本身的限制（原版簡中介面一樣缺），不計。出處與替代字見 pitfalls.md「原版字型缺很多常用符號」。
PZ_PATH = os.environ.get("PZ_PATH", r"D:\SteamLibrary\steamapps\common\ProjectZomboid")
GLYPH_UI_FONTS = ("Small", "Medium", "Large", "NewSmall", "NewMedium", "NewLarge")
GLYPH_HINTS = {0x2192: "-> 、 > 或改寫", 0x2026: "...", 0x30FB: "·", 0x2022: "·", 0x2014: "改寫",
               0x2013: "～ 或 -", 0x2248: "~ 或「約」", 0x201C: "「", 0x201D: "」", 0x2018: "『", 0x2019: "』"}
_fnt_cache = {}


def _fnt_chars(path):
    if path not in _fnt_cache:
        with open(path, encoding="utf-8", errors="replace") as fh:
            ids = [int(x) for x in re.findall(r"^char id=(\d+)", fh.read(), re.M)]
        _fnt_cache[path] = (frozenset(ids), max(ids) if ids else 0)
    return _fnt_cache[path]


def _font_file(roots, rel):
    for r in roots:
        p = os.path.join(r, rel)
        if os.path.isfile(p):
            return p
    return None


def font_glyphs(roots, lang):
    """該語言所有 UI 字型、字級都畫得出的字集與最小的最大字碼；找不到字型回 None。"""
    names = {}
    for code in ("EN",) if lang == "EN" else ("EN", lang):
        p = _font_file(roots, os.path.join(code, "fonts.txt"))
        if p:
            with open(p, encoding="utf-8", errors="replace") as fh:
                for name, body in re.findall(r"font\s+(\w+)\s*\{([^}]*)\}", fh.read()):
                    f = re.search(r"fnt\s*=\s*([^,\s]+)", body)
                    if f:
                        names[name] = f.group(1)
    sets, tops = [], []
    for ui in GLYPH_UI_FONTS:
        fn = names.get(ui)
        if not fn:
            continue
        for size in (None, "1x", "2x", "3x", "4x"):
            cands = ([os.path.join(lang, size, fn)] if size else []) + [os.path.join(lang, fn)]
            if lang != "EN":
                cands += ([os.path.join("EN", size, fn)] if size else []) + [os.path.join("EN", fn)]
            cands.append(fn)
            path = next((p for p in (_font_file(roots, c) for c in cands) if p), None)
            if path:
                s, top = _fnt_chars(path)
                sets.append(s)
                tops.append(top)
    return (frozenset.intersection(*sets), min(tops)) if sets else None


def _cjk_ideograph(cp):
    return 0x3400 <= cp <= 0x4DBF or 0x4E00 <= cp <= 0x9FFF or 0xF900 <= cp <= 0xFAFF or 0x20000 <= cp <= 0x3FFFF


GLYPH_LABEL = "翻譯字元：原版字型能顯示"
_vanilla_fonts = os.path.join(PZ_PATH, "media", "fonts")
if not os.path.isdir(_vanilla_fonts):
    skip(GLYPH_LABEL, f"找不到遊戲字型 {_vanilla_fonts}（設定 PZ_PATH）")
else:
    _roots = [os.path.join(m, "fonts") for m in MEDIA_DIRS if os.path.isdir(os.path.join(m, "fonts"))] + [_vanilla_fonts]
    _glyph_problems, _cn_missing, _glyphs = [], set(), {}
    for m in MEDIA_DIRS:
        troot = os.path.join(m, "lua", "shared", "Translate")
        if not os.path.isdir(troot):
            continue
        for lang in sorted(os.listdir(troot)):
            ldir = os.path.join(troot, lang)
            if not os.path.isdir(ldir):
                continue
            if lang not in _glyphs:
                _glyphs[lang] = font_glyphs(_roots, lang)
            if _glyphs[lang] is None:
                _glyph_problems.append(f"{lang}：找不到這個語言的字型")
                continue
            have, top = _glyphs[lang]
            for name in sorted(os.listdir(ldir)):
                if not name.endswith(".json"):
                    continue
                try:
                    with open(os.path.join(ldir, name), encoding="utf-8") as fh:
                        data = json.load(fh)
                except Exception:
                    continue  # 解析失敗由翻譯 JSON 檢查回報
                for key, val in data.items():
                    if not isinstance(val, str):
                        continue
                    bad = []
                    for ch in dict.fromkeys(val):
                        cp = ord(ch)
                        if cp < 32 or ch.isspace() or cp in have:
                            continue
                        if lang == "CN" and _cjk_ideograph(cp):
                            _cn_missing.add(ch)
                            continue
                        hint = GLYPH_HINTS.get(cp)
                        bad.append(f"{ch}（U+{cp:04X}）畫成{'?' if cp > top else '空白'}" + (f"，可改 {hint}" if hint else ""))
                    if bad:
                        _glyph_problems.append(f"{lang}/{name} {key}：" + "；".join(bad))
    _label = GLYPH_LABEL + (f"（CN 另有 {len(_cn_missing)} 個漢字原版字型就缺，不計）" if _cn_missing else "")
    fail(_label, _glyph_problems) if _glyph_problems else ok(_label)

# ---- 12. craftRecipe 腳本 ----
# 照 MiniMapWatch verify_mod.py 第 18 項移植。引擎逐 token 解析輸入行（InputScript.java:617-766）：mode 的 key 字面大小寫
# 敏感（:666）、值不分大小寫，非法值與不認得的 token 當下 throw（:687、:762）；flags 走 InputFlag.valueOf，無 trim、大小寫
# 敏感（:744-748）。任一 throw 整條配方消失、玩家端零訊息。配方必須在 module Base（短名引用只查 Base，家族 pitfalls.md
# 「CraftRecipe 學習管線」）；引用的物品要真的存在（本 MOD 的看 scripts、Base.* 看原版 scripts，找不到原版就只驗本 MOD）；
# 配方名在每個 Translate 資料夾的 Recipes.json 都有翻譯（Translator.getRecipeName，Translator.java:691-699）。
# OnTest 以 LuaManager.getFunctionObject 解析點號路徑（CraftRecipe.java:1020），**找不到就放行**（:1028-1031）；
# OnAddToMenu 以 callLuaBool＝env.rawget(名稱) 查（LuaManager.java:5745-5746），點號查不到＝整條配方永遠被藏。
# 兩者的函式名在 Lua 裡用迴圈產生（Recipes.lua），靜態 regex 看不到，所以用標準 lua 實際載入 shared/ 的 Lua 再照引擎的
# 查法解析：OnTest 逐段 rawget、OnAddToMenu 只 rawget 全域。只載 shared：伺服器也要有 OnTest（否則伺服器端放行）。
# 名單抄 AutoDrive verify_mod.py（42.20.4 InputFlag.java 逐字）；引擎升版新增 flag 時這裡會假紅——補名單即可。
VALID_ITEM_MODES = {"use", "keep", "destroy", "useprop1", "useprop2", "keepprop1", "keepprop2", "prop1", "prop2"}
INPUT_FLAGS = {
    "HandcraftOnly", "AutomationOnly", "IsFull", "NotFull", "ItemIsUses", "ItemIsFluid", "ItemIsEnergy", "IsEmpty",
    "NotEmpty", "Prop1", "Prop2", "ToolLeft", "ToolRight", "IsDamaged", "IsUndamaged", "IsWholeFoodItem",
    "IsEmptyContainer", "IsUncookedFoodItem", "IsCookedFoodItem", "IsNotDull", "IsHeadPart", "IsSharpenable",
    "DontPutBack", "InheritColor", "InheritCondition", "InheritEquipped", "InheritSharpness", "InheritHeadCondition",
    "MayDegrade", "MayDegradeLight", "MayDegradeVeryLight", "MayDegradeHeavy", "SharpnessCheck", "InheritUses",
    "InheritUsesAndEmpty", "InheritFood", "InheritFoodAge", "InheritCooked", "InheritModelVariation", "InheritWeight",
    "InheritName", "InheritFreezingTime", "DontInheritCondition", "AllowFrozenItem", "AllowRottenItem", "NoBrokenItems",
    "AllowDestroyedItem", "IsWorn", "IsNotWorn", "InheritAmmunition", "CopyClothing", "AllowFavorite", "InheritFavorite",
    "FakeOutput", "DontReplace", "CanBeDoneFromFloor", "ItemCount", "IsExclusive", "RecordInput", "DontRecordInput",
    "ResearchInput", "IsBlunt", "HasOneUse", "HasNoUses", "IsSealed", "IsNotSealed", "Unseal", "EquipSecondary",
    "SetActivated",
}
RECIPE_REQUIRED = ("timedAction", "time", "category")


def recipe_input_errors(rest):
    """一條輸入行數量之後的 token；回錯誤清單（空＝引擎載得進來）。"""
    errs = []
    for tok in rest.split():
        t = tok.rstrip(",")
        if not t:
            continue
        lb, rb = t.find("["), t.find("]")
        if t.startswith("mode:"):
            if t[5:].lower() not in VALID_ITEM_MODES:
                errs.append(f"`{t}` 非法 mode（InputScript.java:687 throw）")
        elif t.startswith("[") or t.startswith("tags") or t.startswith("flags") or t.startswith("mappers"):
            if lb < 0 or rb < lb:
                errs.append(f"`{t}` 缺括號（substring 越界 throw）")
            elif t.startswith("flags"):
                errs += [f"flags 值 `{e}` 不在 InputFlag（valueOf throw，:748）"
                         for e in t[lb + 1:rb].split(";") if e not in INPUT_FLAGS]
            elif t.startswith("tags"):
                errs += [f"tags 項 `{e}` 空值或空 namespace（ResourceLocation.of throw）"
                         for e in t[lb + 1:rb].split(";") if not e or e.startswith(":") or e.endswith(":")]
        elif t.startswith("categories") or t.startswith("apply:"):
            errs.append(f"`{t}` 不能用在物品輸入（InputScript.java:663、:735 throw）")
        elif not t.startswith("overlayMapper") and not t.startswith("shapedIndex:"):
            errs.append(f"`{t}` 不認得的參數（InputScript.java:762 throw）")
    return errs


def script_blocks(text, kind):
    """(module, 名稱, 內文) 清單；內文含巢狀 inputs/outputs。text 已去掉註解。"""
    out = []
    for mm in re.finditer(r"(?m)^\s*module\s+(\w+)\s*\{", text):
        depth, i, start = 1, mm.end(), mm.end()
        while i < len(text) and depth:
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        body = text[start:i - 1]
        for bm in re.finditer(rf"(?m)^\s*{kind}\s+(\w+)\s*\{{", body):
            d, j = 1, bm.end()
            while j < len(body) and d:
                d += {"{": 1, "}": -1}.get(body[j], 0)
                j += 1
            out.append((mm.group(1), bm.group(1), body[bm.end():j - 1]))
    return out


# 用標準 lua 載入 shared/ 的全部 Lua（require 對應到 shared/），照引擎查法回報找不到的 OnTest／OnAddToMenu；
# 前面由 probe_lua_functions 補上 SHARED、FILES、ONTEST、MENU 四個 local
_PROBE = r"""
isClient = function() return false end
isServer = function() return true end
getText = function(k) return k end
Events = setmetatable({}, { __index = function() return { Add = function() end, Remove = function() end } end })
local done = {}
function require(name)
    if done[name] then return end
    done[name] = true
    assert(loadfile(SHARED .. "/" .. name .. ".lua"))()
end
for _, rel in ipairs(FILES) do
    local ok, e = pcall(require, rel)
    if not ok then print("LOADERR " .. rel .. ": " .. tostring(e)) end
end
local function resolve(path)
    local v = _G
    for part in string.gmatch(path, "[^.]+") do
        if type(v) ~= "table" then return nil end
        v = rawget(v, part)
    end
    return v
end
for _, n in ipairs(ONTEST) do if type(resolve(n)) ~= "function" then print("ONTEST " .. n) end end
for _, n in ipairs(MENU) do if type(rawget(_G, n)) ~= "function" then print("MENU " .. n) end end
"""
_lua = shutil.which("lua")


def lua_list(items):
    return "{" + ",".join(json.dumps(s) for s in items) + "}"


def probe_lua_functions(media, ontest, menu):
    """回 (找不到的 OnTest, 找不到的 OnAddToMenu, 載入錯誤)。"""
    shared = os.path.join(media, "lua", "shared")
    files = sorted(os.path.relpath(f, shared)[:-4].replace(os.sep, "/") for f in iter_files(shared, {".lua"}))
    code = f"local SHARED, FILES, ONTEST, MENU = {json.dumps(shared.replace(os.sep, '/'), ensure_ascii=False)}, " \
           f"{lua_list(files)}, {lua_list(ontest)}, {lua_list(menu)}" + _PROBE
    res = subprocess.run([_lua, "-"], input=code, capture_output=True, text=True, encoding="utf-8")
    out = res.stdout.splitlines() + ([f"LOADERR lua 結束碼 {res.returncode}：{res.stderr.strip()}"] if res.returncode else [])
    pick = lambda tag: [l[len(tag) + 1:] for l in out if l.startswith(tag + " ")]
    return pick("ONTEST"), pick("MENU"), pick("LOADERR")


# 原版物品（Base.*）：掃一次原版 scripts；找不到遊戲就不驗 Base.*（寫進標籤）
_vanilla_items = None
_vs = os.path.join(PZ_PATH, "media", "scripts")
if os.path.isdir(_vs):
    _vanilla_items = set()
    for f in iter_files(_vs, {".txt"}):
        with open(f, encoding="utf-8", errors="replace") as fh:
            _vanilla_items.update(re.findall(r"(?m)^\s*item\s+(\w+)\s*\{?\s*$", fh.read()))

recipe_bad, recipe_names, mod_items = [], [], set()
recipe_text_seen = False   # 腳本裡有 craftRecipe 字樣，卻一條都沒解析到＝解析器跟不上格式，不能當 PASS
for m in MEDIA_DIRS:
    sdir = os.path.join(m, "scripts")
    if not os.path.isdir(sdir):
        continue
    texts, ontest, menu, names = [], {}, {}, []
    for f in iter_files(sdir, {".txt"}):
        with open(f, encoding="utf-8") as fh:
            texts.append((os.path.relpath(f, REPO), re.sub(r"/\*.*?\*/", "", fh.read(), flags=re.S)))
    for _, txt in texts:
        for module, name, _ in script_blocks(txt, "item"):
            mod_items.add(f"{module}.{name}")
    for rel, txt in texts:
        if "craftRecipe" in txt:
            recipe_text_seen = True
        for module, name, body in script_blocks(txt, "craftRecipe"):
            names.append(name)
            where = f"{rel} craftRecipe {name}"
            if module != "Base":
                recipe_bad.append(f"{where}：在 module {module}，要放 module Base")
            for key in RECIPE_REQUIRED:
                if not re.search(rf"(?m)^\s*{key}\s*=", body):
                    recipe_bad.append(f"{where}：缺 {key}")
            ot = re.search(r"(?m)^\s*OnTest\s*=\s*([\w.]+)\s*,", body)
            if ot:
                ontest.setdefault(ot.group(1), []).append(where)
            am = re.search(r"(?m)^\s*OnAddToMenu\s*=\s*([\w.]+)\s*,", body)
            if am and "." in am.group(1):
                recipe_bad.append(f"{where}：OnAddToMenu {am.group(1)} 有點號（callLuaBool 只 rawget 全域，整條永遠被藏）")
            elif am:
                menu.setdefault(am.group(1), []).append(where)
            for k in ("inputs", "outputs"):
                sm = re.search(rf"(?ms)^\s*{k}\s*\{{(.*?)^\s*\}}", body)
                if not sm:
                    recipe_bad.append(f"{where}：缺 {k}")
                    continue
                lines = [l.strip() for l in sm.group(1).splitlines() if l.strip()]
                if not lines:
                    recipe_bad.append(f"{where}：{k} 是空的")
                for line in lines:
                    im = re.match(r"item\s+(\S+)\s+(.*?),?$", line)
                    if not im:
                        recipe_bad.append(f"{where}：{k} 這行看不懂 `{line}`")
                        continue
                    try:
                        float(im.group(1))
                    except ValueError:
                        recipe_bad.append(f"{where}：數量 `{im.group(1)}` 不是數字")
                    rest = im.group(2)
                    if k == "inputs":
                        recipe_bad += [f"{where}：{e}" for e in recipe_input_errors(rest)]
                        refs = [t.strip() for sel in re.findall(r"(?:^|\s)\[([^\]]+)\]", rest) for t in sel.split(";")]
                    else:
                        refs = rest.split()[:1]
                    for ref in refs:
                        mod_name, _, short = ref.rpartition(".")
                        if not mod_name:
                            recipe_bad.append(f"{where}：`{ref}` 要寫完整類型（module.名稱）")
                        elif mod_name == "Base":
                            if _vanilla_items is not None and short not in _vanilla_items:
                                recipe_bad.append(f"{where}：原版沒有 {ref}")
                        elif ref not in mod_items:
                            recipe_bad.append(f"{where}：本 MOD 沒有 {ref}")
    recipe_names += names
    if (ontest or menu) and _lua:
        miss_ot, miss_menu, load_err = probe_lua_functions(m, sorted(ontest), sorted(menu))
        recipe_bad += [f"{w}：OnTest {n} 在 shared/ 的 Lua 找不到（引擎會放行）" for n in miss_ot for w in ontest[n]]
        recipe_bad += [f"{w}：OnAddToMenu {n} 不是 shared/ 的全域函式" for n in miss_menu for w in menu[n]]
        if miss_ot or miss_menu:
            recipe_bad += [f"載入 shared/ Lua 時出錯：{e}" for e in load_err]
    troot = os.path.join(m, "lua", "shared", "Translate")
    for lang in sorted(os.listdir(troot)) if os.path.isdir(troot) else []:
        if not os.path.isdir(os.path.join(troot, lang)):
            continue
        rp = os.path.join(troot, lang, "Recipes.json")
        keys = set()
        if os.path.isfile(rp):
            with open(rp, encoding="utf-8") as fh:
                keys = set(json.load(fh))
        missing = [n for n in names if n not in keys]
        if missing:
            recipe_bad.append(f"{lang}/Recipes.json 缺 {len(missing)} 條：{', '.join(missing[:3])}{' …' if len(missing) > 3 else ''}")
_rl = f"craftRecipe 腳本（{len(recipe_names)} 條：module Base、輸入 token、物品引用、OnTest／OnAddToMenu、各語配方名" + \
      ("" if _vanilla_items is not None else "；找不到原版 scripts，Base.* 未驗") + \
      ("" if _lua else "；PATH 沒有 lua，OnTest／OnAddToMenu 函式未驗") + "）"
if recipe_names:
    fail(_rl, recipe_bad) if recipe_bad else ok(_rl)
elif recipe_text_seen:
    fail("craftRecipe 腳本", ["腳本有 craftRecipe 字樣，但一條都沒解析到"])

# ---- 總結 ----
print()
print(f"PASS {len(passed)} / FAIL {len(failed)} / SKIP {len(skipped)}")
sys.exit(1 if failed else 0)
