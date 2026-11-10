# ChatGPT 聊天授权链路与额度错误核查

核查日期：2026-11-10。没有改动登录配置、退出账号、重新授权或刷新凭据。

## 实际链路

当前 GPT「聊天」连接使用 `chatgptPlan` OAuth，经过 SideAI 自己的 `HTTPChatClient` 直接访问公开 Responses API。**不经过 Codex CLI / Codex App Server，不使用 ChatGPT 网页的 backend-api，也不是用户填写的 API Key。** 同一个 API 域名可以承载不同授权方式，不能仅凭域名判断计费来源。

| 环节 | 域名与路径 | 本地实现 |
| --- | --- | --- |
| 浏览器授权 | `https://auth.openai.com/api/accounts/authorize` | `Sources/SideAICore/ChatGPTLogin.swift` |
| 交换 / 刷新令牌 | `https://auth.openai.com/api/accounts/oauth/token` | `Sources/SideAI/ChatGPTAuth.swift`、`ChatGPTStore.swift` |
| 模型列表 | `GET https://api.openai.com/v1/models` | `Sources/SideAI/HTTPChatClient.swift` |
| 聊天生成 | `POST https://api.openai.com/v1/responses` | `SessionStore.send → sendAPI → HTTPChatClient.stream` |

登录申请包含 `resource.invoke` 与 `chatgpt.tokens.use.direct`，令牌保存在 macOS 钥匙串；请求中 `store=false`、`stream=true`。本文不包含授权 URL 的查询参数、账户身份、Token、Cookie、API Key、请求正文或聊天历史。

单独的 **Agent → Codex** 路由才会启动本机 `codex app-server --listen stdio://`，通过 `thread/start` / `thread/resume` / `turn/start` RPC 调用。它与截图中的 GPT 聊天路由不同。本次没有抓取或推断 Codex 进程的外部网络端点。

这条直连方式与 [OpenAI 官方 Models and inference 文档](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference) 描述的 ChatGPT plan usage 流程一致。

## 原始记录与复现的区别

截图所对应的本地失败记录保存了模型 `gpt-6-astra` 和 Subscription Sharing usage limit 文案，但旧版没有保存 HTTP 状态码、事件类型、`error.type`、`error.code` 或响应头。因此，不能将下列复现结果冒充原始那一包网络响应。

2026-11-10 **15:30:55（北京时间）**，使用同一已保存账号的有效授权、同一模型发送了一次最小测试请求；没有携带聊天历史或跨会话记忆，没有刷新令牌，没有自动重试。复现了相同额度错误：

| 字段 | 本次复现实测 |
| --- | --- |
| 请求域名 | `api.openai.com` |
| 请求路径 | `/v1/responses` |
| 方法 | `POST` |
| HTTP 状态码 | **`200`** |
| 流事件 `type` | **`error`** |
| `error.type` | **`invalid_request_error`** |
| `error.code` | **`subscription_sharing_usage_limit_exceeded`** |
| 文案 | 与原始 Subscription Sharing usage limit 报错一致 |
| `Retry-After` | 未返回 |
| `x-ratelimit-reset-requests` / `x-ratelimit-reset-tokens` / `x-ratelimit-reset-project-tokens` | 未返回 |
| 错误对象的 `reset_at` / `resets_at` / `reset_after` / `reset_after_seconds` / `retry_after` / `retry_after_seconds` | 未返回 |

HTTP 200 表示流式连接已经建立，不代表模型生成成功；错误随后作为流事件返回。官方文档中同一错误代码的普通 HTTP 错误映射是 429，但本次实测是 **HTTP 200 + 流内错误**，不能改写成 429。

## 可以和不可以得出的结论

- 这次调用被 ChatGPT plan usage 的共享使用额度限制拦截。独立最小请求也复现，不能归因于跨会话记忆 UI 本身。
- 可能涉及应用级限额；不能据此断言 ChatGPT 网页、整个订阅或 Codex 的额度都已耗尽。
- 返回值没有提供恢复时间，不能推测 3 小时、24 小时或下月重置。
- 应暂停该授权通道的重复请求，按官方指引在 ChatGPT 设置的 Usage 中查看。没有证据表明应该重新登录，更不应自动切换收费方式。

依据：[OpenAI 官方 Errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)。该页面明确要求不要单凭此代码推断整个计划耗尽或重置时间；应用级限额也可能生效。

## v0.10.1 诊断补充

Mac 与 Windows 的后续 HTTP / 流式错误会保留一个白名单诊断对象，在失败回复下展开「请求诊断」可查看。字段仅限主机、无查询参数的路径、真实 HTTP 状态、事件及错误标识、常见重置字段和时间。不会保存原始请求头、Cookie、请求体、原始响应体或错误中的任意附加属性。未提供的字段保持缺失，不编造额度重置时间；没有自动重试或修改登录机制。
