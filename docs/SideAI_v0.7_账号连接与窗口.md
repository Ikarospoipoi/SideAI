# SideAI v0.7：账号连接与窗口

历史版本记录。当前操作请阅读 [v0.8 连接指南](SideAI_v0.8_连接指南.md)。

## 当前可以怎么接入

| 服务 | SideAI 中的接入方式 | 边界 |
| --- | --- | --- |
| GPT | 设置 → 添加与登录 → Continue with ChatGPT；也可配置 OpenAI API | 独立官方授权，不依赖 Codex App Server。账号资格与模型额度由官方决定；本轮未重新验证 GPT 云端推理 |
| Claude | 设置 → 添加与登录 → 连接已登录的 Claude 账号；也可配置 Anthropic API | 通过本机官方 Claude Code 调用，聊天通道工具关闭；不是独立的 SideAI OAuth。本轮真实账号回复已验证 |
| DeepSeek | 配置 DeepSeek API Key | 在 SideAI 内聊天；网站登录不能直接转换为 API 凭据。上轮该账号请求返回余额不足 |
| Kimi | 配置 Moonshot API Key | Kimi Code 已有设备授权接口，但本版尚未适配该授权和传输协议 |
| Qwen | 配置平台 API Key 与对应接口地址 | 官方 Qwen Code 已停用旧 OAuth 免费登录方式 |

各家网页登录、订阅和 API 额度不是自动通用的。SideAI 不提取浏览器 Cookie，也不复制官方 CLI 的 token。账号接入不等于同步官网历史。

## 连接 Claude 账号

1. 已安装并登录官方 Claude Code：直接点击「连接已登录的 Claude 账号」。你的本机账号已在本轮实测可用。
2. 没有登录时，在终端执行 `claude auth login`，按官方流程完成登录，再回 SideAI 点击连接。设置提供「复制官方登录命令」。CLI 当前为 API 登录时会提示，不会把它标成订阅账号。
3. 顶部应显示「聊天」及「Claude · 官方本机账号」，底部显示「纯聊天 · 工具已关闭」。模型按钮可选择官方模型别名与强度；实际可用范围由账号和 CLI 决定。
4. Claude Agent 仍在 Agent 模式，拥有独立的会话、草稿和权限。普通聊天不会复用 Agent 的项目权限，也不会因错误的 Agent 标记开启工具。

该连接使用官方 CLI 的账号状态。之后若在 CLI 更换账号，SideAI 随官方 CLI 使用新账号；SideAI 不保存另一份订阅凭据。用量取决于官方账号与可能关联的 API 额度设置。

## 管理、去重和删除

进入「设置 → 连接管理」，可以进入、编辑或删除连接。

- Claude 本机账号聊天只有一个入口，多次连接不会生成重复配置。删除这个入口不注销官方 CLI，也不删除 Claude Agent 入口；可在「已移除」中恢复。
- 同一服务商可以保留账号与 API 两种配置，但聊天模式只启用当前选择的一个。旧会话仍绑定原连接，不会静默改用另一种认证计费；失败不会自动切换或重发。
- 同地址、协议、认证方式、账号标签的 API 配置禁止重复。不同账号用不同标签。
- GPT 聊天授权与 Codex Agent 是不同用途，允许共存；不会因为 App Server 已登录就禁止 GPT 聊天 API。
- 删除 API / GPT 授权连接会删除 SideAI 保存的对应凭据，保留只读历史；恢复配置后需要重新填密钥或授权。聊天历史不会因删除入口而丢失。

## 窗口移动

拖动窗口顶部短横条。现在可以让窗口一半处于屏幕外，松手、收起再展开都不会被强制拉回屏幕中央。

仅在窗口与所有屏幕的有效交集不足 48 × 48 点时恢复可见位置，避免拔掉显示器后完全找不到窗口。该阈值是可见区域保护，不要求整个窗口处于屏幕内。也可使用「更多 → 窗口回到屏幕左侧」手动复位。

本轮已在当前显示器验证左半越界及收起重开；自动测试覆盖四个方向和多屏坐标。没有宣称实测过物理显示器拔插、所有缩放或 Spaces 组合。

## 验证与官方依据

本轮 51 项测试中 49 通过，2 项需显式启用的云端测试默认跳过，0 失败；另通过运行中的 SideAI 发送隔离测试消息，Claude 返回「OK」。旧 23 个会话的内容、草稿与模型保持不变，原 API 配置保持不变。

- [OpenAI：Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Anthropic：通过 Claude 计划使用 Agent SDK / CLI](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
- [DeepSeek：API 认证](https://api-docs.deepseek.com/api/deepseek-api/)
- [Qwen Code：认证方式及 OAuth 停用说明](https://qwenlm.github.io/qwen-code-docs/en/users/configuration/auth/)
- [Kimi Code：服务接口及授权流程](https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/reference/server-api.md)

官方能力会变化；上表描述的是本版 SideAI 实际已接入的范围。
