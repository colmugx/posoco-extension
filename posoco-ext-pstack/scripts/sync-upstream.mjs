// Syncs the vendored PStack copy under
// assets/skills/poteto-mode/resources/upstream with cursor/plugins at a pinned
// commit. resources/UPSTREAM.md is the contract: its "Imported content" and
// "Excluded content" bullets classify every upstream file, and anything they
// do not classify is reported as UNCLASSIFIED instead of guessed. The write
// phase refuses to run while UNCLASSIFIED files exist.
//
// Usage:
//   node scripts/sync-upstream.mjs --offline --dry-run
//       Re-derive the target from the current vendored tree as if it were
//       upstream at the pinned commit. No network, no writes; the idempotency
//       replay and it must report zero drift.
//   node scripts/sync-upstream.mjs [--ref <sha|branch|tag>] --dry-run
//       Sparse-checkout cursor/plugins at the ref (default: the pinned
//       commit), classify it against the contract, and report drift.
//   node scripts/sync-upstream.mjs --ref <sha|branch|tag>
//       Refresh resources/upstream, move the pin in UPSTREAM.md, regenerate
//       the embedded bundle, and run scripts/check-assets.mjs.
//
// Exit codes: 0 = nothing to do, or a write run finished clean;
// 1 = a dry-run reported drift; 2 = usage error, fetch failure, write run
// aborted, or check-assets failed.
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";

const REPO_URL = "https://github.com/cursor/plugins";
const SUBTREE = "pstack";
// "the Claude Code harness mapping" in the import rules names this one file.
const HARNESS_MAPPING = "docs/harness/claude-code.md";
const PIN_LINE = /^-\s*Pinned commit:\s*`?([0-9a-f]{7,40})`?\s*$/m;

const project = resolve(import.meta.dirname, "..");
const skillDir = join(project, "assets", "skills", "poteto-mode");
const upstreamDir = join(skillDir, "resources", "upstream");
// The runbook lives outside the vendored tree today; prefer the documented
// location if a later workstream moves it in.
const upstreamDoc = existsSync(join(upstreamDir, "UPSTREAM.md"))
  ? join(upstreamDir, "UPSTREAM.md")
  : join(skillDir, "resources", "UPSTREAM.md");
const docRel = relative(upstreamDir, upstreamDoc).split("\\").join("/");
const docInsideUpstream = !docRel.startsWith("..");

const scriptExtensions = new Set([
  ".ts", ".mts", ".cts", ".js", ".mjs", ".cjs", ".jsx", ".tsx",
  ".sh", ".bash", ".zsh", ".py", ".rb", ".pl", ".java", ".kt", ".go", ".rs", ".lua", ".ps1",
]);
const binaryExtensions = new Set([
  ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".icns", ".bmp", ".pdf",
  ".zip", ".gz", ".tgz", ".tar", ".jar", ".wasm", ".woff", ".woff2", ".ttf", ".otf", ".eot",
  ".mp3", ".mp4", ".mov", ".avi", ".wav", ".aiff", ".bin", ".exe", ".dll", ".dylib", ".so", ".class",
]);

// ---------------------------------------------------------------------------
// Contract classification. The include rules are checked first and verbatim;
// only files they do not reach can be excluded, and only files neither side
// reaches are UNCLASSIFIED.
// ---------------------------------------------------------------------------

function classify(rel, file) {
  if (rel === "LICENSE") return { verdict: "import", rule: "LICENSE" };
  if (rel === "README.md") return { verdict: "import", rule: "upstream README" };
  if (rel === HARNESS_MAPPING) return { verdict: "import", rule: "Claude Code harness mapping" };
  if (rel.startsWith("skills/") && rel.endsWith(".md")) {
    return { verdict: "import", rule: "Markdown under pstack/skills" };
  }
  if (rel.startsWith("agents/") && rel.endsWith(".md")) {
    return { verdict: "import", rule: "Markdown under pstack/agents" };
  }
  if (rel.startsWith("docs/guide/") && rel.endsWith(".md")) {
    return { verdict: "import", rule: "Markdown under pstack/docs/guide" };
  }

  const segments = rel.split("/");
  const base = segments.at(-1);
  const dot = base.lastIndexOf(".");
  const ext = dot > 0 ? base.slice(dot).toLowerCase() : "";
  if (base === "plugin.json" || base === "marketplace.json" || segments.includes(".cursor-plugin")) {
    return { verdict: "exclude", rule: "plugin metadata" };
  }
  if (segments[0] === "automations") {
    return { verdict: "exclude", rule: "Cursor automation definitions" };
  }
  // UPSTREAM.md names these explicitly because the bullets above do not
  // classify them; keep the code and the doc in lockstep.
  if (rel === ".gitignore") {
    return { verdict: "exclude", rule: "repository plumbing" };
  }
  if (ext === ".tsv" && segments.includes("references")) {
    return { verdict: "exclude", rule: "non-Markdown reference templates" };
  }
  if (segments.some((segment) => segment === "test" || segment === "tests")) {
    return { verdict: "exclude", rule: "non-Markdown test fixtures" };
  }
  // A skill's scripts/ directory is executable ground: everything under it that
  // the include rules did not already take (their .md) stays out of the bundle.
  if (scriptExtensions.has(ext) || segments.includes("scripts") || file.executable) {
    return { verdict: "exclude", rule: "executable scripts" };
  }
  if (binaryExtensions.has(ext) || file.binary) {
    return { verdict: "exclude", rule: "binary assets" };
  }
  return { verdict: "unclassified" };
}

function classifyTree(files) {
  const target = new Map();
  const excluded = new Map();
  const unclassified = [];
  for (const [rel, file] of files) {
    const verdict = classify(rel, file);
    if (verdict.verdict === "import") target.set(rel, file.bytes);
    else if (verdict.verdict === "exclude") excluded.set(rel, verdict.rule);
    else unclassified.push(rel);
  }
  return { target, excluded, unclassified };
}

// ---------------------------------------------------------------------------
// Trees: vendored (current) and upstream (fetched or replayed offline).
// ---------------------------------------------------------------------------

function walkFiles(root) {
  const out = [];
  const visit = (dir, prefix) => {
    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const abs = join(dir, entry.name);
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (docInsideUpstream && rel === docRel) continue;
      if (entry.isSymbolicLink()) throw new Error(`unexpected symlink in tree: ${rel}`);
      if (entry.isDirectory()) visit(abs, rel);
      else if (entry.isFile()) {
        out.push({ rel, abs, executable: (statSync(abs).mode & 0o111) !== 0 });
      } else throw new Error(`unsupported file type: ${rel}`);
    }
  };
  visit(root, "");
  return out;
}

function loadTree(root) {
  const files = new Map();
  for (const { rel, abs, executable } of walkFiles(root)) {
    const bytes = readFileSync(abs);
    files.set(rel, { bytes, executable, binary: bytes.subarray(0, 8192).includes(0) });
  }
  return files;
}

// Sparse-checkout of the pstack/ subtree into a scratch dir; the scratch dir is
// always removed, including on failure. blob:none keeps the clone to commits
// and trees until the sparse checkout pulls the subtree's blobs.
function fetchUpstream(ref) {
  const scratch = mkdtempSync(join(tmpdir(), "pstack-upstream-"));
  const repoDir = join(scratch, "plugins");
  const git = (args) => execFileSync("git", args, { cwd: repoDir }).toString().trim();
  try {
    try {
      execFileSync("git", ["clone", "--quiet", "--filter=blob:none", "--no-checkout", REPO_URL, repoDir]);
    } catch (error) {
      throw new Error(`could not clone ${REPO_URL} (network?): ${error.message}`);
    }
    git(["sparse-checkout", "init", "--cone"]);
    git(["sparse-checkout", "set", SUBTREE]);
    let sha;
    for (const candidate of [`${ref}^{commit}`, `origin/${ref}^{commit}`]) {
      try {
        sha = git(["rev-parse", "--verify", candidate]);
        break;
      } catch {
        // try the next spelling
      }
    }
    if (!sha) throw new Error(`ref '${ref}' not found in ${REPO_URL}`);
    if (sha !== ref && /^[0-9a-f]{40}$/.test(ref)) {
      throw new Error(`requested commit ${ref} resolved to ${sha}`);
    }
    git(["checkout", "--quiet", "--detach", sha]);
    return { sha, files: loadTree(join(repoDir, SUBTREE)) };
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// Drift, touchpoints, counts.
// ---------------------------------------------------------------------------

function diffTrees(target, current) {
  const added = [];
  const removed = [];
  const changed = [];
  let unchanged = 0;
  for (const [rel, bytes] of target) {
    const existing = current.get(rel);
    if (!existing) added.push({ rel, size: bytes.length });
    else if (!existing.bytes.equals(bytes)) changed.push({ rel, from: existing.bytes.length, to: bytes.length });
    else unchanged += 1;
  }
  for (const [rel, file] of current) {
    if (!target.has(rel)) removed.push({ rel, size: file.bytes.length });
  }
  const byPath = (a, b) => a.rel.localeCompare(b.rel);
  return { added: added.sort(byPath), removed: removed.sort(byPath), changed: changed.sort(byPath), unchanged };
}

function tally(rules) {
  const counts = new Map();
  for (const rule of rules) counts.set(rule, (counts.get(rule) ?? 0) + 1);
  return [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([rule, count]) => `${rule}: ${count}`).join(", ");
}

// Adapter touchpoints: every resources/upstream/... path the adapter docs name,
// plus the paths scripts/check-assets.mjs requires to exist.
function adapterTouchpoints() {
  const refs = new Map();
  const add = (rel, source) => {
    if (!refs.has(rel)) refs.set(rel, []);
    refs.get(rel).push(source);
  };
  const docs = [
    join(skillDir, "SKILL.md"),
    join(skillDir, "..", "poteto-help", "SKILL.md"),
    join(skillDir, "..", "no-comments", "SKILL.md"),
    join(skillDir, "resources", "posoco-harness.md"),
    upstreamDoc,
  ];
  for (const doc of docs) {
    for (const match of readFileSync(doc, "utf8").matchAll(/resources\/upstream\/[^\s`"')\],;]+/g)) {
      const rel = match[0].slice("resources/upstream/".length);
      // Skip prose placeholders like <name> and the literal "..." in harness
      // examples; they name no file.
      if (!rel || rel.endsWith("/") || rel.includes("..") || rel.includes("<")) continue;
      add(rel, relative(skillDir, doc));
    }
  }
  const checkSource = readFileSync(join(project, "scripts", "check-assets.mjs"), "utf8");
  const required = /const required = \[([\s\S]*?)\];/.exec(checkSource);
  if (required) {
    for (const match of required[1].matchAll(/"([^"]+)"/g)) add(match[1], "scripts/check-assets.mjs required list");
  }
  return refs;
}

function touchpointFindings(refs, target, current) {
  const findings = [];
  for (const [rel, sources] of refs) {
    const inTarget = target.has(rel);
    const inCurrent = current.has(rel);
    if (!inTarget) {
      findings.push(`adapter reference disappears in the new tree: resources/upstream/${rel} (${[...new Set(sources)].join(", ")})`);
    } else if (inCurrent && !current.get(rel).bytes.equals(target.get(rel))) {
      findings.push(
        `adapter reference changes: resources/upstream/${rel} ` +
        `(${current.get(rel).bytes.length} -> ${target.get(rel).length} bytes; ${[...new Set(sources)].join(", ")})`,
      );
    }
  }
  return findings.sort();
}

// check-assets.mjs pins the upstream shape with three fixed counts; a sync that
// moves them leaves the check red unless the assertions are updated consciously.
function upstreamCounts(rels) {
  return {
    skills: rels.filter((rel) => /^skills\/[^/]+\/SKILL\.md$/.test(rel)).length,
    playbooks: rels.filter((rel) => /^skills\/poteto-mode\/playbooks\/[^/]+\.md$/.test(rel)).length,
    principles: rels.filter((rel) => /^skills\/principle-[^/]+\/SKILL\.md$/.test(rel)).length,
  };
}

function assertedCounts() {
  const source = readFileSync(join(project, "scripts", "check-assets.mjs"), "utf8");
  const grab = (name) => {
    const match = new RegExp(`assert\\.equal\\(${name}\\.length, (\\d+)`).exec(source);
    return match ? Number(match[1]) : null;
  };
  return { skills: grab("skillFiles"), playbooks: grab("playbooks"), principles: grab("principles") };
}

// ---------------------------------------------------------------------------
// Bundle freshness. The dry-run must write nothing in-repo, so instead of
// running the generator in place it stages a copy whose output path is
// redirected to a scratch file and compares bytes.
// ---------------------------------------------------------------------------

function bundleProbe() {
  const bundle = join(project, "src", "embedded_bundle.generated.mbt");
  const generator = readFileSync(join(project, "scripts", "embed-skill-assets.mjs"), "utf8");
  const originalProject = /^const project = join\(import\.meta\.dirname, "\.\."\);$/m;
  const originalOut = /^const out = join\(project, "src", "embedded_bundle\.generated\.mbt"\);$/m;
  if (!originalProject.test(generator) || !originalOut.test(generator)) {
    throw new Error("embed-skill-assets.mjs no longer matches the probe's expected shape; compare bundles by hand");
  }
  const scratch = mkdtempSync(join(tmpdir(), "pstack-bundle-probe-"));
  try {
    const probeOut = join(scratch, "bundle.generated.mbt");
    const probe = generator
      .replace(originalProject, `const project = ${JSON.stringify(project)};`)
      .replace(originalOut, `const out = ${JSON.stringify(probeOut)};`);
    writeFileSync(join(scratch, "embed-probe.mjs"), probe);
    execFileSync(process.execPath, [join(scratch, "embed-probe.mjs")], { stdio: "ignore" });
    return { fresh: readFileSync(probeOut).equals(readFileSync(bundle)) };
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// UPSTREAM.md is generated, so the runbook text and the pin always agree.
// ---------------------------------------------------------------------------

function runbookTemplate(sha) {
  return `# Upstream provenance and sync runbook

- Repository: ${REPO_URL}
- PStack path: \`${SUBTREE}/\`
- Pinned commit: \`${sha}\`
- Imported content: Markdown files under \`pstack/skills\`, \`pstack/agents\`, and \`pstack/docs/guide\`, plus the Claude Code harness mapping and upstream README.
- Excluded content: executable scripts, binary assets, plugin metadata, Cursor automation definitions, and non-Markdown test fixtures.
- Also excluded, because the bullets above do not classify them: repository plumbing (\`pstack/.gitignore\`) and non-Markdown reference templates (\`pstack/skills/**/references/*.tsv\`).
- License: MIT. The original license text is included at \`resources/upstream/LICENSE\`.

The import and exclusion rules above are the contract: \`scripts/sync-upstream.mjs\` imports exactly the imported content, excludes the excluded content, and reports any other upstream file as UNCLASSIFIED instead of guessing. The vendored files are source references; Posoco-specific behavior and capability limits are defined by \`SKILL.md\` and \`resources/posoco-harness.md\`.

## Sync procedure

1. \`node scripts/sync-upstream.mjs --ref <sha|branch|tag> --dry-run\` — review the drift report: added, removed, and changed files with size deltas, UNCLASSIFIED paths, and adapter touchpoint warnings. Without \`--ref\` it replays the pinned commit.
2. \`node scripts/sync-upstream.mjs --ref <sha|branch|tag>\` — refresh \`resources/upstream/\`, move the pinned commit above, regenerate the embedded bundle, and run \`scripts/check-assets.mjs\`. The run refuses to write while any upstream file is UNCLASSIFIED: extend the rules above consciously first.
3. \`node scripts/check-assets.mjs\` — must be green. Its fixed skill, playbook, and principle counts are a conscious update whenever upstream changes them.
4. Review the adapter warnings from step 1: \`SKILL.md\` and \`resources/posoco-harness.md\` reference pinned \`resources/upstream/\` paths, and \`posoco-harness.md\` restates the pin.

\`node scripts/sync-upstream.mjs --offline --dry-run\` re-derives the target from the vendored tree itself and must report zero drift; that is the idempotency proof.
`;
}

function readPin() {
  const match = PIN_LINE.exec(readFileSync(upstreamDoc, "utf8"));
  if (!match) throw new Error(`no "Pinned commit:" line in ${relative(project, upstreamDoc)}`);
  return match[1];
}

// ---------------------------------------------------------------------------
// Write phase.
// ---------------------------------------------------------------------------

function pruneEmptyDirs(root) {
  let pruned = 0;
  let again = true;
  while (again) {
    again = false;
    const dirs = [];
    const visit = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (entry.isDirectory()) {
          const abs = join(dir, entry.name);
          dirs.push(abs);
          visit(abs);
        }
      }
    };
    visit(root);
    for (const dir of dirs.reverse()) {
      if (readdirSync(dir).length === 0) {
        rmSync(dir, { recursive: true });
        pruned += 1;
        again = true;
      }
    }
  }
  return pruned;
}

function applyTarget(target) {
  const current = loadTree(upstreamDir);
  let written = 0;
  let removed = 0;
  for (const rel of current.keys()) {
    if (target.has(rel)) continue;
    rmSync(join(upstreamDir, rel));
    removed += 1;
  }
  for (const [rel, bytes] of target) {
    const abs = join(upstreamDir, rel);
    const existing = current.get(rel);
    if (existing && existing.bytes.equals(bytes)) continue;
    if (relative(upstreamDir, abs).startsWith("..")) throw new Error(`target path escapes the vendored tree: ${rel}`);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, bytes);
    written += 1;
  }
  return { written, removed, pruned: pruneEmptyDirs(upstreamDir) };
}

function runNode(script) {
  return execFileSync(process.execPath, [join(project, "scripts", script)], { cwd: project, stdio: "pipe" }).toString().trim();
}

// ---------------------------------------------------------------------------
// Reporting and entry point.
// ---------------------------------------------------------------------------

function printDiff(label, entries) {
  console.log(`  ${label} ${entries.length}`);
  for (const { rel, size, from, to } of entries.slice(0, 60)) {
    if (from === undefined) console.log(`    + ${rel} (+${size} bytes)`);
    else if (size !== undefined && to === undefined) console.log(`    - ${rel} (was ${size} bytes)`);
    else console.log(`    * ${rel} (${from} -> ${to} bytes, ${to - from >= 0 ? "+" : ""}${to - from})`);
  }
  if (entries.length > 60) console.log(`    … and ${entries.length - 60} more`);
}

function report(pin, resolvedSha, targetCount, drift, unclassified, excluded, touchpoints, bundle, counts) {
  const replay = resolvedSha === null;
  console.log(`pstack upstream sync — ${replay ? "offline replay of the vendored tree" : `cursor/plugins@${resolvedSha}`}`);
  console.log(`contract: ${relative(project, upstreamDoc)} (pin ${pin})`);
  console.log(`target: ${targetCount} files`);
  if (excluded.size > 0) console.log(`excluded by contract: ${excluded.size} (${tally(excluded.values())})`);
  console.log("");
  console.log("drift (target vs resources/upstream):");
  printDiff("added", drift.added);
  printDiff("removed", drift.removed);
  printDiff("changed", drift.changed);
  console.log(`  unchanged ${drift.unchanged}`);
  const clean = drift.added.length + drift.removed.length + drift.changed.length === 0;
  console.log(clean ? "  => zero drift" : "  => DRIFT PRESENT");

  console.log("");
  console.log(`pin: ${resolvedSha === null ? `${pin} (offline replay uses the pin)` : pin === resolvedSha ? `${resolvedSha} (matches UPSTREAM.md)` : `${pin} -> ${resolvedSha} (write phase moves the pin)`}`);
  console.log(`bundle: ${bundle.fresh ? "embedded_bundle.generated.mbt matches the generator output" : "embedded_bundle.generated.mbt is STALE against assets/"}`);
  const asserted = assertedCounts();
  const match = (c) => c.skills === asserted.skills && c.playbooks === asserted.playbooks && c.principles === asserted.principles;
  console.log(
    `counts: skills ${counts.current.skills}, playbooks ${counts.current.playbooks}, principles ${counts.current.principles}` +
    ` -> skills ${counts.target.skills}, playbooks ${counts.target.playbooks}, principles ${counts.target.principles}` +
    ` (check-assets.mjs asserts ${asserted.skills}/${asserted.playbooks}/${asserted.principles})`,
  );
  if (!match(counts.current)) {
    console.log(`  ⚠ the vendored tree already differs from what check-assets.mjs asserts; the check is red before any sync`);
  }
  if (!match(counts.target)) {
    console.log(`  ⚠ the new tree's counts differ; check-assets.mjs stays red until its assertions are updated consciously`);
  }
  console.log(`touchpoints: ${touchpoints.checked} referenced resources/upstream paths checked`);
  for (const finding of touchpoints.findings) console.log(`  ⚠ ${finding}`);
  if (touchpoints.findings.length === 0) console.log("  all adapter references present and unchanged");
  console.log("");
  if (!replay) {
    if (unclassified.length > 0) {
      console.log("UNCLASSIFIED upstream files (no rule covers them; never imported):");
      for (const rel of unclassified.slice(0, 60)) console.log(`  ? ${rel}`);
      if (unclassified.length > 60) console.log(`  … and ${unclassified.length - 60} more`);
    } else {
      console.log("UNCLASSIFIED: none — every upstream file is classified by the contract.");
    }
  } else {
    console.log("UNCLASSIFIED: not computable offline; the vendored tree only holds imported files. Run without --offline to classify a real upstream tree.");
  }
  console.log("");
  return clean;
}

function usage() {
  console.log(`Usage: node scripts/sync-upstream.mjs [--ref <sha|branch|tag>] [--dry-run] [--offline]

  --ref <sha|branch|tag>  cursor/plugins ref to sync (default: the pinned commit in UPSTREAM.md)
  --dry-run               report drift only; write nothing
  --offline               replay the current vendored tree as if it were upstream at the pin
                          (no network; pair with --dry-run)

Exit codes: 0 clean / write completed; 1 dry-run drift; 2 error.`);
}

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(2);
}

function parseArgs(argv) {
  const args = { ref: null, dryRun: false, offline: false };
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === "--ref") {
      args.ref = argv[++i];
      if (!args.ref) fail("--ref needs a sha, branch, or tag");
    } else if (flag === "--dry-run") args.dryRun = true;
    else if (flag === "--offline") args.offline = true;
    else if (flag === "--help" || flag === "-h") {
      usage();
      process.exit(0);
    } else fail(`unknown argument '${flag}'; see --help`);
  }
  if (args.offline && args.ref) fail("--offline replays the pinned commit; drop --ref");
  if (args.offline && !args.dryRun) fail("--offline is a dry-run replay; add --dry-run");
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const pin = readPin();

  let resolvedSha = null;
  let target;
  let excluded = new Map();
  let unclassified = [];
  if (args.offline) {
    // The vendored tree stands in for upstream at the pin: a vendored file the
    // contract would not import shows up as drift, so the replay proves both
    // idempotency and that every vendored file is justified by the rules.
    target = classifyTree(loadTree(upstreamDir)).target;
  } else {
    const fetched = fetchUpstream(args.ref ?? pin);
    resolvedSha = fetched.sha;
    const classified = classifyTree(fetched.files);
    target = classified.target;
    excluded = classified.excluded;
    unclassified = classified.unclassified;
  }
  const current = loadTree(upstreamDir);
  const drift = diffTrees(target, current);

  const refs = adapterTouchpoints();
  const touchpoints = { checked: refs.size, findings: touchpointFindings(refs, target, current) };
  const counts = { current: upstreamCounts([...current.keys()]), target: upstreamCounts([...target.keys()]) };
  const bundle = bundleProbe();
  const clean = report(pin, resolvedSha, target.size, drift, unclassified, excluded, touchpoints, bundle, counts);

  if (args.dryRun) {
    if (unclassified.length > 0) {
      console.log("note: the rules above leave UNCLASSIFIED files; extend UPSTREAM.md before a write run.");
    }
    console.log("dry run: nothing written.");
    process.exit(clean && bundle.fresh ? 0 : 1);
  }
  if (args.offline) fail("unreachable: offline runs are always dry");
  if (unclassified.length > 0) {
    console.error("refusing to write: the contract does not classify these upstream files (edit UPSTREAM.md first):");
    for (const rel of unclassified) console.error(`  ? ${rel}`);
    process.exit(2);
  }

  const applied = applyTarget(target);
  const doc = runbookTemplate(resolvedSha);
  if (readFileSync(upstreamDoc, "utf8") !== doc) writeFileSync(upstreamDoc, doc);
  console.log(`wrote ${applied.written}, removed ${applied.removed} files, pruned ${applied.pruned} empty dirs; pin now ${resolvedSha}`);

  console.log(runNode("embed-skill-assets.mjs"));
  try {
    console.log(runNode("check-assets.mjs"));
  } catch (error) {
    console.error(`check-assets.mjs failed after the sync: ${error.stdout ?? ""}${error.message}`);
    process.exit(2);
  }

  const residual = diffTrees(target, loadTree(upstreamDir));
  const residualCount = residual.added.length + residual.removed.length + residual.changed.length;
  if (residualCount !== 0) {
    console.error(`write phase left ${residualCount} residual drift entries; investigate before committing`);
    process.exit(2);
  }
  console.log(`sync complete: ${resolvedSha}, 0 residual drift. Next: review the touchpoint warnings above, then commit.`);
}

try {
  main();
} catch (error) {
  console.error(`error: ${error.message}`);
  process.exit(2);
}
