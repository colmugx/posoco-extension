# posoco-ext-jev

> **Targets: native + js (hosted HTTP); wasm/wasm-gc compiles to a typed transport failure**

TypeSafe Jev `DecisionPort` provider for
[Posoco](https://mooncakes.io/docs/colmugx/posoco) agents: one thin adapter
that translates Posoco's provider-neutral `DecisionRequest` protocol into
Jev's hosted System One API and decodes the typed response back.

## Ports contributed

| Port | Contribution |
|------|--------------|
| `DecisionPort` | `evaluate` — one System One HTTPS request per `DecisionRequest` |
| `Extension` | composes into `Agent(exts=[...])` as a decision extension (manifest id `posoco_ext_jev`) |

The extension is intentionally thin: it does not know about LazyTools, Skills,
model routing, permission policy, thresholds, or authority. Composition allows
at most one `DecisionPort` (`CompositionError::MultipleDecisions`); hosts with
no decision provider omit this extension entirely —
`CompositionView::decision` stays `None` and consumers treat it as optional.

## Usage

```bash
moon add colmugx/posoco-ext-jev
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-jev" @jev

let decision = @jev.JevDecisionPort(@jev.JevConfig(api_key))
let agent = @posoco.Agent(exts=[decision, ..other_extensions], config~)
```

The key is conventionally read by the host from the `TYPESAFE_API_KEY`
environment variable (`@env.get_env_var` from `moonbitlang/core/env`).

### JevConfig arguments

| Argument | Type | Default | Description |
|---|---|---|---|
| `api_key` | `String` | required | TypeSafe API key |
| `model~` | `String` | `"jev-latest"` | Jev model id; `jev-latest` tracks the current hosted model |
| `base_url~` | `String` | `"https://api.typesafe.ai"` | API base URL without the endpoint path |
| `timeout_ms~` | `Int` | `30000` | per-request timeout in milliseconds |

A misconfigured provider fails at construction, not mid-turn: empty
`api_key` / `model` / `base_url` or non-positive `timeout_ms` aborts.

## Wire mapping (System One)

One `DecisionRequest` becomes one System One request: every question is keyed
by its id under `"questions"` and all of them share `"state"`. The request
POSTs to `{base_url}/v1/systemone` with `Authorization: Bearer <api_key>`.
`state` must be a string, object, array, or null — primitive number/boolean
state is rejected locally as `InvalidRequest` before any HTTP call.

| Posoco | Jev wire |
|---|---|
| `DecisionQuestion::Boolean` | `{"type": "noul", instructions, "criteria": {"true"?, "false"?}}` → `BooleanAnswer(probability_true = answer.noul)` |
| `DecisionQuestion::Choice` | `{"type": "choice", instructions, "criteria": {option_id: description}}` → `ChoiceAnswer(selected, per-option probabilities, confidence?)` |
| `DecisionQuestion::Score` | `{"type": "score", instructions, "criteria": [levels]}` → `ScoreAnswer(score, per-level probabilities keyed by level index, confidence?)` |
| `DecisionRequest.state` | `"state"` |
| resolved Jev model | `DecisionResult.model` |
| `usage.input_tokens` / `usage.output_tokens` | `DecisionUsage` |

Boolean criteria are optional and forwarded verbatim. Unknown provider fields
in responses are ignored, and every decoded result is re-validated against the
exact request that produced it (`validate_for`), so an answer that does not
match its question fails loudly instead of slipping through.

## Failure semantics

`evaluate` raises `DecisionError`:

- **`InvalidRequest`** — the request violates provider-neutral invariants
  (`DecisionRequest::validate`) or `state` is a primitive
- **`RequestBuild`** — Jev rejected the request (HTTP 400)
- **`RateLimited`** — HTTP 429
- **`Transport`** — any other non-2xx status, connection failure, timeout, or
  the wasm/wasm-gc fallback
- **`ResponseParse`** — a non-UTF-8 / non-JSON body or a malformed response
  (missing fields, wrong answer types, mismatched answers)

Consumers remain responsible for fallback and for mapping probabilities into
their own deterministic policy.
