# colmugx/posoco-ext-nowledge-mem

English | [简体中文](README.zh-CN.md)

[Nowledge Mem](https://mem.nowledge.co) as Posoco's memory backend: passive
per-turn retrieval and transcript sync through the `MemoryPort`, plus eight
`nmem` tools the model calls deliberately. Sessions and tools share one memory.

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
   remote.
2. `nmem` CLI in `PATH` — required by the eight tools, the startup context
   chain, and the passive-index warm-up/refresh:

```bash
nmem status             # verify connection
```

Thread sync needs neither — it talks HTTP directly, so a headless host with
only the server reachable still syncs transcripts.

### Configuration

Per key: **env var > `~/.nowledge-mem/config.json` > default.** Values are
trimmed; blanks count as missing. The file takes camelCase and snake_case
and is shared with every other Nowledge Mem integration — existing spaces
and threads are visible as-is.

| Env var | config.json keys | Meaning | Default |
|---------|------------------|---------|---------|
| `NMEM_API_URL` | `apiUrl` / `api_url` | Service base URL | `http://127.0.0.1:14242` |
| `NMEM_API_KEY` | `apiKey` / `api_key` | API key (`Authorization: Bearer` + `X-NMEM-API-Key`) | — |
| `NMEM_SPACE` / `NMEM_SPACE_ID` | `space` / `spaceId` / `space_id` | Space scoping (`space_id` in request bodies, `--space` on CLI calls) | — |
| `NMEM_AGENT_ID` | `agentId` / `agent_id` | Agent id (AI identity) | — |
| `NMEM_HOST_AGENT_ID` | `hostAgentId` / `host_agent_id` | Host agent id | — |
| `NMEM_PLUGIN_SOURCE_APP` | — (env only) | Runtime override of the constructor's `source_app`; thread ids are `{source_app}-{session_id}` | constructor value |
| `NMEM_SYNC_TIMEOUT_MS` | — (env only) | Thread sync HTTP timeout | `120000`, clamped to 1s–30min |

### Assembly

```mbt nocheck
let nmem = NowledgeMem::new(
  source_app="cetas",
  transport=HttpNmemTransport::HttpNmemTransport() as &NmemTransport,
  runner=PlatformRunner::PlatformRunner() as &NmemRunner,
)

// Call inside the host's with_task_group scope; the group must stay open
// for the agent's lifetime (mcp / ratelimit precedent):
nmem.attach(group)

let agent = Agent(
  exts=[model_ext, nmem, session_ext],
  config={
    max_tool_rounds: None,
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
  },
)
```

- `NowledgeMem::new(source_app~, transport~, runner~, expose_delete_tool?)` —
  `source_app~` is the required host product identity (cetas passes
  `"cetas"`): it prefixes synced thread ids and labels user-visible copy.
  Production passes `HttpNmemTransport` + `PlatformRunner`; both IO seams
  are injectable (tests script them with fakes).
- `attach(group)` — starts the flusher on the host's task group: a 750ms
  poll loop draining thread lanes, then the memory write queue. Without it,
  `on_start` drains once at boot and `on_shutdown` does the final drain —
  nothing staged is lost; `flush_pending()` forces a drain anytime.

### Tools

| Tool | nmem CLI | Notes |
|------|----------|-------|
| `nmem_status` | `--json status` | health check (15s budget) |
| `memory_search` | `m search` | server-side semantic search (deep mode, importance/label filters) — not the local passive index |
| `memory_add` | `m add` | enters through `MemoryPort::store` — the single write path shared with passive stores |
| `memory_update` | `m update` | direct CLI; refreshes the local index so passive search stops serving stale text |
| `memory_delete` | `m delete -f` | hidden by default; `expose_delete_tool=true` registers it (hard delete, irreversible) |
| `thread_search` | `t search` | past threads, including other tools' sessions |
| `thread_show` | `t show` | progressive loading (limit / offset / content cap) |
| `thread_create` | `t create` | curated handoff summary for future sessions |

### What happens automatically

- Every model call: core's `MemoryRetrievalHook` searches the last user
  message against the local index (top_k 5) and injects hits as an
  idempotent `[MEMORY]` SystemMessage — failures become observer events,
  never turn failures.
- Every turn: the model-visible transcript is staged to its
  `(config, session)` lane for incremental HTTP sync (acknowledged cursors,
  sha256 fingerprint, idempotency keys + server-side dedup, checkpoint
  conflicts resolved by full re-send, vanished threads recreated).
- Boot: the index warms from the server (`nmem --json m -n 200`); the
  startup-context chain runs under one 8s budget — `nmem --json context
  --source-app <app>` → `nmem --json wm read` → `~/ai-now/memory.md`
  (default-local only) → degraded reason — capped at 20k chars and appended
  under `## Nowledge Mem Context Bundle` plus the always-present
  `## Nowledge Mem Guidance`.
- `MemoryPort::store` returns a `pending:<n>` id synchronously and queues
  the write for `nmem m add`; metadata keys: `title`, `unit_type`,
  `importance`, `labels`.

### Platform notes

- **native** — `nmem` via `@process.collect_output`, home files via
  `moonbitlang/async/fs`, env via `moonbitlang/core/env`.
- **js (Bun)** — the same `NmemRunner` seam over `Bun.spawn`, `Bun.file`,
  `process.env`; HTTP shared with native (`moonbitlang/async/http`, fetch
  backend on js).

### Testing

From this module directory:

```bash
rtk moon test src --target native   # 130 tests
rtk moon check src --target js      # gates the Bun runner
```

Covers config resolution, message mapping, delta engine, transport acks,
sync state machine, port wiring, MemoryPort semantics, and all eight tools —
all against scripted fakes; no Nowledge Mem install or `nmem` binary.

### Troubleshooting

**Server not running** — call `nmem_status` for a structured connectivity
report, or run `nmem status` yourself.

**Sync failures are silent by design** — a failed flush records the lane's
`last_error` and leaves the acknowledged cursor untouched; the next turn
re-stages the transcript and the flusher retries from the last acknowledged
state (idempotency keys make the re-send safe server-side). Queued memory
writes re-enqueue at the tail. No failed sync can abort a turn.

**Slow or remote sync** — raise `NMEM_SYNC_TIMEOUT_MS`.

## How Nowledge Mem empowers Posoco agents

- **Memory across sessions and tools.** Each turn retrieves relevant
  memories into context (core's `MemoryRetrievalHook` driving the
  `[MEMORY]` SystemMessage). The agent walks in knowing what prior sessions
  settled — its own or another tool's.
- **Decisions enter the shared store.** What a Posoco agent learns is not
  private: `memory_add` and passive stores land in the same memory your
  other AI tools read, and `thread_search` recalls sessions those tools
  synced.
- **Conversations become assets.** Incremental thread sync (cursors,
  fingerprints, idempotency, checkpoint reconcile) turns every session into
  a searchable, deduplicated archive instead of state that evaporates at
  exit.
- **Cold starts get context.** The Context Bundle / Working Memory chain is
  appended to the system prompt at boot, plus standing guidance on when to
  search and when to save. A new session starts oriented, not empty.

## Why Posoco's design lets Nowledge Mem do more

- **Memory is a first-class port.** Posoco declares `MemoryPort` as a
  hexagonal port: this extension implements the trait, lists itself in the
  manifest's `memory` slot, and core's `MemoryRetrievalHook` wires itself —
  declaring the port grants passive memory. No integration has to build its
  own read-transcripts / ship / rewrite-prompts pipeline.
- **One struct, many port views.** `NowledgeMem` is simultaneously
  `Lifecycle` + `Hook` + `Observer` + `SystemPromptContributor` +
  `ToolProvider` + `MemoryPort` + `Extension`, self-reported under each
  manifest slot. All views share one state: the local index serves the
  passive `[MEMORY]` injection and is refreshed by `memory_update`.
- **The synchronous port contract forced a better architecture.**
  `MemoryPort` cannot await a CLI, so the extension keeps a local index
  copy: retrieval is instantaneous — no per-call process spawn or network
  round trip — and writes go through a write-after queue the flusher
  batch-drains: amortized cost, fault isolation, silent retry.
- **The deep-module `Agent` hides the protocol.** Hosts construct the
  extension and drop it into `exts`; that is the entire surface. Nothing
  about cursors, fingerprints, idempotency keys, or degradation chains
  leaks upward, and multiple memory backends coexist — core concatenates
  what each port returns.

## Links

- [Nowledge Mem](https://mem.nowledge.co) | [Docs](https://mem.nowledge.co/docs) | [Blog](https://nowledge-labs.ai/blog)
- [Integrations](https://mem.nowledge.co/docs/integrations)
