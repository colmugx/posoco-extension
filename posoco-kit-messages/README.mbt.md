# posoco-kit-messages

Pure Messages wire-protocol codec for Posoco. This module does **not** provide
HTTP, credentials, streaming transport, retries, or a ModelPort implementation.
The owning extension selects an endpoint, writes headers (including version
and feature negotiation), invokes these codecs, and supervises cancellation.

## Interface and scope

- `message_to_wire`, `system_to_wire`, `tool_to_wire`, `encode_request`:
  encode canonical Posoco content into Messages request JSON.
- `parse_response`: decode a complete assistant response into
  `MessagesResult` with canonical `Completion`, native usage, stop details,
  and opaque top-level extension fields.
- `SseDecoder`, `process_messages_event`, `messages_stream_result`:
  incremental SSE framing, event processing, completion, and usage projection.
- `count_tokens_request`, `parse_count_tokens_response`:
  the protocol's token-counting request and result shapes.
- `MessagesUsage`: native counters with an explicit canonical projection.
- `Reasoning.raw` replay envelope: the codec tag, version, fingerprint and
  opaque blocks are verified before replay.

## Replay safety

New captures retain the **entire assistant wire content-block sequence**
(`full_blocks`) in original order. The replay parser independently projects
text and tool calls from those wire blocks and refuses replay when those values
differ from the canonical assistant turn. This matters when signed thinking
blocks appear between visible text or tool calls.

Legacy `version=1` envelopes without `full_blocks` are accepted for
compatibility, but carry only thinking/opaque blocks. They use the old
thinking-first reconstruction and **do not promise original block order**.
Do not create new legacy envelopes from streaming or non-streaming decoders.

Foreign `Reasoning.raw` payloads are not Messages state and fail explicitly
when passed to `message_to_wire`.

The envelope is NOT cryptographic authentication of a remote response:
its fingerprint detects application-level mismatches in the current canonical
transcript; it does not verify signatures issued by a model provider.

## Limitations

- This is not a general SDK or standalone gateway.
- Opaque beta-specific content and server-side tools are not automatically
  semantically supported. An extension must negotiate the relevant wire
  features and verify their semantics before enabling them.
- Posoco Core currently represents ordinary text and images but cannot
  canonically represent every Messages content-block variant.
- Usage represents endpoint-reported dimensions only. Native cache
  creation/read counters remain separately available.
- Request extras are opaque but cannot override essential fields validated by
  this codec.

## Validation

Run `moon check --target native`, `moon check --target js`,
`moon check --target wasm`, `moon test`, and `moon info` from the workspace
root. Network authentication is not needed for deterministic codec tests.


## Cache economics and prefix strategy

This kit follows **native Messages prompt-caching semantics**, not OpenAI
`prompt_cache_key`. Cache match is a prefix match over the serialized
`tools -> system -> messages` sequence. The caller is responsible for
deterministic tool ordering, exact prompt stability, model selection and
keeping traffic on an upstream identity that can read its previous cache.
Cache keys, authorization and gateway affinity are NOT synthesized by the kit.

### Request policies

`MessagesRequestOptions::MessagesRequestOptions(...)` accepts:

- `cache_mode=CacheUnchanged` (default; backwards compatible)
- `cache_mode=CacheAutomatic5m` (top-level `cache_control`)
- `cache_mode=CacheAutomatic1h`
- `cache_mode=CacheExplicit` (verify caller-provided markers)
- `stable_prefix=Some(StableSystem)` or `Some(StableTools)`
- `stable_prefix_ttl="5m"` or `"1h"`
- `cache_capabilities`: declare actual endpoint support for automatic
  caching and 1h caching; the kit never silently downgrades unsupported
  requests.

For a long-running agent with a genuinely constant system prompt:

    options=MessagesRequestOptions::MessagesRequestOptions(
      cache_mode=CacheAutomatic5m,
      stable_prefix=Some(StableSystem),
    )

The stable System checkpoint caches tools and system. The automatic cache
checkpoint advances with the conversation tail. **Do not** claim that a
per-request timestamp, changing retrieved content or rotating tool schema is
stable. For volatile tails that never recur, prefer explicit stable-only
placement rather than paying the cache-write premium each turn.

`mark_messages_stable_prefix` supports direct construction on already
encoded JSON without mutating caller-owned objects.
`inspect_messages_cache_layout` reports explicit breakpoint usage and
20-position lookback risk; consecutive tool_use/tool_result batch blocks count
as one position. It is a diagnostic, not a token estimator or a cache hit
predictor. Insert explicit stable checkpoints where suitable when the risk is
reported. Never insert a marker inside a thinking block: signed thinking is
preserved exactly.

`compare_messages_cache_prefix` checks that the model, tools, system and
existing message history are stable across two requests, and flags changes in
cache-relevant generation settings. It does NOT verify serialized wire bytes,
provider cache existence, TTL expiration or gateway upstream-account affinity.

### Observed economic metrics

`MessagesResult.cache_creation` preserves the native per-TTL write counters
`cache_creation.ephemeral_5m_input_tokens` and
`cache_creation.ephemeral_1h_input_tokens` on both streaming and nonstreaming
paths. `MessagesUsage` preserves total cache-creation and cache-read tokens.

`MessagesResult::cache_economics` and
`analyze_messages_cache_economics` compute:

- cache-read token ratio, using reported prompt-total token counts;
- actual input cost, based on caller-supplied pricing multipliers;
- baseline cost with no prompt caching and net savings.

No model pricing is guessed from identifiers. If the endpoint omits TTL
breakdown for nonzero cache writes, **cost and savings remain unknown** rather
than arbitrarily pricing writes as 5m. The caller can use actual provider
pricing to convert relative units into currency.

### Operational limits and diagnostics

- Native caching can silently skip a too-small prefix; minimum cacheable
  tokens vary by model and platform. The kit does not invent token counts.
- Four explicit breakpoints maximum, with automatic caching consuming a slot.
- 1h breakpoints must precede 5m breakpoints in prefix order.
- A changing tool list or tool schema invalidates the entire downstream
  cached prefix. A changed system prompt invalidates system and messages.
- Thinking/effort/tool-choice changes may invalidate portions of a cache,
  depending on model generation. Prefer stable configuration inside a
  long-running session.
- The 20-position lookback checks **previously written cache entries**.
  It cannot manufacture a hit when the earlier stable prefix was never
  cached.
- A cache hit requires the same upstream cache identity. A gateway that
  translates to a non-Messages API or changes upstream credentials may lose
  caching; the caller must declare unsupported capabilities rather than
  suggesting a guaranteed hit.
- Cache-read counters are the authority for **actual** hits. Prefix
  diagnostics report potential reuse only. Never confuse cache-hit ratio
  with net cost savings.

### Standalone scope

No changes to posoco-ext-zai, posoco-ext-zai-coding-plan, posoco-ext-magpie,
Posoco Core or Cetas are required for this feature. Adoption is intentional:
existing callers keep CacheUnchanged until they opt into the native policy.
