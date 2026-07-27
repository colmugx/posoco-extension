# colmugx/posoco-ext-deepseek

> **Target: native only** — 依赖 `moonbitlang/async/http`（native-only）。
> 在 js/wasm 环境下不可用；如需 js 支持，需替换 transport 层。

DeepSeek 深度优化的 `ModelPort` 实现。用户只提供一个 model id，provider 负责
thinking、tool calls、FIM、前缀续写和 HTTP 错误处理。

## 实现的 trait

```moonbit
@posoco.ModelPort  // chat() + chat_streaming()
```

## DeepSeek 独有 API（不进 ModelPort trait）

```moonbit
let port = @deepseek.DeepSeekModelPort::new(config)

// FIM 补全（/beta/completions，用 prompt/suffix 参数）
let completion = port.fim_completion(prefix="def fib(a):", suffix="return fib(a-1) + fib(a-2)")

// 前缀续写（/beta/chat/completions，messages[-1] 带 prefix:True）
let result = port.chat_prefix_completion(messages, prefix="```json\n", stop=["```"])
```

## DeepSeek 深度优化

| 特性 | 实现 |
|---|---|
| **Context Cache** | append-only message 顺序，保证 prefix 字节级稳定 |
| **reasoning_content 回传规则** | assistant 有 tool_calls 时回传 reasoning_content；无 tool_calls 时省略 |
| **reasoning 流式** | `StreamChunk::ReasoningDelta` 推给 Observer，用完即弃 |
| **thinking effort** | `High -> high`，`Maximum -> max`，其他开启档位 fallback 到 high 并记录 warn |
| **FIM** | `/beta/completions` + `prompt`/`suffix` 参数 |
| **前缀续写** | `/beta/chat/completions` + `messages[-1]` 带 `prefix:True` |

## Quick Start

```moonbit
let config = @deepseek.DeepSeekConfig::new(
  api_key="sk-...",
  model="deepseek-v4-flash",
)
let port = @deepseek.DeepSeekModelPort::new(config)

// 作为 posoco ModelPort 使用
let agent = @posoco.Agent(port, tools, ...)
```

## Migration

Old config fields `chat_model`, `reasoner_model`, `coder_model`, `thinking`,
and retry fields were removed. Use one model id:

```moonbit
let config = @deepseek.DeepSeekConfig::new(
  api_key="sk-...",
  model="deepseek-v4-flash",
)
```

Deprecated DeepSeek aliases `deepseek-chat` and `deepseek-reasoner` are not
defaults. Pass them explicitly only for compatibility.

## 依赖

- `colmugx/posoco` — ModelPort trait + 类型
- `colmugx/posoco-devkit` — `ExtContext` logger helper
- `moonbitlang/async/http` — HTTP transport
- `moonbitlang/core/json` — JSON 编解码
