# SideAI Cloudflare 中继

Workers + SQLite Durable Objects + WebSocket Hibernation。模型和 Agent 在用户电脑执行；中继只传输设备端加密后的消息，不存储聊天正文，也不接收模型账号凭证。

## 普通用户

Mac 设置 → 手机遥控 → 生成配对二维码，使用 iPhone SideAI 扫描，再在电脑允许手机。默认地址已内置；用户不需要 Cloudflare 账号、服务器、域名或 API Key。需要两端网络都能访问默认中继，电脑保持唤醒。

已部署地址：`wss://sideai-remote-relay.sideai-cloudflare-relay.workers.dev/v1/connect`。

`workers.dev` 在某些地区或网络可能无法访问。免费托管不保证所有运营商都可连通；可在「高级：自定义中继」使用自己可达的 WSS 域名。不要关闭 TLS 校验来解决连接问题。

## 维护者部署

只需一个 Cloudflare 账号。以下命令不会为账号升级套餐：

```bash
cd cloudflare-relay
npm ci --ignore-scripts
npx wrangler login --scopes account:read user:read workers:write workers_scripts:write
npm test
npx wrangler deploy --dry-run
npm run deploy
```

首次部署时注册免费的 `workers.dev` 子域名；以 Wrangler 实际输出为准。新域名的 DNS、证书生效可能有延迟。自部署者将输出地址填入客户端高级设置；发行自己的客户端可修改 `RemoteHost.defaultRelayURL`。不要把 OAuth 配置、Token、配对链接或 Keychain 数据提交到 Git。

使用 Workers Free 计划和 SQLite DO。按 [Cloudflare 定价](https://developers.cloudflare.com/durable-objects/platform/pricing/)，免费额度超出后相关操作失败，日额度于 UTC 00:00 重置；它不是无限免费服务。维护者应在控制台确认账号套餐，若自行开通付费计划则适用付费计费规则。免费中继不包括模型调用费用或 Apple 的应用分发费用。

更新时再次运行测试和 `npm run deploy`。平台托管进程、TLS 和扩缩容，不需要维护 Linux；仍需偶尔查看额度、错误及依赖更新。没有配置自动发布凭证，GitHub CI 只测试和打包检查，不访问生产账号。

## 数据与访问规则

- HTTP 升级前验证房间、角色、Token 格式及凭证摘要；凭证在请求头中，不放 URL。
- 电脑和手机使用不同的中继 Token；它们不能用于推导消息加密密钥。
- 每个随机房间只保留一个电脑连接和一个手机连接。新连接替换同角色旧连接。
- 持久化的只有房间 ID 与两个 Token 的 SHA-256 摘要。无活动连接的房间约七天后清理；仍有连接则延后。
- 未授权连接不能取得房间消息；同房间有凭证的设备还必须通过客户端端到端加密和电脑首次配对审批。
- 每个 IP 每分钟最多 30 次有效格式的连接尝试；每条连接每 10 秒最多 100 帧 / 12 MB，单帧最多 2 MB。流量过大断开后由客户端重连。
- 使用 WebSocket Hibernation；空闲期间不运行定时器。状态不变时电脑只发送小型加密心跳，避免重复整段聊天。
- 未启用持久化请求日志。Cloudflare 仍处理连接 IP、时间、房间和流量元数据；端到端加密不隐藏这些信息。
- 没有离线指令队列。手机重连会重新获取状态，不自动重发不确定是否已执行的指令。

公开端点有边缘限流，但没有注册账号和逐用户计费体系；大规模滥用仍可能耗尽免费额度。当前适合少量用户试用。

## 验证

```bash
npm test
npm run dev
```

在仓库根目录运行真实 Swift 客户端协议测试（虚构会话，不调用模型、不改真实登录）：

```bash
SIDEAI_TEST_RELAY_URL=ws://127.0.0.1:8791/v1/connect swift test --filter RemoteTransportTests
SIDEAI_TEST_RELAY_URL=wss://sideai-remote-relay.sideai-cloudflare-relay.workers.dev/v1/connect swift test --filter RemoteTransportTests
```

本地测试覆盖：升级鉴权、Token 角色隔离、房间隔离、双向转发、替换重连、错误帧、体积/频率限制和房间所有权。Swift 集成测试覆盖加密握手、手机修改电脑模型、重连后的状态恢复与挑战更新。模拟测试不能代替真机在另一 Wi-Fi / 蜂窝网络下的测试。

### 2026-11-12 验证记录

- 已部署到上面的默认地址；健康检查返回 `SideAI relay healthy`。
- 5 项 Worker 测试通过；Swift 回归 81 项，3 项需显式开启的真实服务测试跳过，0 失败。
- 单独开启公网中继集成测试通过：真实 Swift 通道加密传输、修改模型、重连、空闲心跳。使用虚构会话，未调用真实模型。
- Mac 已打包更新；iPhone 16 Pro 已安装并启动新版客户端。
- 当前 Mac 通过已有系统代理连接公网中继成功；直连 DNS 返回异常地址，不能据此承诺国内直连可用。尚未完成用户 iPhone 在另一 Wi-Fi / 蜂窝网下的扫码配对测试。
