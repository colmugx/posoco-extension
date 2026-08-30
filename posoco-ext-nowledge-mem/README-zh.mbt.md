# colmugx/posoco-ext-nowledge-mem

把 [Nowledge Mem](https://mem.nowledge.co) 接入 Posoco，作为 agent 的记忆后端：
走 `MemoryPort` 的启动工作记忆简报与会话同步，外加 8 个工具供模型主动调用。
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

1. Nowledge Mem 服务——本地（默认 `http://127.0.0.1:14242`）或远程。服务在
   `{api_url}/mcp` 上提供 MCP 接口；不需要 `nmem` CLI——所有工具和一次性
   被动工作记忆读取都走 MCP，线程同步直接走 HTTP。

### 配置

每个配置项优先级：**环境变量 > `~/.nowledge-mem/config.json` > 默认值。**
值会 trim，空白视为未设置。配置文件兼容驼峰和蛇形命名，且与所有其他
Nowledge Mem 集成共享——已有的 spaces 和 threads 直接可见。

| 环境变量 | config.json 键 | 含义 | 默认值 |
|---------|----------------|------|--------|
| `NMEM_API_URL` | `apiUrl` / `api_url` | 服务地址 | `http://127.0.0.1:14242` |
| `NMEM_MCP_URL` | `mcpUrl` / `mcp_url` | MCP 端点覆盖 | `{api_url}/mcp`（先剥掉遗留 `/remote-api` 前缀） |
| `NMEM_API_KEY` | `apiKey` / `api_key` | API key（两条通道都是 `Authorization: Bearer`） | — |
| `NMEM_SPACE` / `NMEM_SPACE_ID` | `space` / `spaceId` / `space_id` | space 作用域（同步请求体和工具参数都注入 `space_id`） | — |
| `NMEM_AGENT_ID` | `agentId` / `agent_id` | Agent id（AI identity） | — |
| `NMEM_HOST_AGENT_ID` | `hostAgentId` / `host_agent_id` | 宿主 agent id | — |
| `NMEM_PLUGIN_SOURCE_APP` | —（仅环境变量） | 运行时覆盖构造参数 `source_app`；线程 id 形如 `{source_app}-{session_id}`，MCP 调用也以它署名 | 构造值 |
| `NMEM_SYNC_TIMEOUT_MS` | —（仅环境变量） | 线程同步 HTTP 超时 | `120000`，clamp 到 1s–30min |

### 组装

```mbt nocheck
let nmem = NowledgeMem(
  source_app="cetas",
  transport=HttpNmemTransport::HttpNmemTransport() as &NmemTransport,
  mcp=LazyNmemMcp::LazyNmemMcp() as &NmemMcp,
  platform=PlatformFs::PlatformFs() as &NmemPlatform,
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

// 可选优化——750ms flusher 轮询。在宿主的 with_task_group 作用域内调用；
// group 需伴随 agent 整个生命周期（mcp / ratelimit 同款模式）：
nmem.attach(group)
```

- `NowledgeMem(source_app~, transport~, mcp~, platform~, expose_delete_tool?)` ——
  `source_app~` 是必传的宿主产品身份（cetas 传 `"cetas"`）：它决定同步线程
  id 的前缀、用户可见文案的称呼，并给 MCP 调用署名。生产环境传
  `HttpNmemTransport`（线程同步 HTTP）+ `LazyNmemMcp`（工具）+ `PlatformFs`
  （env + home 文件）；三个 IO 接缝都可注入，测试里全换成脚本化 fake。
- `attach(group)` —— 可选优化：在宿主 task group 上启动 750ms flusher 轮询，
  先排线程同步队列、再排记忆写队列。提交不依赖它——每个 turn 结束即提交
  （见下），`on_start` 启动时排一次，`on_shutdown` 收尾再排一次并关闭 MCP
  连接；随时可调 `flush_pending()` 强制排空。

### MCP 连接

MCP client 与其服务天然 1:1，所以扩展自己维护一个惰性连接的 client
（elyra 内置 web_search 同款模式），不依赖多服务器的 MCP 宿主：

- **惰性** —— `on_start` 只登记解析出的端点（`mcp_url`、Bearer key、client
  名即 `source_app`）；连接在第一次工具调用 / 探测 / 被动读取时才建立，从不
  触碰记忆的宿主零开销。
- **参数即作用域** —— SDK transport 只带 auth token，环境作用域随工具参数
  下发（所有工具带 `space_id`，服务端 schema 接受的工具再带 `source_app` /
  `agent_id` / `host_agent_id`）——与上游 langgraph connector 的拦截器注入
  同一套语义。
- **反应式重连** —— 链路级失败或超时丢弃连接，下次调用原位重连；服务端
  JSON-RPC 错误是真实答案，不触发重连。取消信号永不吞掉。
- **有界** —— 每次调用自带预算（被动读 5s、探测 15s、工具与写回 30s）。

### 工具一览

所有工具都经 MCP client 分发；posoco 侧参数映射到服务端工具 schema
（`id` → `memory_id`，`labels` → `filter_labels`）。

| 工具 | MCP 工具 | 说明 |
|------|----------|------|
| `nmem_status` | 连通探测 | MCP 探测（list_tools + 服务端身份，15s 预算） |
| `read_context_bundle` | `read_context_bundle` | 官方同名；上下文 bundle（`rendered_markdown` \| `markdown` \| `content` 依序取值）——通常已自动注入 system prompt，仅在会话上下文重大变化后才需要重读 |
| `read_working_memory` | `read_working_memory` | 官方同名；working memory 正文——通常已自动注入 system prompt，仅在会话上下文重大变化后才需要重读 |
| `memory_search` | `memory_search` | 官方同名；服务端语义检索（deep 模式、标签过滤）——启动简报之后的主动召回通路 |
| `memory_add` | `memory_add` | 官方同名；经 `MemoryPort::store` 入队——与被动写入同一条通路，排空时发 `memory_add` MCP 调用 |
| `memory_update` | `memory_update` | 直连服务端；检索的唯一事实源就是服务端 |
| `memory_delete` | `memory_delete` | 默认不注册；`expose_delete_tool=true` 开启（硬删除，不可逆） |
| `thread_search` | `thread_search` | 官方同名；检索历史会话，含其他工具同步进来的 |
| `thread_fetch_messages` | `thread_fetch_messages` | 渐进加载（limit / offset） |

五个官方 MCP 工具名（`read_context_bundle` / `read_working_memory` /
`memory_search` / `thread_search` / `memory_add`）与[官方 MCP 工具面](https://mem.nowledge.co/SKILL.md)同名对齐；
`nmem_status`、`memory_update`、`memory_delete`、`thread_fetch_messages`
是 posoco 原生增补。`thread_create` 随 CLI runner 一并移除——服务端 MCP
面没有对应工具；handoff 连续性由自动线程同步承担。`memory_search`、
`thread_search` 和读取类工具的回复是对象/数组时，会把解析后的 JSON 附在
工具结果的 `structured` 通道里。

### 命令

| 命令 | 效果 |
|------|------|
| `/memory status` | MCP 连通探测（10s 预算）+ 每条线程 lane 一行（thread_id / created / 已确认条数 / last_error）+ 写队列深度 + 被动检索状态（done / pending） |
| `/memory flush` | 立刻排空待写线程 lane 与记忆写队列 |

`/memory` 无参或未知子命令时打印 usage。这是同步诊断面：lane 的
`last_error` 从此用户可查，不再只存在内存里——Observer 端口是
core → 扩展的只读通道，扩展自己发不了 observer 事件。

### 命令 —— `/nmem`（连接管理）

| 命令 | 效果 |
|------|------|
| `/nmem` / `/nmem status` | toast 输出连接全景：工具通道（MCP 端点）、同步通道 + local/remote 模式、身份（`source_app`/space）、压过配置文件的 env 覆盖项，附带一次 MCP 连通探测 |
| `/nmem url <api>` | 切换服务基地址（线程同步 + 派生的 `{api}/mcp` 端点）；暂存同步先冲到旧地址；持久化进共享配置文件；探测新端点 |
| `/nmem mcp <url>` | 只覆盖 MCP 端点（同步基地址不动）；同样的冲刷/持久化/探测行为 |

`/nmem` 是把 agent 指向 nmem cloud 的入口：基地址不再是
`http://127.0.0.1:14242`，其余全部跟着走。切换立即生效（config 与惰性
MCP client 原位重配），同时合并写回 `~/.nowledge-mem/config.json`，后续
进程直接从新地址启动——兄弟键保留、文件既有键拼写保持（蛇形文件保持
蛇形）。畸形配置文件会被拒绝而不是覆盖；持久化失败降级为仅运行时生效并
给出警告行；两种情况反馈文本都写明实际发生了什么。env 覆盖
（`NMEM_API_URL` 等）依然压过配置文件，`/nmem status` 会列出它们，意外
地址有迹可循。

### 自动发生的事

- **首轮读记忆**：每个 run 的首轮，自动读取工作记忆并注入到 system prompt 之后是否继续召回，由模型主动调 `memory_search` 决定。读取失败不影响 turn 运行。
- **每轮结束提交**：每个 turn 结束时，本轮的转录与排队的记忆写都会提交到 nmem（完成与失败都提交），崩溃最多只丢进行中的一轮。
- **中途节流**：长 turn 中途按节奏排空暂存，控制内存占用。
- **会话重定向**：会话被重定向时，当前转录先暂存进旧会话，之后同步跟随新会话 id。
- **启动**：解析配置、把解析出的 MCP 端点交给惰性 client、排空一次。
- **记忆写入**：`memory_add` 等写入排队、以 `memory_add` MCP 调用写回服务端，metadata 约定键：`title`、`unit_type`、`importance`、`labels`。

### 平台说明与本地补丁

- **native** —— MCP 走 `moonbitlang/async/http`（colmugx/mcp 内部），home
  文件走 `moonbitlang/async/fs`，env 走 `moonbitlang/core/env`。
- **js (Bun)** —— 同一套接缝；home 文件走 `Bun.file`，env 走
  `process.env`；HTTP 与 native 共享（js 后端即 fetch）。
- **colmugx/mcp 修复随工作区 `.mooncakes` 同步** —— Nowledge Mem 服务端
  （2025-11-25 streamable HTTP）暴露出 SDK client 的两处缺陷，均已修复于
  colmugx/mcp 源码树（待发版）；发布前本工作区的 `.mooncakes` 副本与源码树
  保持字节级同步，发版后升依赖引脚、撤销同步即可：
  1. `client/era_probe.mbt` —— `server/discover` 探测被 HTTP 4xx 拒绝时
     回退 legacy initialize 握手（该服务端对非 initialize 首消息回
     `422 "Unexpected message, expect initialize request"`），不再直接致命失败。
  2. `transport/sse.mbt`（`sse_event_verdict`）+ 两处响应循环 —— SSE 流开头
     空 data 的 keepalive 事件不再作为 JSON-RPC 消息入队（否则 initialize
     解析到空串、响应队列错位）；带 `id` 的注释心跳不再被误判为流结束。

  已对本地 nowledge-mem 0.10.72 真机验证：连接、`tools/list`（67 个工具）、
  `read_working_memory`、`memory_search` 全部跑通。

### 测试

在本模块目录下：

```bash
rtk moon test src --target native   # 154 个测试
rtk moon check src --target js      # 门禁 Bun 平台接缝
```

覆盖配置解析（含 `mcp_url` 推导）、消息映射、delta 引擎、transport 应答
判定、同步状态机、端口接线、MemoryPort 语义、turn 结束提交各路径（完成、
失败、超时有界、before_tool 节流——全程不调 flush_pending/attach）、全部
8 个工具（参数映射与 structured 载荷）、MCP client 契约（脚本化 fake）、
`/memory` 与 `/nmem` 命令（status 行、URL 切换的先冲刷 + 持久化合并语义 +
失败降级）、会话重定向——全部跑在脚本化 fake 上，不需要装
Nowledge Mem，也不需要 `nmem` 二进制。

### 常见问题

**服务没起** —— 调 `nmem_status` 拿结构化的连通性报告，跑 `/memory status`
看完整诊断（lane、队列、被动检索状态）。

**同步失败是刻意静默的** —— 失败或超时的提交记录 lane 的 `last_error`
（记忆写记 `mem.last_error`），不动已确认游标；下个 turn 重新暂存全量转录、
返回前再次提交（幂等键保证服务端重发安全）。排队的记忆写失败则重入队尾。
任何同步失败都不可能中断 turn——turn 结束排空自带 `NMEM_SYNC_TIMEOUT_MS`
预算，也不会拖住返回。

**同步慢 / 远程服务** —— 调大 `NMEM_SYNC_TIMEOUT_MS`。

## Nowledge Mem 给 Posoco 带来什么

nmem 的立场是「智能可以短租，记忆必须属于你」：记忆要跟着你走，而不是焊死在
单个工具里。Posoco 把 nmem 从 L1 抬到 L2 的 harness：它把记忆接进 agent 的回合
循环，让记忆跟着你的 agent 走，而不用你手搓转录采集、上下文注入、写入队列和
失败重试。

- **被动记忆不用自己接线。** 首轮自动把工作记忆注入上下文，agent 一进场就
  知道之前定了什么。你不必手搓「读转录 / 搬运 / 改 prompt」的管道，换记忆后端
  也只是换一个端口实现。
- **主动写和被动召回不打架。** 模型主动存的记忆和回合里被动沉淀的转录，走同
  一条写通路、同一份状态：不会出现「工具刚存的记忆，下一轮召回却读不到」的
  漂移，`/memory` 诊断面看的也是同一批数据。
- **一份事实，不养会过期的本地副本。** 被动检索直查服务端，没有需要预热、
  刷新、悄悄过期的本地缓存；每个 run 恰好取一次。写入批量回写——成本摊销、
  故障隔离、失败静默重试，绝不拖垮回合。

## Posoco 的设计为什么能放大它的能力

- **记忆是声明出来的，不是接出来的。** Posoco 把 `MemoryPort` 做成六边形的一等
  端口：你实现它、在 manifest 的 `memory` 槽位自报，被动记忆就自动接线——不用
  自己写「读转录 / 搬运 / 改 prompt」的管道。换一个记忆后端也只是换端口实现，
  agent 主体一行不动。
- **一个扩展覆盖全部切面，状态不分裂。** `NowledgeMem` 同一个 struct 同时是
  生命周期、钩子、工具、系统提示、命令多个端口视图，在 manifest 各槽位自报同一个
  `self`。所有视图共享一份状态：工具写的记忆和端口被动沉淀的转录走同一条写通路——
  不会出现「工具存了、召回却读不到」的两套账。
- **服务端即事实，没有会过期的本地副本。** 记忆端口异步化后，被动检索直查
  服务端，没有需要预热、刷新、悄悄过期的本地缓存；每个 run 恰好取一次。写入
  批量回写——成本摊销、故障隔离、失败静默重试，绝不拖垮回合。
- **深模块把协议藏到底，后端可并存。** 你构造扩展、放进 `exts` 就完事：同步、
  去重、容错的细节一概不上漏。多个记忆后端可并存，core 把各端口结果直接拼接——
  今天接 nmem，明天加一个也只是多挂一个端口。

## 链接

- [Nowledge Mem 官网](https://mem.nowledge.co) | [文档](https://mem.nowledge.co/docs) | [博客](https://nowledge-labs.ai/blog)
- [集成生态](https://mem.nowledge.co/docs/integrations)
