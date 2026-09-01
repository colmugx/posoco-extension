# colmugx/posoco-ext-nowledge-mem

把 [Nowledge Mem](https://mem.nowledge.co) 接入 Posoco，作为 agent 的记忆后端：
走 `MemoryPort` 的启动工作记忆简报与会话同步


## Nowledge Mem 是什么

官方定位是「AI 工作的记忆层」（[docs](https://mem.nowledge.co/docs)）：所有 AI
工具读写同一个记忆库，而不是各玩各的、记忆焊死在单个平台里。

**一句话宣言。** "Everything about execution is depreciating; context is
  the only thing appreciating"——租用智能，拥有记忆
  （[官方博客](https://nowledge-labs.ai/blog/rent-the-intelligence-own-the-memory)）。

## 使用本扩展

### 前置条件

1. Nowledge Mem 服务——本地（默认 `http://127.0.0.1:14242`）或远程。服务在
   `{api_url}/mcp` 上提供 MCP 接口；不需要 `nmem` CLI——所有工具和会话开场
   的记忆读取都走 MCP，线程同步直接走 HTTP。

### 配置

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

```bash
moon add colmugx/posoco-ext-nowledge-mem
```

```mbt nocheck
// moon.pkg: "colmugx/posoco-ext-nowledge-mem" @nmem
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

### 工具一览

所有工具都经 MCP client 分发；posoco 侧参数映射到服务端工具 schema
（`id` → `memory_id`）。

| 工具 | MCP 工具 | 说明 |
|------|----------|------|
| `nmem_status` | 连通探测 | MCP 探测（list_tools + 服务端身份，15s 预算） |
| `read_context_bundle` | `read_context_bundle` | 官方同名；上下文组合包——working memory + 相关蒸馏知识——渲染为 markdown（`rendered_markdown` \| `markdown` \| `content` 依序取值）；仅在会话上下文重大变化后按需重读，不必常规调用 |
| `memory_update` | `memory_update` | 直连服务端；新信息细化既有记忆时就地更新（update 语义不在 port 面上） |
| `thread_search` | `thread_search` | 官方同名；检索历史会话，含其他工具同步进来的 |
| `thread_fetch_messages` | `thread_fetch_messages` | 渐进加载（limit / offset） |
| `memory_delete` | `memory_delete` | 默认不注册；`expose_delete_tool=true` 开启；走 `MemoryPort` `delete` 槽——`pending:` 票据本地撤销排队写入，真实 id 排队硬删除（不可逆）待排空 |

### 命令

| 命令 | 效果 |
|------|------|
| `/memory status` | MCP 连通探测（10s 预算）+ 每条线程 lane 一行（thread_id / created / 已确认条数 / last_error）+ 写队列深度 + 会话 inbound 状态（injected / pending） |
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

## 自动发生的事

- **首回合注入开场记忆（会话快照）**：会话首回合时，core 发现加载的
  transcript 为空，给每个接入的 memory provider 恰好一次
  `inbound(session_id~, request~)` 调用。本扩展经 MCP 通道读取工作记忆快照
  （5s 预算——这次读在模型调用路径上），包进自己的
  `<nmem-context type="memory" trust="false">` 信封（受上下文长度上限约束）
  作为完整正文返回；core 在自己的固定引导句之后
  原样注入一条 user 角色消息，置于首条真实用户输入之前。该消息被冻结：
  一个会话生命周期只注入一次，永不改写——即便工作记忆为空，这次尝试也已
  消耗。resume 的进程在加载的历史里发现已持久化的消息，逐字节原样保留——
  历史是在它之下推导出来的，换成最新的快照会把对话和它的上下文割裂（还会
  击穿整段历史的 provider 前缀缓存）。信封也不会进同步线程：`map_messages`
  跳过它，线程标题仍是第一条真实用户消息。工作记忆为空则不贡献；读取失败
  上报给 core，由 core 发出点名本扩展的 `secondary_failure` observer 事件
  ——turn 照常进行。开场快照之后，召回全凭主动：core 的 `memory_search`
  路由进本 port，`read_context_bundle` 按需重读。
- **每轮结束提交**：每个 turn 结束时，本轮的转录与排队的记忆写都会提交到 nmem（完成与失败都提交），崩溃最多只丢进行中的一轮。
- **中途节流**：长 turn 中途按节奏排空暂存，控制内存占用。
- **会话重定向**：会话被重定向时，当前转录先暂存进旧会话，之后同步跟随新会话 id。
- **启动**：解析配置、把解析出的 MCP 端点交给惰性 client、排空一次。
- **记忆写入**：`MemoryPort` 存储槽——`store` 排队并返回 `pending:<n>` 票据、以 `memory_add` MCP 调用写回服务端（metadata 约定键：`title`、`unit_type`、`importance`、`labels`）；`delete` 对票据本地撤销、对真实 id 排队远端删除。`search` 发 `memory_search` MCP 调用（`top_k` 映射为服务端 `limit`），把 `{"memories":[…]}` 渲染为每条一行 `- [id] content`（无命中返回 `None`；非 JSON 文本降级为原文）。排队的写在线程车道之后排空，`/memory flush` 可强制。

### 常见问题

**服务没起** —— 调 `nmem_status` 拿结构化的连通性报告，跑 `/memory status`
看完整诊断（lane、队列、会话 inbound 状态）。

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

- **被动记忆不用自己接线。** 会话首回合自动把工作记忆快照注入上下文，agent
  一进场就知道之前定了什么。你不必手搓「读转录 / 搬运 / 改 prompt」的管道；
  读取藏在扩展的 `MemoryPort` 视图背后，会话快照语义（一次注入、永不改写）
  随 port 而来。
- **主动写和被动召回不打架。** 经 core 内置 `memory_add` 存下的记忆和回合里
  被动沉淀的转录，走同一条写通路、同一份状态：不会出现「工具刚存的记忆，
  下一轮召回却读不到」的漂移，`/memory` 诊断面看的也是同一批数据。
- **一份事实，不养会过期的本地副本。** 被动检索直查服务端，没有需要预热、
  刷新、悄悄过期的本地缓存；每个会话恰好取一次。写入批量回写——成本摊销、
  故障隔离、失败静默重试，绝不拖垮回合。

## Posoco 的设计为什么能放大它的能力

- **注入是 port，不是管道工的活。** 会话开场记忆消息是 core 的
  `MemoryPort` 机制：引导句、消息角色、置于首条用户输入之前、冻结与
  resume 语义都归 core；本扩展只用信封正文应答那一次 `inbound` 调用。
  core 保持产品无关，换一个记忆后端也只是换一个扩展，agent 主体一行不动。
- **一个扩展覆盖全部切面，状态不分裂。** `NowledgeMem` 同一个 struct 同时是
  `MemoryPort`、生命周期、钩子、观察者、系统提示、工具、命令多个端口视图，
  在 manifest 各槽位自报同一个 `self`。所有视图共享一份状态：内置工具写的
  记忆和同步被动沉淀的转录走同一条写通路——不会出现「工具存了、召回却读
  不到」的两套账。
- **服务端即事实，没有会过期的本地副本。** 被动检索直查服务端，没有需要预热、
  刷新、悄悄过期的本地缓存；每个会话恰好取一次。写入批量回写——成本摊销、
  故障隔离、失败静默重试，绝不拖垮回合。
- **深模块把协议藏到底，后端可并存。** 你构造扩展、放进 `exts` 就完事：同步、
  去重、容错的细节一概不上漏。多个记忆扩展可并存，各自拥有自己的注入——
  今天接 nmem，明天加一个也只是多挂一个扩展。

## 链接

- [Nowledge Mem 官网](https://mem.nowledge.co) | [文档](https://mem.nowledge.co/docs) | [博客](https://nowledge-labs.ai/blog)
- [集成生态](https://mem.nowledge.co/docs/integrations)
