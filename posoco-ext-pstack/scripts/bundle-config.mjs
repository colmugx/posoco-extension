// Single source of truth for PStack skill bundling decisions, shared by
// embed-skill-assets.mjs (generator) and check-assets.mjs (invariants). Every
// list here is the ONE authoritative definition; do not duplicate it.

// Hand-written Posoco adapter skills under assets/skills/, in bundle
// registration order. Each one also exists as an upstream skill directory
// under poteto-mode's resources/upstream/skills/, so the adapter replaces the
// generated wrapper that would otherwise be produced for it.
export const adapterSkills = ["poteto-mode", "poteto-help", "no-comments"];

// Upstream skill directories deliberately not registered as Posoco Skills.
// Every upstream directory must be covered by an adapter, a generated
// wrapper, or one entry here; check-assets.mjs enforces that audit. Values
// are reasons, cited in generator and audit failures.
export const excludedUpstreamSkills = {
  "make-bot-ui":
    "pure Cursor Automations/plugin UI machinery: webhook routines created through update_state, api2.cursor.sh/automations webhook URLs, SendToUser secret-request cards, the chat-header Routines panel, and Tailscale hosting. poteto-mode's resources/posoco-harness.md lists Cursor Automations and external services as intentionally outside the port, and no portable workflow prose survives without them",
};
