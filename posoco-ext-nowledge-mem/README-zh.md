# colmugx/posoco-ext-nowledge-mem

[English](README.md) | 简体中文

把 [Nowledge Mem](https://mem.nowledge.co) 接入 Posoco，作为 agent 的记忆后端：
走 `MemoryPort` 的每轮自动检索与会话同步，外加 8 个 `nmem` 工具供模型主动调用。
被动检索和主动工具共享同一份记忆。

## Nowledge Mem 是什么

官方定位是「AI 工作的记忆层」（[docs](https://mem.nowledge.co/docs)）：所有 AI
工具读写同一个记忆库，而不是各玩各的、记忆焊死在单个平台里。

- **一份记忆，全工具通用。** "Claude, ChatGPT, Cursor. One memory that
  compounds"（[官网](https://mem.nowledge.co)）。官方连接器已覆盖 Claude
  Code、Cursor、Codex、Gemini CLI、Copilot CLI、ChatGPT 等；任何工具存下的
  记忆，其他工具都能搜到。
- **全文 thread 之上再做蒸馏。** 会话原文逐字保留（threads），决策被蒸馏成
  带来源、日期、置信度的类型化记忆（fact / decision / learning）；后台自动
  关联相关记忆、把新证据并入旧结论，overnight learning 产出早间简报。会话
  启动时先给蒸馏层——Context Bundle 优先，取不到再读 Working Memory
  （[docs](https://mem.nowledge.co/docs)）。
- **本地优先，可远程。** 桌面 / headless / Docker 服务跑在你自己机器上
  （"everything local, fully offline if you want"；"your data never touches
  Nowledge servers"），远程服务器和 Cloud beta 提供跨设备同步。
- **记忆是结构化的、可分域。** 记忆带 unit type、重要度、标签，检索时可
  过滤；spaces 按项目或 agent 划分独立泳道。
- **一句话宣言。** "Everything about execution is depreciating; context is
  the only thing appreciating"——租用智能，拥有记忆
  （[官方博客](https://nowledge-labs.ai/blog/rent-the-intelligence-own-the-memory)）。

## 使用本扩展

### 前置条件

1. Nowledge Mem 服务——本地（默认 `http://127.0.0.1:14242`）或远程。
2. `nmem` CLI 在 PATH 里——8 个工具、启动上下文链、被动索引预热/刷新都要
   用它：

```bash
nmem status             # 验证连通性
```

线程同步两者都不需要——它直接走 HTTP。只有服务可达的无头宿主照样能同步
会话。

### 配置

每个配置项优先级：**环境变量 > `~/.nowledge-mem/config.json` > 默认值。**
值会 trim，空白视为未设置。配置文件兼容驼峰和蛇形命名，且与所有其他
Nowledge Mem 集成共享——已有的 spaces 和 threads 直接可见。

| 环境变量 | config.json 键 | 含义 | 默认值 |
|---------|----------------|------|--------|
| `NMEM_API_URL` | `apiUrl` / `api_url` | 服务地址 | `http://127.0.0.1:14242` |
| `NMEM_API_KEY` | `apiKey` / `api_key` | API key（`Authorization: Bearer` + `X-NMEM-API-Key` 双头） | — |
| `NMEM_SPACE` / `NMEM_SPACE_ID` | `space` / `spaceId` / `space_id` | space 作用域（请求体注入 `space_id`，CLI 加 `--space`） | — |
| `NMEM_AGENT_ID` | `agentId` / `agent_id` | Agent id（AI identity） | — |
| `NMEM_HOST_AGENT_ID` | `hostAgentId` / `host_agent_id` | 宿主 agent id | — |
| `NMEM_PLUGIN_SOURCE_APP` | —（仅环境变量） | 运行时覆盖构造参数 `source_app`；线程 id 形如 `{source_app}-{session_id}` | 构造值 |
| `NMEM_SYNC_TIMEOUT_MS` | —（仅环境变量） | 线程同步 HTTP 超时 | `120000`，clamp 到 1s–30min |

### 组装

```mbt nocheck
let nmem = NowledgeMem::new(
  source_app="cetas",
  transport=HttpNmemTransport::HttpNmemTransport() as &NmemTransport,
  runner=PlatformRunner::PlatformRunner() as &NmemRunner,
)

// 在宿主的 with_task_group 作用域内调用；group 需伴随 agent 整个生命周期
// （mcp / ratelimit 同款模式）：
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

- `NowledgeMem::new(source_app~, transport~, runner~, expose_delete_tool?)` ——
  `source_app~` 是必传的宿主产品身份（cetas 传 `"cetas"`）：它决定同步线程
  id 的前缀和用户可见文案的称呼。生产环境传 `HttpNmemTransport` +
  `PlatformRunner`；两个 IO 接缝都可注入，测试里全换成脚本化 fake。
- `attach(group)` —— 在宿主 task group 上启动 flusher：750ms 轮询，先排线程
  同步队列、再排记忆写队列。不 attach 也不丢数据：`on_start` 启动时排一次，
  `on_shutdown` 收尾再排一次；随时可调 `flush_pending()` 强制排空。

### 工具一览

| 工具 | nmem CLI | 说明 |
|------|----------|------|
| `nmem_status` | `--json status` | 连通性检查（15s 预算） |
| `memory_search` | `m search` | 服务端语义检索（deep 模式、重要度/标签过滤）——不走本地被动索引 |
| `memory_add` | `m add` | 经 `MemoryPort::store` 入队——与被动写入同一条通路 |
| `memory_update` | `m update` | 直连 CLI；成功后刷新本地索引，被动检索不再返回旧文案 |
| `memory_delete` | `m delete -f` | 默认不注册；`expose_delete_tool=true` 开启（硬删除，不可逆） |
| `thread_search` | `t search` | 检索历史会话，含其他工具同步进来的 |
| `thread_show` | `t show` | 渐进加载（limit / offset / 内容截断） |
| `thread_create` | `t create` | 主动产出一份 handoff 摘要，供后续会话取用 |

### 自动发生的事

- **每次模型调用**：core 的 `MemoryRetrievalHook` 拿最后一条用户消息查本地
  索引（top_k 5），命中以幂等的 `[MEMORY]` SystemMessage 注入——检索失败只
  发 observer 事件，绝不让 turn 失败。
- **每个 turn**：模型可见转录进入所属 `(配置, 会话)` lane 等待增量同步
  （已确认游标、sha256 指纹、幂等键 + 服务端去重，checkpoint 冲突全量重发
  自愈，线程消失则重建）。
- **启动时**：索引从服务端预热（`nmem --json m -n 200`）；启动上下文链在
  总预算 8s 内依次尝试 `nmem --json context --source-app <app>` →
  `nmem --json wm read` → `~/ai-now/memory.md`（仅默认本地服务）→ 降级原因，
  单段 20k 字符截断，最终以 `## Nowledge Mem Context Bundle` 追加进
  system prompt，外加固定注入的 `## Nowledge Mem Guidance`。
- **`MemoryPort::store`**：同步返回 `pending:<n>` 票据并排队等 `nmem m add`
  写入服务端；metadata 约定键：`title`、`unit_type`、`importance`、`labels`。

### 平台支持

- **native** —— `nmem` 走 `@process.collect_output`，家目录文件走
  `moonbitlang/async/fs`，环境变量走 `moonbitlang/core/env`。
- **js（Bun）** —— 同一套 `NmemRunner` 接缝，底层换成 `Bun.spawn`、
  `Bun.file`、`process.env`；HTTP 与 native 共享（`moonbitlang/async/http`，
  js 后端就是 fetch）。
- **wasm** —— 不支持；包只面向 `native + js`。

### 测试

在本模块目录下：

```bash
rtk moon test src --target native   # 130 个测试
rtk moon check src --target js      # 门禁 Bun runner
```

覆盖配置解析、消息映射、delta 引擎、transport 应答判定、同步状态机、端口
接线、MemoryPort 语义和全部 8 个工具——全部跑在脚本化 fake 上，不需要装
Nowledge Mem，也不需要 `nmem` 二进制。

### 常见问题

**服务没起** —— 调 `nmem_status` 拿结构化的连通性报告，或直接跑
`nmem status`。

**同步失败是刻意静默的** —— 失败的 flush 记录 lane 的 `last_error`，不动
已确认游标；下个 turn 重新暂存全量转录，flusher 从最后确认状态重试
（幂等键保证服务端重发安全）。排队的记忆写失败则重入队尾。任何同步失败都
不可能中断 turn。

**同步慢 / 远程服务** —— 调大 `NMEM_SYNC_TIMEOUT_MS`。

## Nowledge Mem 给 Posoco 带来什么

- **记忆跨会话、跨工具。** 每轮对话自动把相关记忆检索进上下文（core 的
  `MemoryRetrievalHook` 驱动 `[MEMORY]` SystemMessage）。agent 一进场就知道
  之前的会话定了什么结论——不管那结论是它自己存的，还是别的工具存的。
- **决策进入共享库。** Posoco agent 学到的东西不私有：`memory_add` 和被动
  写入落进同一个记忆库，你的其他 AI 工具都能读；`thread_search` 能召回那些
  工具同步进来的会话。
- **会话变成资产。** 增量线程同步（游标、指纹、幂等、checkpoint 自愈）把
  每次会话变成可检索、去重的档案，而不是退出即蒸发的状态。
- **冷启动有上下文。** Context Bundle / Working Memory 链在启动时追加进
  system prompt，外加何时搜索、何时保存的常驻指引。新会话开局就有方向，
  不是从零开始。

## Posoco 的设计为什么能放大它的能力

- **记忆是一等端口。** Posoco 把 `MemoryPort` 声明为六边形端口：本扩展实现
  trait、在 manifest 的 `memory` 槽位自报，core 的 `MemoryRetrievalHook`
  自动接线——声明端口即获得被动记忆，不需要自建「读转录 / 搬运 / 改
  prompt」的整套管道。
- **一个 struct，多个端口视图。** `NowledgeMem` 同时是 `Lifecycle` + `Hook`
  + `Observer` + `SystemPromptContributor` + `ToolProvider` + `MemoryPort` +
  `Extension`，在 manifest 各槽位自报同一个 `self`。所有视图共享一份状态：
  本地索引既服务被动 `[MEMORY]` 注入，也被 `memory_update` 刷新。
- **同步端口契约逼出了更好的架构。** `MemoryPort` 等不了 CLI，于是扩展维护
  本地索引副本：检索瞬时完成——没有逐次进程 spawn，没有网络往返；写入走
  写后队列由 flusher 批量写回——成本摊销、故障隔离、静默重试。
- **深模块 Agent 藏住协议。** 宿主构造扩展、放进 `exts`，到此为止。游标、
  指纹、幂等键、降级链一概不上漏；多个记忆后端可并存——core 把各端口返回
  的结果直接拼接。

## 链接

- [Nowledge Mem 官网](https://mem.nowledge.co) | [文档](https://mem.nowledge.co/docs) | [博客](https://nowledge-labs.ai/blog)
- [集成生态](https://mem.nowledge.co/docs/integrations)
