import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, resolve, relative } from "node:path";
import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";

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

// Registration order for the embedded bundle; a new adapter skill is a
// conscious change here and in embed-skill-assets.mjs.
const adapterSkills = ["poteto-mode", "poteto-help", "no-comments"];
const actualSkillDirs = readdirSync(join(assets, "skills"))
  .filter(name => !name.startsWith("."))
  .sort();
assert.deepEqual(
  actualSkillDirs,
  [...adapterSkills].sort(),
  `assets/skills must hold exactly the adapter skills, found ${actualSkillDirs}`,
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

// Adapter skill frontmatter carries only name and description, and the body
// never names a bundled skill with a $: cetas-js re-scans injected
// instructions for $-tokens, so a literal would double-inject the skill.
function frontmatter(source) {
  const match = /^---\n([\s\S]*?)\n---\n/.exec(source);
  assert.ok(match, `SKILL.md is missing frontmatter`);
  const keys = [...match[1].matchAll(/^([A-Za-z_-]+):/gm)].map(m => m[1]);
  return keys;
}
function bodyOf(source) {
  return source.replace(/^---\n[\s\S]*?\n---\n?/, "");
}
for (const name of adapterSkills) {
  const source = readFileSync(join(assets, "skills", name, "SKILL.md"), "utf8");
  assert.match(source, new RegExp(`^---\\nname: ${name}\\n`), `Bad frontmatter name: ${name}`);
  assert.match(source, /\ndescription: \S/m, `Missing description frontmatter: ${name}`);
  assert.deepEqual(
    frontmatter(source),
    ["name", "description"],
    `Frontmatter must be name + description only: ${name}`,
  );
  for (const other of adapterSkills) {
    assert.ok(
      !bodyOf(source).includes(`$${other}`),
      `Body of ${name} must not contain the literal $${other}; write "its $\`-mention" instead`,
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

console.log(`PStack bundle OK: ${skillFiles.length} skills, ${playbooks.length} playbooks, ${principles.length} principles, ${adapterSkills.length} adapter skills, ${Object.keys(agentModes).length} agents`);
