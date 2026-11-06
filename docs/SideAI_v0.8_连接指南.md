# SideAI 连接指南

适用于 0.8.0，核查日期：2026 年 11 月 6 日。

## 从这里开始

1. 首页点击 **添加 AI**。
2. 选择服务，点击登录。在服务商的官方页面完成授权，SideAI 会自动建立连接。
3. 回到 SideAI 开始聊天。首页只显示你已添加的连接。
4. 要处理本机项目，切换到 **Agent**，添加 Codex 或 Claude Code。

浏览器用于官方身份验证；连接成功后，对话在 SideAI 内进行。不同服务的账号资格、地区、订阅与用量限制由服务商决定；网页登录成功不代表一定具备模型调用额度。

## 哪些可以账号登录

| 服务 | SideAI 中的方式 | 账号与额度来源 |
| --- | --- | --- |
| GPT | Continue with ChatGPT，官方 OAuth / PKCE | ChatGPT 官方开放的计划令牌共享，权限由授权页显示 |
| Kimi | 登录 Kimi，官方设备码授权 | 官方 Kimi Code 客户端及其账号额度；不等同于 Kimi 网页聊天额度 |
| Gemini | 使用 Google 登录 | 官方 Antigravity 账号及其可用额度；企业账号在「其他接入方式」中登录 |
| Grok | 登录 Grok，官方浏览器 OAuth | 官方 Grok Build 客户端及账号资格 |
| OpenRouter | 登录 OpenRouter，官方 OAuth / PKCE | OpenRouter 余额，授权后可选择其提供的模型 |
| Claude | 聊天模式使用 API；Agent 模式登录 Claude Code | Claude API 单独计费；Claude Code 使用官方客户端支持的账号 |
| DeepSeek | API 密钥 | DeepSeek 开放平台余额 |
| Qwen | API 密钥 | 阿里云百炼或兼容接口的额度 |
| Codex（Agent） | 登录 Codex，官方 App Server 账号登录 | 官方 Codex / ChatGPT 账号 |
| Claude Code（Agent） | 登录 Claude Code；高级设置也可选择 Claude Console | 官方 Claude Code 客户端管理登录 |

Kimi、Gemini、Grok 的登录与续期由原版官方客户端处理。SideAI 的聊天连接关闭本机工具，不提供文件、终端或权限批准能力；这些连接不是复制对应网页的登录 Cookie，也不自动带入网页历史。

**Claude 的区别：** Anthropic 没有向第三方聊天应用开放 Claude.ai 订阅 OAuth。官方规则允许在产品中运行原版 Claude Code、由最终用户自行登录，但不允许把其订阅凭据提取为第三方聊天 API。因此 Claude Code 登录放在 Agent 模式；直接 Claude 聊天提供 API。

**Google 的变更：** 旧 Gemini CLI 自 2026 年 6 月 18 日起不再为个人、AI Pro、AI Ultra 账号提供服务。本版使用 Google 当前的 Antigravity ACP 客户端进行账号授权，不使用已失效的旧个人账号入口。

**没有账号授权的判断：** 在本次核查的公开官方接入文档中，DeepSeek 没有面向第三方客户端的通用账号 OAuth；Qwen Code 原有 OAuth 已于 2026 年 4 月 15 日停用。它们使用 API，不提供无效的登录按钮。这不是对所有厂商、所有私有合作渠道都不存在授权的断言。

## API 怎么连接

没有官方账号授权的服务会直接显示 **连接 API**。粘贴密钥，点击连接即可；接口地址与协议使用预设。模型可以留空自动读取，或填写服务商提供的模型名称。API 通常独立计费，不共享网页会员额度。

已有账号登录的服务仍可在 **其他接入方式 → 使用 API 密钥** 中添加 API。高级设置仅在需要自定义接口或区分多个账号时展开。

## 避免重复连接

- 同一个 Kimi / Gemini / Grok 账号入口重复登录，会更新已有连接。
- 同一 ChatGPT 账号重新授权会更新对应连接；OpenRouter 登录默认更新现有授权连接。
- API 按服务地址、协议、认证方式和账号标签检查重复；要换密钥，使用 **连接管理 → 编辑**。
- 聊天与 Agent 是不同用途，可以同时保留 GPT 与 Codex、Claude API 与 Claude Code。每次发送只使用当前连接，不会同时发给多个后端。
- 同一服务的不同连接可以并存，选择其中一个作为当前连接。不同连接的会话与草稿独立。

## 删除与重新体验

**设置 → 连接管理** 集中显示所有连接。删除单个连接会清除它在 SideAI 中的凭据，保留本地对话；重新使用需要再次连接。API 或服务端授权如果还需要远程撤销，可在服务商自己的账号页面操作。

**从头开始** 会解除全部 SideAI 聊天和 Agent 连接，并清空当前会话列表。旧会话和非密钥配置保存在：

`~/Library/Application Support/SideAI/Backups/<时间>/state.json`

API 密钥与 OAuth 密钥不写入这份备份，不能通过备份恢复登录。

新版 Codex、Claude Code、Kimi、Gemini、Grok 使用 SideAI 独立账号目录：

`~/Library/Application Support/SideAI/Accounts/`

这使 SideAI 能独立退出和重新登录，不会自动借用终端中的账号，也不会注销你在终端、Codex App、Claude Code 或浏览器中的其他登录。浏览器仍可能记住服务商账号，官方授权页面因此可能无需重新输入密码。

## 官方资料

- GPT：[Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)。
- Kimi：[官方登录命令](https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/reference/kimi-command.md)、[ACP 接口](https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/reference/kimi-acp.md)。
- Gemini：[旧个人账号入口停用说明](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals)、[Antigravity 官方 ACP 认证](https://antigravity.google/docs/ide/extensions/acp/)。
- Grok：[官方 CLI](https://docs.x.ai/build/cli/reference)、[账号认证](https://docs.x.ai/build/enterprise)。
- OpenRouter：[OAuth PKCE](https://openrouter.ai/docs/guides/overview/auth/oauth)。
- Claude：[账号使用与集成规则](https://code.claude.com/docs/en/legal-and-compliance)、[CLI 登录命令](https://code.claude.com/docs/en/cli-reference)。
- DeepSeek：[API 文档](https://api-docs.deepseek.com/)。
- Qwen：[官方认证说明与 OAuth 停用通知](https://qwenlm.github.io/qwen-code-docs/en/users/configuration/auth/)。

## 验证范围

已验证本地构建、自动化测试、官方 Kimi / Antigravity / Grok 客户端的 ACP 握手及认证方法发现。流式消息、取消、拒绝工具请求、连接隔离、重置和备份经过本地测试。Grok 在实机测试中完成官方登录并读取模型列表；Gemini 完成 Google 授权、读取模型列表并收到真实中文回复；Kimi 设备码页面已验证。真实授权由用户在各官方页面完成；未代用户点击授权确认，也未对所有服务进行付费推理验证。
