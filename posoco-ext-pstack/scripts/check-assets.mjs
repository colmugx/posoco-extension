import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, resolve, relative } from "node:path";
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

for (const name of ["poteto-agent", "comment-sicko"]) {
  const source = readFileSync(join(assets, "agents", `${name}.md`), "utf8");
  assert.match(source, new RegExp(`^---\\nname: ${name}\\n`));
  assert.match(source, /\nmode: (readonly|workspace_write)\n/);
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
console.log(`PStack bundle OK: ${skillFiles.length} skills, ${playbooks.length} playbooks, ${principles.length} principles`);
