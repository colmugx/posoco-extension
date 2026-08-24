# posoco-ext-askquestion

Interactive `ask_question` tool for Posoco. The extension delegates user input,
confirmation, and single-choice prompts to an injected `UiPort`.

```moonbit
let ask = @askquestion.AskQuestionTools(ui as &@posoco.UiPort)
let agent = @posoco.Agent(exts=[ask, ...], config=...)
```

Tool arguments:

- `question` (required string)
- `type` (`input`, `confirm`, or `select`; defaults by inference)
- `options` (string array, required for `select`)
- `default` (optional input prefill)
- `default_index` (optional selected option index)
