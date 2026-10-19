# posoco-ext-deepseek

> **Targets: native + js** — depends on `moonbitlang/async/http`.
> wasm-gc is not in the supported matrix.

A deeply DeepSeek-tuned [`ModelPort`](https://mooncakes.io/docs/colmugx/posoco)
implementation for Posoco. You pick one model id; the provider owns the
endpoint, thinking effort, tool calls, FIM, prefix continuation, and HTTP
error handling.

## Ports contributed

Two structs, one layer each:

| Struct | Port | Responsibility |
|--------|------|----------------|
| `DeepSeekModelPort` | `ModelPort` | chat / chat_streaming (standard trait path) plus DeepSeek-native APIs |
| `DeepSeekModelPort` | `Extension` | composes into `Agent(exts=[...])` as a model extension |
| `DeepSeekProvider` | `llm.ApiKeyFactory` / `ProviderFactory` / `RefreshableProviderFactory` | host-side provider registration: builds ports from generic settings/secret sources and refreshes the catalog from an authenticated `/models` response |

## Usage

```bash
moon add colmugx/posoco-ext-deepseek
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-deepseek" @deepseek

let config = @deepseek.DeepSeekConfig(
  "sk-...",
  model="deepseek-flash", // provider-owned default; may be omitted
)
let port = @deepseek.DeepSeekModelPort(config)
let catalog = port.model_catalog()
let router = @llm.RouterModelPort::from_catalogs(catalogs=[catalog])

// RouterModelPort is itself an Extension — compose it as the Agent's model.
let agent = @posoco.Agent(exts=[router, ..other_extensions], config~)
```

Hosts can also take the factory path (what cetas does): register
`DeepSeekProvider(ctx~) as &@llm.ProviderFactory` in the factory list, and
settings, login, and catalog refresh all reuse the same seam.

## DeepSeek-native APIs (outside the ModelPort trait)

```moonbit
// FIM completion (/beta/completions, prompt/suffix parameters)
let completion = port.fim_completion(
  "def fib(a):",
  Some("return fib(a-1) + fib(a-2)"),
)

// Prefix continuation (/beta/chat/completions, messages[-1] carries prefix:True)
let result = port.chat_prefix_completion(messages, "```json\n", Some(["```"]))
```

## DeepSeek-specific tuning

| Feature | Implementation |
|---|---|
| **Context cache** | append-only message ordering keeps the prefix byte-stable |
| **reasoning_content replay rule** | resent when the assistant message carries tool_calls; omitted otherwise |
| **reasoning streaming** | `StreamChunk::ReasoningDelta` is pushed to Observers, then discarded |
| **thinking effort** | plain strings `minimal` / `low` / `medium` / `high` / `xhigh` / `max` / `ultra`; empty string disables thinking (no `reasoning_effort` on the wire). Unknown efforts abort in the config constructor and are rejected as a typed `CompositionError` at the refresh entry — no implicit fallback |
| **FIM** | `/beta/completions` + `prompt`/`suffix` parameters |
| **Prefix continuation** | `/beta/chat/completions` + `messages[-1]` carrying `prefix:True` |
| **compaction** | two tiers by trigger — Manual = full KV-replay summary; Auto = evict tool-call/result pairs older than the three most recent user turns first, escalate to the same summary only when nothing is evictable or the kept transcript would still sit at ≥ 75% of the window |
| **API key** | `DeepSeekProvider` implements `@llm.ApiKeyFactory`; hosts supply only a generic secret prompt/store |

Hosts may call provider-owned `RefreshableProviderFactory::refresh` during
explicit startup or login to update model order from the authenticated
`/models` response. Reasoning effort is a uniform provider policy: every
DeepSeek model advertises the complete ladder
`minimal/low/medium/high/xhigh/max/ultra` — the selection is passed through
verbatim and DeepSeek's server maps it itself (minimal/low→low,
medium/high/xhigh→high, max/ultra→max). Request
timeouts, non-2xx statuses, invalid
UTF-8/JSON, and empty catalogs are all typed failures with no implicit
fallback to a static model; the provider composes its own default
`deepseek-flash` when no `model` setting is present — a credential alone
yields a working catalog, and the optional setting only pins priority in the
refreshed result. The standard OpenAI envelope must also carry
`object: "list"`.

## Balance readings

DeepSeek has no subscription plan: the account spends a prepaid balance,
and what the platform announces is "how much money is left" plus "can the
account still serve requests" — never a used percentage or a reset time.
`DeepSeekProvider::balance_source(source)` returns a `devkit.QuotaSource`
(or `None` when unconfigured) backed by
`GET {base}/user/balance` (Bearer key, reusing the settings + credential
the model catalog uses).

Each `balance_infos[]` currency entry becomes one `devkit.QuotaReading`
with `window: "balance"`, `amount: (total_balance, currency)`, the envelope's
`is_available` as `available`, and no `used_percent` / `reset_at_ms` —
exhaustion recovery is a manual top-up, so nothing is schedulable. Entries
missing `currency` or `total_balance` are skipped; with no usable entries
the availability-only reading still reports `is_available`.

```moonbit nocheck
match provider.balance_source(source) {
  Some(source) => match QuotaSource::read(source) {
    Ok(readings) => // compare amount against a configured floor
    Err(reason) => // reading unavailable; never fall back to estimates
  }
  None => // provider not configured
}
```

Both the factory `build` and the explicit `refresh` also register the balance
source into the devkit process-wide quota registry under the provider id
`deepseek` — every configured build re-registers, so the registry always holds
the latest credential snapshot, and the `/status` command pulls from it live.

## Migration

Old config fields `chat_model`, `reasoner_model`, `coder_model`, `thinking`,
and retry fields were removed. Use one model id:

```moonbit
let config = @deepseek.DeepSeekConfig(
  "sk-...",
  model="deepseek-flash",
)
```

Deprecated DeepSeek aliases `deepseek-chat` and `deepseek-reasoner` are not
defaults. Pass them explicitly only for compatibility.

## Dependencies

- `colmugx/posoco` — ModelPort trait + types
- `posoco/devkit` — `ExtContext` logger helper
- `posoco/ext-llm` — provider-neutral catalog/router
- `posoco/ext-oauth` — credential store / auth interaction seams
- `posoco/kit-chat-completions` — OpenAI-compatible chat protocol kit
- `colmugx/posoco-kit-compact-evict` — turn-protected tool-result eviction (the Auto compaction tier)
- `moonbitlang/async/http` — HTTP transport

## Reasoning convergence guards

The provider has two independent safeguards:

- **Repeated tool-call guidance:** after three identical assistant tool calls in the same user turn, with tools still available, the next request includes a one-time convergence instruction. This does not interrupt a single hidden-thinking response.
- **Optional streaming ceiling:** `DeepSeekConfig("sk-...", max_reasoning_chars=Some(120000))` limits accumulated streamed reasoning characters. This is **not** a token budget. The default `None` leaves the ceiling disabled. On breach, the stream is closed and `ModelError::Transport` is raised; no synthetic successful completion is returned. Hosts must handle the error and should not assume a complete assistant message was produced. Non-streaming requests are not affected.

These are safety rails rather than a semantic proof of stagnation. Too-small limits may interrupt useful complex reasoning; choose the ceiling based on observed workload and avoid automatic silent retries after partial stream output.

### Shared ProviderFactory configuration

Any Posoco host that registers `DeepSeekProvider` through the generic `ProviderFactory` can set `max_reasoning_chars` as a positive JSON integer in the provider settings. The limit is read both by offline `build` and live `refresh`, propagated to discovered models and preserved by credential/effort rebuilds. No Cetas-specific integration is needed. Invalid values cause a typed `CompositionError::ManifestSchemaError`; omitted values keep the guard disabled.

The budget is a *fail-closed* streaming resource cap, not automatic semantic convergence or a successful recovery. This feature is scoped to DeepSeek, but works for every Posoco Agent using this extension.

## Optional safe non-stream recovery

All Posoco agents using `DeepSeekProvider` can set
`recover_on_reasoning_exhaustion: true` in generic provider settings, or
`DeepSeekConfig("sk-...", recover_on_reasoning_exhaustion=true)` directly.
The default is false. On a non-stream response with `finish_reason=length`,
no answer text and no tool calls, the adapter makes **at most one** second
request at low reasoning effort. The original transcript is unchanged.
Partial answers and any tool calls suppress retry. Recovery is intentionally
disabled for streaming calls because already forwarded stream events cannot
be safely retracted. Failures of the second attempt remain visible errors;
the adapter does not conceal or indefinitely loop on them.
The provider emits an ordinary ExtContext warning when it takes this path.
