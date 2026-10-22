# posoco-ext-opencode-go

> **Targets: native + js** — depends on `moonbitlang/async/http`. wasm-gc is
> not in the supported matrix.

A named [`ProviderFactory`](https://mooncakes.io/docs/colmugx/posoco) for
**OpenCode Go** — the subscription plane ($10 Go / $40 Go Plus monthly) of
the OpenCode gateway. Go is quota-based: usage limits are monthly dollar
amounts per model, split into a 5-hour window (20% of the model's monthly
allowance), weekly (50%), and monthly (100%) per the vendor's own rule. This
extension publishes the catalog as the `opencode-go` provider
(`/login opencode-go`, `/model`), dispatches every model to the wire it is
served on, reads the live `/usage` three-window quota, and feeds typed
rate-limit verdicts with authoritative reset times to the host's automatic
recovery.

The wire machinery, protocol derivation, models.dev metadata, identity
headers, anchored compact, and spend accounting live in
`posoco-ext-opencode-zen` (the shared base); this package is the Go plane's
product seam over them.

## Ports contributed

| Struct | Port | Responsibility |
|--------|------|----------------|
| `OpenCodeGoProvider` | `llm.ProviderFactory` | static `build`: a no-network catalog over the resolved credential/endpoint/model (expanded offline from host-cached records when available) |
| `OpenCodeGoProvider` | `llm.RefreshableProviderFactory` | live `refresh`: one authenticated `/models` call, one slot per discovered model, enriched from the models.dev mirror |
| `OpenCodeGoProvider` | `llm.ApiKeyFactory` | the `/login opencode-go` secret prompt |
| `GoUsageQuotaSource` | devkit `QuotaSource` | the live `/usage` reading: `5h` / `weekly` / `monthly` percentages, reset times, and the endpoint's own rate-limited verdict |
| `GoRateLimitModelPort` | `ModelPort` (slot decorator) | fills `reset_at_ms` on `RateLimited` verdicts from the `/usage` probe so the host's rate-limit guard schedules automatic recovery |
| `go_monthly_allowance` | lookup | the vendor table's per-model monthly dollar allowance for the configured plan (`go` / `go_plus`); `None` = Unlimited or unknown — never a guessed figure |

The extension implements **no** `Extension::manifest`: it is a
factory-registered provider composed through cetas-core's registry, never
held as a top-level extension by the Agent.

## The plane

- **Endpoints** — `https://opencode.ai/inference/go/v1` by default (the
  legacy `https://opencode.ai/zen/go/v1` spelling keeps working via
  `base_url`); chat per model over `{base}/chat/completions`,
  `/responses`, or `/messages`, derived exactly like the zen plane but with
  the **Go** table: qwen3.8-max/flash and MiniMax M3/M2.7 are served on
  Anthropic Messages here (they sit on chat completions on the pay-as-you-go
  plane), luna/grok/muse on Responses, glm/kimi/longcat/deepseek/mimo/hy/
  space-bunny on chat completions, claude on Messages.
- **Credential isolation** — a Zen (`oc_sk_…`) key on the Go plane answers
  `403 EntitlementError`; the two planes never share a credential seam, and
  a misconfigured key surfaces verbatim instead of rendering as fake
  zero-percent quota rows.
- **Identity** — the same OpenCode routing headers as the zen plane with
  this plane's client (`x-opencode-client: opencode-go`,
  `User-Agent: posoco/opencode-go`, process-stable `x-opencode-session`).
- **Spend** — Go pays the same token prices as the pay-as-you-go plane, so
  the shared rates-backed estimate records into this plane's own tracker
  (`posoco_ext_opencode_go`) and publishes the statusbar `spent` segment.
- **Unserved wires** — Google Generative AI / SystemOne models are excluded
  from the catalog; unknown ids default to chat completions and a wrong
  endpoint surfaces as a typed `model_protocol_unsupported` marker.

## Quota: the `/usage` contract

`GET {base}/usage` (Bearer auth) answers `{usage:{rolling,weekly,monthly}}`
(unwrapped accepted too), each window `{percent, resetsAt, status}` —
percentages of the allowance, an absolute reset timestamp, and the
endpoint's own `ok` / `rate-limited` verdict. The endpoint takes no model
parameter and publishes no dollar balance and no plan tier; nothing here
invents them. The readings map onto the shared quota vocabulary:
`window="5h"|"weekly"|"monthly"`, `used_percent`, `reset_at_ms`, and
`available = !rate_limited`. A malformed or missing window is a typed error
— three fabricated `0%` rows would read as a measurement the payload never
made.

## Rate limit: automatic recovery

The shared wire layer already classifies 429 / quota-phrased bodies into
`ModelError::RateLimited`. What the Go plane adds is the **reset time** the
error body usually omits: the slot decorator probes `/usage` (10s timeout)
and fills `reset_at_ms` from the window that is verifiably out — widest
first (monthly → weekly → 5-hour), because a monthly cap explains a refusal
a 5-hour window cannot. The host's rate-limit guard then schedules recovery
at the reset time instead of guessing a backoff. A failed probe keeps the
original error (`reset_at_ms = None`), which the host treats with its
designed probing backoff — never a fabricated reset time.

## Settings contract

`.cetas/settings.json` — all keys optional:

```json
{
  "providers": {
    "opencode-go": {
      "api_key": "sk-...",
      "model": "glm-5.3-flash",
      "plan": "go",
      "max_reasoning_chars": 120000,
      "repeated_reasoning_span_chars": 256,
      "recover_on_reasoning_exhaustion": true
    }
  }
}
```

| Field | Required | Default | Meaning |
|---|---|---|---|
| `api_key` | no | — | Also injectable via `/login opencode-go`; persisted to `~/.cetas/credentials/opencode-go.json`. With neither, the provider is Unconfigured (no slot, no error) |
| `model` | no | `glm-5.3-flash` | The vendor's cheap high-allowance coding slot ($60/month on Go) as the pre-refresh default |
| `base_url` | no | `https://opencode.ai/inference/go/v1` | Override for mirrors; the legacy `zen/go/v1` spelling keeps working |
| `plan` | no | `go` | `go` or `go_plus` — the vendor publishes no way to probe the tier, so the allowance lookup stays a setting; an unknown value is a typed composition failure |
| `protocol_overrides` | no | — | Same contract as the zen plane |
| `max_reasoning_chars` | no | `120000` | DeepSeek reasoning ceiling in streamed characters (not tokens); `null` disables the guard |
| `repeated_reasoning_span_chars` | no | `256` | Exact repeated reasoning suffix span in characters, minimum `128`; `null` disables the collapse guard |
| `recover_on_reasoning_exhaustion` | no | `true` | One bounded nonstream retry at low effort after a reasoning-only length cutoff; `false` disables it |

The three DeepSeek keys are parsed on every build and refresh — a malformed
value is a typed composition failure even when no `deepseek*` model is
selected, never a silent fallback.

## DeepSeek serving contract

The selected `deepseek*` models are served on the chat-completions wire, so the Go
plane mounts the DeepSeek serving contract (`colmugx/posoco-kit-deepseek`)
on those slots only: canonical tool order, request-local user convergence guidance, one
bounded nonstream recovery at low effort, and the two stream guards. The
guards are fail-closed — a collapsing or over-budget reasoning stream is
aborted and surfaces as a typed transport error carrying
`reasoning_repetition` or `reasoning_budget_exceeded`, never a truncated
completion. Models on the Messages wire (and every non-`deepseek` id) are
untouched: the convergence system message is a chat-completions affordance
only. The same key names configure the direct `deepseek` provider, so one
host configuration describes the contract whichever endpoint serves the
model.

## `/login` and `/model`

```bash
/login opencode-go             # prompts "OpenCode Go API key"
```

The static build never touches the network (single slot, or the offline
expansion of the host cache). `/model refresh` performs the authenticated
`GET /models`, enriches from the models.dev mirror (best-effort — the
mirror has no Go section, so Go-only ids degrade to the safe fallbacks),
pins the configured model first, and re-registers the `/usage` quota source
with the current credential. Slot ids are `opencode-go/<bare-model-id>`,
tabbed under `display_group="go"`.

## Compact

Same anchored local summary as the zen plane (no gateway compact endpoint),
with the rate-limit decorator wrapping it so a quota verdict during
compaction recovers the same way.

## Boundaries

- **This extension**: the Go plane's provider seam — settings/plan, the
  Go wire table, `/usage` fetch/decode/quota-source, the rate-limit reset
  decorator, the allowance table, and the `/login` prompt.
- **`posoco-ext-opencode-zen`**: the shared wire ports, protocol
  derivation, models.dev metadata, identity headers, anchored compact, and
  spend accounting.
- **`cetas-core`**: registers `OpenCodeGoProvider` into
  `provider_factories()` / `refreshable_factories()` /
  `api_key_factories()` — one place.

## Dependencies

- `colmugx/posoco` — `ModelPort` trait + `ModelError` / `CompositionError` types
- `colmugx/posoco-ext-opencode-zen` — the shared multi-protocol base
- `posoco/devkit` — `ExtContext`, quota registry
- `colmugx/posoco-kit-rate-limit` — shared quota-verdict classification and
  reset-timestamp parsing
- `colmugx/posoco-kit-deepseek` — the DeepSeek serving contract mounted on
  the `deepseek*` chat-completions slots
- `posoco/ext-llm` — `ProviderFactory` / `RefreshableProviderFactory` / `ApiKeyFactory` / `ProviderModelCatalog` / `ModelSlot`
- `posoco/ext-oauth` — `ApiKeyCredential` / `AuthPromptInteraction`
- `moonbitlang/async/http` — `/models`, `/usage`, and chat transport
