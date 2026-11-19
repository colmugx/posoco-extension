#!/usr/bin/env python3
"""Expose local fs-session, upstream HawDB, and Posoco integration modules to moon.work.

CI checks out the latest upstream main. This edits only the ephemeral runner
workspace and does not pin or publish an engine version.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
work = root / "moon.work"
members = [
    '  "./posoco-ext-fs-session",',
    '  "./_hawdb_checkout/bindings/moonbit",',
    '  "./posoco-ext-hawdb-session",',
]
lines = work.read_text(encoding="utf-8").splitlines()
if not lines or lines[0].strip() != "members = [":
    raise SystemExit("Unrecognized moon.work: expected members = [ on first line")
for member in members:
    if member not in lines:
        lines.insert(1, member)
work.write_text("\n".join(lines) + "\n", encoding="utf-8")
