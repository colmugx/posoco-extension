# colmugx/posoco-ext-deepseek

> **Target: native only** — 依赖 `moonbitlang/async/http`（native-only）。
> 在 js/wasm 环境下不可用；如需 js 支持，需替换 transport 层。

DeepSeek 深度优化的 `ModelPort` 实现。把 DeepSeek 的 context cache / reasoning_content
语义 / FIM / 前缀续写做到位。不做「通用 OpenAI 兼容」——通用场景用 `posoco-ext-openai-chat`。

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
| **reasoning_content 不回传** | wire encoder 永不 emit 历史消息的 reasoning（posoco Message 无此字段，类型保证） |
| **reasoning 流式** | `StreamChunk::ReasoningDelta` 推给 Observer，用完即弃 |
| **FIM** | `/beta/completions` + `prompt`/`suffix` 参数 |
| **前缀续写** | `/beta/chat/completions` + `messages[-1]` 带 `prefix:True` |

## Quick Start

```moonbit
let config = @deepseek.DeepSeekConfig::new(api_key="sk-...")
let port = @deepseek.DeepSeekModelPort::new(config)

// 作为 posoco ModelPort 使用
let agent = @posoco.Agent::new(port, tools, ...)
```

## 依赖

- `colmugx/posoco` — ModelPort trait + 类型
- `moonbitlang/async/http` — HTTP transport
- `moonbitlang/core/json` — JSON 编解码
