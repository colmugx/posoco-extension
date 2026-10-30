# Board 安全、资源与性能审查（Performance Profiler）

- 范围：`posoco-ext-board`、`posoco-ext-board-web`、`posoco-ext-board-native`
- 方法：[Performance Profiler](https://github.com/borghei/Claude-Skills/blob/main/engineering/performance-profiler/SKILL.md) 的 **Profile → Confirm → Fix → Re-measure**。
- 约束：不新增、删除或修改测试；不改变 Board 公共协议、构建产物名称和业务行为。
- 审查分支：`refactor/board-clean-architecture-20261030`。
- 本报告将**已测量数据**、**静态代码证据**与**未验证风险**明确分开。没有 CPU Flamegraph 或 Heap Snapshot，绝不声称完成动态性能/内存验证。

## 1. 可复现的构建基线（GitHub Actions）

现有 CI 运行：[workflow 40995362340](https://github.com/colmugx/posoco-extension/actions/runs/40995362340)。

| 信号 | CI 结果 |
| --- | --- |
| `moon check --target native --output-json` | 通过 |
| `moon check --target js --output-json` | 通过 |
| `moon test --target native` | 3691 passed / 0 failed |
| `moon test --target js` | **失败**：`posoco-ext-mbtx/src/cancellation_test.mbt` 的 `TaskGroup::add_defer` panic，需独立排查是否为既有失败或时间相关回归 |
| Vite `index.js` | 597.92 kB raw / **135.59 kB gzip** |
| Vite `board.css` | 39.53 kB raw / **8.58 kB gzip** |
| Vite `index.html` | 0.68 kB raw / 0.36 kB gzip |
| P50/P95/P99、CPU 火焰图、Heap Snapshot、RSS | **未采集** |

Vite 的 500 kB chunk warning 是**未压缩**阈值，并非实际加载失败；该体积应作为继续收集浏览器性能数据的基线，而不是直接认定为性能故障。用户没有提供项目 SLA；参考指南中的阈值不能自动当成本项目验收标准。

## 2. 安全审查（源码事实，不等于渗透测试）

| 项目 | 已存在的保护 / 发现 | 后续关注 |
| --- | --- | --- |
| 监听边界 | `server.mbt` 仅绑定 `127.0.0.1` 的临时端口 | 检查反向代理或宿主应用是否会意外转发服务 |
| 令牌 | `request_security.mbt` 用 OS 熵生成 32 字节随机令牌；OS 熵不可用时拒绝启动 | 令牌放在浏览器 URL 查询字符串，仍可能进入浏览器历史、进程参数或诊断记录 |
| 请求来源 | 必须匹配 Host；WebSocket 的 Origin 存在时必须匹配本机服务 Origin | 未发送 Origin 的本地非浏览器客户端仍被允许，这是现有策略 |
| HTTP 响应 | 提供 `Cache-Control: no-store`、`X-Content-Type-Options: nosniff`；`index.html` 声明 `referrer=no-referrer` | 未发现统一 CSP 响应头；引入前须确认构建输出兼容性 |
| WebSocket 输入 | `board_read_text` 将单个客户端文本消息限制在 **8192 字节**；Hello 超时 **5 秒** | 仍需评估同一令牌持有者能否大量建立连接/持续发送短命令；暂未实现速率或连接数上限 |
| HTML 注入 | 界面走 Rabbita HTML 节点组件 | 本次未完成对所有动态文本出口与外部库行为的 XSS 渗透验证 |

不要以「loopback」推断绝对安全：本地恶意进程、已泄露令牌及浏览器扩展仍属于应考虑的威胁模型。

## 3. 资源与内存生命周期

| 组件 | 源码事实 | 判断 |
| --- | --- | --- |
| `BoardEventHub` | history 容量默认为 **4096**，客户端 mailbox 深度 **256**，溢出触发 resync | **有界**，但总占用与客户端数量及事件 payload 大小成比例；未见全局并发连接上限 |
| `BoardEventHub::unsubscribe` | 标记 closed，清空并关闭 mailbox/overflow 队列，移除订阅对象 | 正常断开路径有显式释放，不构成已证实泄漏 |
| `NativeBoardWebServer::serve_ws` | `defer backend.unsubscribe(client)`、`defer ws.close()` | 具有清理路径；仍需在异常、取消及大量重连下测量存活对象与句柄数 |
| `NativeBoardWebServer::bind` | `make_app` 失败时关闭 listener，`close` 清空 endpoint/token | 具备失败回收；需以实际 FD/RSS 监测验证 |
| 浏览器 `ui.mbt` | document-level 事件监听仅安装一次，使用 window 标识去重 | 普通页面生命周期内数量有界；反复挂载/HMR 的解绑行为尚未测量 |
| Ticket 进度 seen-set | 每次权威列表更新后，仅保留当前存在的 progress keys | 已有过期条目淘汰逻辑 |
| 事件保留策略 | `BoardEventHub::publish` 在满容量时 `Array.remove(0)` | **静态热点候选**：每次淘汰会移动数组剩余元素，可能造成持续事件写入时的 CPU/GC 压力。需要 profile 验证后再决定是否换成环形缓冲 |

这些检查不能替代真实的持续负载下 RSS、堆快照和 FD 监控；**目前没有证据证明零内存泄漏，也没有证据确认存在持续泄漏**。

## 4. 本轮低风险资源优化

`posoco-ext-board-web/src/ticket.mbt` 的 `ticket_run_for` 原先每次渲染卡片都用 `filter` 构造新的 run 数组，然后寻找第一个 running run / 最后一个匹配 run。改为单次遍历、一个可选引用；保持「首个 running 优先，否则最后一个匹配」的结果规则，省去中间数组的分配。

| 指标 | Before | After | 证据 |
| --- | --- | --- | --- |
| 中间 filter 数组 | 每调用分配 1 个 | 0 个 | 源码级对照 |
| 遍历复杂度 | O(N) + filter allocation | O(N) / 找到 running 可提前返回 | 源码级对照 |
| 真实 CPU 时间 | 未测 | 未测 | 需要浏览器 Performance profile |
| Heap allocations / RSS delta | 未测 | 未测 | 需要两次相同负载的 Heap Snapshot |

不要将「减少了 1 次临时数组分配」等同于「速度提高了 XX%」。

## 5. 建议的后续 Profiling 操作（不新增测试）

1. **浏览器**：在相同、真实规模的看板数据上，使用 Chrome DevTools > Performance 录制初次加载、滚动卡片、打开 Inbox、断线重连。保留 Main Thread 火焰图、长任务、JS heap 与 FPS。用 DevTools Memory 采集重连前后 Heap Snapshots，对比 retained objects。
2. **Native**：在非生产环境运行原生 Board。用 `perf record -g -p <PID>`（Linux）抓取 CPU 热点；用 `heaptrack <command>`（可用时）或等价工具分析原生分配；周期性记录 `/proc/<PID>/status` 的 `VmRSS`、`/proc/<PID>/fd` 句柄数及 WebSocket 连接数。
3. **负载**：复用现有部署及真实样本，不向仓库添加 k6 测试。观察空闲、重复重连、持续事件、慢消费者和关闭后的资源回收；记录吞吐、P50/P95/P99、错误率与队列溢出次数。
4. **比较**：使用同样的构建类型、样本数据、机器与客户端数量，记录变更前后值和 delta。若事件历史确认为高 CPU 热点，再单独评估 ring buffer，确保 replay 顺序与断线游标语义不变。
5. **安全补充**：采用受控 localhost 环境检查 token 泄漏、非授权 Host/Origin、连接洪泛与异常关闭；不要在生产环境执行突发负载实验。

## 6. 合并前条件

- 全部现有项目静态检查和构建通过。
- JS 测试的 `posoco-ext-mbtx` 失败被定位且判定是否与此 PR 有关。
- 如果要宣称性能改善，必须补齐同环境的 before/after 数据。
- 如果要宣称内存稳定，必须补齐重复重连/持续流量的 Heap/RSS/FD 对比。

**结论：** 当前能证明多项资源容量限制和回收路径存在，但不能证明无安全、资源或内存问题；本轮只处理有明确语义的临时分配，其他风险保留具体证据与验证步骤。
