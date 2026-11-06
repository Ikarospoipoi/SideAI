> 历史版本说明。当前操作请阅读 [v0.8 连接指南](SideAI_v0.8_连接指南.md)。

# SideAI v0.6：连接管理与官方入口

更新：2026-11-05。应用位于 `build/SideAI.app`。

## DeepSeek 密码提示与闪退

原崩溃报告显示错误出现在创建 URLSession 流式任务时。新版让每个网络请求拥有独立生命周期，取消只取消请求任务，待调用结束后才关闭网络会话；同时跟踪从凭据准备到请求结束的整个任务。

发送时默认静默读取 macOS 钥匙串。若旧密钥需要新版应用重新取得访问权限，SideAI 显示提示并保留草稿；到「设置 → 连接管理 → 对应连接 → 允许钥匙串访问」主动授权。macOS 可能要求的是系统登录钥匙串密码，不是 DeepSeek 网站密码；请只在系统窗口输入，SideAI 不收集该密码。取消授权不会发送消息。

本机 DeepSeek API 实际回归测试没有弹密码框、没有闪退，返回 **HTTP 402：Insufficient Balance**。这是 API 账户余额不足，需用户在官方 API 平台处理；官网聊天账号与 API 额度并不等同。应用没有自动重试或自动切换供应商。

## 官方入口

聊天入口卡片下方，以及「设置 → 连接管理 → 官方入口」均可打开官网。按照你的选择，使用系统默认浏览器，兼容已有官方登录。

| 服务 | 官方聊天网站 |
| --- | --- |
| GPT | https://chatgpt.com/ |
| Claude | https://claude.ai/ |
| DeepSeek | https://chat.deepseek.com/ |
| Kimi | https://www.kimi.com/ |
| Qwen | https://chat.qwen.ai/ |

官网聊天按钮打开网站，不创建 SideAI API 连接，也不抓取网站密码、登录令牌或历史。GPT 原有独立官方授权保留在「添加与登录」；Claude Code 官方 CLI 登录仍位于 Agent 设置。其余服务在 SideAI 自有聊天界面继续使用相应 API 配置，没有伪造第三方账号授权。

依据：[DeepSeek 官方首页及网页版链接](https://www.deepseek.com/)、[DeepSeek API 认证](https://api-docs.deepseek.com/api/deepseek-api/)、[Kimi 官网](https://www.kimi.com/)、[Qwen 官方产品页](https://qwen.ai/qwenchat)、[Claude API 认证方式](https://platform.claude.com/docs/en/manage-claude/authentication)。

## 管理与删除连接

打开「设置 → 连接管理」，同一页可以看到聊天连接、Agent 连接、官方入口和已移除配置。

- **API / 独立 GPT 授权**：可进入聊天、编辑或重新授权、主动授权钥匙串、删除连接。删除前会确认，确认后删除 SideAI 保存的凭据并移除可发送入口。
- **旧历史与草稿**：不会删除，保留为只读。不会自动迁到其他连接。可在「已移除」中恢复原配置，重新填写密钥 / 授权后继续原会话。
- **Codex / Claude Code**：可移除 SideAI 入口；本客户端的 Codex 连接会断开，但不会注销官方 CLI 的账号，也不删除官方历史。
- 正在发送、测试连接、授权或连接后端时禁止删除，避免执行中的任务失去归属。钥匙串拒绝删除时，原连接配置保持不变。

删除本地凭据不等于在服务商后台撤销 API Key / OAuth 授权。需要彻底撤销时，应在对应官方账号后台处理。

## 验证与备份

升级前备份为 `~/Library/Application Support/SideAI/state.pre0.6.backup.json`。原用户连接未被开发测试删除；原草稿保留。新增一条独立 DeepSeek 测试会话，记录本次 HTTP 402 响应。

自动测试覆盖取消后再发送、取消与请求启动竞态、请求中的取消、三种 API 流式协议、删除失败的原子性、执行中禁止删除、历史与草稿保留、恢复原连接 ID，以及缺失凭据时保留草稿。真实 UI 检查了统一管理页和删除确认弹窗；没有用你的实际凭据做删除测试。

开发构建使用本机 ad-hoc 签名，未公证。钥匙串可能在后续更换构建后再次要求授权；这是系统信任边界，应用不会通过公开凭据或宽松访问控制绕过它。[Apple 本地认证上下文说明](https://developer.apple.com/documentation/security/ksecuseauthenticationcontext)
