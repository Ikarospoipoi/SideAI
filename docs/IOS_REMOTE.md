# SideAI iPhone 遥控使用与部署（v0.11.0）

这一版让 iPhone 遥控 **Mac 上正在运行的 SideAI**。手机和电脑可以不在同一个 Wi-Fi。电脑运行模型与 Agent，手机显示进度、发送指令与处理审批。已有的 AI 登录、任务历史和跨会话记忆继续由电脑管理。

本次提供原生 iOS 工程、Mac 遥控入口和可自行部署的中继。没有预置公共服务器，也没有替你开通收费服务。Windows 客户端保留原有功能；本次手机遥控的电脑端实现是 macOS，Windows 尚未接入这条遥控协议。

## 你需要准备什么

- 一台保持开机、唤醒、联网且运行 SideAI 的 Mac（macOS 14 或更新）。锁屏与睡眠不同；电脑睡眠后不能接收指令。
- iOS 17 或更新的 iPhone；使用 Mac 上的 Xcode 安装。扫码功能需要系统支持；也可粘贴配对链接。
- 一个两端都能访问的 WSS 中继地址。没有服务器时，可先完成 Xcode 安装；异地连接要在中继部署后才能使用。

## 第一步：部署中继

最直接的方案是一台公网 Linux 服务器 + 一个域名 + 仓库中附带的 Docker Compose。服务器只转发加密数据，不运行模型，不需要 GPU，也不需要 AI API Key。下面使用 `relay.example.com` 作为占位域名，请换成你自己的。

1. 在服务器安装 Docker Engine 和 Compose 插件，参考 [Docker 官方安装说明](https://docs.docker.com/engine/install/)。
2. 将域名的 A 记录指向服务器公网 IP。仅当 IPv6 确实可达时配置 AAAA 记录。在服务器和云平台防火墙放行 TCP 80、443。无需开放 Mac 的端口，也不要向公网开放中继内部的 8787 端口。
3. 在服务器下载代码并进入目录：

```bash
git clone https://github.com/Ikarospoipoi/SideAI.git
cd SideAI/remote-relay
cp env.example .env
```

4. 编辑 `.env`，只填写域名，不加 `https://` 或路径：

```dotenv
RELAY_DOMAIN=relay.example.com
```

5. 启动并检查：

```bash
docker compose config
docker compose up -d --build
curl https://relay.example.com/health
```

返回 `SideAI relay healthy` 后，在 Mac SideAI 中填写：

```text
wss://relay.example.com/v1/connect
```

Compose 包含中继和 Caddy。Caddy 在域名正确解析、80/443 可访问时自动申请和续期证书；证书保存在持久卷中。参见 [Caddy 自动 HTTPS 条件](https://caddyserver.com/docs/automatic-https) 和 [Docker Compose 官方入门](https://docs.docker.com/compose/gettingstarted/)。首次启动申请证书可能需要一些时间。

查看故障与更新：

```bash
docker compose logs --tail=100
git pull
docker compose up -d --build
```

停止服务：`docker compose down`。不带 `-v`，保留证书卷。中继重启时，电脑和手机会重连；未确认指令不会自动补发。此方案应使用单个中继实例，房间状态在内存中，不支持无状态多副本轮询负载均衡。

如果将来改用托管容器平台，部署 `remote-relay/Dockerfile`，容器监听 8787，健康检查 `/health`；平台必须支持长期 WebSocket、HTTPS 和单实例，关闭空闲自动休眠。公开地址仍使用 `/v1/connect`。

## 第二步：用 Xcode 安装到 iPhone

1. 在 Mac 打开仓库里的 `ios/SideAI.xcodeproj`，Scheme 选择 **SideAI**。
2. 选择 **SideAIPhone** target → **Signing & Capabilities**，开启 **Automatically manage signing**，Team 选择你自己的 Apple 账号。若 Bundle Identifier 不可用，改成自己的唯一标识。
3. 用数据线连接 iPhone，按系统提示信任 Mac，并在 iPhone 设置中开启开发者模式（若系统要求）。在 Xcode 运行目标中选择你的 iPhone。
4. 点击 Run。第一次安装可能需要根据 iPhone 的系统提示信任开发者。签名有效期、可安装设备等限制由你的 Apple 开发者账号决定；到期后可通过 Xcode 重新安装。

工程没有写入我的 Team 或签名证书。具体设备准备流程见 [Apple 的 Xcode 真机运行说明](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)。

## 第三步：配对，只需一次

1. 在 Mac SideAI 中打开 **设置 → 手机遥控**。
2. 填入中继地址，点击 **生成配对二维码**。
3. 打开 iPhone SideAI → **连接我的电脑** → **扫描电脑上的二维码**。也可以复制电脑上的配对链接，粘贴到手机。扫码后点击连接。
4. 在 Mac 点击 **允许这台手机**。
5. iPhone 出现电脑上的会话和 AI 连接，即可开始。

二维码 10 分钟内可用于首次配对。配对后无需每天扫码；授权保存在两端 Keychain。二维码或配对链接是敏感的遥控凭证，不能公开发布。怀疑泄露时，在电脑解除配对并重新生成；不要只依赖二维码过期。

## 日常怎么用

| 你想做的事 | 手机操作 |
| --- | --- |
| 接着电脑上的任务做 | 左上角「会话」，选择原会话 |
| 新建任务或聊天 | 右上角新建按钮，选择电脑已连接的 AI |
| 切换 AI | 顶部连接菜单；进入该连接的会话，不会改写原任务所属的 Agent |
| 切换模型或思考强度 | 输入框上方「模型与项目」，选择模型和强度，保存；下一轮请求使用新设置 |
| 切换项目 | Agent 的「模型与项目」中选择电脑已经使用过的项目；新目录先在电脑选择一次 |
| 发指令 | 在底部输入消息并发送；由电脑执行，沿用电脑的记忆与权限规则 |
| 批准操作 | 点击橙色审批卡片，检查操作详情和目录，允许此次操作或拒绝；Agent 提问可填写答案 |
| 停止执行 | 点击输入框旁停止按钮；审批详情也有停止按钮 |
| 暂停手机权限 | Mac 的手机遥控设置 → 暂停遥控；重启电脑后仍保持暂停 |
| 永久解除本次配对 | Mac → 解除手机配对；手机也可移除本地配对 |

执行中的任务不能中途更换模型或项目，请停止或等本轮完成后再改。电脑有未发送草稿时，手机不会覆盖它；可以先处理电脑草稿，或在手机新建会话。

手机切换会话是查看原任务；发送指令时会选择该任务对应的桌面会话，但不会主动把电脑窗口弹到前台。模型列表来自电脑已有连接，可点击刷新；手机不添加 AI 密钥、不代替电脑执行登录。

## 断网、后台和限制

- 手机进入后台或锁屏后，iOS 可能暂停连接。Agent 在电脑继续，重新打开手机后同步。**本版没有后台推送通知**；审批会留在电脑等待处理。
- 指令送达状态不确定时，手机会提示。请查看同步后的任务再决定是否重试；程序不会自动重发，以免重复执行。
- 第一版一台电脑配对一台手机。切换电脑需要移除手机上的配对后重新配对。
- 手机展示最近 300 个未归档会话、当前会话最近 60 条内容；单条长内容截取，快照过大时进一步减少较早条目。完整记录仍在电脑。
- 同时显示最多 4 条待审批；处理后继续显示其他审批。详情过长的操作只能拒绝或在电脑完整查看后批准。
- 当前手机输入为文字，不上传图片或文件；已有图片消息的图片本体不传到手机。
- 远程访问不改变账号额度。电脑的 ChatGPT / Claude / API 若限额或失效，手机也会显示相应错误。

## 本机开发与验证

本机中继仅用于 Mac 与同机 iOS Simulator 联调；真机的 `127.0.0.1` 指向手机自己，不能用来连接 Mac。

```bash
cd remote-relay
npm ci --ignore-scripts
npm test
HOST=127.0.0.1 npm start
```

Mac 配置 `ws://127.0.0.1:8787/v1/connect`。非 loopback 地址强制使用 WSS，不提供忽略证书校验选项。

在仓库根目录执行：

```bash
swift test
xcodebuild -project ios/SideAI.xcodeproj -scheme SideAI -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

`RemoteTransportTests` 会启动临时本机中继，验证加密通道中手机修改电脑模型并重连恢复；需要先安装中继依赖。UI 测试使用离线虚构数据，不调用真实模型。真机扫码、用户签名、蜂窝网到公网中继的测试需要实际 iPhone 和部署后的域名，本次没有将模拟器通过等同于这些真机验证。

## 安全与运维说明

两端通过 HTTPS/WSS 连接中继，应用消息另外使用 AES-256-GCM 加密。HKDF 为电脑、手机两个方向派生不同密钥。消息绑定房间、方向、会话和序号；指令还需匹配本次握手挑战、设备、时间和去重 ID。审批绑定当前请求内容，拒绝旧请求重放。

中继只保存临时房间和鉴权摘要，不落盘聊天、不记录请求内容、不排队存放离线指令。中继运营者仍能观察 IP、连接时间、房间标识及流量大小。持有配对密钥的设备可以解密该配对的内容；这不是独立安全审计，也不提供前向保密保证。

Docker 中继使用非 root 用户、只读文件系统、连接和消息大小上限。它是个人自托管版本，不是公开多租户 SaaS：如果向大量陌生用户开放，还需要服务注册、租户配额、边缘限流与运维监控。不要开放 Docker 管理端口，也不要把配对链接写入工单或日志。
