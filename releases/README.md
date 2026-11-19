# SideAI 开发版安装包

## macOS · 2026-11-19

[下载 SideAI 0.11.0 工作台开发版（Apple Silicon）](https://github.com/Ikarospoipoi/SideAI/raw/refs/heads/main/releases/SideAI-0.11.0-workbench-20261119-macOS-arm64.zip)

- 要求：Apple Silicon（arm64），macOS 14+；不是 Intel 通用二进制。
- 安装：解压 ZIP，将 `SideAI.app` 拖到“应用程序”，退出旧版后打开新版。
- 签名：本地 ad-hoc 签名，未进行 Apple 公证。系统可能阻止首次打开；确认下载来源后，可在“系统设置 → 隐私与安全性”查看是否提供“仍要打开”。不需要关闭系统安全功能。
- 此包只包含应用，不包含账号凭据、聊天记录、附件缓存或开发环境。
- 版本标识沿用 0.11.0（构建 12），通过文件名日期与 SHA-256 区分本次开发快照。
- 功能入口：首页或聊天页的“工作台”。详见 [功能说明](../docs/PRODUCTIVITY.md)、[连接指南](../docs/SideAI_v0.8_连接指南.md)、[iPhone 安装与部署](../docs/IOS_REMOTE.md)。

SHA-256：

```text
f2bec08ab97475d23a6fb0597cbfe260197b5f32e822c42a455ef5d37c919639  SideAI-0.11.0-workbench-20261119-macOS-arm64.zip
```

## 其他平台与验证

- Windows：本次上传包含最新源码与使用说明，TypeScript 构建和 11 项离线测试通过；尚无此开发快照对应的 Windows 安装包。已有 Actions 构建流程保留，本次上传跳过自动 CI，避免触发 Claude 测试或客户端安装流程。
- iPhone：包含 Xcode 工程和部署指南，模拟器构建通过；未提供可直接安装的 IPA。APNs 后台推送留待后续接入。
- macOS：Release 构建、签名校验及 42 项定向回归通过；未调用真实模型或 Claude，真实服务及跨机器安装仍需实际验证。

这次上传保存当前工作区，包括开发开始前已经存在的改动。Claude 专属源码未在工作台开发及上传过程中修改；已有版本随项目一并保存。
