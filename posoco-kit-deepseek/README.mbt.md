# posoco-kit-deepseek

> **Targets: all backends** — no HTTP, no platform gates.

The client-side half of DeepSeek's serving contract, shared by every plane that
serves a DeepSeek model: the direct API extension (`posoco-ext-deepseek`) and
gateway planes such as OpenCode Go. Nothing here is a generic model guardrail —
each rule exists because of how DeepSeek's serving engine behaves.

## Why these rules exist

DeepSeek's production serving path treats a turn as an append-only token
stream: the stable prefix is served from a shared KV cache and only the newest
suffix is prefilled. Two things follow, and both are obligations on the client:

| Rule | Serving behaviour it protects |
|---|---|
| Append-only history; guidance appended at the **tail** | A rewritten middle invalidates the cached prefix and forces a full re-prefill. |
| Canonical tool declaration order | The tool schema is rendered into the stable system prefix; declaration order jitter is a different prefix for the same tool set. |
| Fail-closed reasoning ceiling | Decode ends when the server stops thinking; a client that never bounds reasoning pays for the stream and then for the compaction it triggers. |
| Exact repeated-suffix detection | A degenerate decode is deterministic in its suffix shape; the check is deliberately narrow and never claims semantics. |
| One bounded low-effort retry | A `length` cutoff with no text and no tool calls is the only response that can be replayed without retracting anything that reached the host. |
| One-shot convergence guidance | Three identical tool calls in one user turn are a loop, and telling the model so is cheaper than another round trip. |

## API

```moonbit
let policy = @deepseek_policy.DeepSeekPolicy::from_settings(
  source.settings,
  manifest_id="my_provider",
)                                 // defaults: 120000 chars / 256 span / retry on

let port = @deepseek_policy.deepseek_policy_port(
  inner=wire_port,                // the DeepSeek-speaking transport port
  policy~,
  retry_at_low=Some(fn() { low_effort_port }),
  inject_convergence=wire == ChatCompletions,
  source="my_provider",
)
```

- `DeepSeekPolicy::from_settings` reads `max_reasoning_chars`,
  `repeated_reasoning_span_chars`, `recover_on_reasoning_exhaustion` from a
  provider settings object. Same keys on every plane, `null`/`false` to opt out,
  typed composition errors for malformed values.
- `deepseek_policy_port` owns the request-side rules and the non-stream retry.
- `DeepSeekPolicy::observe(acc, done~)` is the stream bound. It must be called
  by the code that reads the connection: a `Stream` callback cannot raise, so a
  decorator cannot stop a runaway stream by itself. The caller closes the
  connection and raises `ModelError::Transport` with
  `ReasoningBreach::category()` in the message.

## Deliberate deviations

- **Reasoning replay**: some adapters replay `reasoning_content` only when the
  outgoing request carries tools. A gateway shared with other vendors keeps the
  keep-all policy instead — DeepSeek requires replay on tool turns and tolerates
  it elsewhere, and replaying costs tokens but never breaks the prefix.
- **Guidance position**: the instruction is appended before the transport folds
  tool attachments. If the transcript ends in a tool run with media, the
  synthetic media message lands after it. Semantics are unchanged; the guidance
  is still at the tail.
