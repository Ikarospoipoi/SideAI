# 实现说明

## v0.5 工作区与适配边界

`WorkspaceMode` 将 Chat 与 Agent 分开；`ConnectionRoute.selectionGroup` 用模式和供应商（Agent 使用执行器 ID）隔离启用状态。旧 `activeRoutes` 迁移至路由版本 2，保留原会话、草稿、后端 ID 与原先选中的 API。Codex 与 Claude Code 不再排斥同家聊天 API。

`HandoffLink` 关联源会话与独立任务；`HandoffBuilder` 只复制用户选择的完整文字、附件和手动记忆。创建草稿不启动执行器、不发送模型请求；带回结果追加到原草稿。后端工具状态和权限不跨执行器迁移。

`AgentDescriptor.catalog` 注册可用执行器及未实现入口。本版仍使用分别实现的 Codex App Server 和 Claude CLI 传输；OpenCode / OpenClaw 的适配器尚不存在，不宣称任意 CLI 即插即用。SideAI 持有跨模式会话索引，后端继续持有各自原生执行状态。

`ChatGPTLoginAttempt` 实现官方动态客户端授权、PKCE、state、nonce；`ChatGPTIdentity` 校验 RS256/JWKS、issuer/audience/expiry/subject。`OAuthLoopback` 只监听 127.0.0.1 随机端口，拒绝不匹配回调，最多等待 5 分钟。认证 HTTP 不跟随重定向；凭据按连接 UUID 保存至 Keychain，续期按连接合并。不会复用 Codex 凭据。真实 OAuth 授权 / 推理仍待首次用户登录验证。

Claude 新任务采用受限文件工具、manual 权限模式和 stdio 控制协议；服务端 `can_use_tool` 转为可拒绝 / 单次批准的 UI 请求。只读任务不注册写入工具；旧任务沿用空工具集。工具清单与 init 返回进行校验，未知控制请求明确拒绝。真实 Write 拒绝 / 批准已通过本机 CLI 验证。

以下按各版本记录实现细节；v0.3 的服务商互斥与空工具集描述只适用于旧版本 / 旧 Claude 会话。

## 目录

```text
Package.swift                    Swift Package 工程 / macOS 14+
Sources/SideAICore/
  JSON.swift                     JSON 值、按字节解析 NDJSON、协议错误
  Models.swift                   面板/会话/任务、事件归并、审批队列
  Persistence.swift              版本化本地快照、原子写入、恢复保护
Sources/SideAI/
  App.swift                      菜单栏、原生编辑菜单、设置、退出语义
  EdgePanelController.swift      三个 NSPanel、热键、悬停、焦点与显示器
  CodexClient.swift              子进程、stdio、请求关联、超时、系统代理
  SessionStore.swift             UI 状态、thread 恢复、发送、中断、审批响应
  ConversationView.swift         时间线、输入、Markdown、预览、把手
  SupportingViews.swift          审批、会话切换、设置、原生 NSTextView 输入
Tests/SideAICoreTests/            分片、路由、幂等、审批失效、持久化测试
scripts/                         build/run、协议与崩溃验证、图标生成
Resources/                       Info.plist 与原生矢量绘制图标
build/SideAI.app                  本地可运行产物
```

## 窗口

独立的把手、预览与完整聊天面板；收起时对聊天面板 `orderOut`，不销毁 SwiftUI 树，不终止后端。把手/预览 `canBecomeKey=false`，只有完整面板允许键盘焦点。Carbon `RegisterEventHotKey` 不使用键盘全局监听。鼠标悬停使用 tracking area 和可取消延迟任务，没有高频指针轮询。

展开记录此前的前台应用；仅当用户主动收起且侧栏持有焦点时尝试恢复原应用。外部点击收起不重新激活旧应用。面板使用主屏/选定屏的 `visibleFrame`，监听显示器参数变更；固定屏断开后回退主屏。全屏辅助窗口与跨 Spaces behavior 已配置，实体多屏及全屏兼容性仍需人工验证。

## 后端

针对 `codex-cli 0.163.0-alpha.10.2`，用 `codex app-server generate-json-schema --out docs/protocol` 生成本机 schema。该生成目录不纳入源代码版本控制，可随 CLI 重建。

- `Process` 直接启动可执行文件，不拼 shell 命令，不开放 TCP 端口。
- 顺序：`initialize` → `initialized` → `account/read` → `thread/start` 或 `thread/resume` → `turn/start`。
- stdout 在后台队列按 UTF-8 字节分帧，处理多帧/半帧；解析完成后切回主 actor。
- JSON-RPC ID 保留数值/字符串类型；客户端请求的 continuation 和服务端审批分开关联。
- 写入在串行后台队列中执行。stderr 仅 drain，不保存可能包含私密数据的内容。
- RPC 60 秒超时；发生不确定的 start 结果时关闭连接并要求恢复核实，禁止自动重放。
- 恢复读取官方历史，分页 `thread/turns/list(itemsView=full)`。不能只因历史 turn 的 `inProgress` 就认为崩溃后任务仍在执行，要结合 thread 当前 runtime status。
- `turn/interrupt` 在收到 `turn/started` 后可操作。真实协议测试发现接受 turn/start 与实际可中断之间有短暂竞争，因此不单凭 start response 启用停止。

## 状态与正确性

`PanelState`、`SessionStatus`、连接状态彼此独立。后端 thread ID 精确路由到本地 UUID 会话，切换 UI 不更改事件归属。目前一条运行任务时仍可查看其他历史，禁止并发发起多个新 turn。

`item/agentMessage/delta` 与命令输出以 50 ms 为一批合入状态；非增量事件到来前先 flush，避免最终 item 被滞后 delta 追加。最终 item 按 ID 替换，不重复追加；完成后忽略迟到 delta。NDJSON 连接没有重放机制，协议未提供逐 delta 序号，因此不采用按文本猜测去重（相同文本可能是合法重复）。

审批身份是连接 generation + 原始 request ID。重复请求不重复入队，已确认请求记录 tombstone，断连时整批失效。点击按钮只标记“已提交，等待后端确认”；`serverRequest/resolved` / item 完成 / turn 完成后才移除。未支持的服务端请求以 JSON-RPC error 明确拒绝。

本地保存 thread ID 后才发起可能修改文件的 turn。持久化不包含可点击审批，重启时把缓存中的运行状态转为待核实的停止状态；连接恢复后再用真实历史校准。

## 测试边界

`swift test` 覆盖核心归并与存储。`protocol_smoke.py --live` 验证真实服务端流式、多轮、重启、停止和单次批准/拒绝；`lifecycle_smoke.py` 验证等待审批时杀死本测试子进程，再恢复，确认没有重放写入。原生 UI 通过 computer-use 实际发送中文消息、追问和操作真实审批。

屏幕行为不能由单元测试替代；未实测的系统场景在 VALIDATION.md 中单列。


## 0.2 连接、图片与历史

- `SideAICore/Connections.swift`：后端类型、连接配置、图片元数据、模型信息、Codex turn 参数与两类 API 请求、逐字节 SSE 解码。
- `SideAICore/ChatGPTImport.swift`：官方导出 JSON 的当前分支导入，只保留可见 user/assistant 内容；归档不自动发送。
- `ConnectionStore.swift` / `ConnectionViews.swift`：模型选择、独立 API 连接、登录方式、分页同步、设置与历史界面。
- `HTTPChatClient.swift`：URLSession 异步字节流、HTTP 状态检查、取消、错误脱敏、禁止重定向；仅聊天，不执行模型工具调用。
- `Credentials.swift`：macOS Keychain generic password，每个 API profile UUID 对应一条密钥。
- `Attachments.swift`：ImageIO 验证、缩放、PNG 持久化；原生 NSTextView 分别接收文件 URL、PNG/TIFF 和 NSFilePromiseReceiver。
- 新增字段为可选 Codable 属性，兼容旧快照，不迁移或读取其他客户端的私有数据库。
- Codex 历史浏览与执行连接分离：thread/list → thread/read / thread/turns/list 只读；首次发送才 resume。项目选择同时控制 cwd 与下一轮 sandboxPolicy。
- 时间线采用固定尺寸图片和分批显示的 VStack，避免图片历史连续发送时触发 LazyVStack 布局循环；初始显示最后 100 条，用户可载入更早消息。
- `Tests/SideAIIntegrationTests` 使用本机随机端口 Python HTTP fixture，验证真实 URLSession 的 Responses、Chat Completions、分片 Unicode、取消、重定向拦截和错误脱敏；测试不使用真实密钥。

## v0.3 多服务商连接

`ConnectionRoute` 是 UI 空间及发送路由的唯一标识，API 路由绑定不可变 profile UUID，模型选择不改变路由。`activeRoutes` 以服务商为组，每组至多一个发送通道；自定义服务按规范化 endpoint 分组。官方域名优先推断服务商，避免误选分类绕过互斥。`lastConversationByRoute` 记录上次选择，优先于同步历史的 updatedAt。

API profile 使用三个适配器：Responses、Chat Completions、Anthropic Messages；新增服务商预设只需映射 provider、URL、协议，模型通过 `/models` 或手填。模型能力/额度仍由服务器验证。保存前拒绝规范化相同地址；有会话的配置禁止换地址、协议、服务商，防止旧上下文意外发送到另一个目标。

`ClaudeCodeClient` 执行已安装的官方 CLI，每轮独立进程，结构化 stdin 含本轮文本和 base64 图片，stdout 为 NDJSON。首次指定 UUID，后续 `--resume`；认证由 CLI 管理，不解析凭据文件。safe-mode、空工具集、空 MCP 与 dontAsk 限定为无工具聊天。客户端检查 init 工具列表，流增量及最终文本去重，保留实际模型；终止时 SIGTERM，2 秒后仅对仍运行的该进程 SIGKILL。5 分钟请求超时，无重发/跨连接 fallback。

Codex、Claude Code、API 会话的 draft/model/history 分别保存。连接切换只选取目标会话；v0.3 的跨连接上下文复制入口是用户主动选择导入档案的 API 续聊副本，并在界面提示发送目标。API Key 存在钥匙串，官方 CLI 的认证方式与订阅/API 计费规则单独说明。
