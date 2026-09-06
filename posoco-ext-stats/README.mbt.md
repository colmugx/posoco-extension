# posoco-ext-stats

Speed metrics extension for [Posoco](https://mooncakes.io/docs/colmugx/posoco):
observes core turn events and publishes the `ttft` / `tps` / `avg` status
segments through the devkit status protocol. It computes nothing that is not
derivable from turn events — there is no turn counter, no token tally, and no
session knowledge.

## Ports contributed

| Port | Contribution |
|------|--------------|
| `Observer` | Watches `TurnStarted` / `StreamChunkReceived` / `ModelResponseReceived` and publishes speed segments |
| `Extension` | Composes into `Agent(exts=[...])` (manifest contributes only the observer) |

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
