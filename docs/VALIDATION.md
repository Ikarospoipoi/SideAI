# v0.8 验证（2026-11-06）

- 55 项自动测试，53 通过、2 项显式启用的云端测试跳过，0 失败。覆盖首次启动零连接、解绑备份、账号路由与草稿隔离、OAuth 回调验证、ACP 分片与取消、工具权限拒绝。
- Release 0.8.0 / build 8。官方运行时：Kimi Code 2.5.1、Grok 1.0.77、Google Antigravity 1.5.1；均完成真实 ACP 握手。Antigravity 使用官方发布清单及 SHA512 校验下载。
- Kimi：实机点击后显示官方设备码及登录页入口，取消成功。
- Grok：实机官方授权完成，返回账号模型列表。
- Gemini：确认旧 Gemini CLI 个人账号入口被官方停用，改用 Antigravity ACP。实机 Google 授权回调成功、模型列表加载成功、发送后收到真实中文回复，状态完成，无工具请求。
- 新建 API 表单仅显示密钥、可选模型和折叠高级配置；连接管理按实际连接显示。
- 重置前先备份原始会话及非密钥配置；不使用或注销全局 Codex / Claude Code 登录。测试期间创建的连接按用户要求再次清空。
- 未代用户点击浏览器授权确认。GPT / OpenRouter 的完整线上推理、Kimi 线上推理和所有账号资格组合未逐一验证；不把协议测试等同于云端额度验证。

---

# v0.7 验证（2026-11-06）

- `swift test`：51 项，49 通过，2 项真实云端测试默认跳过，0 失败。新增 Claude 聊天 / Agent 路由与草稿隔离、错误权限标记时仍无工具、删除恢复和持久化，以及窗口四边越界 / 多屏 / 不可见恢复测试。
- Release 0.7.0 / build 7 构建成功；签名与 Info.plist 检查通过。
- 原生 UI：点击「连接已登录的 Claude 账号」，检测本机官方登录成功，进入聊天模式。发送「SideAI账号连接测试，请只回复OK。」，实际返回「OK」；底部显示工具关闭，模型 Claude Sonnet。
- 原生 UI：500 点宽窗口从顶部拖动到 x=-242、y=88，左侧约一半移出屏幕。收起、重新展开、固定后坐标保持，截图确认没有弹回。再通过「窗口回到屏幕左侧」复位成功。
- 升级前备份 state.pre0.7.backup.json；旧 23 个会话无缺失，draft / backend / profileID / claudeSessionID / modelID / attachments / items 无变化；API 配置完全一致。仅新增 1 个隔离的 Claude 账号聊天测试会话。
- GPT 独立授权沿用原实现；本轮未重新登录或测其线上推理。Kimi Code 设备授权未实现，DeepSeek / Kimi / Qwen 当前使用 API；没有将官网快捷入口冒充应用内账号授权。
- 多屏实物拔插、Spaces 和所有缩放尚未实测；对应坐标算法由自动测试覆盖。

截图：[半越界且重新展开后的窗口](screenshots/window-half-offscreen-v0.7.png)、[Claude 账号实际回复](screenshots/claude-account-chat-v0.7.png)。

以下为历史版本记录。

---

# v0.6 验证（2026-11-05）

- 49 项自动测试：47 通过，2 项真实 Claude 调用默认跳过，0 失败。取消后的客户端再次发送、30 次请求启动 / 取消竞态、仅取消 HTTP 客户端、三种协议的正常流 / 断流 / 错误 / 重定向全部覆盖。
- 删除 / 恢复测试：原连接 ID 和历史草稿保留；执行中阻止删除；凭据删除失败时保持配置；移除 Agent 重启后不复活；缺失凭据保留发送草稿；官网地址与 API 地址分离。
- 原崩溃报告：SideAI-2026-11-05-180912.ips，SIGABRT，NSURLSession.bytes(for:) → taskForClassInfo。修复网络会话过早失效路径，每次请求独立持有会话直至调用返回，取消不再提前 invalidate。
- 原生 UI + 真实 DeepSeek API：独立测试会话发送“SideAI 连接回归测试，请只回复 OK。”，模型 deepseek-flash，正常收到 HTTP 402 Insufficient Balance。无密码提示、无闪退；该账号余额不足，未宣称模型生成成功。
- 原生 UI：统一连接管理可见现有 3 个聊天连接、2 个 Agent 和 5 个官方入口。点击 DeepSeek 删除按钮正确显示凭据删除 / 历史保留说明；取消后实际用户连接保持原样。未对真实用户凭据执行删除。
- 升级前 state.pre0.6.backup.json；退出验收后对比旧 22 个会话全部存在，旧 draft / items / modelID / profileID / attachments 无变化，API 配置完全一致；仅新增 1 个隔离测试会话。
- 系统浏览器官网入口采用固定官方 HTTPS URL；网页授权 / 登录不由 SideAI 代理，未自动点击各站点授权页面。
- 仍待用户操作验证：系统钥匙串主动授权时的密码输入 / 取消；开发过程没有读取或代填系统密码。新增默认静默读取和非交互刷新，凭据拒绝提示返回应用并保留草稿。

以下为历史版本记录。

---

# v0.5 验证（2026-11-05）

- Release 构建成功，版本 0.5.0 / build 5；`codesign --verify --deep --strict` 与 `plutil -lint` 通过。新版已在本机启动。
- `swift test`：43 项，41 通过，2 项真实调用默认跳过，0 失败。新增工作区迁移、同家 Chat / Agent 共存、原 API 选择保留、交接草稿 / 结果回传、OAuth PKCE / state / nonce / RS256 / audience / expiry / subject 和本地回调服务测试。
- 另行启用 `SIDEAI_CLAUDE_AGENT_LIVE=1 swift test --filter ClaudeTransportTests/testLiveClaudeAgentFilePermissions`：真实 Claude Code 2.1.318，拒绝与批准两轮均各收到 1 次 Write 确认；拒绝后原文件不变，批准后为预期内容，最终回合正常结束。夹具为专用临时目录，不触碰用户项目。
- 原生 UI：聊天 / Agent 入口切换、仅名称着色、卡片黑灰背景；聊天入口内容不再溢出裁切。设置的聊天 / Agent 分区、官方 GPT 登录入口、记忆笔记说明均可见。
- 原生 UI：从已有 API 聊天创建“SideAI v0.5 界面验收草稿”，状态就绪、消息列表为空、无后端 thread ID；点击原会话回到聊天，原消息和草稿未变。此本地验收草稿保留，未向模型发送。
- 原生 UI：原 Claude Code 会话在 Agent 模式仍可找到，历史保留，清晰提示旧会话无工具权限。交接弹窗可编辑任务并取消，无发送。
- 升级前正常退出并备份 `state.pre0.5.backup.json`。首次迁移后对比：旧会话 19 个，新增验收草稿 1 个，旧 ID 无缺失；旧 draft / backend / profileID / claudeSessionID / modelID / attachments / items 均无变化，API profile ID 全部保留。

未宣称完成的验证：独立 GPT OAuth 的真实浏览器账号授权、真实 plan-backed 模型推理与线上刷新轮换；Claude 原生确认卡片的人工点击（本次真实审批在传输集成测试中完成）；各 API 供应商的所有模型 / 区域。OpenCode / OpenClaw 明确尚未接入。

截图：[聊天入口](screenshots/launcher-chat-v0.5.png)、[Agent 入口](screenshots/launcher-agent-v0.5.png)、[聊天设置](screenshots/settings-chat-v0.5.png)、[交接预览](screenshots/handoff-v0.5.png)。

以下为历史版本验证，能力边界以当前 README 和 v0.5 指南为准。

---

# 0.2 增量验证（2026-11-04）

- `swift test`：22 项通过，含旧快照/草稿兼容、模型与推理强度、项目 cwd/写入根、两种 API 上下文/图片结构、SSE 字节分片、ChatGPT 当前分支导入、Codex 断开不打断 API。
- 本地 HTTP 集成：Responses 和 Chat Completions 的模型读取、Unicode 流、取消、截断、HTTP 401 脱敏、307 禁止跳转全部通过。没有真实 API Key，因此不宣称已验证第三方云服务账户。
- 原生 NSTextView + 独立 NSPasteboard：文件 URL 和 PNG 数据进入附件回调，原文字保持不变；普通文本仍交给编辑器。ImageIO 缩放与缓存、无效文件拒绝通过。
- 真实 UI：已有 thread 在只读模式可打开项目选择器，成功更改为 SideAI 项目；切换项目 Agent 后仍可选择目录。
- 真实 UI：选择 GPT-6-Astra，附加专用测试 PNG 并发送，模型正确回复“红色正方形和蓝色圆形”。输入时不存在旧占位文字。
- 真实 UI：同一会话切换 GPT-6.1 Terra，后端完成“切换后可继续”；发现含图片 LazyVStack 布局循环并修复后，再次连续发送返回“通过”，界面正常响应。
- 真实 UI：连接与模型设置显示 ChatGPT Codex 账户；会话设置显示同步 16 个可见 Codex 线程；GPT/Codex 分类可操作。
- 资源快照：布局修复后空闲 CPU 0.1%，RSS 约 146 MiB；单次采样，不代表长期性能基准。
- 升级前备份 state.json；原会话、模型选择、目录、图片和历史在重启后恢复。

截图：[图片识别](screenshots/vision-v0.2.png)、[连接设置](screenshots/settings-v0.2.png)。

仍待真实场景覆盖：跨应用拖拽/截图悬浮缩略图的 file promise 路径、真实 API 密钥/钥匙串授权、设备码与更换官方登录、用户实际 ChatGPT 导出文件。相关代码已实现，不能把自动化夹具视为这些场景均已实测。普通 ChatGPT 云端历史不支持自动双向同步，当前提供导出 JSON 导入。

以下为 0.1 的原始验证记录；与上方冲突的旧能力描述以上方和 README 为准。

---

# 验证记录

日期：2026-11-04（Asia/Shanghai）。环境：macOS 26.3.1，Apple Silicon，Swift 6.3，Codex CLI 0.163.0-alpha.10.2。本次真实调用沿用 CLI 默认模型 `gpt-6-astra`。

## 已通过

| 层级 | 验证与证据 |
| --- | --- |
| 构建 | `swift build`、release 构建成功；输出 `build/SideAI.app`，约 2.1 MB |
| 本地签名 | `codesign --verify --deep --strict build/SideAI.app` 成功；`plutil -lint` 成功 |
| 自动测试 | `swift test`：10 项 XCTest，0 失败。覆盖 UTF-8 每个分片边界、多帧、损坏消息、ID 类型、会话隔离、最终事件重复、迟到 delta、审批队列/重复/失效、旧 turn 完成、持久化、面板固定与权限策略 |
| 官方连接 | initialize / initialized / account/read 成功，账户已登录；未读取或打印认证文件 token |
| 真实聊天 | 收到 agentMessage delta 与 completed；同一会话第二轮准确记住测试词“青松” |
| 进程重启恢复 | 关闭测试 app-server，重新启动，thread/resume + thread/turns/list 后继续多轮对话，历史与上下文保留 |
| 中断 | 在 turn/started 后调用 turn/interrupt，收到 turn/completed(status=interrupted) |
| 真审批批准 | 实际收到 item/commandExecution/requestApproval，用原始 request ID 回复 accept；指定临时文件随后存在 |
| 真审批拒绝 | 回复 decline；指定临时文件没有创建，turn 正常结束 |
| 崩溃 | 在真实审批未回答时 SIGKILL 本测试后端；重连恢复显示 idle，未执行未批准的写入；新消息仍可完成 |
| 原生 UI | 通过已打包 .app 输入中文文本、Command+Return 发送，收到“侧栏已连接”，连续追问收到“青松” |
| 原生审批 | 侧栏实际显示命令、原因、目录、等待时间；点击批准/拒绝；分别核实 `ui-accepted.txt` 存在、`ui-declined.txt` 不存在 |
| 收起后台 | 审批测试发送后立即 Esc 收起；之后把手显示“1 项等待确认”，展开可处理；收起未终止 turn |
| 草稿 | 中文草稿在 Esc 收起、点击把手展开后仍完整存在 |
| 窗口与恢复 | 原生应用多次正常退出、重新打开并显示官方后端恢复后的会话；固定按钮与非固定按钮状态可切换 |
| 代理 | 初始 GUI 联调遇到 Reconnecting，补充读取系统 HTTP/HTTPS 代理后，界面连续多轮真实请求通过；没有改系统设置 |

机器可读原始结果：

- [真实协议结果](live-validation.json)
- [崩溃恢复结果](lifecycle-validation.json)
- [资源采样](performance-samples.json)

所有写入测试仅在 `tempfile.mkdtemp(prefix='sideai-…')` 创建的专用目录中进行；没有使用用户真实项目验证改写。测试文件保留供核验。

## 实际截图

以下均来自本机运行中的应用，没有模拟回复或拼装界面。

- [真实聊天](screenshots/chat-real.png)
- [真实审批](screenshots/approval-real.png)
- [收起把手](screenshots/collapsed-real.png)（截图只含窄窗口，因此图像本身也很窄）

预览窗口已实现，但本次未取得稳定的单独预览截图；不以聊天或审批截图冒充预览。亮色模式尚未截图。

## 尚需人工覆盖

以下实现存在，但不能因构建或单元测试通过就宣称原生系统行为已经通过：

- 其他应用前台时的全局 Control+Option+Space；自动化按键未成功证实系统全局事件路径。菜单栏与把手入口可用。
- 快捷键冲突的真实注册失败；设置中修饰键/字母可选与错误提示逻辑已实现。
- 悬停 300 ms、防误触与预览不抢走其他应用输入焦点的真人手感。
- 中文输入法候选状态下的 Esc（中文粘贴/发送已通过，不等价于输入法 composition 测试）。
- 多显示器拔插、非主屏坐标、Retina 不同缩放、Spaces、全屏、Stage Manager、睡眠唤醒。
- 浅色、减少透明度、增加对比度、超长代码/消息的极限尺寸。
- 文件变更审批、permissions 请求、交互问题表单的完整端到端测试；真实命令审批已通过。
- 真实账户退出/过期、服务限流；后端断开路径和错误状态已实现，崩溃协议已实测。
- 异常退出后外部命令的子进程清理。应用会终止自己启动的 app-server，不宣称能撤销已经发生的副作用。
- 最近一次窗口事件修复避免把原生菜单/弹出窗口当成外部点击；release 编译通过，仍需在下次启动新构建后回归菜单交互。

## 资源采样

在无运行任务时采样 6 次，每次间隔 2 秒，使用 `ps %cpu` 与 RSS，而非 Instruments：

- SideAI：CPU 六个样本均为 0.0%，末次 RSS 106.0 MiB。
- 该应用的 Codex 子进程：CPU 样本为 0.5%、2.2%、0.1%、0.5%、2.7%、3.6%，末次 RSS 171.0 MiB。

采样靠近启动/历史恢复阶段，不能视为长期稳态性能基准；其他进程负载、CLI 插件和会话数量会影响结果。界面没有截图识别、忙循环或全屏鼠标轮询。

## v0.3 多连接与 Claude 验证

本轮开发于 2026-11-04 开始，2026-11-05 继续验收。

- `swift test`：32 个测试，31 个通过、1 个需显式启用的云端测试默认跳过，无失败。覆盖同服务商互斥、重复地址、旧配置兼容、会话路由/草稿/模型隔离、同步历史不抢占上次选择、活跃任务阻止切换、三种 HTTP 流协议及错误脱敏/重定向/断流、Claude 进程取消/非法输出。
- `SIDEAI_CLAUDE_LIVE=1 swift test --filter ClaudeTransportTests`：3 个测试全部通过。实际调用本机 Claude Code 2.1.318；第一轮保存测试词，第二轮恢复同一会话并识别红色图片，实际模型 claude-sonnet-5-5。只发送合成测试内容。
- Claude 图片测试的首次失败来自测试夹具使用动态 NSColor 未写出红色像素，改用确定的 RGBA 像素后通过；没有通过降低断言掩盖问题。
- 原生 SideAI 界面已实测 Claude 发送/回复、low 强度选取、连接切换、草稿保留和续聊记忆。不同连接没有共享输入框内容。
- 新版有 OpenAI、Claude、DeepSeek、Kimi、Qwen 与自定义 API 预设。没有真实 API Key，故不宣称这些直接 API 已通过云端账户验证。本地 HTTP 夹具验证与云端模型生成明确区分。
- Word 指南共 4 页，已使用随运行时捆绑的 LibreOffice 渲染，并检查每页。渲染时配置可见的 macOS 中文字体，修复中文缺字；去除模板标题边框并检查分页。
- 升级前状态备份：Application Support/SideAI/state.pre0.3.backup.json。没有注销或替换官方 Codex / Claude 登录。
- 最终原生回归：预览卡片展开连接菜单，选择 OpenAI 后进入 OpenAI 聊天空间；设置页检测 Claude 登录、展示各服务商预设，选择 DeepSeek 后自动填写 URL 与协议。预览窗口点击可获得菜单焦点，单纯显示仍使用不激活窗口方式。
- 最终 `swift test` 仍为 32 项，默认 1 项显式云端测试跳过，其余通过；release 构建与 `codesign --verify --strict` 通过。


## v0.4 UI 与交互验证（2026-11-05）

- `swift test`：35 项，34 通过，1 项需要显式开启的真实 Claude 调用跳过，零失败。本轮没有发送模型请求。
- 新增交互回归：Enter / 数字键盘 Enter 发送、Shift + Enter 插入换行、Command + Enter 兼容、中文 marked text 确认不发送；位置保存、旧设置兼容、调整宽度保持原点、断开显示器后回到可见范围。
- Release 构建与签名完成，原生应用已升级至 0.4.0。升级前保存 `state.pre0.4.backup.json`，现有会话、草稿、账户与 API 配置保留。
- 原生 UI：入口六张卡片只显示 AI 名称和状态；Claude 卡片打开橙色聊天，DeepSeek 打开蓝色聊天；Kimi 未配置入口打开设置并滚到 Kimi API 预设，未保存测试配置。
- 实际顶部拖动已产生位移并写入设置；已检查收起、重开与连接切换。采用鼠标拖动事件移动窗口，避免无边框面板的系统 performDrag 在本机未产生移动的问题。
- 界面记录：`screenshots/launcher-v0.4.png`、`screenshots/claude-theme-v0.4.png`、`screenshots/deepseek-theme-v0.4.png`。本轮实机外观为深色；浅色配色已有实现，但未切换系统外观验证。
