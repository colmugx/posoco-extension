# posoco-ext-lazytools

[Tool lazy-loading gateway for Posoco agents](https://mooncakes.io/docs/colmugx/posoco-ext-lazytools) —
collapses any number of `ToolProvider`s into three model-visible meta tools
(`search`, `list`, `execute`), so an agent with 70+ tools
stops paying for every definition on every request. Deferred tool schemas
never enter the model context; discovery and invocation both go through the
gateway.

> **Targets: all backends** — pure catalog logic, no IO of its own.

## Ports contributed

| Port | Contribution |
|---|---|
| `ToolProvider` | the `tool_list` / `tool_execute` meta tools |
| `SystemPromptContributor` | the `## Deferred tools` section: a MUST directive to `tool_list` before giving up, plus one bullet per deferred extension group with its tools (names + descriptions) |
| `Observer` | records deferred executions (bounded to the 5 most recent) |
| `PipelineHook` | `before_model`: injects/refreshes a `<lazytools-context>` user envelope with the recent-tools hint |

## Discoverability: how the model knows what is deferred

Two resident surfaces, split by mutability:

- **System prompt (`## Deferred tools`, static per composition)** — one
  bullet per deferred extension group: the manifest id (packaging prefix
  stripped, `posoco_ext_webfetch` shows as `webfetch`) followed by its
  tools, names and descriptions auto-concatenated. Descriptions come from
  the deferred tools themselves — from today on, tool descriptions are part
  of the deferred-extension contract.
- **`before_model` recent-tools envelope (dynamic)** — the Observer records
  every deferred execution (most recent first, capped at 5); the hook
  injects a `<lazytools-context>` user message telling the model it can
  skip `tool_list` and call those with `tool_execute` directly. The message
  is replaced in place as usage changes — the hook, not the system prompt,
  carries it so the prompt-cache prefix stays intact.

## Meta tools

| Tool | Arguments | Meaning |
|---|---|---|
| `tool_list` | `keyword` string, optional | Browse the folded catalog: no keyword lists every group; a keyword (space-separated, AND-matched against extension ids and tool names/descriptions) returns the matching groups **whole** — every tool with name, description and full JSON input schema |
| `tool_execute` | `tool` string, required; `arguments` object, optional | Routes the call to the owning provider and returns its outcome verbatim; missing `arguments` are passed as an empty object |

## Output contract

- `search` renders hits as a JSON array (`name`, `description`,
  `input_schema`) after a one-line header; when truncated the header says
  `showing M of N`. An empty result is a **Success** that steers the model
  to `list`.
- `execute` passes the child's `ToolOutcome` through unchanged —
  `Success`/`ToolReportedError` reach the model as the gateway's outcome;
  a raised `RuntimeError` propagates so the kernel maps it exactly as if
  the child had been called directly.
- Argument mistakes (missing `query`/`tool`, non-object `arguments`, empty
  keyword query) raise `RuntimeError::UnknownTool`, matching the read
  tool's error style. An unknown deferred tool name is a
  `ToolReportedError` with steering text, not a hard failure.

## Behavior notes

- **Flat, stable catalog** — the agent sees exactly three tools for the
  whole conversation. There is no mid-turn table expansion, which keeps the
  tool prefix prompt-cache friendly; the cost is that every deferred call
  carries a `tool` + `arguments` indirection instead of a native tool call.
- **Ranking** — every keyword must match (AND) the tool's name or
  description; name hits score 100 per keyword, description hits 1, and
  declaration order breaks ties.
- **Policies** — `search`/`list` are `Parallel`; `execute`
  is `Sequential` so deferred side effects never share a wave (child
  policies are hidden behind the gateway).
- **Error split** — the gateway never converts child business failures
  (`ToolReportedError`) into exceptions or vice versa; only its own
  argument validation raises.

Background: `docs/tools-lazyload-research.md` (mechanism (a) — meta-tool
search + deferred loading — implemented as a pure extension, no kernel
support needed because deferred definitions never enter the context).
