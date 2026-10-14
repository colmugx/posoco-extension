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
