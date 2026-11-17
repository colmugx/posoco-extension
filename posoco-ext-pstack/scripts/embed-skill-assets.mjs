// Embeds the PStack workflow skill into the package so hosts that ship PStack
// inside their binary need no assets directory. Run after updating
// assets/skills/poteto-mode:
//   node posoco-ext-pstack/scripts/embed-skill-assets.mjs
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, relative, sep } from "node:path";

const project = join(import.meta.dirname, "..");
const skillDir = join(project, "assets", "skills", "poteto-mode");
const out = join(project, "src", "embedded_bundle.generated.mbt");

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

const body = stripFrontmatter(readFileSync(join(skillDir, "SKILL.md"), "utf8"));
const resources = walk(skillDir)
  .filter((path) => relative(skillDir, path) !== "SKILL.md")
  .map((path) => ({
    path: relative(skillDir, path).split(sep).join("/"),
    content: readFileSync(path, "utf8"),
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
lines.push("// Generated from assets/skills/poteto-mode; do not edit.");
lines.push("// Run: node posoco-ext-pstack/scripts/embed-skill-assets.mjs");
lines.push("");
lines.push("///|");
lines.push("/// SKILL.md instructions, shipped inside the host binary.");
lines.push("pub fn embedded_skill_body() -> String {");
lines.push("  " + literal(body));
lines.push("}");
lines.push("");
lines.push("///|");
lines.push("/// Playbooks and references readable through read_skill_resource.");
lines.push("pub fn embedded_skill_resources() -> Map[String, String] {");
lines.push("  Map::from_array([");
for (const resource of resources) {
  lines.push(
    "    (" + literal(resource.path) + ", " + literal(resource.content) + "),",
  );
}
lines.push("  ])");
lines.push("}");

writeFileSync(out, lines.join("\n") + "\n");
console.log(`wrote ${out} (${resources.length} resources)`);
