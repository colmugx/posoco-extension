#!/usr/bin/env python3
"""Configure MoonBit's native linker for the current locally built HawDB.

This is a development/test build adapter, not a dependency installer or a
version lock. Fail if the expected upstream Rust archive was not built.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
PKG = ROOT / "posoco-ext-hawdb-session" / "moon.pkg"
NATIVE = ROOT / "_hawdb_checkout" / "bindings" / "moonbit" / "native"
PLATFORMS = {"linux", "macos", "windows"}
WINDOWS_LIBS = (
    "ws2_32.lib userenv.lib bcrypt.lib advapi32.lib ntdll.lib "
    "shell32.lib secur32.lib crypt32.lib iphlpapi.lib ole32.lib"
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--os", choices=sorted(PLATFORMS))
    args = parser.parse_args()
    platform = args.os or (
        "windows" if sys.platform == "win32"
        else "macos" if sys.platform == "darwin"
        else "linux"
    )
    suffix = "hawdb_moonbit.lib" if platform == "windows" else "libhawdb_moonbit.a"
    archive = (NATIVE / "target" / "release" / suffix).resolve()
    if not archive.is_file() or archive.stat().st_size == 0:
        raise SystemExit(f"Missing upstream HawDB native archive: {archive}")

    # The moon native linker runs from the workspace, not the package folder.
    # An absolute archive path also works for independent app workspace roots.
    flags = archive.as_posix()
    if platform == "windows":
        flags += " " + WINDOWS_LIBS
    else:
        flags += " -ldl -lpthread -lm"
        if platform == "macos":
            flags += " -framework CoreFoundation -framework IOKit"

    original = PKG.read_text(encoding="utf-8")
    pattern = r'(?m)^(\s*"cc-link-flags":\s*)"[^"\n]*"(,\s*)$'
    replacement = lambda match: match.group(1) + json.dumps(flags) + match.group(2)
    updated, count = re.subn(pattern, replacement, original)
    if count != 1:
        raise SystemExit(f"Expected one native cc-link-flags entry in {PKG}; found {count}")
    PKG.write_text(updated, encoding="utf-8")
    print(f"HAWDB_LINK_PLATFORM={platform}")
    print(f"HAWDB_NATIVE_ARCHIVE={archive}")


if __name__ == "__main__":
    main()
