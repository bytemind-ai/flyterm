# FlyTerm

**Your coding agent doesn't stop when you close the laptop.**
**合上电脑，活儿不该就停了。**

[English](./README.md) · [中文]

FlyTerm 是一个装在手机里、干活在你服务器上的 coding agent。它通过 SSH、Mosh
或自研的 QUIC 传输连接，跑的任务能熬过你锁屏，需要你拍板时会推一条通知给你。

> **截图 / 演示 GIF 放这里。** 拍 on-call 流程：锁屏通知
> `agent wants to run systemctl restart nginx — approve?`，点进去看到命令和
> 上下文，批准，agent 继续。这一个片段同时演示了远端任务、推送审批、多机、
> 知识沉淀四件事。

## 它为什么不是「带聊天框的终端」

三条是结构性的，不是外观差异 —— 桌面 agent 不是这么设计的，也没什么动机改：

**任务活在服务器上，不活在客户端。** `run_background` 把任务落到目标机的
`~/.flyterm/jobs/`，之后用 `check_job`、`list_jobs` 回来查。锁屏、断网、app
被系统杀掉，任务照跑。桌面 agent 的任务绑在启动它的那个终端进程上。

**审批走推送通知。** agent 需要你拍板时推一条通知给你，并且带前台抑制 ——
你正看着那个会话时它不吵你。这是手机**优于**桌面的地方，不是妥协：桌面 agent
得你盯着终端才能发现它在等你回答。

**多机是一等公民。** `bash` 和 `read_file` 都带 `server` 参数，还有
`copy_between_servers`、`list_servers`。一次会话能横跨你的整个机群。多数
coding agent 的模型是单机、单工作目录。

由此延伸出两条：agent 能重新配置 app 自身（加服务器、开隧道、生成 SSH 密钥、
切布局）；知识沉淀在 app 端而不是跟着目录走 —— 可复用的技能跨机器带着走，
每台机器的事实留在那台机器名下。

## 其余能力

**会话熬得过地铁。** Mosh 式状态同步加 QUIC 传输，Wi-Fi 切 5G、过隧道，活儿
不断。

**为小屏幕上的 agent 会话做过优化。** scrollback 本地渲染、零网络往返，所以
往回翻看 agent 干了什么是瞬间的。检测到 TUI 应用会切换滚动策略。抑制闪烁。
长按退格会重复。CJK 双宽字符正确渲染。这些是只有真在手机上跑过 agent 才会
发现的问题。

**可审计。** 这是个 SSH 客户端 —— 你把生产机器的凭据交给它。源码公开，协议
实现可读。威胁模型见 [SECURITY.md](./SECURITY.md)，包括**哪些部分没有**经过
审计。

**该有的终端功能一样不少**：SFTP、SSH 密钥管理（Ed25519 与 RSA 4096）、跳板机
串联、端口转发、分屏与浮动窗口、完全可编程的屏幕键盘栏、tmux 集成、10 套配色。

## 安装

从 [Releases](https://github.com/bytemind-ai/flyterm/releases) 下载 APK，或自己
构建（见下）。所有功能免费，没有任何内购。

## 构建

需要 Flutter 3.47.2（Dart 3.13.2）、JDK 17、Rust 1.99 工具链。完整环境配置见
[CONTRIBUTING.md](./CONTRIBUTING.md)。

```bash
flutter pub get
flutter gen-l10n
flutter test
scripts/build_apk.sh
```

产物：`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

如果 `PATH` 里没有符合版本要求的 `flutter`，显式指给脚本：
`export FLYTERM_FLUTTER=/path/to/flutter/bin/flutter`。

**签名。** 打 release APK 正常需要 `android/key.properties` 里的凭据（该文件和
keystore 本体都不进 git）。你多半没有，所以缺凭据时 `scripts/build_apk.sh` 会
替你开启 debug 签名，并大声提示。本地构建、在真机上读代码，这都没问题 ——
但 **debug 签名的包绝不能分发**。Android 的 debug keystore 是公开已知的固定
密钥，任何人都能伪造一个「更新」；而且 Android 不允许跨签名密钥升级，一旦发
出去，这不是个之后能悄悄纠正的错误。

## 文档

- [ARCHITECTURE.md](./docs/ARCHITECTURE.md) —— 分层、provider 装配、关键设计决策
- [CONTRIBUTING.md](./CONTRIBUTING.md) —— 工具链、构建、测试、PR 流程
- [SECURITY.md](./SECURITY.md) —— 威胁模型与漏洞报告
- [docs/protocols/](./docs/protocols/) —— SSP v2 与 AQT 协议说明
- [CHANGELOG.md](./CHANGELOG.md)

## 遥测

源码构建**什么都不发**。崩溃上报需要 `SENTRY_DSN` 编译时变量，而开源构建从不
注入它 —— 变量为空时遥测层在启动时直接返回。商店版会上报崩溃，但主机名经过
哈希、用户名被压成一个长度 token 之后才离开设备。

## 许可

[GPL-3.0-or-later](./LICENSE)。第三方归属见 [NOTICE](./NOTICE)。

贡献需要签 [CLA](./CLA.md) —— 版权仍归你；这份授权的存在是为了同一份代码能
通过应用商店分发，而单靠 GPLv3 做不到这件事。

## 商标

"FlyTerm" 这个名字和 app 图标不在 GPL 覆盖范围内。如果你 fork 后再分发，请换
一个名字和图标。
