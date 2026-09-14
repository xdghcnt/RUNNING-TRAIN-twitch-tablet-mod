"""
gen_ue4ss_def.py -- generate a .def file from UE4SS.dll's export table.

Why: a C++ UE4SS mod links against UE4SS.dll, but the official build produces the
import library as a by-product of building UE4SS from source -- which we cannot do,
because the `deps/first/Unreal` submodule (Re-UE4SS/UEPseudo) is private.

Since every symbol we need (CppUserModBase's ctor/dtor/virtuals and
LuaMadeSimple::Lua's register_function/set_number/set_string/set_bool/get_number)
is exported by name from the shipped UE4SS.dll, we can synthesise an import library
from the export table instead:

    python gen_ue4ss_def.py <UE4SS.dll> <out.def>
    lib /def:out.def /machine:x64 /out:UE4SS.lib

Usage:
    python gen_ue4ss_def.py "<path to UE4SS.dll>" "<path to output .def>"
"""

import sys

import pefile


# Symbols we must find, or the mod cannot link. Checked so a silent ABI change in a
# future UE4SS build fails here loudly instead of at link time with a wall of noise.
REQUIRED_FRAGMENTS = [
    "CppUserModBase",
    "register_function@Lua@LuaMadeSimple",
    "set_number@Lua@LuaMadeSimple",
    "set_bool@Lua@LuaMadeSimple",
    "set_string@Lua@LuaMadeSimple",
    "get_number@Lua@LuaMadeSimple",
    "is_number@Lua@LuaMadeSimple",
    # used by TwitchTablet on top of what HeadTracking needed
    "set_nil@Lua@LuaMadeSimple",
    "set_integer@Lua@LuaMadeSimple",
    "is_integer@Lua@LuaMadeSimple",
    "get_integer@Lua@LuaMadeSimple",
    "is_string@Lua@LuaMadeSimple",
    "get_string@Lua@LuaMadeSimple",
]


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    dll_path, def_path = sys.argv[1], sys.argv[2]

    pe = pefile.PE(dll_path)
    pe.parse_data_directories()

    export_dir = getattr(pe, "DIRECTORY_ENTRY_EXPORT", None)
    if export_dir is None:
        print("ERROR: no export directory in", dll_path)
        return 1

    names = sorted({s.name.decode() for s in export_dir.symbols if s.name})
    if not names:
        print("ERROR: export table is empty")
        return 1

    missing = [frag for frag in REQUIRED_FRAGMENTS
               if not any(frag in n for n in names)]
    if missing:
        print("ERROR: UE4SS.dll does not export the symbols this mod needs.")
        for frag in missing:
            print("   missing:", frag)
        print("The installed UE4SS build is probably incompatible with this mod.")
        return 1

    with open(def_path, "w", encoding="ascii", errors="replace") as f:
        f.write("LIBRARY UE4SS.dll\n")
        f.write("EXPORTS\n")
        for n in names:
            # Names must be written bare. Quoting them makes lib.exe treat the
            # quotes as part of the symbol, which produces an import library that
            # links against nothing and yields a wall of LNK2019s.
            f.write(f"    {n}\n")

    print(f"wrote {def_path}: {len(names)} exports")
    return 0


if __name__ == "__main__":
    sys.exit(main())
