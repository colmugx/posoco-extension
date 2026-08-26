# posoco-ext-askquestion

An interactive `ask_question` tool extension for
[Posoco](https://mooncakes.io/docs/colmugx/posoco). It gives the model one
tool — `ask_question` — for asking the user a focused question mid-turn and
waiting for the answer. All prompting is delegated to a host-injected
[`UiPort`](https://mooncakes.io/docs/colmugx/posoco/port): free-text input,
yes/no confirmation, and single-choice selection map onto
`UiRequest::Input` / `Confirm` / `Select`.

## Usage

```bash
moon add colmugx/posoco-ext-askquestion
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-askquestion" @askquestion

let ask = @askquestion.AskQuestionTools(ui as &@posoco.UiPort)
let agent = @posoco.Agent(exts=[ask, ..other_extensions], config~)
```

`ui` is your host's `UiPort` implementation (cetas-js, cetas-native,
testkit, …). Register the extension only when an interactive UI exists;
without one every call comes back as "Interactive UI is unavailable".

## Tool arguments

| Argument | Type | Description |
|----------|------|-------------|
| `question` | string, required | The focused question to present |
| `type` | string | `input`, `confirm`, or `select`; inferred when omitted (`options` present → `select`, otherwise `input`) |
| `options` | string[] | Choices for `select`; must be non-empty when `type` is `select` |
| `default` | string | Pre-filled value for `input` |
| `default_index` | integer | Zero-based pre-selected option for `select`; must be in bounds |

Example call:

```json
{
  "question": "Which database should we use?",
  "type": "select",
  "options": ["postgres", "sqlite"],
  "default_index": 0
}
```

## Behavior

- **Exclusive execution** — declared with `ExecutionPolicy::Exclusive`, so
  no other tools run while the question is on screen.
- **Prompt contributor** — injects a system-prompt section telling the model
  to ask only when a user decision or missing fact blocks progress, one
  focused question at a time, preferring `select` with known choices.
- **Validation before UI** — bad arguments (missing/empty `question`, empty
  `options` for `select`, out-of-bounds `default_index`) raise
  `RuntimeError::UnknownTool` without ever touching the UI.
- **Cancellation is recoverable** — user dismissal maps to
  `ToolReportedError` with structured `{ "cancelled": true }`; the turn
  continues instead of dying.
- **Structured results** — success outcomes carry text content plus a
  structured payload (`{"type": "confirm", "value": true}`, selected option
  with index, etc.) so hosts can render them precisely.
