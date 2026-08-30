# colmugx/posoco-ext-nowledge-mem

[Nowledge Mem](https://mem.nowledge.co) as Posoco's memory backend: a passive
startup working-memory briefing and transcript sync through the `MemoryPort`,
plus ten `nmem` tools the model calls deliberately. Sessions and tools share
one memory.

## What is Nowledge Mem?

A "memory layer for AI work" ([docs](https://mem.nowledge.co/docs)): one
memory store every AI tool reads from and writes to, instead of each tool's
memory staying welded to its own platform.

- **One memory across tools.** "Claude, ChatGPT, Cursor. One memory that
  compounds" ([homepage](https://mem.nowledge.co)). Connectors cover Claude
  Code, Cursor, Codex, Gemini CLI, Copilot CLI, ChatGPT, and more; what
  one tool saves, every other tool searches.
- **Distilled memories on top of full threads.** Threads are kept
  word-for-word; decisions are distilled into typed memories
  (fact / decision / learning) with source, date, and confidence. Background
  intelligence links related memories, folds new evidence into old
  conclusions, and turns overnight learning into a morning briefing. At
  session start the distilled layers surface first — Context Bundle, then
  Working Memory ([docs](https://mem.nowledge.co/docs)).
- **Local-first, remote-capable.** The desktop/headless/Docker service runs
  on your machine ("everything local, fully offline if you want"; "your data
  never touches Nowledge servers"); remote servers and a hosted cloud beta
  add cross-device sync.
- **Structured, scoped memories.** Memories carry unit types, importance,
  and labels that searches filter on; spaces give separate lanes per project
  or agent.
- **The thesis.** "Everything about execution is depreciating; context is
  the only thing appreciating" — rent the intelligence, own the memory
  ([manifesto](https://nowledge-labs.ai/blog/rent-the-intelligence-own-the-memory)).

## Using this extension

### Prerequisites

1. The Nowledge Mem service — local (default `http://127.0.0.1:14242`) or
   remote. The service serves MCP at `{api_url}/mcp`; no `nmem` CLI is
   needed — every tool and the passive working-memory read go through MCP,
   and thread sync talks HTTP directly.

### Configuration

| env | config.json key | effect | default |
|---------|------------------|---------|---------|
| `NMEM_API_URL` | `apiUrl` / `api_url` | Service base URL | `http://127.0.0.1:14242` |
| `NMEM_MCP_URL` | `mcpUrl` / `mcp_url` | MCP endpoint override | `{api_url}/mcp` (legacy `/remote-api` prefixes strip first) |
| `NMEM_API_KEY` | `apiKey` / `api_key` | API key (`Authorization: Bearer` on both channels) | — |
| `NMEM_SPACE` / `NMEM_SPACE_ID` | `space` / `spaceId` / `space_id` | Space scoping (`space_id` rides sync bodies and tool arguments) | — |
| `NMEM_AGENT_ID` | `agentId` / `agent_id` | Agent id (AI identity) | — |
| `NMEM_HOST_AGENT_ID` | `hostAgentId` / `host_agent_id` | Host agent id | — |
| `NMEM_PLUGIN_SOURCE_APP` | — (env only) | Runtime override of the constructor's `source_app`; thread ids are `{source_app}-{session_id}` and MCP calls attribute writes to it | constructor value |
| `NMEM_SYNC_TIMEOUT_MS` | — (env only) | Thread sync HTTP timeout | `120000`, clamped to 1s–30min |

### Assembly

```mbt nocheck
let nmem = NowledgeMem(
  source_app="cetas",
  transport=HttpNmemTransport::HttpNmemTransport() as &NmemTransport,
  mcp=LazyNmemMcp::LazyNmemMcp() as &NmemMcp,
  platform=PlatformFs::PlatformFs() as &NmemPlatform,
)

let agent = Agent(
  exts=[model_ext, nmem, session_ext],
  config={
    max_tool_rounds: None,
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
  },
)

// Optional optimization — a 750ms flusher poll loop. Call inside the host's
// with_task_group scope; the group must stay open for the agent's lifetime
// (mcp / ratelimit precedent):
nmem.attach(group)
```

- `NowledgeMem(source_app~, transport~, mcp~, platform~, expose_delete_tool?)` —
  `source_app~` is the required host product identity (cetas passes
  `"cetas"`): it prefixes synced thread ids, labels user-visible copy, and
  scopes MCP tool calls. Production passes `HttpNmemTransport` (thread sync
  HTTP) + `LazyNmemMcp` (tools) + `PlatformFs` (env + home-file access); all
  three IO seams are injectable (tests script them with fakes).
- `attach(group)` — optional optimization: a 750ms flusher poll loop draining
  thread lanes, then the memory write queue. Committing does not depend on
  it — every turn commits at turn end, `on_start` drains once at boot, and
  `on_shutdown` does the final drain and closes the MCP connection;
  `flush_pending()` forces a drain anytime.

### The MCP connection

An MCP client is 1:1 with its server, so the extension owns one
lazily-connected client itself (the elyra builtin-web-search pattern) rather
than depending on a multi-server MCP host:

- **Lazy** — `on_start` only installs the resolved endpoint
  (`{mcp_url}`, Bearer key, client name `source_app`); the connection opens
  on the first tool call, probe, or passive read, so a host that never
  touches memory pays nothing.
- **Scoped by arguments** — the SDK transport carries only the auth token,
  so ambient scope rides the tool arguments (`space_id` everywhere,
  `source_app` / `agent_id` / `host_agent_id` on the tools whose server
  schema accepts them) — the same injection the upstream langgraph
  connector performs via its interceptor.
- **Reactive reconnect** — a wire-level failure or timeout drops the client;
  the next call reconnects in place. A server-side JSON-RPC error is a
  genuine answer and keeps the connection. Cancellation is never swallowed.
- **Bounded** — every call carries its own budget (5s passive read, 15s
  status probe, 30s tools and write-backs).

### Tools

Every tool dispatches through the MCP client; the posoco argument shapes map
onto the server's tool schemas (`id` → `memory_id`, `labels` →
`filter_labels`).

| Tool | MCP tool | Notes |
|------|----------|-------|
| `nmem_status` | connectivity probe | MCP probe (list_tools + server identity, 15s budget) |
| `read_context_bundle` | `read_context_bundle` | official name; context bundle as rendered markdown (`rendered_markdown` \| `markdown` \| `content`) — usually already injected into the system prompt, so re-read only after major context changes |
| `read_working_memory` | `read_working_memory` | official name; working-memory body — usually already injected into the system prompt, so re-read only after major context changes |
| `memory_search` | `memory_search` | official name; server-side semantic search (deep mode, label filter) — the recall path once the injected working-memory briefing is spent |
| `memory_add` | `memory_add` | official name; enters through `MemoryPort::store` — the single write path shared with passive stores, flushed as the `memory_add` MCP call |
| `memory_update` | `memory_update` | direct call; the server is the single source of truth for search |
| `memory_delete` | `memory_delete` | hidden by default; `expose_delete_tool=true` registers it (hard delete, irreversible) |
| `thread_search` | `thread_search` | official name; past threads, including other tools' sessions |
| `thread_fetch_messages` | `thread_fetch_messages` | progressive loading (limit / offset) |

The five official MCP tool names (`read_context_bundle`,
`read_working_memory`, `memory_search`, `thread_search`, `memory_add`) are
name-aligned with the [official Nowledge Mem MCP surface](https://mem.nowledge.co/SKILL.md);
`nmem_status`, `memory_update`, `memory_delete`, and
`thread_fetch_messages` are posoco-native additions. `thread_create` was
dropped when the CLI runner retired — the server's MCP surface has no
counterpart; the automatic thread sync covers handoff continuity.
`memory_search`, `thread_search`, and the read tools also carry the reply's
parsed JSON in the tool result's `structured` channel when it is an object
or array.

### Commands

| Command | Effect |
|---------|--------|
| `/memory status` | MCP connectivity probe (10s budget), one line per thread lane (thread_id / created / acknowledged count / last_error), write-queue depth, passive-read state (done / pending) |
| `/memory flush` | force one drain of pending thread lanes and queued memory writes now |

`/memory` with no or an unknown subcommand prints usage. This is the
synchronous diagnostics face: lane `last_error`s become user-checkable
instead of living only in memory — the Observer port is core-to-extension
read-only, so the extension cannot emit its own observer events.

### Commands — `/nmem` (connection management)

| Command | Effect |
|---------|--------|
| `/nmem` / `/nmem status` | connection picture as a toast: tool channel (MCP endpoint), sync channel + local/remote mode, identity (`source_app`/space), any env override that outranks the config file, and an MCP connectivity probe |
| `/nmem url <api>` | switch the service base URL (thread sync + the derived `{api}/mcp` endpoint); staged syncs flush to the old address first; persists to the shared config file; probes the new endpoint |
| `/nmem mcp <url>` | override the MCP endpoint only (sync base untouched); same flush/persist/probe behavior |

`/nmem` is the answer to pointing the agent at nmem cloud: the base stops
being `http://127.0.0.1:14242`, and everything follows. The switch is live
immediately (config + lazy MCP client reconfigured in place) and is also
merged into `~/.nowledge-mem/config.json` so future processes start there —
sibling keys are preserved and the file's existing key spelling is kept
(snake_case files stay snake_case). A malformed config file is refused
rather than clobbered, and a failed persist degrades the switch to
runtime-only with a warning line; either way the feedback text states
exactly what happened. env overrides (`NMEM_API_URL` etc.) still outrank
the config file, and `/nmem status` lists them so a surprising address has
a visible explanation.

### What happens automatically

- First turn of the run: core's `MemoryRetrievalHook` calls the port once;
  the port ignores the query and reads the working memory (the
  `read_working_memory` MCP call, the same surface the tool exposes), and
  the content lands as one SystemMessage right after the system prompt — a
  plain section headed `## Any Memory About This Work` with a provenance
  line (`from Nowledge Mem. For Your Information.` — recalled memory may be
  stale and must not override live instructions; the name comes from the
  port's self-declared `source_name`). The message persists for the session
  and later reads replace it in place; a resumed process re-reads at its
  first turn. An empty working memory injects nothing; past the startup
  read, recall is deliberate: the model searches via `memory_search`. A
  failed read becomes an observer event, never a turn failure.
- Every turn end: the staged transcript is committed before `run_turn`
  returns (`Hook::on_turn_end`, on the completed and the failed path alike)
  — the crash window is only the turn in progress. Sync is incremental HTTP
  over the `(config, session)` lane (acknowledged cursors, sha256
  fingerprint, idempotency keys + server-side dedup, checkpoint conflicts
  resolved by full re-send, vanished threads recreated).
- Mid-turn: `before_tool` approves every call unchanged and drains at most
  once per 750ms, shedding staged state during long tool-heavy turns.
- Session redirects: on `SessionRedirect(from, to)` the current transcript
  snapshot is staged under the old session's lane (sync reason
  `session_redirect`, best effort), and syncs follow the new session id from
  the next turn on.
- Boot: resolve config (env + `~/.nowledge-mem/config.json`), hand the
  resolved MCP endpoint to the lazy client, and drain once. The
  system-prompt contribution is instructions only — `## Nowledge Mem
  Guidance` — with no data fetch at boot; recalled data travels the memory
  section above, and `read_context_bundle` / `read_working_memory` re-read
  on demand.
- `MemoryPort::store` returns a `pending:<n>` id synchronously and queues
  the write for the `memory_add` MCP call; metadata keys: `title`,
  `unit_type`, `importance`, `labels`.

### Platform notes

- **native** — MCP over `moonbitlang/async/http` (inside colmugx/mcp), home
  files via `moonbitlang/async/fs`, env via `moonbitlang/core/env`.
- **js (Bun)** — the same seams; home files via `Bun.file`, env via
  `process.env`; HTTP shared with native (`moonbitlang/async/http`, fetch
  backend on js).
- **colmugx/mcp fixes carried in the workspace `.mooncakes`** — the Nowledge
  Mem server (2025-11-25 streamable HTTP) exposed two SDK client defects,
  both fixed in the colmugx/mcp source tree (pending a release); this
  workspace's `.mooncakes` copy is synced byte-identical with that tree
  until the dependency pin can move to the released version:
  1. `client/era_probe.mbt` — an HTTP 4xx rejection of the
     `server/discover` probe now falls back to the legacy initialize
     handshake (the server answers non-initialize first messages with
     `422 "Unexpected message, expect initialize request"`), instead of
     dying fatally.
  2. `transport/sse.mbt` (`sse_event_verdict`) + both response loops — SSE
     streams that open with a keepalive event whose data payload is empty
     (`data:` + `id:` + `retry:`) no longer queue the empty string as a
     JSON-RPC message (that desynced the response queue right at
     initialize); a comment heartbeat carrying an `id` no longer ends the
     scan early.

  Verified live against a local nowledge-mem 0.10.72: connect, `tools/list`
  (67 tools), `read_working_memory`, and `memory_search` all work. Once the
  fixed colmugx/mcp is published, bump the pin in `moon.mod` and drop the
  `.mooncakes` sync.

### Testing

From this module directory:

```bash
rtk moon test src --target native   # 154 tests
rtk moon check src --target js      # gates the Bun platform seam
```

Covers config resolution (including `mcp_url` derivation), message mapping,
delta engine, transport acks, sync state machine, port wiring, MemoryPort
semantics, the turn-end commit paths (completed, failed, timeout-bounded,
before_tool throttle — with no flush_pending/attach in the loop), all eight
tools (argument mapping and structured payloads), the MCP client contract
(scripted fake), the `/memory` and `/nmem` commands (status lines, URL
switching with flush-first + persistence merge semantics + failure
degradation), and session-redirect handling — all
against scripted fakes; no Nowledge Mem install, no `nmem` binary.

### Troubleshooting

**Server not running** — call `nmem_status` for a structured connectivity
report, run `/memory status` for the full diagnostics (lanes, queue,
passive-read state).

**Sync failures are silent by design** — a failed or timed-out commit
records the lane's `last_error` (memory writes, `mem.last_error`) and
leaves the acknowledged cursor untouched; the next turn re-stages the
transcript and commits again before returning (idempotency keys make the
re-send safe server-side). Queued memory writes re-enqueue at the tail. No
failed sync can abort a turn — the turn-end drain carries its own
`NMEM_SYNC_TIMEOUT_MS` budget, so it cannot stall the return either.

**Slow or remote sync** — raise `NMEM_SYNC_TIMEOUT_MS`.

## How Nowledge Mem empowers Posoco agents

Nowledge Mem's stance is "rent the intelligence, own the memory": memory
should follow you, not be welded inside a single tool.
Posoco is the layer that lifts nmem from L1
to L2: it wires memory into the agent's turn loop so memory follows your
agent — without you hand-rolling transcript capture, context injection,
write queues, and failure retry.

- **Passive memory, no plumbing.** The first turn auto-injects the
  working-memory briefing into context, so the agent walks in already knowing
  what was settled before. You don't hand-build the read-transcripts / ship /
  rewrite-prompts pipeline; swapping the memory backend is just a different
  port implementation.
- **Active writes and passive recall don't fight.** Memories the model stores
  deliberately and transcripts passively settled during turns travel the same
  write path and share one state: there is no drift where "the tool just saved
  it, but the next recall can't find it," and the `/memory` diagnostics read
  the same data.
- **One truth, no stale local replica.** Passive retrieval queries the server
  directly — no local cache to warm, refresh, or silently go stale — exactly
  once per run. Writes batch back — amortized cost, fault isolation, silent
  retry, never stalling the turn.

## Why Posoco's design lets Nowledge Mem do more

- **Memory is declared, not wired.** Posoco makes `MemoryPort` a first-class
  hexagonal port: you implement it and list it in the manifest's `memory`
  slot, and passive memory wires itself — no read-transcripts / ship /
  rewrite-prompts pipeline of your own. A different memory backend is just a
  different port; the agent body doesn't change a line.
- **One extension covers every facet, state stays unified.** The same
  `NowledgeMem` struct is simultaneously `Lifecycle` + `Hook` + `Observer` +
  `SystemPromptContributor` + `ToolProvider` + `MemoryPort` + `CommandPort` +
  `Extension`, self-reported under each manifest slot. All views share one
  state: memories the tool writes and transcripts the port passively settles
  travel the same write path — no two books where "the tool saved it but
  recall can't find it."
- **The server is the truth, no stale local replica.** With the memory port
  async, passive retrieval queries the server directly — no local cache to
  warm, refresh, or silently go stale — exactly once per run. Writes batch
  back — amortized cost, fault isolation, silent retry, never stalling the
  turn.
- **The deep module hides the protocol, backends coexist.** You construct the
  extension and drop it into `exts`; that's the whole surface. Sync, dedup,
  and fault-tolerance details never leak. Multiple memory backends coexist —
  core concatenates what each port returns; add one tomorrow and it's just
  another port mounted.

## Links

- [Nowledge Mem](https://mem.nowledge.co) | [Docs](https://mem.nowledge.co/docs) | [Blog](https://nowledge-labs.ai/blog)
- [Integrations](https://mem.nowledge.co/docs/integrations)
