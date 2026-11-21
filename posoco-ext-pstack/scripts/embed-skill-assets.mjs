// Embeds the PStack workflow skills and Kind presets into the package so hosts
// that ship PStack inside their binary need no assets directory. Run after
// updating assets/skills or assets/agents:
//   node posoco-ext-pstack/scripts/embed-skill-assets.mjs
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, relative, sep } from "node:path";

const project = join(import.meta.dirname, "..");
const out = join(project, "src", "embedded_bundle.generated.mbt");

// Registration order for embedded_skill_frontmatter() and the descriptor
// array hosts pass to merge_builtin_skills. Every directory under
// assets/skills must be listed here or generation fails, so a new skill
// directory is a conscious change to the registration order.
const skillOrder = ["poteto-mode", "poteto-help", "no-comments"];
// Deterministic parse order for embedded_kinds(); load_kinds reads the same
// order from disk.
const agentOrder = ["poteto-agent", "comment-sicko"];

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

function stripFrontmatter(source) {
  const match = /^---\n[\s\S]*?\n---\n?/.exec(source);
  return match ? source.slice(match[0].length) : source;
}

function frontmatterField(source, field) {
  const match = new RegExp(`^${field}: (.*)$`, "m").exec(source);
  return match ? match[1].trim() : null;
}

const skillsRoot = join(project, "assets", "skills");
const actualSkills = readdirSync(skillsRoot)
  .filter((name) => statSync(join(skillsRoot, name)).isDirectory())
  .sort();
if (JSON.stringify(actualSkills) !== JSON.stringify([...skillOrder].sort())) {
  throw new Error(
    `assets/skills directories ${JSON.stringify(actualSkills)} do not match skillOrder ${JSON.stringify(skillOrder)}; update skillOrder consciously`,
  );
}

const skills = skillOrder.map((name) => {
  const dir = join(skillsRoot, name);
  const source = readFileSync(join(dir, "SKILL.md"), "utf8");
  const frontName = frontmatterField(source, "name");
  if (frontName !== name) {
    throw new Error(`SKILL.md name '${frontName}' differs from directory '${name}'`);
  }
  const description = frontmatterField(source, "description");
  if (!description) {
    throw new Error(`SKILL.md for ${name} has no description frontmatter`);
  }
  // The cetas-js terminal re-scans injected instructions for $-tokens, so a
  // body that names a bundled skill with a $ would double-inject it.
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
  return { name, description, body: stripFrontmatter(source), resources };
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
console.log(
  `wrote ${out} (${skills.length} skills, ${resourceCount} resources, ${agents.length} agents)`,
);
