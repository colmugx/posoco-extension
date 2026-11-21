# Upstream provenance and sync runbook

- Repository: https://github.com/cursor/plugins
- PStack path: `pstack/`
- Pinned commit: `bf0c7cd80abdbf7fe47b634978a7d1b4071f71a7`
- Imported content: Markdown files under `pstack/skills`, `pstack/agents`, and `pstack/docs/guide`, plus the Claude Code harness mapping and upstream README.
- Excluded content: executable scripts, binary assets, plugin metadata, Cursor automation definitions, and non-Markdown test fixtures.
- Also excluded, because the bullets above do not classify them: repository plumbing (`pstack/.gitignore`) and non-Markdown reference templates (`pstack/skills/**/references/*.tsv`).
- License: MIT. The original license text is included at `resources/upstream/LICENSE`.

The import and exclusion rules above are the contract: `scripts/sync-upstream.mjs` imports exactly the imported content, excludes the excluded content, and reports any other upstream file as UNCLASSIFIED instead of guessing. The vendored files are source references; Posoco-specific behavior and capability limits are defined by `SKILL.md` and `resources/posoco-harness.md`.

## Sync procedure

1. `node scripts/sync-upstream.mjs --ref <sha|branch|tag> --dry-run` — review the drift report: added, removed, and changed files with size deltas, UNCLASSIFIED paths, and adapter touchpoint warnings. Without `--ref` it replays the pinned commit.
2. `node scripts/sync-upstream.mjs --ref <sha|branch|tag>` — refresh `resources/upstream/`, move the pinned commit above, regenerate the embedded bundle, and run `scripts/check-assets.mjs`. The run refuses to write while any upstream file is UNCLASSIFIED: extend the rules above consciously first.
3. `node scripts/check-assets.mjs` — must be green. Its fixed skill, playbook, and principle counts are a conscious update whenever upstream changes them.
4. Review the adapter warnings from step 1: `SKILL.md` and `resources/posoco-harness.md` reference pinned `resources/upstream/` paths, and `posoco-harness.md` restates the pin.

`node scripts/sync-upstream.mjs --offline --dry-run` re-derives the target from the vendored tree itself and must report zero drift; that is the idempotency proof.
