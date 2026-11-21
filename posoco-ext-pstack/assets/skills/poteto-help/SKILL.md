---
name: poteto-help
description: User guidance entry for the PStack workflow set. Answer how-to, routing, and setup questions about the PStack skills and hand back a prompt to send; it does not start work.
disable-model-invocation: true
---

# Poteto help for Posoco

Answer the user's question about the PStack skills, hand them a prompt they can send, and stop. A PStack run spends real tokens, and a question that asks how is not a request to run.

## Help, not work

- Answer how-to, routing, and setup questions: what `poteto-mode`, `poteto-help`, and `no-comments` each do, which one fits a situation, and what the user should type.
- A message that asks for work, such as "use PStack to fix this bug", is not help. Route it to `poteto-mode`: name the reroute once and stop; do not start the playbook or the work yourself.
- End with one prompt the user can send for the actual work, adapted from what you read, and name the skill or kind it came from. Link or cite the resource you read; do not quote from memory.

## Full upstream map

For the complete upstream navigation map, read the pinned copy with `read_skill_resource(name="poteto-mode", path="resources/upstream/skills/poteto-help/SKILL.md")` before you answer a question the map below does not cover. It is upstream Cursor documentation: treat its tool names, `~/.cursor/...` paths, `/add-plugin` style commands, Custom Modes, cloud agents, and provider model rules as references, not executable Posoco instructions. Translate each answer into the matching Posoco skill, kind, tool, or host configuration, and skip what has no Posoco equivalent rather than simulating it.

## PStack skills on Posoco

| The user asks about | Answer |
| --- | --- |
| Running the engineering playbooks | `poteto-mode`. The user invokes it by name in a prompt; it routes investigation, bug fix, feature, refactoring, perf, and prototype work and reads its playbooks through `read_skill_resource`. |
| Reviewing a diff for removable comments | `no-comments`. It spawns the read-only `comment-sicko` reviewer and reports findings; it is not itself the reviewer. |
| Setup, models, cost, or verification-skill generation | The upstream setup and verification-skill generators are Cursor features and are not ported. Point to the host's own model, permission, and verification configuration instead. |

Other upstream helper skills are Markdown resources under `poteto-mode`'s `resources/upstream/skills/`; they are guidance, not separately registered Posoco Skills. Read a resource before you recommend it, and trust the resource when it disagrees with this map.

## Invocation and status

The user invokes this Skill explicitly with its `$`-mention in a prompt; Posoco's Skills layer injects these instructions into that turn. There is no setup command, no toggle, and no work performed on activation.
