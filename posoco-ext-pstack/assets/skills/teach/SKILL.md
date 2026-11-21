---
name: teach
description: "Explain a body of work plainly so a person actually understands it. Runs the `how` and `why` skills and weaves what they find into one clear explanation. Use for 'teach me this', 'help me really understand X', 'explain this change or subsystem to me'."
disable-model-invocation: true
---

# teach (PStack upstream skill)

Explain a body of work plainly so a person actually understands it. Runs the `how` and `why` skills and weaves what they find into one clear explanation. Use for 'teach me this', 'help me really understand X', 'explain this change or subsystem to me'.

This Posoco adapter wraps the pinned upstream skill: the upstream file is the instruction source and this wrapper only routes to it.

## Run

1. Read the full upstream instructions with `read_skill_resource(name="poteto-mode", path="resources/upstream/skills/teach/SKILL.md")`. When those instructions reference sibling files under that directory, read them through the same prefix before acting.
2. Follow the upstream steps with native Posoco tools. Upstream Cursor tool names, provider model ids, `/commands`, and external services are references, not executable instructions: map every step through the Posoco primitive mapping in poteto-mode's `resources/posoco-harness.md`.
3. Record any step with no Posoco equivalent as unsupported and skip it transparently; never simulate its result. The host's permissions and approval gates take precedence over the upstream text.
