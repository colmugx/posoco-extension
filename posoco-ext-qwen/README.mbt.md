# posoco-ext-qwen

Named Qwen provider for Posoco using Alibaba Cloud Model Studio's OpenAI-compatible Chat Completions API.

The extension intentionally owns Qwen-specific wire semantics instead of teaching the generic OpenAI-compatible adapter about Alibaba-only fields:

- `reasoning_effort` / `enable_thinking`
- `preserve_thinking` and assistant `reasoning_content` replay
- `tool_stream` on streaming tool calls
- Qwen-specific model defaults while keeping custom model ids usable

## Settings

```json
{
  "providers": {
    "qwen": {
      "api_key": "sk-...",
      "base_url": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
      "model": "qwen3.8-max"
    }
  }
}
```

For Alibaba Cloud Token Plan, use the Token Plan-specific `base_url` issued/documented for that plan; the adapter does not rewrite billing endpoints or credentials.

Optional settings:

- `endpoint_prefix`
- `reasoning_effort`
- `enable_thinking`
- `preserve_thinking`
- `tool_stream`
- `image_input`
- `context_window`

`reasoning_effort` and `enable_thinking` are mutually exclusive.

Known Qwen3.8 Max/Flash ids default to preserved thinking and expose the host picker as `off | low | medium | xhigh`; `off` is sent as `reasoning_effort: "none"`.

## Scope

This package deliberately does not own pricing or a remote model catalog in its first version. The goal is a correct Qwen Chat Completions transport with stable provider-specific semantics.
