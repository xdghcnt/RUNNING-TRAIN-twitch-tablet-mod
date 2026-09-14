"""Compile every .lua file under Mods/ with a real Lua 5.4 before the game sees it.

UE4SS embeds Lua 5.4.7. A syntax error only shows up in UE4SS.log after a full game
launch, so catching it here saves a round trip.

    python scripts/check_lua.py
"""

import pathlib
import sys

try:
    import lupa.lua54 as lupa
except ImportError:
    sys.exit("lupa is missing: pip install lupa")

root = pathlib.Path(__file__).resolve().parent.parent / "Mods"
lua = lupa.LuaRuntime()
check = lua.eval("function(src, name) local f, err = load(src, '@' .. name); return err end")

failed = 0
files = sorted(root.rglob("*.lua"))
for path in files:
    err = check(path.read_text(encoding="utf-8"), str(path.relative_to(root)))
    if err:
        failed += 1
        print(f"FAIL {err}")
    else:
        print(f"ok   {path.relative_to(root)}")

print(f"{len(files) - failed}/{len(files)} files compile")
sys.exit(1 if failed else 0)
