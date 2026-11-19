#!/usr/bin/env python3
"""Assemble a source workspace from the current Posoco and HawDB main branches.

The checked-out source module versions are copied into ephemeral dependency
requirements so MoonBit resolves the local workspace members, not stale
Mooncakes releases. Only the CI/developer working tree is edited.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "moon.work"


def module_version(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    match = re.search(r'(?m)^version\\s*=\\s*"([^"]+)"\\s*$', text)
    if not match:
        raise SystemExit(f"Could not read module version from {path}")
    return match.group(1)


def set_import_version(path: Path, module: str, version: str) -> None:
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(r'("' + re.escape(module) + r'@)[^"]+(")')
    updated, count = pattern.subn(lambda m: m.group(1) + version + m.group(2), text)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one {module} import in {path}; found {count}"
        )
    path.write_text(updated, encoding="utf-8")


def main() -> None:
    posoco_mod = ROOT / "_posoco_checkout" / "moon.mod"
    hawdb_mod = ROOT / "_hawdb_checkout" / "bindings" / "moonbit" / "moon.mod"
    fs_mod = ROOT / "posoco-ext-fs-session" / "moon.mod"
    integration_mod = ROOT / "posoco-ext-hawdb-session" / "moon.mod"

    posoco_version = module_version(posoco_mod)
    hawdb_version = module_version(hawdb_mod)
    fs_version = module_version(fs_mod)

    # MoonBit registry imports require a concrete minimum version. Derive it
    # from the source currently checked out for this CI run; do not freeze a
    # historical dependency version in the integration workflow.
    set_import_version(fs_mod, "colmugx/posoco", posoco_version)
    set_import_version(integration_mod, "colmugx/posoco", posoco_version)
    set_import_version(integration_mod, "colmugx/posoco-ext-fs-session", fs_version)
    set_import_version(integration_mod, "nowledge-co/hawdb", hawdb_version)

    members = [
        '  "./_posoco_checkout",',
        '  "./posoco-ext-fs-session",',
        '  "./_hawdb_checkout/bindings/moonbit",',
        '  "./posoco-ext-hawdb-session",',
    ]
    lines = WORK.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].strip() != "members = [":
        raise SystemExit("Unrecognized moon.work: expected members = [ on first line")
    for member in members:
        if member not in lines:
            lines.insert(1, member)
    WORK.write_text("\\n".join(lines) + "\\n", encoding="utf-8")

    print(f"POSOCO_MAIN_VERSION={posoco_version}")
    print(f"HAWDB_MAIN_VERSION={hawdb_version}")
    print(f"FS_SESSION_WORKSPACE_VERSION={fs_version}")


if __name__ == "__main__":
    main()
