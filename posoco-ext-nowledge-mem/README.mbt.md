# colmugx/posoco-ext-nowledge-mem

[Nowledge Mem](https://mem.nowledge.co) as Posoco's memory backend: a passive
startup working-memory briefing and transcript sync through the `MemoryPort`,
plus ten `nmem` tools the model calls deliberately. Sessions and tools share
one memory.

## What is Nowledge Mem?

A "memory layer for AI work" ([docs](https://mem.nowledge.co/docs)): one
memory store every AI tool reads from and writes to, instead of each tool's
memory staying welded to its own platform.

**The thesis.** "Everything about execution is depreciating; context is
  the only thing appreciating" — rent the intelligence, own the memory
  ([manifesto](https://nowledge-labs.ai/blog/rent-the-intelligence-own-the-memory)).

## Using this extension

### Prerequisites

1. The Nowledge Mem service — local (default `http://127.0.0.1:14242`) or
   remote. The service serves MCP at `{api_url}/mcp`; no `nmem` CLI is
   needed — every tool and the session's opening memory read go through
   MCP, and thread sync talks HTTP directly.

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

```bash
moon add colmugx/posoco-ext-nowledge-mem
```

```mbt nocheck
// moon.pkg: "colmugx/posoco-ext-nowledge-mem" @nmem
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

### Tools

Every tool dispatches through the MCP client; the posoco argument shapes map
onto the server's tool schemas (`id` → `memory_id`).

| Tool | MCP tool | Notes |
|------|----------|-------|
| `nmem_status` | connectivity probe | MCP probe (list_tools + server identity, 15s budget) |
| `read_context_bundle` | `read_context_bundle` | official name; the context bundle — working memory plus related distilled knowledge — as rendered markdown (`rendered_markdown` \| `markdown` \| `content`); re-read on demand after major context changes, not routinely |
| `memory_update` | `memory_update` | direct call; update an existing memory in place when new information refines it (update semantics are not on the port surface) |
| `thread_search` | `thread_search` | official name; past threads, including other tools' sessions |
| `thread_fetch_messages` | `thread_fetch_messages` | progressive loading (limit / offset) |
| `memory_delete` | `memory_delete` | hidden by default; `expose_delete_tool=true` registers it; the `MemoryPort` `delete` slot — a `pending:` ticket drops the queued add locally, a real id queues the hard delete for the drain |

### Commands

| Command | Effect |
|---------|--------|
| `/memory status` | MCP connectivity probe (10s budget), one line per thread lane (thread_id / created / acknowledged count / last_error), write-queue depth, session inbound state (injected / pending) |
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

## What happens automatically

- First turn of a session: core sees the empty loaded transcript and gives
  every wired memory provider exactly one `inbound(session_id~, request~)`
  call. This extension reads the working-memory snapshot over the MCP
  channel (5s budget — the read sits on the model-call path) and returns it
  wrapped in its own `<nmem-context type="memory" trust="false">` envelope
  (capped by the context limit) as the complete body;
  core injects it verbatim as one user-role message behind its fixed lead
  line, placed before the first real user input. The message is frozen:
  injected exactly once per session lifetime and never rewritten — the
  attempt is spent even when working memory is empty. A resumed process
  finds the persisted message in the loaded history and keeps it
  byte-identical — the history was derived under it, so swapping in a newer
  snapshot would detach the conversation from its context (and break the
  provider's prefix cache for the whole history). The envelope also never
  reaches the synced thread: `map_messages` skips it, so thread titles stay
  the first real user message. An empty working memory contributes nothing;
  a failed read is reported to core, which emits a `secondary_failure`
  observer event naming this extension — the turn proceeds. Past the
  opening snapshot, recall is deliberate: core's `memory_search` routes
  into this port, and `read_context_bundle` re-reads on demand.
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
  Guidance` — with no data fetch at boot; recalled data travels the
  session-opening inbound envelope above, and `read_context_bundle` re-reads
  on demand.
- The `MemoryPort` write path: `store` returns a `pending:<n>` id
  synchronously and queues the write for the `memory_add` MCP call
  (metadata convention keys: `title`, `unit_type`, `importance`, `labels`);
  `delete` drops a pending ticket locally or queues the remote delete.
  `search` runs the `memory_search` MCP call with `top_k` as the server's
  `limit` and renders `{"memories":[…]}` as one `- [id] content` line per
  hit (`None` when nothing matches; non-JSON text degrades to the raw
  reply). Queued writes drain after the thread lanes — `/memory flush`
  forces a drain.

### Troubleshooting

**Server not running** — call `nmem_status` for a structured connectivity
report, run `/memory status` for the full diagnostics (lanes, queue,
session inbound state).

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

- **Passive memory, no plumbing.** A session's first turn auto-injects the
  working-memory snapshot into context, so the agent walks in already
  knowing what was settled before. You don't hand-build the read-transcripts /
  ship / rewrite-prompts pipeline; the read lives behind the extension's
  `MemoryPort` view, and the snapshot semantics (once per session, never
  rewritten) come with the port.
- **Active writes and passive recall don't fight.** Memories saved through
  core's built-in `memory_add` and transcripts passively settled during
  turns travel the same write path and share one state: there is no drift
  where "the tool just saved it, but the next recall can't find it," and
  the `/memory` diagnostics read the same data.
- **One truth, no stale local replica.** Passive retrieval queries the server
  directly — no local cache to warm, refresh, or silently go stale — exactly
  once per session. Writes batch back — amortized cost, fault isolation,
  silent retry, never stalling the turn.

## Why Posoco's design lets Nowledge Mem do more

- **Injection is a port, not plumbing.** The session-opening memory message
  is core's `MemoryPort` machinery: core owns the lead line, the message
  role, the placement before the first user input, the freeze, and the
  resume semantics; this extension only answers the one `inbound` call with
  its envelope body. Core stays product-agnostic — a different memory
  backend is just a different extension; the agent body doesn't change a
  line.
- **One extension covers every facet, state stays unified.** The same
  `NowledgeMem` struct is simultaneously `MemoryPort` + `Lifecycle` +
  `PipelineHook` + `Observer` + `SystemPromptContributor` + `ToolProvider` +
  `CommandPort` + `Extension`, self-reported under each manifest slot. All
  views share one state: memories the built-in tools write and transcripts
  the sync passively settles travel the same write path — no two books
  where "the tool saved it but recall can't find it."
- **The server is the truth, no stale local replica.** Passive retrieval
  queries the server directly — no local cache to warm, refresh, or silently
  go stale — exactly once per session. Writes batch back — amortized cost,
  fault isolation, silent retry, never stalling the turn.
- **The deep module hides the protocol, backends coexist.** You construct the
  extension and drop it into `exts`; that's the whole surface. Sync, dedup,
  and fault-tolerance details never leak. Multiple memory extensions coexist
  — each owns its injection; add one tomorrow and it's just another
  extension mounted.

## Links

- [Nowledge Mem](https://mem.nowledge.co) | [Docs](https://mem.nowledge.co/docs) | [Blog](https://nowledge-labs.ai/blog)
- [Integrations](https://mem.nowledge.co/docs/integrations)
