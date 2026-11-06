# SideAI for Windows

Windows 10 / 11 的 AI 侧栏客户端。Windows 11 x64 是本次主要目标。保留同仓库的 macOS SwiftUI 版本，Windows 使用 Electron + TypeScript，窗口切换使用 Win32。

## 安装与使用

在仓库的 **Actions → Windows build and tests → 最近一次成功运行 → Artifacts → SideAI-Windows-x64** 下载构建产物。

- `SideAI-0.9.0-Windows-x64.exe`：安装向导，不需要以管理员身份安装。
- 同名 `.zip`：解压后运行 `SideAI.exe`，无需安装。
- 本项目尚未配置 Windows 代码签名证书，构建物不是已签名商业安装包。

首次启动点击「添加 AI」。主页只显示已连接的 AI，聊天与 Agent 分开。API 密钥使用 Electron safeStorage 的 Windows DPAPI 加密，不写入会话 JSON。不会导入 Mac 的登录或复用其他客户端的账号目录。

默认快捷键 **Ctrl + Alt + Space**：呼出 / 收起。可在设置更改，冲突会明确提示。紧急收起 **Ctrl + Alt + Shift + F12**。托盘图标与屏幕边缘把手也可呼出。进入聊天后自动聚焦输入框；Enter 发送、Shift + Enter 换行，中文输入法组词期间不发送。

## 游戏内使用

1. 先在 SideAI 连接 AI / Agent，选好项目、模型，并启动任务。
2. 保持设置中的「游戏模式」开启，切回游戏。
3. 按热键：SideAI 记住原窗口，置前、聚焦聊天框，解除鼠标 ClipCursor 限制，把鼠标移到面板内。
4. 查看进度或点击「批准本次 / 拒绝」。审批不会自动同意，游戏模式不会因新审批而抢焦点。
5. 再按同一个热键：等待热键修饰键松开，再尝试把焦点交回原游戏窗口，隐藏侧栏。任务继续执行。

**不能宣称支持“所有游戏且无缝”。** 本版本没有游戏进程注入、图形 Hook、驱动、键盘钩子或反作弊规避机制。Windows 会限制前台激活；游戏也可能在后台读取 Raw Input、独占显示、拦截热键或以不同权限运行。

| 场景 | 实现策略 / 限制 |
| --- | --- |
| 窗口 / 无边框全屏 | 原生热键 + 置顶窗口 + 解除鼠标限制，是优先兼容路径 |
| 独占全屏 | 尝试切换前台；游戏可能最小化、黑屏切换或重新获取显示设备，无法承诺无闪烁 |
| 游戏以管理员权限运行 | 正常权限 SideAI 的前台请求可能受限；优先让两者按普通权限运行，不自动提权 |
| 反作弊 / 游戏拦截热键 | 无法保证热键送达；更换组合、用托盘或切换无边框模式 |
| 游戏后台仍接收输入 | 不会通过注入强行屏蔽游戏。若出现边聊天边操控，关闭游戏的后台输入选项或暂停游戏 |
| Alt-Tab 切到第三个应用 | SideAI 放弃旧窗口恢复，避免随后抢回游戏焦点 |
| 游戏退出 / HWND 被复用 | 校验窗口与进程 ID，不恢复到失效或复用窗口 |
| 多显示器 / 缩放 | 使用 Electron DIP 与 Windows 物理坐标转换；保留部分越界位置，拔屏后恢复可见区域 |

侧栏隐藏时暂停界面流式推送，显示时补齐状态；图片预览按 ID 缓存，避免流式文字更新重复传输图片。后台任务不会因为隐藏而暂停。

收起时不恢复旧的鼠标限制矩形，也不伪造点击或按键。游戏在重新得到前台后自行恢复输入捕获。

## 连接与功能

- 聊天：GPT 官方授权、OpenRouter 官方授权；Kimi / Grok / Gemini 通过官方客户端登录，在 SideAI 聊天。
- API：Responses、Chat Completions、Anthropic Messages；预设 GPT、Claude、DeepSeek、Kimi、Gemini、Grok、Qwen、OpenRouter、自定义地址。
- Agent：Codex App Server、Claude Code。只读 / 项目模式、项目目录、真实进度、逐次审批、停止、后台继续执行。
- 各连接独立会话、草稿、模型；模型可从后端获取或手填，强度能否使用由模型校验。
- 图片按钮 / 拖放 / 粘贴，最多 8 张，每张源文件 20 MB，统一最长边 2048 的 PNG。
- 会话搜索、重命名、归档、Codex 历史同步；ChatGPT 导出 JSON 导入为只读档案。
- 聊天交给 Agent、续聊副本和带回结果：仅创建草稿，用户发送后才提交上下文。
- 设置统一管理连接、重登、删除、从头体验；删除保留只读历史，重置先备份。

同一 AI 的**聊天连接**只保留一种接入方式，避免官网授权和 API 重复混用。聊天 GPT 与 Agent Codex 属于不同模式，可以同时存在。登录资格、订阅额度与 API 计费仍由各家服务决定。

官方客户端安装在 SideAI 的私有 Runtimes 中。Codex、Claude Code、Kimi、Grok 使用官方 npm 包；Gemini 下载 Google Antigravity 官方 exe 并校验清单 SHA-512。也可指定已安装官方客户端路径。Claude Code 的 Windows 前置要求（例如 Git for Windows）仍需满足；安装或登录失败会显示错误，不模拟成功。

登录和 API 请求使用真实后端。开发阶段的本地 HTTP / CLI fixture 只在测试目录，不用于正常回复。Windows 官方账号授权与付费请求未在真实 Windows 账号上端到端验证。

## 开发

要求 Node.js 24+。从仓库根目录：

```powershell
cd windows
npm ci
npx install-electron
npm test
npm start
npm run pack
```

输出位于 `windows/release/`。`npm run smoke` 使用临时数据目录验证启动、预加载桥和页面；`npm run game-lab` 打开全屏 / 鼠标锁定测试场，便于手动反复切换。测试场不是 FPS / MOBA 或反作弊验证。

原生 Mac 版仍使用仓库根目录的 `./scripts/build.sh` 和 `swift test`。两套客户端目前各自保存数据，不自动同步账号和历史。

## 数据目录

`%APPDATA%\SideAI-Windows\`：

- `state.json`：设置、会话、草稿、图片预览；包含对话内容，不包含 API Key。
- `Credentials\`：当前 Windows 用户的 DPAPI 加密凭据。
- `Accounts\`：SideAI 独立官方客户端登录目录。
- `Attachments\`：发送的图片副本。
- `Backups\`：删除 / 重置前的本地历史备份，不含凭据文件。
- `Runtimes\`：官方客户端，按需安装。

重启后，之前运行中的任务标为中断，不持久化可点击审批，不自动重发。Codex 历史以官方 App Server 为准。退出断开本客户端子进程，不等于撤销已经完成的修改。

## 验证边界

见 [Windows 验证清单](../docs/WINDOWS_VALIDATION.md)。CI 可以验证真实 Windows 的编译、原生 DLL 加载和应用启动，但不能代表真实游戏、反作弊、高刷新率、HDR、独占全屏或不同权限组合的验收。

## 官方接口依据

- [Windows SetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow)
- [Windows ClipCursor](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-clipcursor)
- [Windows RegisterHotKey](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey)
- [Electron 安全存储](https://www.electronjs.org/docs/latest/api/safe-storage)
- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [Codex Windows 沙箱](https://learn.chatgpt.com/docs/windows/windows-sandbox)
- 各家授权入口沿用 [v0.8 连接指南](../docs/SideAI_v0.8_连接指南.md) 对应的官方协议与限制。
