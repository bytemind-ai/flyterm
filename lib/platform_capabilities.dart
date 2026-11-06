// SPDX-License-Identifier: GPL-3.0-or-later
// lib/platform_capabilities.dart
//
// 平台能力的**单一真相点**。
//
// ## 为什么需要它
//
// iOS 上架前，`lib/` 里散落着若干 `Platform.isIOS` / `Platform.isAndroid`
// 判定（本地终端、MediaStore 下载、Android 语音 MethodChannel、前台服务、
// 应用内更新……）。照现状撒下去，将无人说得清「iOS 上究竟哪些功能开着」——
// 而这些分支绝大多数在 Linux 的 `flutter test` 里根本跑不到（`dart:io` 的
// `Platform` 在测试宿主上恒为 linux），等于没有回归护栏。
//
// 平台守卫的架构决策：收敛为可注入的单一来源，**Linux 上即可对
// iOS 行为做全量单测** —— 注入 `hasLocalShell: false` 后断言本地终端入口
// 消失、冷启动不启动 PTY、DB 里已存的 `local` 记录不崩。无需 Mac、无需真机。
//
// ## 边界
//
// - 它做什么：回答「本平台是否具备某能力」。
// - 怎么用：`PlatformCapabilities.instance`（生产默认按 `Platform` 判定），
//   或 `debugOverride` 注入（测试）；单个字段的独立开关沿用各模块已有的
//   `debug*` 惯例（`PublicDownloads.debugIsAndroid` 等）——那套已经被测试
//   覆盖，不重复迁移。
// - 依赖什么：仅 `dart:io` 的 `Platform`。不 import 任何 Flutter 组件，
//   也不 import 具体功能模块 —— 反向依赖会让这份文件变成新的上帝对象。
//
// ## 新增能力字段的约定
//
// 只收「**平台能否做某件事**」这类事实判断；不要收状态（那是 ChangeNotifier
// 的事）、不要收配置（那是 Settings 的事）。每加一个字段，同步在
// `test/platform_capabilities_test.dart` 里补两条：默认值按平台正确 +
// 注入覆盖生效。
import 'dart:io' show Platform;

class PlatformCapabilities {
  const PlatformCapabilities({
    required this.hasLocalShell,
    required this.hasMediaStoreDownload,
    required this.hasNativeSpeechChannel,
    required this.hasForegroundService,
    required this.hasInAppUpdate,
  });

  /// Android 是当前唯一的全功能平台；其余平台（iOS/Linux desktop）都缺
  /// 本地终端 —— 这份构造器是测试的**明确**写法，不依赖宿主平台。
  const PlatformCapabilities.android()
      : hasLocalShell = true,
        hasMediaStoreDownload = true,
        hasNativeSpeechChannel = true,
        hasForegroundService = true,
        hasInAppUpdate = true;

  /// 无本地终端、无 MediaStore、无自研语音通道、无前台服务语义、无应用内
  /// 更新 —— iOS 首发的能力面（也是 Linux desktop 的能力面）。
  const PlatformCapabilities.limited()
      : hasLocalShell = false,
        hasMediaStoreDownload = false,
        hasNativeSpeechChannel = false,
        hasForegroundService = false,
        hasInAppUpdate = false;

  /// 本机的实际能力。生产代码应优先用它；测试用上面的具名构造器。
  factory PlatformCapabilities.instance() => PlatformCapabilities(
        hasLocalShell: Platform.isAndroid,
        hasMediaStoreDownload: Platform.isAndroid,
        hasNativeSpeechChannel: Platform.isAndroid,
        hasForegroundService: Platform.isAndroid,
        hasInAppUpdate: Platform.isAndroid,
      );

  /// 本地终端（flutter_pty + `/system/bin/sh`）。
  ///
  /// iOS 沙盒禁止 `fork/exec`，且审核指南 2.5.2 禁止执行非自带代码 ——
  /// 本地 shell 在 iOS 上是**永久缺失**，不是「还没做」。要做需要自建一整套
  /// 静态链接的内置命令集（Blink Shell 的做法），相当于另一个子项目，
  /// 明确不在范围内。
  ///
  /// 影响四处：`composite_transport_factory` 的 connect/reconnect 分派、
  /// `terminal_screen` 的冷启动恢复与新建连接、`server_form_screen` 的
  /// 类型选择、`home_screen` 的已存 local 记录展示。
  final bool hasLocalShell;

  /// 「发布到系统 Downloads」（MediaStore native channel）。
  ///
  /// iOS 没有系统 Downloads 概念；`PublicDownloads.publish` 在非 Android 上
  /// 返回 null（既有行为，保持），UI 侧兜底是 share sheet。
  final bool hasMediaStoreDownload;

  /// 自研的两个 Android 语音 MethodChannel
  /// （`SystemSpeechPlugin.kt` / `InlineSpeechPlugin.kt`）。
  ///
  /// iOS 没有对应 Swift 实现；iOS 走 `speech_to_text` 包 → Apple Speech
  /// 框架，是完全不同的代码路径。
  final bool hasNativeSpeechChannel;

  /// `flutter_foreground_task` 的前台服务语义（Android 专属概念）。
  ///
  /// iOS 上该包有实现但语义不同（后台 ~30s/15min 的 BGTask），且本项目
  /// 的后台保活开关已休眠（`foreground_service.dart` 的 `_enabled=false`）。
  final bool hasForegroundService;

  /// Play Core 应用内更新（`in_app_update`）。
  ///
  /// iOS 的更新检查走 App Store 自身（或 TestFlight），没有站内更新流。
  /// 引导用户去站外下载违反审核指南 3.1.1。
  final bool hasInAppUpdate;

  /// 覆盖单个字段的副本，便于逐项注入。
  PlatformCapabilities copyWith({
    bool? hasLocalShell,
    bool? hasMediaStoreDownload,
    bool? hasNativeSpeechChannel,
    bool? hasForegroundService,
    bool? hasInAppUpdate,
  }) =>
      PlatformCapabilities(
        hasLocalShell: hasLocalShell ?? this.hasLocalShell,
        hasMediaStoreDownload:
            hasMediaStoreDownload ?? this.hasMediaStoreDownload,
        hasNativeSpeechChannel:
            hasNativeSpeechChannel ?? this.hasNativeSpeechChannel,
        hasForegroundService:
            hasForegroundService ?? this.hasForegroundService,
        hasInAppUpdate: hasInAppUpdate ?? this.hasInAppUpdate,
      );
}
