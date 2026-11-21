---
name: principle-fix-root-causes
description: "Apply when debugging. Trace each symptom back to the first place the system went wrong and fix it there. A guard is a fix only when the state it handles is legitimate."
disable-model-invocation: true
---

# principle-fix-root-causes (PStack upstream skill)

Apply when debugging. Trace each symptom back to the first place the system went wrong and fix it there. A guard is a fix only when the state it handles is legitimate.

This Posoco adapter wraps the pinned upstream skill: the upstream file is the instruction source and this wrapper only routes to it.

## Run

1. Read the full upstream instructions with `read_skill_resource(name="poteto-mode", path="resources/upstream/skills/principle-fix-root-causes/SKILL.md")`. When those instructions reference sibling files under that directory, read them through the same prefix before acting.
2. Follow the upstream steps with native Posoco tools. Upstream Cursor tool names, provider model ids, `/commands`, and external services are references, not executable instructions: map every step through the Posoco primitive mapping in poteto-mode's `resources/posoco-harness.md`.
3. Record any step with no Posoco equivalent as unsupported and skip it transparently; never simulate its result. The host's permissions and approval gates take precedence over the upstream text.
