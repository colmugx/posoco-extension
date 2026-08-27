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
   remote.
2. `nmem` CLI in `PATH` — required by the ten tools and the one-shot
   passive working-memory read:

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
let nmem = NowledgeMem(
  source_app="cetas",
  transport=HttpNmemTransport::HttpNmemTransport() as &NmemTransport,
  runner=PlatformRunner::PlatformRunner() as &NmemRunner,
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

- `NowledgeMem(source_app~, transport~, runner~, expose_delete_tool?)` —
  `source_app~` is the required host product identity (cetas passes
  `"cetas"`): it prefixes synced thread ids and labels user-visible copy.
  Production passes `HttpNmemTransport` + `PlatformRunner`; both IO seams
  are injectable (tests script them with fakes).
- `attach(group)` — optional optimization: a 750ms flusher poll loop draining
  thread lanes, then the memory write queue. Committing does not depend on
  it — every turn commits at turn end, `on_start` drains once at boot, and
  `on_shutdown` does the final drain; `flush_pending()` forces a drain
  anytime.

### Tools

| Tool | nmem CLI | Notes |
|------|----------|-------|
| `nmem_status` | `--json status` | health check (15s budget) |
| `read_context_bundle` | `context` | official MCP name; context bundle as rendered markdown (`rendered_markdown` \| `markdown` \| `content`) — usually already injected into the system prompt, so re-read only after major context changes |
| `read_working_memory` | `wm read` | official MCP name; working-memory body — usually already injected into the system prompt, so re-read only after major context changes |
| `memory_search` | `m search` | official MCP name; server-side semantic search (deep mode, importance/label filters) — the recall path once the injected working-memory briefing is spent |
| `memory_add` | `m add` | official MCP name; enters through `MemoryPort::store` — the single write path shared with passive stores |
| `memory_update` | `m update` | direct CLI; the server is the single source of truth for search |
| `memory_delete` | `m delete -f` | hidden by default; `expose_delete_tool=true` registers it (hard delete, irreversible) |
| `thread_search` | `t search` | official MCP name; past threads, including other tools' sessions |
| `thread_show` | `t show` | progressive loading (limit / offset / content cap) |
| `thread_create` | `t create` | curated handoff summary for future sessions |

The five official MCP tool names (`read_context_bundle`,
`read_working_memory`, `memory_search`, `thread_search`, `memory_add`) are
name-aligned with the [official Nowledge Mem MCP surface](https://mem.nowledge.co/SKILL.md);
`nmem_status`, `memory_update`, `memory_delete`, `thread_show`, and
`thread_create` are posoco-native additions. `memory_search`, `thread_search`,
and `nmem_status` also carry the CLI's parsed JSON in the tool result's
`structured` channel.

### Commands

| Command | Effect |
|---------|--------|
| `/memory status` | nmem connectivity probe (10s budget), one line per thread lane (thread_id / created / acknowledged count / last_error), write-queue depth, passive-read state (done / pending) |
| `/memory flush` | force one drain of pending thread lanes and queued memory writes now |

`/memory` with no or an unknown subcommand prints usage. This is the
synchronous diagnostics face: lane `last_error`s become user-checkable
instead of living only in memory — the Observer port is core-to-extension
read-only, so the extension cannot emit its own observer events.

### What happens automatically

- First turn of the run: core's `MemoryRetrievalHook` calls the port once;
  the port ignores the query and reads the working memory (`nmem --json wm
  read`, the same surface the `read_working_memory` tool exposes), and the
  content lands as one SystemMessage right after the system prompt — a plain
  section headed `## Any Memory About This Work` with a provenance line
  (`from Nowledge Mem. For Your Information.` — recalled memory may be
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
- Boot: resolve config (env + `~/.nowledge-mem/config.json`) and drain once.
  The system-prompt contribution is instructions only — `## Nowledge Mem
  Guidance` — with no data fetch at boot; recalled data travels the memory
  section above, and `read_context_bundle` / `read_working_memory` re-read
  on demand.
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
rtk moon test src --target native   # 150 tests
rtk moon check src --target js      # gates the Bun runner
```

Covers config resolution, message mapping, delta engine, transport acks,
sync state machine, port wiring, MemoryPort semantics, the turn-end commit
paths (completed, failed, timeout-bounded, before_tool throttle — with no
flush_pending/attach in the loop), all ten tools (with
structured payloads), the `/memory` command, and session-redirect handling —
all against scripted fakes; no Nowledge Mem install or `nmem` binary.

### Troubleshooting

**Server not running** — call `nmem_status` for a structured connectivity
report, run `/memory status` for the full diagnostics (lanes, queue,
passive-read state), or run `nmem status` yourself.

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
