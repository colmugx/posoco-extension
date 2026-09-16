# posoco-ext-lazytools

[Tool lazy-loading gateway for Posoco agents](https://mooncakes.io/docs/colmugx/posoco-ext-lazytools) —
collapses any number of `ToolProvider`s into two model-visible meta tools
(`tool_list`, `tool_execute`), so an agent with 70+ tools
stops paying for every definition on every request. Deferred tool schemas
stay out of the resident tool catalog; discovery and invocation both go through the
gateway.

> **Targets: all backends** — pure catalog logic, no IO of its own.

## Ports contributed

| Port | Contribution |
|---|---|
| `ToolProvider` | the `tool_list` / `tool_execute` meta tools |
| `SystemPromptContributor` | the stable `## Deferred tools` section: lists deferred groups and tells the model to reuse schemas already present in history before calling `tool_list` again |
| `Observer` | inert compatibility view in normal manifest composition; the public `LazyTools` Observer impl remains available to explicit callers |
| `PipelineHook` | inert compatibility view in normal manifest composition; the public `LazyTools` hook impl remains available to explicit callers |

## Discoverability and prompt-cache behavior

The default composition deliberately keeps deferred-tool guidance stable. The `## Deferred tools` system-prompt section is assembled once per Agent and contains one bullet per deferred extension group: the manifest id (packaging prefix stripped, so `posoco_ext_webfetch` shows as `webfetch`) followed by its tool names and descriptions. Full input schemas are fetched only through `tool_list`.

When a schema has already appeared in an earlier `tool_list` result, the prompt tells the model to reuse that schema from conversation history and call `tool_execute` directly. It should not repeat `tool_list` merely to rediscover the same schema.

Older LazyTools behavior recorded the five most recently executed deferred tools and rewrote a `<lazytools-context>` user envelope during `before_model`. Because Posoco persists hook rewrites into the transcript, changing that envelope could invalidate provider prefix-cache reuse from an old history position onward. Normal manifest composition therefore uses inert Observer/Hook compatibility views instead. The public `LazyTools` Observer and PipelineHook implementations remain available to callers that explicitly want the legacy behavior.

## Meta tools

| Tool | Arguments | Meaning |
|---|---|---|
| `tool_list` | `keyword` string, optional | Browse the folded catalog: no keyword lists every group; a keyword (space-separated, AND-matched against extension ids and tool names/descriptions) returns the matching groups **whole** — every tool with name, description and full JSON input schema |
| `tool_execute` | `tool` string, required; `arguments` object, optional | Routes the call to the owning provider and returns its outcome verbatim; missing `arguments` are passed as an empty object |

## Output contract

- `tool_list` returns grouped deferred-tool metadata including full input schemas. An empty keyword match is a **Success** with steering text to browse without arguments.
- `tool_execute` passes the child's `ToolOutcome` through unchanged — `Success`/`ToolReportedError` reach the model as the gateway's outcome; a raised `RuntimeError` propagates so the kernel maps it exactly as if the child had been called directly.
- Argument mistakes (missing `tool`, non-object `arguments`, blank keyword) raise `RuntimeError::UnknownTool`. An unknown deferred tool name is a `ToolReportedError` with steering text, not a hard failure.

## Behavior notes

- **Flat, stable catalog** — the agent sees exactly two LazyTools meta tools for the whole conversation. Deferred schemas do not expand the resident tool catalog, which keeps the tool-definition prefix small and stable.
- **Stable prompt prefix** — usage-driven recent-tool state is not auto-injected into durable transcript history. Reuse guidance lives in the frozen system prompt instead.
- **Grouping/search** — keyword lookup operates over extension ids and tool names/descriptions and returns matching groups whole so related schemas arrive together.
- **Policies** — `tool_list` is `Parallel`; `tool_execute` is `Sequential` so deferred side effects never share a wave (child policies are hidden behind the gateway).
- **Error split** — the gateway never converts child business failures (`ToolReportedError`) into exceptions or vice versa; only its own argument validation raises.

Background: `docs/tools-lazyload-research.md` (mechanism (a) — meta-tool search + deferred loading — implemented as a pure extension, no kernel support needed because deferred definitions never enter the resident tool catalog).
