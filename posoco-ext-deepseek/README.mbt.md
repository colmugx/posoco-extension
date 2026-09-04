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
  model="deepseek-v4-flash", // default; may be omitted
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
| **thinking effort** | plain strings `high` / `max`; empty string disables thinking (no `reasoning_effort` on the wire). Unknown efforts abort in the config constructor and are rejected as a typed `CompositionError` at the refresh entry — no implicit fallback |
| **FIM** | `/beta/completions` + `prompt`/`suffix` parameters |
| **Prefix continuation** | `/beta/chat/completions` + `messages[-1]` carrying `prefix:True` |
| **compaction** | two tiers by trigger — Manual = full KV-replay summary; Auto = evict tool-call/result pairs older than the three most recent user turns first, escalate to the same summary only when nothing is evictable or the kept transcript would still sit at ≥ 75% of the window |
| **API key** | `DeepSeekProvider` implements `@llm.ApiKeyFactory`; hosts supply only a generic secret prompt/store |

Hosts may call provider-owned `RefreshableProviderFactory::refresh` during
explicit startup or login to update model order and reasoning-effort
capabilities from the authenticated `/models` response. DeepSeek's `/models`
schema declares no effort field, so the extension advertises `high/max` only
for the documented v4/reasoner families and never guesses that an unknown
model is a reasoning model. Request timeouts, non-2xx statuses, invalid
UTF-8/JSON, and empty catalogs are all typed failures with no implicit
fallback to a static model; the standard OpenAI envelope must also carry
`object: "list"`, and the configured model id keeps priority in the refreshed
result.

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

## Migration

Old config fields `chat_model`, `reasoner_model`, `coder_model`, `thinking`,
and retry fields were removed. Use one model id:

```moonbit
let config = @deepseek.DeepSeekConfig(
  "sk-...",
  model="deepseek-v4-flash",
)
```

Deprecated DeepSeek aliases `deepseek-chat` and `deepseek-reasoner` are not
defaults. Pass them explicitly only for compatibility.

## Dependencies

- `colmugx/posoco` — ModelPort trait + types
- `colmugx/posoco-devkit` — `ExtContext` logger helper
- `colmugx/posoco-ext-llm` — provider-neutral catalog/router
- `colmugx/posoco-ext-oauth` — credential store / auth interaction seams
- `colmugx/posoco-kit-chat-completions` — OpenAI-compatible chat protocol kit
- `colmugx/posoco-kit-compact-evict` — turn-protected tool-result eviction (the Auto compaction tier)
- `moonbitlang/async/http` — HTTP transport
