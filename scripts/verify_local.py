# -*- coding: utf-8 -*-
"""Safehouse 專屬的靜態檢查：scripts/verify_mod.py 第 19 項會呼叫；單獨跑 `python scripts/verify_local.py`。
從換成家族模板前的 verify_mod.py 原樣搬來（模板沒有，或條件比模板嚴）：
  - 翻譯鍵放在前綴對應的檔 — UI_／IGUI_／Sandbox_ 鍵放錯檔時畫面顯示鍵名本身
  - Kahlua 禁用全域        — 模板只禁 next/xpcall；這裡另禁 os.clock（Kahlua 的 os 只有 time／date／difftime）
  - craftRecipe 腳本       — module Base、必要欄位、輸入行 token、物品存在、OnTest／OnAddToMenu 函式存在
                           （OnAddToMenu 不得有點號）、每個 Translate 資料夾的 Recipes.json 都有配方名；
                           解析錯誤整條配方靜默消失、找不到 OnTest 直接放行、點號 OnAddToMenu 整條永遠被藏
"""
import json
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

passed, failed = [], []

# 豁免清單與 verify_mod.py 共用：scripts/verify_ignore.txt，每行一個子字串樣式（# 開頭為註解）。
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


MEDIA_DIRS = find_media()
if not MEDIA_DIRS:
    print("找不到 MOD/*/Contents/mods/*/42/media，中止")
    sys.exit(2)

LUA_FILES = [f for m in MEDIA_DIRS for f in iter_files(os.path.join(m, "lua"), {".lua"})
             if os.path.isdir(os.path.join(m, "lua"))]
PZ_PATH = os.environ.get("PZ_PATH", r"D:\SteamLibrary\steamapps\common\ProjectZomboid")

# ---- 翻譯鍵放在前綴對應的檔 ----
# 鍵的前綴決定遊戲從哪個檔讀：放錯檔時畫面顯示鍵名本身（2026-11-22 按鍵設定頁的 UI_ 鍵放在 IG_UI.json）。
# 缺檔與 JSON 解析失敗由 verify_mod.py 的「翻譯鍵集一致」「翻譯 JSON 可解析」回報。
homes = {"UI_": "UI.json", "IGUI_": "IG_UI.json", "Sandbox_": "Sandbox.json"}
for m in MEDIA_DIRS:
    troot = os.path.join(m, "lua", "shared", "Translate")
    if not os.path.isdir(troot):
        continue
    langs = sorted(d for d in os.listdir(troot) if os.path.isdir(os.path.join(troot, d)))
    names = sorted({n for l in langs for n in os.listdir(os.path.join(troot, l)) if n.endswith(".json")})
    misplaced = []
    for n in names:
        for l in langs:
            p = os.path.join(troot, l, n)
            if not os.path.isfile(p):
                continue
            try:
                with open(p, encoding="utf-8") as fh:
                    data = json.load(fh)
            except Exception:
                continue
            for k in data:
                home = next((f for pre, f in homes.items() if k.startswith(pre)), None)
                if home and home != n:
                    misplaced.append(f"{l}/{n} 的 {k}（要放 {home}）")
    fail("翻譯鍵放在前綴對應的檔", misplaced) if misplaced else ok("翻譯鍵放在前綴對應的檔（UI_／IGUI_／Sandbox_）")

# ---- Kahlua 禁用全域（含 os.clock）----
FORBIDDEN = ("next", "xpcall")
# os 只有 time／date／difftime（OsLib.java:322-324）：os.clock 在 Kahlua 是 nil
FORBIDDEN_MEMBERS = ("os.clock",)
hits_forbidden = []
for f in LUA_FILES:
    rel = os.path.relpath(f, REPO)
    with open(f, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            code = line.split("--", 1)[0]
            for name in FORBIDDEN:
                for mm in re.finditer(rf"(?<![\w_:.]){name}\s*\(", code):
                    hits_forbidden.append(f"{rel}:{lineno} 用了 {name}()")
            for name in FORBIDDEN_MEMBERS:
                if re.search(rf"(?<![\w_]){re.escape(name)}\s*\(", code):
                    hits_forbidden.append(f"{rel}:{lineno} 用了 {name}()")
fail("Kahlua 禁用全域（next/xpcall/os.clock）", hits_forbidden) if hits_forbidden \
    else ok("Kahlua 禁用全域（next/xpcall/os.clock）")

# ---- craftRecipe 腳本 ----
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

sys.exit(1 if failed else 0)
