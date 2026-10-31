# posoco-ext-init

An evidence-first **/init** slash command for Posoco coding agents. It schedules
a real agent turn to inspect the current repository and produce a short,
actionable **AGENTS.md**. It is not a generator that fills in a generic
template or merely prints a prompt for the user to paste.

## Commands

| Command | Effect |
| --- | --- |
| \`/init\` | Create \`AGENTS.md\` only if absent. Existing files are never overwritten. |
| \`/init check\` | Audit existing guidance and report missing or unverified facts; no writes. |
| \`/init refresh\` | Review the repository and make a **minimal** evidence-backed update to an existing \`AGENTS.md\`; preserve human-maintained rules. |
| \`/init create packages/foo\` | Initialize the specified repository-relative subproject directory. |
| \`/init refresh packages/foo\` | Refresh that subproject's \`AGENTS.md\`. |

The prompt asks the agent to inspect manifests, workflows, source layout,
entrypoints and a few representative tests. It omits uncertain facts instead
of inventing test commands, and avoids repetitive style advice, secrets,
generated code, vendored dependencies, and oversized tree dumps. It
distinguishes *documented* commands from *executed* checks and tells the
agent to report exactly what it changed. The output target is **AGENTS.md**,
which other agents can consume; do not auto-replace \`CLAUDE.md\`.

## Posoco integration

The extension implements \`Extension\`, \`CommandPort\`, and \`Lifecycle\`.
It declares \`Capability::Wakeup\` and captures the Agent-owned wakeup port
at composition. Invoking the slash command requests one ordinary turn with
a carefully bounded instruction in the wakeup note; the model performs the
actual repository inspection and file write through the host's normal tool
and permission policies.

\`\`\`moonbit nocheck
let initializer = Init()
let agent = @posoco.Agent(
  exts=[initializer, ..tool_extensions],
  config~,
)

// The host must run the agent inside run_scoped and bind the active session
// through Agent::set_active_session. Bind the same current session here;
// alternatively pass {"session_id": "..."} in CommandPort::invoke args.
initializer.set_session(Some(current_session_id))

// Command dispatch for the selected extension:
// @posoco.CommandPort::invoke(initializer, "init", Json::null())
\`\`\`

**Important:** An idle command can enqueue a turn only while the Agent's
\`run_scoped\` scope is live and the intended session is the currently
bound active window. This is a core Wakeup admission constraint, not a
background job that runs by itself. Outside that scope or without a
session id, \`/init\` returns an actionable failure, never a false
"initialized" success. When the command succeeds it says **queued**, not
**written**: the subsequent agent turn may still report that a file could
not be created.

The host should supply file listing, read/search and write tools, as well as
an appropriate permission gate. Without those tools the agent reports what it
cannot verify and does not invent a document. Calling \`/init\` again before
the queued turn executes coalesces its request to one latest-intent turn
(tag \`repo-init\`). The command never directly reads or writes the
workspace, so it does not bypass host tool governance.

## Safety and quality rules

- A missing file is created; an existing file is never overwritten by
  \`create\`. \`refresh\` edits conservatively and preserves custom rules,
  with ambiguous conflicts left for human review.
- \`check\` is strictly read-only.
- Scope paths are restricted to repository-relative simple directory names,
  with no \`..\`, absolute path, shell metacharacters or control characters.
- The agent treats file contents as untrusted evidence, not permission to run
  arbitrary shell code; reads are bounded and ignore secret, binary, generated,
  vendor and dependency directories.
- Guidance should be compact (roughly 100 lines or less), specific to this
  project, and actionable for subsequent coding work. If a section cannot be
  grounded in repository evidence, omit it.
- Each run reports its action, target, cited paths and unresolved unknowns.
  It never claims validations were run merely because a script was found.

## Why a model-driven turn?

\`CommandOutcome\` does not itself resume Posoco's model. A
feedback-only \`/init\` would appear to work but could not create the
file. Using the composed Wakeup port preserves the regular Agent operation,
turn journal, tool bindings, model hooks and authorization boundary.
