# posoco-devkit

Small helper layer for Posoco extension authors.

Core Posoco does not depend on this package. Extension authors can depend on it
for shared diagnostics helpers, gate classifiers, and cross-extension plumbing
instead of re-implementing them per extension.

## Logging context

`ExtContext` carries one `&Logger` through extension code. `NoopLogger` is the
default; `MemoryLogger` records events for tests. Devkit defines only the
trait and these two in-memory sinks — it binds no output backend, so hosts
stay free to wire logging (or omit it) at the product layer.

```moonbit
let logger = MemoryLogger()
let ctx = ExtContext(logger)
ctx.warn(source="my-ext", code="my.warn", message="something happened")
```

## Cross-extension event bus

`EventBus` is the product-level pub/sub channel: the host constructs one bus
and hands it to every extension that wants to publish or subscribe (`BusEvent`
carries `source`/`topic`/`data`). Publishing is fire-and-forget, dispatch is
synchronous and ordered, reentrant publishes queue behind the in-flight batch,
and a subscription registered mid-batch starts receiving with the next batch.

```moonbit
let bus = EventBus::EventBus()
bus.publish({ source: "posoco_ext_scrum", topic: "status", data: Json::null() })
```

## Status protocol

`status_op` is the wire protocol shared by every status-bar publisher and the
statusbar bridge extension. Operations travel on the bus topic
`"status"` as Json object payloads, so the protocol survives transport
mapping and third-party publishers:

| Op | Payload |
|----|---------|
| register | `{"op":"register","segment":s,"priority":p,"label":l,"value":v,"color":c}` — `label`/`value`/`color` keys emitted only when present, `priority` always |
| update | `{"op":"update","segment":s,"value":v}` |
| unregister | `{"op":"unregister","segment":s}` |

- **Ownership** is enforced by the bridge, not here: the source of the first
  register-or-update for a segment owns it, and the bridge ignores other
  sources' operations on it.
- **update auto-registers**: an update for a segment the bridge has not seen
  acts as an implicit register with default priority 0.
- **Decode tolerance**: `decode_status_op` returns `None` for events on other
  topics, non-object payloads, missing/unknown `op`, and missing or wrongly
  typed required fields — decoding never raises, so one bad publisher cannot
  crash the host. `priority` is the one forgiving field: absent or
  non-numeric decodes to 0 rather than dropping the event.
- **Color is a register-time declaration** (`color?` on
  `publish_status_register`): a semantic role from the closed vocabulary
  returned by `status_color_roles()` — `accent` / `warning` / `error` /
  `success` / `info` / `muted` — never a raw color value; ANSI/hex strings
  do not travel on the protocol. The vocabulary is exposed as a *function*
  (`status_color_roles()` returns a fresh array per call) because the
  toolchain rejects `const` arrays; membership tests go through
  `is_status_color_role`. Decode is strict on type but not on vocabulary:
  a present non-String `color` rejects the whole event, while a
  present-but-unknown role still decodes. Negotiation is propose/dispose:
  the extension proposes a role, the host theme resolves it to concrete
  colors and may ignore any declaration — the bridge silently de-colors
  unknown roles (`is_status_color_role` is the enforcement hook). Changing
  color means re-registering the segment; `update` never carries it.

```moonbit nocheck
// Publisher side — order segments on the bar with priority (ascending),
// optionally proposing a semantic color role.
publish_status_register(
  bus,
  source="posoco_ext_myext",
  segment="greet",
  priority=10,
  value="hello",
  color="accent", // optional; omit for a role-less segment
)
publish_status_update(bus, source="posoco_ext_myext", segment="greet", value="hi")

// Consumer side (the bridge, or any subscriber):
match decode_status_op(event) {
  Some(Register(segment~, priority~, ..)) => // claim or metadata change
  Some(Update(segment~, value~)) => // value change
  Some(Unregister(segment~)) => // release
  None => () // malformed event: drop and move on
}
```

## Provider quota seam

`QuotaSource` is the seam between provider adapter extensions and quota
consumers (rate-limit guards, status bars): implementations live in the
adapter extensions, where the credentials and base URLs the probe needs
already reside, and consumers depend only on the trait. Implement `read`
(per `QuotaSource`) to expose a provider's authoritative readings; `read`
returning `Err` means the reading is unavailable — never a fallback estimate.

Each `QuotaReading` is one authoritative reading as stated by a provider;
nothing is estimated locally. The optional fields exist only when the
provider stated them: `used_percent` is the provider's official percentage,
`reset_at_ms` its stated reset time (balance-style providers have neither),
`amount` is `(value, currency)` for balance-style readings whose semantics
are "remaining funds" rather than "fraction of a window used", and
`available` is the provider's own yes/no on whether the account can currently
serve requests. `fetched_at_ms` always accompanies a reading so consumers can
gate on staleness. `window` is a provider-owned opaque label string (examples
seen: `"5h"`, `"weekly"`, `"balance"`); devkit defines no label vocabulary and
never interprets labels.

```moonbit nocheck
// Consumer side: labels are provider-owned; match on what it actually emits.
match QuotaSource::read(source) {
  Ok(readings) => // per reading: used_percent / amount / reset_at_ms / available
  Err(reason) => // reading unavailable; never fall back to estimates
}
```

## Provider pricing seam

`PricingSource` is the pricing analog of the quota seam: adapter extensions
that own a vendor pricing rule state the current phase — `fn phase(Self) ->
PricingPhase?` where `tier` is `"peak"` or `"off-peak"`, `multiplier` is the
provider's own multiplier text, and `window` is its display text naming the
surcharge period — and consumers such as the `/model` catalog pull the phase
live at command time. `phase` returning `None` means no pricing is known,
never a fallback estimate. Registration mirrors the quota registry: register
under the provider id on every configured build (last write wins), look up at
consumption (`src/pricing.mbt`).

## Provider metrics seam

`ModelMetricsSource` is the third pull seam: adapter extensions that know an
external benchmark feed state per-model-per-effort points — `async fn
read(Self) -> Result[Array[MetricsPoint], String]` where each point carries
the source's own `model`, `effort`, `iq`, `cost_usd`, and `passed`/`total`
problem counts, plus optional `tokens`/`minutes` (average run token total
and duration) present only when the source stated them — the dimensions a
consumer needs to compare completions of the same task. Nothing is
estimated locally: `read` returning `Err` means metrics are unavailable,
omitted optionals are never zero-filled, and entries for other providers
pass through unfiltered — consumers intersect the points with their own
slots. Registration mirrors the quota and pricing registries: register
under the provider id on every configured build (last write wins), look up
at consumption (`src/metrics.mbt`).

## Read-before-modify freshness

`FreshnessGuard` is the ledger shared by the read/write/edit tool extensions:
reads record a `FileStamp` (mtime + size), and write/edit compare a fresh stat
against it so a write never silently clobbers content that changed since the
last read. Verdicts are `Fresh` / `NeverRead` / `Modified`, with
`freshness_hint` providing the plain-language error text.

```moonbit
let ledger = FreshnessGuard::FreshnessGuard()
ledger.note_read("/a.txt", stamp)
inspect(ledger.check("/a.txt", Some(stamp)), content="Fresh")
```

## Diagnostics sanitization

`sanitize_path` / `sanitize_label` keep user-controlled paths and names
bounded and single-line in tool error messages: truncation with a trailing
`...`, and every control character (newline, tab, escape sequence, DEL) is
replaced with a space so diagnostics cannot forge terminal output.

## Context prompt envelopes

`context_envelope` builds one
`<{ns}-context type="…" trust="…" source="…" …>…</{ns}-context>` element
with XML-escaping of `source`, custom attribute values, and `content` —
the same builder a context extension's `ContextPromptContributor` uses,
available to any host that assembles context prompts. `ns` is the host's
bare namespace (`"cetas"` renders `cetas-context` elements); the
`-context` suffix is appended by the builder. Extra `attrs=[(name, value),
…]` pairs render after the standard attributes, in order (names are
trusted configuration, values are escaped), for per-call facts like
`turn="4/10"`. `render_context_envelope` remains as a deprecated alias.
