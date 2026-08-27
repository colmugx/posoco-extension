# colmugx/posoco-ext-nowledge-mem

把 [Nowledge Mem](https://mem.nowledge.co) 接入 Posoco，作为 agent 的记忆后端：
走 `MemoryPort` 的启动工作记忆简报与会话同步，外加 10 个 `nmem` 工具供模型主动调用。
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
2. `nmem` CLI 在 PATH 里——10 个工具和一次性被动工作记忆读取都要用它：

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
let nmem = NowledgeMem(
  source_app="cetas",
  transport=HttpNmemTransport::HttpNmemTransport() as &NmemTransport,
  runner=PlatformRunner::PlatformRunner() as &NmemRunner,
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

- `NowledgeMem(source_app~, transport~, runner~, expose_delete_tool?)` ——
  `source_app~` 是必传的宿主产品身份（cetas 传 `"cetas"`）：它决定同步线程
  id 的前缀和用户可见文案的称呼。生产环境传 `HttpNmemTransport` +
  `PlatformRunner`；两个 IO 接缝都可注入，测试里全换成脚本化 fake。
- `attach(group)` —— 可选优化：在宿主 task group 上启动 750ms flusher 轮询，
  先排线程同步队列、再排记忆写队列。提交不依赖它——每个 turn 结束即提交
  （见下），`on_start` 启动时排一次，`on_shutdown` 收尾再排一次；随时可调
  `flush_pending()` 强制排空。

### 工具一览

| 工具 | nmem CLI | 说明 |
|------|----------|------|
| `nmem_status` | `--json status` | 连通性检查（15s 预算） |
| `read_context_bundle` | `context` | 官方 MCP 同名工具；上下文 bundle（`rendered_markdown` \| `markdown` \| `content` 依序取值）——通常已自动注入 system prompt，仅在会话上下文重大变化后才需要重读 |
| `read_working_memory` | `wm read` | 官方 MCP 同名工具；working memory 正文——通常已自动注入 system prompt，仅在会话上下文重大变化后才需要重读 |
| `memory_search` | `m search` | 官方 MCP 同名工具；服务端语义检索（deep 模式、重要度/标签过滤）——启动简报之后的主动召回通路 |
| `memory_add` | `m add` | 官方 MCP 同名工具；经 `MemoryPort::store` 入队——与被动写入同一条通路 |
| `memory_update` | `m update` | 直连 CLI；检索的唯一事实源就是服务端 |
| `memory_delete` | `m delete -f` | 默认不注册；`expose_delete_tool=true` 开启（硬删除，不可逆） |
| `thread_search` | `t search` | 官方 MCP 同名工具；检索历史会话，含其他工具同步进来的 |
| `thread_show` | `t show` | 渐进加载（limit / offset / 内容截断） |
| `thread_create` | `t create` | 主动产出一份 handoff 摘要，供后续会话取用 |

五个官方 MCP 工具名（`read_context_bundle` / `read_working_memory` /
`memory_search` / `thread_search` / `memory_add`）与[官方 MCP 工具面](https://mem.nowledge.co/SKILL.md)同名对齐；
`nmem_status`、`memory_update`、`memory_delete`、`thread_show`、
`thread_create` 是 posoco 原生增补。`memory_search`、`thread_search`、
`nmem_status` 的成功结果还会把 CLI 输出解析后的 JSON 附在工具结果的
`structured` 通道里。

### 命令

| 命令 | 效果 |
|------|------|
| `/memory status` | nmem 连通探测（10s 预算）+ 每条线程 lane 一行（thread_id / created / 已确认条数 / last_error）+ 写队列深度 + 被动检索状态（done / pending） |
| `/memory flush` | 立刻排空待写线程 lane 与记忆写队列 |

`/memory` 无参或未知子命令时打印 usage。这是同步诊断面：lane 的
`last_error` 从此用户可查，不再只存在内存里——Observer 端口是
core → 扩展的只读通道，扩展自己发不了 observer 事件。

### 自动发生的事

- **首轮读记忆**：每个 run 的首轮，自动读取工作记忆并注入到 system prompt 之后是否继续召回，由模型主动调 `memory_search` 决定。读取失败不影响 turn 运行。
- **每轮结束提交**：每个 turn 结束时，本轮的转录与排队的记忆写都会提交到 nmem（完成与失败都提交），崩溃最多只丢进行中的一轮。
- **中途节流**：长 turn 中途按节奏排空暂存，控制内存占用。
- **会话重定向**：会话被重定向时，当前转录先暂存进旧会话，之后同步跟随新会话 id。
- **启动**：解析配置并排空一次。
- **记忆写入**：`memory_add` 等写入排队写回服务端，metadata 约定键：`title`、`unit_type`、`importance`、`labels`。

### 测试

在本模块目录下：

```bash
rtk moon test src --target native   # 150 个测试
rtk moon check src --target js      # 门禁 Bun runner
```

覆盖配置解析、消息映射、delta 引擎、transport 应答判定、同步状态机、端口
接线、MemoryPort 语义、turn 结束提交各路径（完成、失败、超时有界、
before_tool 节流——全程不调 flush_pending/attach）、全部 10 个工具（含
structured 载荷）、`/memory` 命令和会话重定向——全部跑在脚本化 fake 上，
不需要装 Nowledge Mem，也不需要 `nmem` 二进制。

### 常见问题

**服务没起** —— 调 `nmem_status` 拿结构化的连通性报告，跑 `/memory status`
看完整诊断（lane、队列、被动检索状态），或直接跑 `nmem status`。

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
