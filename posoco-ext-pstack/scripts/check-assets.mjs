import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, resolve, relative } from "node:path";
import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";
import { adapterSkills, excludedUpstreamSkills } from "./bundle-config.mjs";

const project = resolve(import.meta.dirname, "..");
const assets = join(project, "assets");
const skillDir = join(assets, "skills", "poteto-mode");
const upstream = join(skillDir, "resources", "upstream");

const required = [
  "skills/poteto-mode/SKILL.md",
  "skills/poteto-mode/playbooks/feature.md",
  "skills/poteto-mode/playbooks/investigation.md",
  "skills/principle-model-the-domain/SKILL.md",
  "skills/architect/SKILL.md",
  "skills/swarm/SKILL.md",
  "LICENSE",
];
for (const file of required) {
  assert(existsSync(join(upstream, file)), `Missing PStack resource: ${file}`);
}

// Registration order for the embedded bundle lives in bundle-config.mjs: the
// hand adapters first, then one generated wrapper per remaining upstream
// skill. A new adapter is a conscious change to that file.
const actualSkillDirs = readdirSync(join(assets, "skills"))
  .filter(name => !name.startsWith("."))
  .sort();
const upstreamSkillDirs = readdirSync(join(upstream, "skills"))
  .filter(name => !name.startsWith("."))
  .sort();
assert.deepEqual(
  actualSkillDirs,
  [...adapterSkills, ...upstreamSkillDirs.filter(name => !adapterSkills.includes(name) && !excludedUpstreamSkills[name])].sort(),
  `assets/skills must hold the adapters plus one generated wrapper per registered upstream skill, found ${actualSkillDirs}`,
);

// Coverage audit: every upstream skill directory must be covered by a
// hand-written adapter, a generated wrapper, or an explicit exclusion entry
// in bundle-config.mjs. Nothing may fall through silently.
for (const name of upstreamSkillDirs) {
  assert.ok(
    adapterSkills.includes(name) ||
      existsSync(join(assets, "skills", name, "SKILL.md")) ||
      excludedUpstreamSkills[name],
    `Upstream skill ${name} has no adapter, no generated wrapper, and no exclusion entry in bundle-config.mjs`,
  );
}
assert.equal(
  upstreamSkillDirs.length,
  adapterSkills.length +
    (upstreamSkillDirs.filter(name => existsSync(join(assets, "skills", name, "SKILL.md")) && !adapterSkills.includes(name))).length +
    Object.keys(excludedUpstreamSkills).length,
  "upstream skill count must equal adapters + generated wrappers + exclusions",
);

const rootSkill = readFileSync(join(skillDir, "SKILL.md"), "utf8");
assert.match(rootSkill, /^---\nname: poteto-mode\n/m);
const corePlaybooks = ["investigation", "bug-fix", "feature", "refactoring", "perf-issue", "prototype"];
const adapterPaths = [
  "resources/upstream/skills/poteto-mode/SKILL.md",
  "resources/posoco-harness.md",
  ...corePlaybooks.map(name => `resources/upstream/skills/poteto-mode/playbooks/${name}.md`),
];
for (const path of adapterPaths) {
  assert(existsSync(join(skillDir, path)), `Missing adapter reference: ${path}`);
}
assert.match(rootSkill, /read_skill_resource/);
assert.match(rootSkill, /resources\/posoco-harness\.md/);
for (const name of corePlaybooks) {
  assert(rootSkill.includes(`playbooks/${name}.md`), `Unrouted core workflow: ${name}`);
}

// Adapter skill frontmatter carries name + description + the upstream
// disable-model-invocation flag, and no body names a bundled skill with a $:
// cetas-js re-scans injected instructions for $-tokens, so a literal would
// double-inject the skill.
function frontmatter(source) {
  const match = /^---\n([\s\S]*?)\n---\n/.exec(source);
  assert.ok(match, `SKILL.md is missing frontmatter`);
  const keys = [...match[1].matchAll(/^([A-Za-z_-]+):/gm)].map(m => m[1]);
  return keys;
}
function bodyOf(source) {
  return source.replace(/^---\n[\s\S]*?\n---\n?/, "");
}
// Raw frontmatter lines of one key, verbatim (single-line or block scalar).
function rawField(source, field) {
  const frontmatterBlock = /^---\n([\s\S]*?)\n---\n?/.exec(source);
  assert.ok(frontmatterBlock, `SKILL.md is missing frontmatter`);
  const lines = frontmatterBlock[1].split("\n");
  const start = lines.findIndex(line => new RegExp(`^${field}:`).test(line));
  assert.ok(start !== -1, `frontmatter has no ${field} field`);
  const raw = [lines[start]];
  for (let i = start + 1; i < lines.length; i++) {
    if (/^[A-Za-z_-]+:/.test(lines[i])) break;
    raw.push(lines[i]);
  }
  while (raw.length > 1 && raw[raw.length - 1].trim() === "") raw.pop();
  return raw;
}
function carriesUserInvokedOnly(source) {
  return /^disable-model-invocation: true$/m.test(source);
}
for (const name of adapterSkills) {
  const source = readFileSync(join(assets, "skills", name, "SKILL.md"), "utf8");
  assert.match(source, new RegExp(`^---\\nname: ${name}\\n`), `Bad frontmatter name: ${name}`);
  assert.match(source, /\ndescription: \S/m, `Missing description frontmatter: ${name}`);
  // The three adapters align with upstream policy: user-invoked-only.
  assert.deepEqual(
    frontmatter(source),
    ["name", "description", "disable-model-invocation"],
    `Frontmatter must be name + description + disable-model-invocation: ${name}`,
  );
  assert.equal(
    carriesUserInvokedOnly(source),
    carriesUserInvokedOnly(readFileSync(join(upstream, "skills", name, "SKILL.md"), "utf8")),
    `Adapter flag must match its upstream copy: ${name}`,
  );
  for (const other of actualSkillDirs) {
    assert.ok(
      !bodyOf(source).includes(`$${other}`),
      `Body of ${name} must not contain the literal $${other}; write "its $\`-mention" instead`,
    );
  }
}

// Generated wrapper skills: frontmatter copies the upstream name,
// description, and invocation flag verbatim; the body routes to the pinned
// upstream instructions through poteto-mode's resource tree and carries no $
// at all.
const wrapperSkills = actualSkillDirs.filter(name => !adapterSkills.includes(name));
assert.equal(
  wrapperSkills.length,
  upstreamSkillDirs.length - adapterSkills.length - Object.keys(excludedUpstreamSkills).length,
  "expected one generated wrapper per registered upstream skill",
);
for (const name of wrapperSkills) {
  const source = readFileSync(join(assets, "skills", name, "SKILL.md"), "utf8");
  const upstreamSource = readFileSync(join(upstream, "skills", name, "SKILL.md"), "utf8");
  assert.match(source, new RegExp(`^---\\nname: ${name}\\n`), `Bad wrapper frontmatter name: ${name}`);
  const keys = frontmatter(source);
  assert.ok(
    JSON.stringify(keys) === JSON.stringify(["name", "description"]) ||
      JSON.stringify(keys) === JSON.stringify(["name", "description", "disable-model-invocation"]),
    `Wrapper frontmatter must be name + description [+ disable-model-invocation]: ${name}`,
  );
  assert.deepEqual(
    rawField(source, "description"),
    rawField(upstreamSource, "description"),
    `Wrapper description must copy the upstream frontmatter verbatim: ${name}`,
  );
  assert.equal(
    carriesUserInvokedOnly(source),
    carriesUserInvokedOnly(upstreamSource),
    `Wrapper invocation flag must match upstream frontmatter: ${name}`,
  );
  const body = bodyOf(source);
  assert.ok(!body.includes("$"), `Generated wrapper body must be $-literal-free: ${name}`);
  assert.match(
    body,
    new RegExp(
      `read_skill_resource\\(name="poteto-mode", path="resources/upstream/skills/${name}/SKILL\\.md"\\)`,
    ),
    `Wrapper must route to the pinned upstream instructions: ${name}`,
  );
  assert.match(body, /resources\/posoco-harness\.md/, `Wrapper must point at the Posoco primitive mapping: ${name}`);
  for (const other of actualSkillDirs) {
    assert.ok(
      !body.includes(`$${other}`),
      `Body of ${name} must not contain the literal $${other}`,
    );
  }
}

// poteto-help is a help-not-work router: it hands back a prompt and points at
// the upstream navigation map instead of starting work.
const helpSkill = readFileSync(join(assets, "skills", "poteto-help", "SKILL.md"), "utf8");
assert.match(helpSkill, /read_skill_resource\(name="poteto-mode", path="resources\/upstream\/skills\/poteto-help\/SKILL\.md"\)/);

// no-comments spawns the read-only reviewer kind and defers the policy to it.
const noCommentsSkill = readFileSync(join(assets, "skills", "no-comments", "SKILL.md"), "utf8");
assert.match(noCommentsSkill, /subagent\(kind="comment-sicko"/);
assert.match(noCommentsSkill, /resources\/upstream\/skills\/no-comments\/SKILL\.md/);

// The embedded Kind presets: one write delegate, one read-only reviewer.
const agentModes = { "poteto-agent": "workspace_write", "comment-sicko": "readonly" };
assert.deepEqual(
  readdirSync(join(assets, "agents")).filter(name => name.endsWith(".md")).sort(),
  Object.keys(agentModes).map(name => `${name}.md`).sort(),
  "assets/agents must hold exactly the two bundled Kind presets",
);
for (const [name, mode] of Object.entries(agentModes)) {
  const source = readFileSync(join(assets, "agents", `${name}.md`), "utf8");
  assert.match(source, new RegExp(`^---\\nname: ${name}\\n`));
  assert.match(source, new RegExp(`\\nmode: ${mode}\\n`));
}

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(path));
    else if (entry.isFile()) out.push(path);
  }
  return out;
}

const sources = walk(join(upstream, "skills"));
const skillFiles = sources.filter(x => /\/skills\/[^/]+\/SKILL\.md$/.test(x));
const playbooks = sources.filter(x => /\/skills\/poteto-mode\/playbooks\/[^/]+\.md$/.test(x));
const principles = sources.filter(x => /\/skills\/principle-[^/]+\/SKILL\.md$/.test(x));
assert.equal(skillFiles.length, 58, "expected upstream skill count at pinned revision");
assert.equal(playbooks.length, 23, "expected upstream playbook count");
assert.equal(principles.length, 24, "expected upstream principle count");
const root = resolve(skillDir);
for (const p of [join(root, "SKILL.md"), ...sources]) {
  assert(!relative(root, p).startsWith(".."), `Asset escaped bundle: ${p}`);
}

// The generated bundle is the only artifact hosts read, so the committed file
// must be exactly what the generator produces, and producing it twice must
// change nothing.
const embed = join(project, "scripts", "embed-skill-assets.mjs");
const bundle = join(project, "src", "embedded_bundle.generated.mbt");
const committed = readFileSync(bundle);
execFileSync(process.execPath, [embed], { cwd: project, stdio: "ignore" });
const generated = readFileSync(bundle);
assert.ok(
  committed.equals(generated),
  "embedded_bundle.generated.mbt is stale; run scripts/embed-skill-assets.mjs and commit its output",
);
execFileSync(process.execPath, [embed], { cwd: project, stdio: "ignore" });
assert.ok(
  generated.equals(readFileSync(bundle)),
  "embed-skill-assets.mjs is not idempotent: two runs produced different bytes",
);

// Descriptor flags match frontmatter: the bundle's user-invoked-only map is
// the generated counterpart of each SKILL.md's disable-model-invocation flag,
// and embedded_descriptors passes it straight into every descriptor.
const flagSection = /pub fn embedded_skill_user_invoked_only\(\) -> Map\[String, Bool\] \{\n  Map::from_array\(\[\n([\s\S]*?)\n  \]\)\n\}/.exec(
  generated.toString(),
);
assert.ok(flagSection, "bundle is missing embedded_skill_user_invoked_only");
const bundledFlags = new Map(
  [...flagSection[1].matchAll(/\("([^"]+)", (true|false)\),/g)].map(m => [m[1], m[2] === "true"]),
);
assert.deepEqual(
  [...bundledFlags.keys()].sort(),
  actualSkillDirs,
  "bundle flags must cover exactly the bundled skill directories",
);
for (const name of actualSkillDirs) {
  const source = readFileSync(join(assets, "skills", name, "SKILL.md"), "utf8");
  assert.equal(
    bundledFlags.get(name),
    carriesUserInvokedOnly(source),
    `bundle user_invoked_only must match SKILL.md frontmatter: ${name}`,
  );
}

console.log(
  `PStack bundle OK: ${skillFiles.length} skills, ${playbooks.length} playbooks, ${principles.length} principles, ${upstreamSkillDirs.length} upstream skills = ${adapterSkills.length} adapters + ${wrapperSkills.length} wrappers + ${Object.keys(excludedUpstreamSkills).length} exclusions (${[...bundledFlags.values()].filter(flag => flag).length} user-invoked-only), ${Object.keys(agentModes).length} agents`,
);
