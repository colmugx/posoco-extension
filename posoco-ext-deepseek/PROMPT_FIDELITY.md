# DeepSeek model-aware prompt fidelity

The DeepSeek adapter is the HTTP/API boundary. The upstream open-source
[deepseek-recipe](https://github.com/deepseek-ai/deepseek-recipe) is the
reference for the V4 / V4.1 *model prompt renderer*, not a guarantee that the
hosted API uses identical server-side configuration. DeepInfer is an offline
inference runtime; its kernel flags are **not** hosted API parameters.

## Verifiable V4.1 behavior

- The V4.1 renderer appends the tool prompt and non-deferred tool schemas to
  the first system message (or inserts a system message when absent).
- Tool order and schema bytes therefore matter to the model prompt prefix.
  Preserve the host's stable declaration order. Do **not** reorder tools in
  the adapter without validating any execution-order or schema assumptions.
- With a tool prompt, historical assistant reasoning is rendered. Without one,
  historical assistant reasoning is dropped by the renderer. The outgoing
  request must preserve reasoning for tools; see `encode.mbt`.
- Rendering normalizes adjacent user/tool messages and sorts tool results by
  preceding call order. HTTP JSON equality alone is not prompt token equality.
- Efforts map in V4.1: minimal/low -> 50, medium/high/xhigh -> 75,
  max/ultra -> 100. Disabled thinking is separate. The adapter deliberately
  sends the declared effort unchanged and lets the server resolve it.
- V4 and V4.1 differ in system-message normalization. In particular, moving
  an auxiliary system hint to the end of a request should not be presumed to
  retain the same prefix across model versions.

Sources:
- https://github.com/deepseek-ai/deepseek-recipe/blob/main/deepseek-recipe-encoding/src/v4/dsv41.rs
- https://github.com/deepseek-ai/deepseek-recipe/blob/main/deepseek-recipe-encoding/src/v4/dsv4.rs
- https://github.com/deepseek-ai/deepseek-recipe/blob/main/deepseek-recipe/src/protocol/reasoning.rs
- https://github.com/deepseek-ai/deepseek-recipe/blob/main/docs/tokenizer.md

## Compaction and prefix reuse

A summary request must **reuse the same tools** as the routed chat request.
Otherwise the tool schema preamble and historical reasoning replay diverge.
The auxiliary request may return tool calls: these are rejected; compaction
does not execute tools and never interprets a tool invocation as a checkpoint.

This restores an essential *precondition* for cached-prefix reuse, not a
promise of cache hit. The summary instruction itself is an appended user turn.
Use the actual API response's `prompt_cache_hit_tokens` and
`prompt_cache_miss_tokens` to quantify the result, against an unmodified
control workload.

## Context estimation

The fallback `chars / 4` heuristic now includes historical reasoning, but
it remains a heuristic. It does **not** model exact prompt tokenization,
system-inserted tool schemas, token marker overhead, or image expansion.
Prefer the core's verified `InvocationScope.pressure` values; do not
fabricate context windows from the `/models` catalog.

For an exact local golden corpus, use the model's matching tokenizer with
`deepseek-recipe` (V4 or V4.1), record its rendered prompt, special token
ranges, and token IDs. Never tokenize the displayed prompt naively: user
strings that *look like* special tokens must remain plain text.

Suggested golden cases: zero/one/multiple tools, reordered tool definitions,
assistant reasoning with/without active tools, prefix continuation, required
tool_choice, adjacent tool results, compaction with unchanged tools, images,
JSON schema, and non-thinking mode. Treat local renderer behavior and hosted
API behavior as **separate** validation layers.

## Feature boundaries

Do not inject DSML directly into Chat Completions requests, spoof tokenizer
control tokens in user text, assume deferred-tool-loading support for a
particular hosted model, or forward DeepInfer's speculative decoding and SWA
environment flags to the cloud API. Strict response schema enforcement
depends on server-side constrained decoding, not merely prompt text.

## Validation

- Run `moon check --target native` and `moon test --target native` from the
  repository workspace with the required MoonBit toolchain installed.
- Run the JS build/tests as supported by the workspace configuration.
- Compare real API runs at the same model, efforts, tools and prompts, using
  cache-hit tokens, prompt tokens, TTFT, cost, and tool-call correctness.
- No live-API success or performance gain is claimed without measured data.
