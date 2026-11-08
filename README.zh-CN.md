<div align="center">

# FlyTerm

**合上电脑，活儿不该就停了。**

装在手机里、干活在你服务器上的 AI 编程助手——
通过 SSH、Mosh，或者一条不会断的 QUIC 连接。

[![Release](https://img.shields.io/github/v/release/bytemind-ai/flyterm)](https://github.com/bytemind-ai/flyterm/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](./LICENSE)
![Platform](https://img.shields.io/badge/platform-Android-3ddc84)

[**下载 APK**](https://github.com/bytemind-ai/flyterm/releases/latest) ·
[快速上手](#快速上手) ·
[English](./README.md)

<img src="docs/images/hero.gif" alt="通知请求批准 systemctl restart nginx，点进去看到命令，批准后助手继续干活" width="320">

</div>

---

## 它能帮你做什么

### 你走开了，任务还在跑

让助手去跑数据迁移、编译、一整套测试。任务跑在服务器上，不在 App 里：锁屏、
断网、App 被系统杀掉，它都照跑。过一会儿回来，接着看进度和结果。

<img src="docs/images/jobs.png" alt="助手的任务列表：编译还在跑，测试已跑完，点一下就能看输出" width="300">

### 动手之前先问你，等你时会通知你

助手要执行需要你拍板的操作时，会推一条通知给你。点进去能看到具体命令和来龙
去脉，批准或拒绝都在一个界面里。你不用一直盯着终端看它是不是在等你；而你正在
看那个会话时，它也不会再弹通知打扰你。

服务器上跑着 Claude Code 或 Codex？接上 `flyterm notify`，它们干完活或停下来
等审批时也能推到你手机上——消息只在你的服务器和你的手机之间走，不经过任何
第三方中转，也不需要注册账号（[怎么接](./docs/agent-notifications.md)）。

<img src="docs/images/approve.png" alt="审批界面：显示要执行的具体命令和前面的对话" width="300">

### 一次对话，管你所有的服务器

「对比一下 web-1 和 web-2 的 nginx 配置。」「把 CI 机上的构建产物拷到预发环境。」
助手能在你添加过的所有服务器上执行命令、读文件、在机器之间搬文件，都在同一次
对话里完成，不局限于你当前连着的那一台。

<img src="docs/images/multi-host.png" alt="助手在一次回复里对比两台服务器的配置" width="300">

它还会记住学到的东西：通用的技能跟着你在各台服务器间通用，某台机器特有的情况
记在那台机器名下。它甚至能帮你配置 FlyTerm 本身——加服务器、开隧道、生成
SSH 密钥。

## 底层是一个不会断的终端

助手下面是一个完整的终端，专门为手机「网络说断就断」的现实设计。

- **换网络，会话不断。** Wi-Fi 切 5G、进隧道又出来，FlyTerm 的 QUIC 连接会跟着
  你走，而不是断开重连。
- **UDP 被封也能用。** 酒店 Wi-Fi、公司 VPN、只开放 22 端口的服务器——遇到封
  UDP 的网络，FlyTerm 会把同一条连接转到 SSH 通道里继续用；UDP 一恢复，又自动
  切回来。不用改设置，也不用重连。
- **也支持 Mosh**，网络慢时打字有本地回显，不卡顿。
- **为小屏幕打磨过。** 滚动历史保存在本地，往回翻看助手做过什么是瞬间的。完全
  可自定义的键盘快捷栏、分屏和悬浮窗、tmux 集成、中文等宽字符正确显示、10 套
  配色主题。

<img src="docs/images/terminal.png" alt="在 FlyTerm 里运行 tmux，键盘上方是自定义快捷栏" width="300">

## 快速上手

1. **安装**：从 [Releases](https://github.com/bytemind-ai/flyterm/releases/latest)
   下载 APK（Android 7.0 及以上，arm64）。所有功能免费，没有订阅，也没有内购。
2. **添加服务器**：用密码或 SSH 密钥。第一次用 QUIC 连接时，FlyTerm 会自动在
   服务器上装好一个很小的服务端组件（[它会装什么](./docs/user/quic-setup.md)）。
3. **接入你自己的模型**：填上 Anthropic、OpenAI、Gemini 或 OpenRouter 的 API
   Key，也可以接本地的 Ollama。

## 功能一览

| | |
|---|---|
| **连接** | SSH · Mosh · QUIC（换网无感、UDP 被封自动走 SSH）· 跳板机 · 端口转发 |
| **终端** | tmux 集成 · 分屏 · 悬浮窗 · 可自定义快捷栏 · 10 套主题 · 中文显示 |
| **文件** | SFTP 文件浏览 · 在当前会话里直接上传下载 |
| **助手** | 后台任务 · 通知审批 · 跨服务器操作 · 技能与每台机器的笔记 |
| **密钥** | 生成 Ed25519 和 RSA 4096 密钥 · 密钥只存在手机上 |

## 隐私与安全

- **完全开源。** 你会把生产服务器的钥匙交给一个 SSH 客户端，它理应是你能读懂
  的。协议实现的说明见 [docs/protocols/](./docs/protocols/)。
- **凭据只存在你的手机上**，保存在系统的安全存储里。
- **从源码构建的版本不上报任何数据。** 只有编译时注入了 `SENTRY_DSN` 才会有崩溃
  上报，开源构建从不注入。应用商店版会上报崩溃，但主机名会先做哈希，用户名只
  保留长度。
- 威胁模型和漏洞报告方式见 [SECURITY.md](./SECURITY.md)。

## 从源码构建

需要 Flutter、Rust 工具链和 Android SDK，具体版本和每一步都在
[CONTRIBUTING.md](./CONTRIBUTING.md) 里。装好后一条命令：

```bash
scripts/build_apk.sh
```

## 文档

- [配置 QUIC 连接](./docs/user/quic-setup.md) ·
  [常见问题排查](./docs/user/quic-troubleshooting.md)
- [给 Claude Code / Codex 接任务通知](./docs/agent-notifications.md)
- [架构说明](./docs/ARCHITECTURE.md) · [协议文档](./docs/protocols/) ·
  [更新日志](./CHANGELOG.md)
- [参与贡献](./CONTRIBUTING.md) · [安全](./SECURITY.md)

目前支持 Android，iOS 版正在路上。

## 许可

[GPL-3.0-or-later](./LICENSE)，第三方组件声明见 [NOTICE](./NOTICE)。
贡献代码需要签署 [CLA](./CLA.md)——版权仍归你所有；这份授权是为了让同一份代码
能上架应用商店，单靠 GPLv3 做不到这一点。

「FlyTerm」这个名字和应用图标不在 GPL 授权范围内。如果你 fork 后再分发，请换
一个名字和图标。
