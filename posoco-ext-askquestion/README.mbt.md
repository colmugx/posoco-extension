# posoco-ext-askquestion

An interactive `ask_question` tool extension for
[Posoco](https://mooncakes.io/docs/colmugx/posoco). It gives the model two
tools on the human face — `ask_question`, for a focused question that waits
for the answer, and `notify_user`, for a question that must not block the
turn. All prompting for the blocking face is delegated to a host-injected
[`UiPort`](https://mooncakes.io/docs/colmugx/posoco/port): free-text input,
yes/no confirmation, and single-choice selection map onto
`UiRequest::Input` / `Confirm` / `Select`.

## Usage

```bash
moon add colmugx/posoco-ext-askquestion
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-askquestion" @askquestion

// The composed UiPort (and, for notify_user, the wakeup capability) are
// captured at composition time from `requires`; nothing is passed in here.
let ask = @askquestion.AskQuestionTools()
let agent = @posoco.Agent(exts=[ask, ..other_extensions], config~)
```

The host wires the composed `UiPort` through composition; without one every
`ask_question` returns `ui unavailable`.

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

## Non-blocking asks (`notify_user`)

`ask_question` is the wrong tool when the answer is not needed to keep
working: it parks the turn until the user replies. `notify_user` takes the
same question shape and returns immediately:

```json
{ "status": "submitted", "question_id": "question-3", "short_id": "@q3", "type": "select" }
```

- **The turn never blocks.** The model is told the reply arrives later as
  ordinary user input and must not wait for it.
- **The question is a host event, not model input.** Each submission lands
  on the subscription channel as `QuestionEvent::Asked`; hosts render it
  (cetas-js shows a `?` line and routes the answer back).
- **Answers are delivered exactly once.** The host hands the reply to
  `answer_async`; the next `before_model` appends one envelope line and
  drains it:

  ```
  [question-reply id=question-3] answer: sqlite
  ```

- **Expiry is a delivery-time fact.** Past the answer deadline (default
  10 minutes; `AskQuestionTools::with_async_timeout`) the question reports

  ```
  [question-expired id=question-3] Which database should we use? — no answer arrived in time; decide yourself
  ```

  and a late answer is refused with `AsyncAskError::Expired` instead of
  silently winning.
- **Turn-end delivery.** When a turn ends with an undelivered answer the
  extension requests one ordinary turn through `Capability::Wakeup`, so the
  answer is not stranded until the user types something. Hosts without that
  capability degrade to lazy delivery on the next ordinary input; a host
  that wants wakeup admission calls `set_session` with the parent session.
- **No persistence.** Questions and answers live for the process lifetime
  (the same contract as the subagent question broker); a restart forgets
  them.

Host glue is small: subscribe to `QuestionEvent`s for display, call
`answer_async(question_id~, response~)` with the human's reply, and read
`open_questions()` for an answer picker.

## Behavior

- **Exclusive execution** — `ask_question` is declared with
  `ExecutionPolicy::Exclusive`, so no other tools run while the question is
  on screen. `notify_user` is `Sequential`: it never forms a barrier in
  front of long-running tools.
- **No resident prompt cost** — the manifest exposes only the tool; the same
  usage constraint is carried by its compact ToolDef. The public prompt
  contributor remains available for hosts that explicitly opt into it.
- **Validation before UI** — bad arguments (missing/empty `question`, empty
  `options` for `select`, out-of-bounds `default_index`) raise
  `RuntimeError::UnknownTool` without ever touching the UI.
- **Cancellation is recoverable** — user dismissal maps to
  `ToolReportedError` with structured `{ "cancelled": true }`; the turn
  continues instead of dying.
- **Structured results** — success outcomes carry text content plus a
  structured payload (`{"type": "confirm", "value": true}`, selected option
  with index, etc.) so hosts can render them precisely.
