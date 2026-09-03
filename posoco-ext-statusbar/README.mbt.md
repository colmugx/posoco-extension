# posoco-ext-statusbar

A pure status-bar bridge for [Posoco](https://mooncakes.io/docs/colmugx/posoco):
it keeps one registry entry per status segment and projects the registry into
a single `UiSlot::Status` render intent with the conventional key
`"statusbar"`. The bar owns no facts — it knows nothing about agents, turns,
models, or tokens. Peer extensions own every segment and publish
`register` / `update` / `unregister` ops on the shared
[posoco-devkit](../posoco-devkit) `EventBus` (topic `"status"`); the bridge
consumes those ops and renders.

## Ports contributed

| Port | Contribution |
|------|--------------|
| `BusSubscriber` | Decodes status ops from the shared event bus and applies them to the registry |
| `CommandPort` | `/statusbar` — read-only provider listing |
| `Lifecycle` | Receives the composed `UiPort` at `on_compose`; render intents flow only from then on |
| `Extension` | Self-reporting manifest (`requires: [Ui]`; the `ui` slot stays empty — the bridge is a UI consumer, not a provider) |

## Usage

```bash
moon add colmugx/posoco-ext-statusbar
```

```moonbit nocheck
// moon.pkg: "colmugx/posoco-ext-statusbar" @statusbar

///|
// Composed as in cetas-js (lib/cetas_js.mbt) — one shared bus, constructed
// before any publisher so no fire-and-forget status op is dropped:
let event_bus = @devkit.EventBus()
let statusbar = @statusbar.StatusBar(bus=Some(event_bus))
// ... publishers share the same bus ...
let agent = @posoco.Agent(exts=[statusbar, ..other_extensions], config~)
```

Without `bus`, the bridge never subscribes; hosts and tests can still drive
the same semantics directly through `set_segment` / `clear_segment`.

## Status ops

The bridge understands the three devkit status operations (wire shapes in
`@devkit.status_op`; malformed events decode to `None` and are dropped):

- **register** — claim `segment` with `label`, `priority`, and `value`. The
  **first source to register-or-update a segment owns it**; operations on the
  segment from any other source are ignored (no state change, no render). The
  owner may re-register to overwrite its metadata, keeping its original
  position.
- **update** — set the segment's value. For a segment the bridge has not
  seen, an update acts as an implicit register (owner = source, priority 0,
  no label).
- **unregister** — remove the segment. Only the owner can release it;
  foreign or unknown segments are ignored. A segment can register again
  afterwards.

## Color roles

A register op may declare a **semantic color role** for the segment (the
devkit `color?` field). The bridge validates the declared role against the
devkit vocabulary (`status_color_roles()`) and stores it per segment: a
known role passes through; an unknown or absent role is stored as none —
unknown roles are silently de-colored, never surfaced to the host. The role
is register metadata like label and priority: `update` never carries it, so
changing color means re-registering the segment. Roles surface in two
places: the `/statusbar` listing and each entry of the `UiBody::Entries`
render body. **Separators and concrete colors are host policy** — the
closed vocabulary is the only contract between publisher and host.

## Ordering and rendering

- Segments display in **priority ascending** (left to right); equal
  priorities keep **first-seen registration order**.
- Only segments with a value are visible; valueless registered segments
  appear in `segments()` and `/statusbar` but not on the bar.
- Every **applied** change renders exactly once — including a change that
  empties the bar (an empty Entries body clears the host line). Ignored
  events (ownership rejections, malformed payloads) never render.
- The render is one `UiRender` with slot `UiSlot::Status`, key
  `"statusbar"`, body `UiBody::Entries` (no title, no ttl) — one entry per
  visible segment, each carrying `key`, `value`, and the segment's optional
  color role. **Placement is the host's layout policy**: cetas-js
  routes `status:statusbar` to a mount below the editor; another host may
  mount it elsewhere or ignore it.
- Before `on_compose` delivers the UI, applied changes stay silent instead
  of rendering nowhere. With event-driven publishers there is nothing to
  show at startup anyway: the bar starts empty and fills as peers publish.

## /statusbar

Takes no arguments — segment order is decided by publishers through their
priorities, not by the user. It prints `segment | owner | p<priority> |
<color> | <value>` per registered segment (role-less and valueless shown
as `—`) plus a structured JSON listing that carries each segment's role.

## Status facts reference

The bundled publishers and their priorities (see each package's README):

| Segment | Provider | Priority |
|---------|----------|----------|
| `plan` | posoco-ext-plan | 10 |
| `model` / `tok` / `cache` | posoco-ext-llm | 20 / 30 / 40 |
| `ttft` / `tps` / `avg` | posoco-ext-stats | 50 / 60 / 70 |
| `session` | posoco-ext-fs-session | 80 |
| `resume` | posoco-ext-ratelimit | 90 |
