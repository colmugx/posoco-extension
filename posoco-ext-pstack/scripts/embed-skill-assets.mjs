// Embeds the PStack workflow skills and Kind presets into the package so hosts
// that ship PStack inside their binary need no assets directory. Run after
// updating assets/skills or assets/agents:
//   node posoco-ext-pstack/scripts/embed-skill-assets.mjs
//
// Besides embedding, this script generates one wrapper SKILL.md per upstream
// skill directory that has no hand-written adapter and is not excluded in
// bundle-config.mjs. Wrappers are written only when absent: a file that
// already exists is never overwritten, so hand-written content (and the
// upstream sync workstream re-running this generator over the tree) is safe.
import { readFileSync, readdirSync, statSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join, relative, sep } from "node:path";
import { pathToFileURL } from "node:url";

const project = join(import.meta.dirname, "..");
const out = join(project, "src", "embedded_bundle.generated.mbt");

// Loaded through a dynamic import against the real project path so the sync
// workstream's bundle probe (it stages a copy of this script in a scratch
// directory and redirects only `out`) keeps resolving the config that lives
// next to this file.
const { adapterSkills, excludedUpstreamSkills } = await import(
  pathToFileURL(join(project, "scripts", "bundle-config.mjs")).href
);

// Deterministic parse order for embedded_kinds(); load_kinds reads the same
// order from disk.
const agentOrder = ["poteto-agent", "comment-sicko"];

const skillsRoot = join(project, "assets", "skills");
const upstreamSkillsRoot = join(
  skillsRoot,
  "poteto-mode",
  "resources",
  "upstream",
  "skills",
);

function walk(dir) {
  const files = [];
  for (const name of readdirSync(dir).sort()) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      files.push(...walk(path));
    } else {
      files.push(path);
    }
  }
  return files;
}

function frontmatterBlock(source, file) {
  const match = /^---\n([\s\S]*?)\n---\n?/.exec(source);
  if (!match) {
    throw new Error(`${file} is missing YAML frontmatter`);
  }
  return match[1];
}

function stripFrontmatter(source, file) {
  const match = /^---\n[\s\S]*?\n---\n?/.exec(source);
  if (!match) {
    throw new Error(`${file} is missing YAML frontmatter`);
  }
  return source.slice(match[0].length);
}

// Raw frontmatter lines for one key: the `key: value` line plus any
// continuation lines of a multi-line scalar, verbatim.
function fieldRawLines(frontmatter, field) {
  const lines = frontmatter.split("\n");
  const start = lines.findIndex((line) => new RegExp(`^${field}:`).test(line));
  if (start === -1) {
    return null;
  }
  const raw = [lines[start]];
  for (let i = start + 1; i < lines.length; i++) {
    if (/^[A-Za-z_-]+:/.test(lines[i])) break;
    raw.push(lines[i]);
  }
  while (raw.length > 1 && raw[raw.length - 1].trim() === "") raw.pop();
  return raw;
}

// Effective single-line value of a raw scalar: unquotes quoted scalars and
// folds block scalars. Good enough for catalog metadata; file-backed
// discovery re-parses the real YAML with the runtime parser.
function scalarValue(raw) {
  const header = raw[0];
  const marker = header.slice(header.indexOf(":") + 1).trim();
  const body = raw.slice(1).map((line) => line.replace(/^ {2}/, ""));
  if (marker === "" || marker.startsWith(">") || marker.startsWith("|")) {
    const folded = marker.startsWith("|") ? body.join("\n") : body.join(" ");
    return folded.trim();
  }
  if (marker.startsWith('"')) {
    try {
      return JSON.parse(marker);
    } catch {
      // Fall through to the raw marker instead of guessing escapes.
    }
  }
  if (marker.startsWith("'")) {
    return marker.slice(1, -1).replace(/''/g, "'");
  }
  return marker;
}

function frontmatterField(source, field, file) {
  const raw = fieldRawLines(frontmatterBlock(source, file), field);
  return raw ? scalarValue(raw) : null;
}

function isUserInvokedOnly(source, file) {
  return /^disable-model-invocation: true$/m.test(frontmatterBlock(source, file));
}

// Upstream skill directories, sorted: the generator's wrapper source of truth.
const upstreamNames = readdirSync(upstreamSkillsRoot)
  .filter((name) => statSync(join(upstreamSkillsRoot, name)).isDirectory())
  .sort();

// Generate the wrapper SKILL.md for every upstream skill that has neither a
// hand-written adapter nor an explicit exclusion. Existing files are never
// touched.
function renderWrapper(name, upstreamSource) {
  const upstreamFrontmatter = frontmatterBlock(upstreamSource, `upstream ${name}`);
  const descriptionRaw = fieldRawLines(upstreamFrontmatter, "description");
  if (!descriptionRaw) {
    throw new Error(`Upstream SKILL.md for ${name} has no description frontmatter`);
  }
  const description = scalarValue(descriptionRaw);
  if (!description) {
    throw new Error(`Upstream SKILL.md for ${name} has an empty description`);
  }
  const lines = [];
  lines.push("---");
  lines.push(`name: ${name}`);
  lines.push(...descriptionRaw);
  if (isUserInvokedOnly(upstreamSource, `upstream ${name}`)) {
    lines.push("disable-model-invocation: true");
  }
  lines.push("---");
  lines.push("");
  lines.push(`# ${name} (PStack upstream skill)`);
  lines.push("");
  lines.push(description);
  lines.push("");
  lines.push(
    "This Posoco adapter wraps the pinned upstream skill: the upstream file is the instruction source and this wrapper only routes to it.",
  );
  lines.push("");
  lines.push("## Run");
  lines.push("");
  lines.push(
    `1. Read the full upstream instructions with \`read_skill_resource(name="poteto-mode", path="resources/upstream/skills/${name}/SKILL.md")\`. When those instructions reference sibling files under that directory, read them through the same prefix before acting.`,
  );
  lines.push(
    "2. Follow the upstream steps with native Posoco tools. Upstream Cursor tool names, provider model ids, `/commands`, and external services are references, not executable instructions: map every step through the Posoco primitive mapping in poteto-mode's `resources/posoco-harness.md`.",
  );
  lines.push(
    "3. Record any step with no Posoco equivalent as unsupported and skip it transparently; never simulate its result. The host's permissions and approval gates take precedence over the upstream text.",
  );
  return lines.join("\n") + "\n";
}

let generated = 0;
for (const name of upstreamNames) {
  if (adapterSkills.includes(name) || excludedUpstreamSkills[name]) continue;
  const target = join(skillsRoot, name, "SKILL.md");
  if (existsSync(target)) continue;
  mkdirSync(join(skillsRoot, name), { recursive: true });
  writeFileSync(
    join(skillsRoot, name, "SKILL.md"),
    renderWrapper(name, readFileSync(join(upstreamSkillsRoot, name, "SKILL.md"), "utf8")),
  );
  generated += 1;
}

// Registration order for embedded_skill_frontmatter() and the descriptor
// array hosts pass to merge_builtin_skills: the hand-written adapters first,
// then the generated wrappers sorted by name. Every directory under
// assets/skills must be an adapter or an upstream-derived wrapper, so a stray
// directory fails generation instead of shipping silently.
const wrapperNames = upstreamNames.filter(
  (name) => !adapterSkills.includes(name) && !excludedUpstreamSkills[name],
);
const skillOrder = [...adapterSkills, ...wrapperNames];
const actualSkills = readdirSync(skillsRoot)
  .filter((name) => statSync(join(skillsRoot, name)).isDirectory())
  .sort();
if (JSON.stringify(actualSkills) !== JSON.stringify([...skillOrder].sort())) {
  throw new Error(
    `assets/skills directories ${JSON.stringify(actualSkills)} do not match the registered skills ${JSON.stringify([...skillOrder].sort())}; adapters live in bundle-config.mjs, wrappers mirror resources/upstream/skills`,
  );
}

const skills = skillOrder.map((name) => {
  const dir = join(skillsRoot, name);
  const source = readFileSync(join(dir, "SKILL.md"), "utf8");
  const frontName = frontmatterField(source, "name", name);
  if (frontName !== name) {
    throw new Error(`SKILL.md name '${frontName}' differs from directory '${name}'`);
  }
  const description = frontmatterField(source, "description", name);
  if (!description) {
    throw new Error(`SKILL.md for ${name} has no description frontmatter`);
  }
  // The cetas-js terminal re-scans injected instructions for $-tokens, so a
  // body that names a bundled skill with a $ would double-inject it. Generated
  // wrappers must not carry a $ at all: their frontmatter copies the upstream
  // description verbatim and their body is fully generator-authored.
  const body = stripFrontmatter(source, name);
  if (!adapterSkills.includes(name) && body.includes("$")) {
    throw new Error(`Generated wrapper for ${name} must not contain a literal $`);
  }
  for (const other of skillOrder) {
    if (source.includes(`$${other}`)) {
      throw new Error(
        `SKILL.md for ${name} contains the literal $${other}; write "its $\`-mention" phrasing instead`,
      );
    }
  }
  const resources = walk(dir)
    .filter((path) => relative(dir, path) !== "SKILL.md")
    .map((path) => ({
      path: relative(dir, path).split(sep).join("/"),
      content: readFileSync(path, "utf8"),
    }));
  return {
    name,
    description,
    userInvokedOnly: isUserInvokedOnly(source, name),
    body,
    resources,
  };
});

const agentsRoot = join(project, "assets", "agents");
const agents = agentOrder.map((name) => ({
  name,
  content: readFileSync(join(agentsRoot, `${name}.md`), "utf8"),
}));

function literal(value) {
  return (
    '"' +
    value
      .replace(/\\/g, "\\\\")
      .replace(/"/g, '\\"')
      .replace(/\n/g, "\\n")
      .replace(/\r/g, "\\r")
      .replace(/\t/g, "\\t") +
    '"'
  );
}

const lines = [];
lines.push("// Generated from assets/skills and assets/agents; do not edit.");
lines.push("// Run: node posoco-ext-pstack/scripts/embed-skill-assets.mjs");
lines.push("");
lines.push("///|");
lines.push("/// Name and description of every embedded skill, in registration order.");
lines.push("pub fn embedded_skill_frontmatter() -> Array[(String, String)] {");
lines.push("  [");
for (const skill of skills) {
  lines.push(
    "    (" + literal(skill.name) + ", " + literal(skill.description) + "),",
  );
}
lines.push("  ]");
lines.push("}");
lines.push("");
lines.push("///|");
lines.push(
  "/// User-invoked-only flag per embedded skill, mirroring each SKILL.md's",
);
lines.push(
  "/// disable-model-invocation frontmatter: true means the skill stays out of",
);
lines.push(
  "/// the model-facing startup catalog and activates only on explicit user",
);
lines.push("/// invocation.");
lines.push("pub fn embedded_skill_user_invoked_only() -> Map[String, Bool] {");
lines.push("  Map::from_array([");
for (const skill of skills) {
  lines.push(
    "    (" + literal(skill.name) + ", " + String(skill.userInvokedOnly) + "),",
  );
}
lines.push("  ])");
lines.push("}");
lines.push("");
lines.push("///|");
lines.push("/// SKILL.md instructions per skill, shipped inside the host binary.");
lines.push("pub fn embedded_skill_bodies() -> Map[String, String] {");
lines.push("  Map::from_array([");
for (const skill of skills) {
  lines.push("    (" + literal(skill.name) + ", " + literal(skill.body) + "),");
}
lines.push("  ])");
lines.push("}");
lines.push("");
lines.push("///|");
lines.push("/// Resources per skill, readable through read_skill_resource.");
lines.push("pub fn embedded_skill_resource_sets() -> Map[String, Map[String, String]] {");
lines.push("  Map::from_array([");
for (const skill of skills) {
  lines.push("    (" + literal(skill.name) + ", Map::from_array([");
  for (const resource of skill.resources) {
    lines.push(
      "      (" + literal(resource.path) + ", " + literal(resource.content) + "),",
    );
  }
  lines.push("    ])),");
}
lines.push("  ])");
lines.push("}");
lines.push("");
lines.push("///|");
lines.push("/// poteto-mode's SKILL.md instructions, shipped inside the host binary.");
lines.push("/// Retained for existing hosts; new callers read embedded_skill_bodies().");
lines.push("pub fn embedded_skill_body() -> String {");
lines.push('  embedded_skill_bodies().get("poteto-mode").unwrap()');
lines.push("}");
lines.push("");
lines.push("///|");
lines.push("/// poteto-mode's playbooks and references, readable through");
lines.push("/// read_skill_resource. Retained for existing hosts; new callers read");
lines.push("/// embedded_skill_resource_sets().");
lines.push("pub fn embedded_skill_resources() -> Map[String, String] {");
lines.push('  embedded_skill_resource_sets().get("poteto-mode").unwrap()');
lines.push("}");
lines.push("");
lines.push("///|");
lines.push("/// Kind preset files per preset name, frontmatter included.");
lines.push("pub fn embedded_agent_bodies() -> Map[String, String] {");
lines.push("  Map::from_array([");
for (const agent of agents) {
  lines.push("    (" + literal(agent.name) + ", " + literal(agent.content) + "),");
}
lines.push("  ])");
lines.push("}");

writeFileSync(out, lines.join("\n") + "\n");
const resourceCount = skills.reduce((sum, skill) => sum + skill.resources.length, 0);
const userOnly = skills.filter((skill) => skill.userInvokedOnly).length;
console.log(
  `wrote ${out} (${skills.length} skills, ${userOnly} user-invoked-only, ${resourceCount} resources, ${agents.length} agents; ${generated} wrappers generated, ${Object.keys(excludedUpstreamSkills).length} upstream skills excluded)`,
);
