# SideAI

**iPhone 遥控（v0.11.0）：** 新增原生 iOS 客户端和 macOS 手机遥控入口，支持异地查看任务、发指令、切模型及审批。附带自托管加密中继，先用 Xcode 安装到自己的 iPhone。见 [安装与部署指南](docs/IOS_REMOTE.md)。

**Windows 版本：** 新增 `windows/` 客户端，支持游戏内热键唤出、鼠标释放、返回原窗口，以及聊天 / Agent 连接。安装、功能对照与游戏兼容边界见 [Windows 使用指南](windows/README.md)。Windows 安装包由 [GitHub Actions](https://github.com/Ikarospoipoi/SideAI/actions/workflows/windows.yml) 构建。

**跨会话记忆（v0.10.1）：** 聊天和 Agent 发送后自动参考本地旧对话及导入历史，来源随每轮回复折叠显示，输入框旁可开关记忆。详见 [记忆使用说明](docs/CROSS_CONVERSATION_MEMORY.md)。

以下为 macOS 原生版本说明。

一个留在 Mac 屏幕左侧的原生 AI 抽屉。SwiftUI + AppKit 界面，支持 Codex App Server / 本机 Claude Code Agent，以及 Responses / Chat Completions / Anthropic Messages API。正常使用没有模拟回复。

## 连接你的 AI

点击首页「添加 AI」，选择官方账号登录或 API。首页只显示实际添加的连接；聊天与 Agent 分开管理，背景保持黑灰，仅 AI 名称使用品牌色。

支持 GPT、Kimi、Gemini、Grok、OpenRouter 的官方账号入口，以及 Claude、DeepSeek、Qwen 和自定义 API。Agent 模式支持 Codex 和 Claude Code 官方登录。不同入口的账号资格与额度不同，详见 [连接指南](docs/SideAI_v0.8_连接指南.md)。

「设置 → 连接管理」支持编辑、重新登录、删除连接和从头开始。重置会把旧会话另存备份，并清除 SideAI 凭据；新版官方客户端使用独立账号目录，不借用其他软件的登录。

## 启动

本次构建的应用：**`build/SideAI.app`**。在 Finder 中双击即可，或执行：

```bash
./scripts/run.sh
```

首次打开先添加连接。聊天账号与 Agent 登录分别配置，额度取决于当前会话使用的连接。

应用是菜单栏程序，不常驻 Dock。收起后在主屏幕左侧中间保留细把手。点击把手或菜单栏图标可以找回。

## 日常使用

- 默认全局快捷键：**Control + Option + Space**，再次按下收起。在“更多 → 设置”中更改修饰键与按键；注册失败会显示提示。
- 鼠标进入把手后轻微露出，停留约 300 ms 显示预览。预览不成为键盘焦点窗口；点击后才进入聊天。
- 完整侧栏可正常编辑多行文字，**Enter** 发送，**Shift + Enter** 换行。支持中文文本；输入法候选的 Esc 优先交给输入系统。
- **Esc** 收起；草稿和当前窗口中的阅读位置保留。右上角图钉固定侧栏，右边缘可拖动调整宽度。
- 左上角打开会话切换器：搜索标题、右键重命名或本地归档。归档不删除 Codex 后端历史。
- 收起不会停止任务。需要中断时点击输入区的停止按钮。当前只允许一条执行中的任务，其间可以切换到其他历史会话。
- 审批显示操作、工作目录、原因、等待时间与完整请求。仅提供单次批准（权限请求为本回合）和拒绝，不提供永久授权。
- 等待确认时把手变为琥珀色，预览显示数量；默认自动显示非激活卡片。可在设置关闭自动预览。更多菜单的“选择 AI…”也可打开卡片。
- 关闭/收起面板不退出应用。真正退出时，若有任务，会明确询问是否终止连接；不能依赖退出后的命令继续执行或自动停止。

## Agent 权限与项目

聊天模式的 API / 独立 ChatGPT 连接不执行本机工具。Agent 模式区分 Codex 与 Claude Code；下表是 Codex 的权限策略。Claude Code 新任务在只读模式提供 Read / Glob / Grep，项目模式增加 Edit / Write，写入需逐次确认；旧 Claude Code 会话仍为无工具模式。

| 模式 | 本地命令沙箱 |
| --- | --- |
| 只读 Agent（默认） | `readOnly`，禁用命令网络访问；读取文件与只读命令仍可能执行，写入/越界需后端审批 |
| 项目 Agent | `workspaceWrite`，写入根限定为用户选取的项目；命令网络关闭，排除临时目录的隐式写入权限，额外权限按后端审批 |

新会话默认工作目录是 `~/Library/Application Support/SideAI/Scratch`，不是整个主目录。执行项目任务时选择项目，再选“项目 Agent”。已有会话也可在空闲时重选项目，下一轮同时更新工作目录与写入沙箱根；只读 / 项目模式均可选目录。默认 `approvalPolicy=on-request`、`approvalsReviewer=user`，不会把审批交给自动代理。

只读是本地文件/命令沙箱，不是禁止所有工具的隔离机制，也不是把读取范围限制在当前目录。CLI 自身的用户配置仍会生效，外部 MCP 工具的副作用不由本地文件沙箱约束。本客户端关闭 Apps 与多 Agent 功能；未支持的服务端交互请求明确拒绝，不暗中批准。

支持图片按钮、拖入图片文件、截图文件承诺和粘贴图片。图片立即复制到本地附件库，以免系统临时截图消失；每条最多 8 张、每张原文件最多 20 MB，转为最长边 2048 像素的 PNG（动图只取首帧）。发送时作为真实 localImage / API 图片输入，不作为文件路径文字。暂不支持其他文件附件或语音。输入框已移除占位文字，避免与中文输入法组词重叠。

## 环境与构建

- 目标系统：macOS 14+，本次在 **macOS 26.3.1 / Apple Silicon / Xcode / Swift 6.3** 构建与运行；最低版本尚未在实体机器验证。
- 已验证 Codex CLI：**0.163.0-alpha.10.2**。App Server 接口有版本差异；升级 CLI 后建议重新跑协议检查。
- 零第三方 Swift 包依赖。Swift Package 可直接用 Xcode 打开 `Package.swift`。

```bash
./scripts/build.sh              # release 构建、打包 .app、adhoc 签名
./scripts/run.sh                # 启动，缺少 .app 时先构建
swift test                     # 确定性测试，不调用 AI
python3 scripts/protocol_smoke.py --live  # 使用真实账户额度的协议检查
python3 scripts/lifecycle_smoke.py       # 使用真实账户额度的崩溃/恢复检查
```

产物位于 `build/SideAI.app`。仅做本机 ad-hoc 签名，未公证、未发布。跨机器分发需要另行签名与公证，不要求付费开发者账号即可在此机开发运行。

## Codex 配置与登录

自动查找 Homebrew、常见 CLI 路径，以及 ChatGPT/Codex 应用捆绑的 CLI。GUI 不依赖交互 shell 的 PATH，可在设置中直接指定可执行文件。

在「添加 AI → Agent」点击「登录 Codex」，通过官方 App Server 在浏览器完成登录。新版使用 SideAI 专属 CODEX_HOME，不导入终端或其他应用的登录。登录密钥由原版官方客户端管理。

子进程会优先沿用环境变量代理，否则读取 macOS 系统 HTTP/HTTPS 代理设置。不会修改系统代理，不支持仅 PAC 或仅 SOCKS 的自动转换。此机配置的本地系统代理已实测用于 GUI 联网。

连接失败、后端退出与请求超时会显示错误。重连只恢复 thread，不自动重发用户请求，以免重复执行文件操作。点击输入区下方模型按钮选择模型和推理强度；模型列表从 `model/list` 分页获取，选择按会话保存，并传入下一轮 `turn/start`。不支持的模型由后端明确报错。

## 连接空间与 API

「设置 → 添加 AI」添加官方账号或 API；「连接管理」修改或删除已有连接。API 默认读取模型列表，不提供列表时可手动填写模型名称。密钥存于 macOS 钥匙串；修改接口地址必须重新输入密钥。

AI 入口卡片和主聊天顶部均可切换连接，右上角可在当前连接新建会话。每条 API 会话绑定自己的连接，API 每轮发送本地文字与图片上下文，Responses 请求使用 `store:false`。这些请求仍受服务商的数据政策约束。API 与 ChatGPT 订阅分别计费；没有配置 API 时，可进入 Agent 模式登录 Codex / Claude Code；独立 GPT 聊天也可尝试官方 ChatGPT 授权。

左上角会话列表提供“当前连接 / 当前模式 / 全部连接”筛选。连接 Codex 或点击同步时分页读取本机 App Server 可见的所有来源与归档线程，按 thread ID 去重；浏览历史只读，发消息时才 resume。不会读取桌面应用私有数据库。

普通 ChatGPT 网页历史当前不能通过该本地接口自动同步。设置的“会话”页可导入官方导出数据中的 `conversations.json`，读取当前分支文字并去重；附件二进制不在 JSON 内。导入为只读档案，可创建默认 API 连接的续聊副本，直到用户发送新消息才提交副本上下文。这不是 ChatGPT 云端双向同步。

## 数据与隐私

- `~/Library/Application Support/SideAI/state.json`：带版本的设置、会话索引、草稿与显示缓存。目录权限 0700，文件权限 0600；原子替换写入。
- 官方 Codex thread 是历史权威来源，恢复时通过受支持的 `thread/read` / `thread/turns/list` 读取。
- Codex / Claude Code 认证由官方 CLI 管理，API 密钥与独立 ChatGPT OAuth 凭据由钥匙串管理。没有新增云数据库或遥测服务。独立 GPT 授权期间临时监听 127.0.0.1 随机端口，完成、取消或超时后关闭。
- 图片缓存位于 `~/Library/Application Support/SideAI/Attachments`。旧版数据格式仍可读取；本次升级前已额外保留状态备份。
- SideAI 不持久化后端 stderr，不将完整聊天写入诊断日志；聊天缓存本身包含会话内容，请按本地敏感文件对待。
- 数据文件损坏或版本不兼容时显示错误，保护原文件，不自动覆盖。

本应用自身不请求辅助功能、屏幕录制权限。全局快捷键使用 Carbon 热键注册，外部点击监测只订阅鼠标点击事件。后端执行所需的额外权限通过真实审批展示。

## 已知边界

- 尚需人工验证：中文输入法候选取消、其他应用前台时的全局热键、快捷键实际冲突、多显示器拔插、Spaces、全屏、Stage Manager、睡眠唤醒。已实现对应窗口/屏幕处理，不把代码存在当作已验收。
- Markdown 支持内联语法、段落和可横向滚动/复制的 fenced code；不含完整表格、数学公式或语法高亮渲染器。
- Codex 与 API 聊天流以 50 ms 批量刷新 UI；任务输出显示缓存最多保留尾部 100,000 字符。后端历史不因此删除。
- 仅保证收起/展开保留当前滚动位置；跨会话切换重新进入时定位到最新内容。
- 文件修改审批、权限子集审批和后端问题表单已接入协议，但本次端到端实测覆盖的是命令审批。未支持的旧版审批或 MCP elicitation 会明确拒绝。
- 退出会终止本客户端启动的 Codex 子进程，但外部命令是否留下子进程取决于后端与命令本身。不要把关闭应用当作撤销已经执行的操作。
- ChatGPT 普通网页会话仅支持导出导入，不自动同步云端聊天、记忆与附件。
- API 云端真实认证需要用户提供密钥；本次已验证三个协议的本地 HTTP 流式、断流、错误行为，以及 HTTP 取消，未用真实 API Key 冒充云端验证。
- 历史初次渲染最新 100 条，可点击载入更早消息；完整本地缓存和后端历史保留。

详细记录见 [验证记录](docs/VALIDATION.md) 与 [实现说明](docs/ARCHITECTURE.md)。

## 官方依据

实现结合本机 CLI 生成的 JSON Schema，并核对 [OpenAI Codex App Server 官方文档](https://learn.chatgpt.com/docs/app-server)。本机 schema 与在线文档不一致的字段，以已实测版本为准。
