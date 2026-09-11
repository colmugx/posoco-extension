# posoco-ext-llm

`posoco-ext-llm` is a provider-agnostic model router. It does not construct
HTTP adapters and it does not depend on DeepSeek, Kimi, or OpenAI. Provider
extensions construct their own `ProviderModelCatalog` values; the host only
assembles those catalogs.

```moonbit
let provider = make_provider_port()
let catalog = provider.model_catalog()
let router = @llm.RouterModelPort::from_catalogs(catalogs=[catalog])
```

`RouterModelPort` delegates `ModelPort` calls to the active slot. Provider
catalogs advertise effort choices and provide a rebuild hook, so
`/model {slot, effort}` validates and applies effort without the host knowing
provider request fields.

The router also declares these commands:

- `/model [slot]` lists the slot catalog or switches the active slot. The
  no-argument catalog enriches each slot-contributing provider's entries with
  its devkit-registered pricing phase (`pricing: {tier, multiplier, window}`
  facts stated by the provider extension; omitted when none is registered —
  `src/command_model_pricing.mbt:13-41`); the quick-pick, slot-switch, and
  effort payloads carry no pricing.
- `/model {slot, effort}` additionally selects a provider-advertised effort.
- `/model quick-pick` returns the slot catalog enriched with each
  slot-contributing provider's quota readings (host-injected sources first,
  then the devkit registry; sources are read concurrently, each under a
  2500 ms cap; a failed or slow provider is omitted, never estimated —
  `src/command_model_quick.mbt:23-73`), and refreshes the active provider's
  status bar when its pull succeeds (`src/command_model.mbt:349-359`). The
  keyword is reserved and wins over a real slot of the same name; an `effort`
  argument is rejected (`src/command_model.mbt:342-346`).
- `/model <provider> pick` auto-picks a cost-efficient model+effort from
  the provider's devkit-registered metrics source: points whose model
  names one of the provider's slots and whose effort that slot advertises,
  guarded by a minimum benchmark sample (`total >= 30`) and required to
  state every scored dimension (token total, duration, positive pass
  count; token efficiency is amortized tokens per solved problem —
  `tokens * total / passed` — because failed attempts burn tokens too).
  Points dominated on all four dimensions (IQ, token efficiency, cost,
  duration) drop out before ranking, then the survivors rank by
  `iq - 1.0 * (tokens_per_pass / 1M) - 2.0 * cost_usd - 0.5 *
  (minutes / 10)` — the priority gradient 分数 > tokens > 金钱 > 时间,
  calibrated so the expensive-efficient pick beats a cheap-but-verbose
  one (107.81 IQ @ $2.26 / 1.53M tokens-per-pass / 9 min wins over
  102.23 IQ @ $0.54 / 26.34M / 37 min). The winner
  switches exactly like a manual `/model {slot, effort}`; ranks 2-3 ride
  along in the structured payload as `{slot_id, model, effort, iq,
  cost_usd}` candidates for host-side notices. A failed read, an unknown
  provider, or an empty eligible pool fails the command — never a fallback
  pick (`src/command_model_pick.mbt`, intercept at
  `src/command_model.mbt:367-390`).
- `/login [provider]` lists provider authentication capabilities or runs the
  selected injected provider login flow. Use
  `/login {provider: "kimi", method: "oauth"}` or
  `/login {provider: "deepseek", method: "api_key"}`.
- `/status` reports the active provider's facts as multi-line feedback (plus
  a structured JSON twin): provider/model ids, selected effort, context
  window (provider-stated when the slot carries one), reasoning efforts, and
  the `5h`/`weekly` quota windows when a provider extension has published
  them on the shared bus (Codex's quota publisher does). It also pulls the
  active provider's registered quota source live at invocation through the
  devkit quota registry (DeepSeek's balance, Z.ai Coding Plan's windows);
  bus windows win over registry duplicates, and a provider `Err` reading is
  skipped, never estimated. With no bus and no pull readings it states
  `quota: no readings yet` instead of estimating. Quota windows render
  codex CLI-style as `5h: 66% left`: registry readings convert the
  provider-declared used percent with exact arithmetic (`100 − used`, not an
  estimate), and bus-published window values — already published in `N%
  left` shape by their provider — are passed through unchanged.

## Status facts

With an `EventBus` injected (`bus? = None` by default — without one every
publication below is a silent no-op), the router publishes three status-bar
segments through the devkit status protocol for a status-bar bridge to
render:

- **`model`** (priority 20) — `"<model-id>:<effort>"`: the active slot's
  model id plus the selected effort, falling back to the slot's declared
  default effort and then `"default"`.
- **`ctx`** (priority 30) — `ctx: <occ>/<window> · <pct>`: the
  core-projected context state of the active session
  (`src/observer.mbt:56-145`). Occupancy is the last measured reading plus
  the core-reported estimate, marked `~` whenever an estimated component is
  included; an absent or untrusted reading renders `?` — never zero. The
  window renders `?` when the slot carries none, and the percentage appears
  only when occupancy and a positive window are both known. State is per
  session: `TurnStarted` re-publishes the scoped session's own state and
  never resets occupancy, and compact/operation-lifecycle events never
  touch the segment (core projects the state around them; post-compact it
  is explicitly awaiting measurement; `src/router_wbtest.mbt:411-663`).
- **`cache`** (priority 40) — `"<n>%"`: the last committed round's
  cached-input percentage (`cached × 100 / input`). When the round reports
  no usable cache counters (or zero input) the segment is **unregistered**
  so a stale percentage never lingers.

Publication triggers: `ContextStateUpdated` (store the session's state and
publish `ctx`), `TurnStarted` (re-publish the scoped session's `ctx` — no
reset), and `ModelResponseReceived` (republish `cache` and `model`). A
successful `/model` or `/effort` switch re-publishes
`model` immediately — slot switches go through `switch_slot`, which
publishes too, so the bar reflects the choice before the next turn.

Whenever the active slot's provider can change — `on_compose`, a `/model`
switch, `/effort`, `switch_slot`, or the `replace_provider_slots` fallback —
the router also publishes a **`provider`** event on the bus: source
`"posoco_ext_llm"`, topic `"provider"`, payload
`{"provider_id": "<active provider id>"}`. Provider-scoped status publishers
(Codex's quota segments, for example) subscribe to it to show or hide their
own segments when the active provider changes; republication is idempotent.
Without a bus the publication is a silent no-op.

The router also publishes **registry quota segments** (priority 45) when the
active provider has a source in the devkit quota registry — DeepSeek's
`balance`, and the Z.ai Coding Plan / Kimi `5h`/`weekly` windows: balance
readings render a `balance` segment with `"<value> <currency>"`, window
readings render the window name with `"<n>% left"` (`≤20` warning, `≤0`
error, matching codex). Refresh points: after each chat response (the pull
never delays the first token), on `/status` (the command's live pull doubles
as the bar refresh), and immediately on a `/model`/`/effort` switch;
`switch_slot` only clears the previous provider's segments and resets the
pull cache. Successful pulls throttle re-reads for 30 minutes and failed
pulls back off for 5 minutes, so a bad endpoint never slows chat. Codex
deliberately has no registry source — its windows are push-shaped and stay
owned by `CodexQuotaStatus`, while the router clears its own quota segments
for it (distinct `source`; provider scoping keeps the two publishers
mutually exclusive).

Authentication is explicit and provider-neutral. OAuth uses a
`CredentialStore`, an `AuthInteraction`, an `OAuthProvider` on the slot, and,
when credentials change adapter configuration, a `rebuild_on_credential`
factory. API-key login uses an `ApiKeyStore`, an `AuthPromptInteraction`, an
`ApiKeyFactory`, and `rebuild_on_api_key`. The router persists credentials and
replaces every matching slot that declares the corresponding factory. Missing
dependencies fail as `CommandError::ExecutionFailed`; no silent fallback is
used. API-key secrets are never included in diagnostic text.

Provider adapters and catalogs live in separate extensions, one per provider;
each catalog advertises only the capabilities that provider supports (for
example chat/streaming/reasoning only for a provider without FIM support).

Providers with authenticated model discovery may additionally implement the
optional async `RefreshableProviderFactory` seam. Hosts invoke it explicitly
(for example at startup or immediately after login); normal catalog composition
remains a pure snapshot build and `/model` never performs an implicit network
refresh. A refresh failure is typed and observable rather than hidden behind a
stale/static fallback.
