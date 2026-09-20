# posoco-ext-stats

Speed and token-accounting metrics extension for
[Posoco](https://mooncakes.io/docs/colmugx/posoco): observes core turn
events and publishes the `ttft` / `tps` / `avg` / `cache` status segments
through the devkit status protocol, and renders the accumulated accounting
through two read-only commands. It computes nothing that is not derivable
from turn events — speed from round anchors, token accounting from reported
usage. There is no sampling, no provider polling, and no configuration.

## Ports contributed

| Port | Contribution |
|------|--------------|
| `Observer` | Watches `TurnStarted` / `StreamChunkReceived` / `ModelResponseReceived` and publishes speed segments |
| `CommandPort` | The read-only `cache_doctor` and `usage` commands (`src/stats.mbt:322-353`) |
| `Extension` | Composes into `Agent(exts=[...])` (manifest contributes the observer and the command port, `src/stats.mbt:304-319`) |

## Usage

```bash
moon add colmugx/posoco-ext-stats
```

```moonbit nocheck
// moon.pkg: "colmugx/posoco-ext-stats" @stats

///|
// Composed as in cetas-js (lib/cetas_js.mbt): shares the host's one bus
// with the statusbar bridge and the other publishers.
let stats = @stats.Stats(bus=Some(event_bus))
let agent = @posoco.Agent(exts=[stats, ..other_extensions], config~)
```

Both parameters are optional keyword arguments: `bus? : EventBus? = None`
and `clock? : () -> Int64 = fn() { @async.now() }` (wall-clock
milliseconds). With `bus = None` the observer still maintains its anchors
and publishes nowhere — useful for testing. The injectable clock drives
deterministic tests.

## Segments

| Segment | Priority | Value format |
|---------|----------|--------------|
| `ttft` | 50 | `"<ms>ms"` |
| `tps` | 60 | `"<x.y>/s"` |
| `avg` | 70 | `"<x.y>/s"` |
| `cache` | 80 | `"<hits>/<requests>·<x.y>%"` (process aggregate, withheld until input tokens are reported) |

A **round** is one model response: `TurnStarted` anchors the round start,
the first `TextDelta`/`ReasoningDelta` chunk records the first-token time,
and `ModelResponseReceived` closes the round. Closing recomputes metrics,
then re-anchors at the current time and clears the first-token mark — so a
tool loop measures one round per model response even without a fresh
`TurnStarted`.

Per-round formulas:

- `ttft` = first-token time − round start time (published only when both
  anchors exist, i.e. the round streamed at least one chunk).
- round span = close time − round start time; counted only when
  `0 ≤ span ≤ Int32.max` milliseconds.
- `tps` = output tokens × 1000 / span (ms), for rounds with usage and a
  valid positive span.
- `avg` = running mean of per-round `tps` across every round that had a
  computable rate.

Displayed values: `ttft` as whole milliseconds; `tps`/`avg` to one decimal
place (half-up, e.g. `42.7/s`). A round without usable usage publishes no
segment, and `avg` appears only after the first computable round.

## Token accounting and commands

Each round whose `ModelResponseReceived` carries a `Usage` also accumulates
into a per-session bucket keyed by the dispatched `EventScope` session id
(falling back to a `"(no scope)"` process bucket). Counters move only on
reported data: a round without usage never counts as a request, and absent
token fields contribute nothing — unknown is not zero
(`src/stats.mbt:31-46,108-132`).

Two read-only commands render these buckets as multi-line feedback plus a
structured JSON twin (`src/stats.mbt:398-408`):

- **`cache_doctor`** — per-session prompt-cache hit rates with a read-only
  channel diagnosis: a channel with ≥ 5 usage rounds and an essentially
  zero token hit rate warns that the provider may not cache prompts or a
  proxy splits session affinity across upstreams (`src/stats.mbt:389-395`).
- **`usage`** — cumulative, explicitly labeled token accounting, one line
  per session plus an aggregate
  (`requests · in · out · cache hits <hits>/<requests> (<rate>%)`; the rate
  is omitted while no input tokens are reported) with a `stats_usage`
  structured twin (`src/stats.mbt:493-570`).

Both commands mutate nothing; tests: `cache_doctor …` / `usage reports
cumulative labeled accounting per session and aggregate`
(`src/stats_wbtest.mbt:648-844`).
