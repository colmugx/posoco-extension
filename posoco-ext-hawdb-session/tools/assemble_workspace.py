#!/usr/bin/env python3
"""Assemble the Posoco and HawDB source workspace."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "moon.work"


def module_version(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    match = re.search(r'(?m)^version\s*=\s*"([^"]+)"\s*$', text)
    if not match:
        raise SystemExit(f"Missing module version in {path}")
    return match.group(1)


def set_import_version(path: Path, module: str, version: str) -> None:
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(r'("' + re.escape(module) + r'@)[^"]+(")')
    updated, count = pattern.subn(lambda m: m.group(1) + version + m.group(2), text)
    if count != 1:
        raise SystemExit(f"Expected one {module} import in {path}; found {count}")
    path.write_text(updated, encoding="utf-8")


def main() -> None:
    posoco = ROOT / "_posoco_checkout" / "moon.mod"
    hawdb = ROOT / "_hawdb_checkout" / "bindings" / "moonbit" / "moon.mod"
    integration = ROOT / "posoco-ext-hawdb-session" / "moon.mod"

    set_import_version(integration, "colmugx/posoco", module_version(posoco))
    set_import_version(integration, "nowledge-co/hawdb", module_version(hawdb))

    members = [
        '  "./_posoco_checkout",',
        '  "./_hawdb_checkout/bindings/moonbit",',
        '  "./posoco-ext-hawdb-session",',
    ]
    lines = WORK.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].strip() != "members = [":
        raise SystemExit("Invalid moon.work")
    for member in members:
        if member not in lines:
            lines.insert(1, member)
    WORK.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
