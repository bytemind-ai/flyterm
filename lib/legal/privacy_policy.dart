// SPDX-License-Identifier: GPL-3.0-or-later
// lib/legal/privacy_policy.dart

/// 隐私政策 markdown 静态文案。中英双语。
///
/// 内容修改如属实质性变更（数据收集类型变化、SDK 增减等），必须 bump
/// ConsentPolicy.currentVersion 触发用户重新同意。typo 修复无需 bump。
///
/// 文案由产品/法务 review 后编辑；进入欧盟市场前建议律师过一遍。
abstract class PrivacyPolicy {
  static const String zh = '''
# 隐私政策

**最后更新日期：** 2026-11-04

FlyTerm（"我们"、"本应用"）尊重并保护您的隐私。本政策说明我们如何收集、使用、存储与共享您的信息。

## 我们收集什么

**1. 您主动提供的信息**

- 服务器配置（主机名、端口、用户名）：仅存储在您设备本地的加密数据库中，不上传任何服务器。
- SSH 密钥：仅存储在您设备的安全存储区（iOS Keychain / Android Keystore），不上传任何服务器。
- 密码：同上。

**2. 自动收集的诊断信息（可在设置中关闭）**

- 崩溃日志：发生应用崩溃时，崩溃堆栈、设备型号、系统版本上传至 Sentry，用于修复缺陷。
- 应用性能数据：关键操作（连接、断开、重连）的耗时统计，用于优化性能。
- 关键操作事件：连接尝试 / Paywall 显示 / 内购流程等业务事件标记，用于产品改进。

**3. 我们不收集**

- 您的终端输出内容（远程服务器返回的任何字符）
- 您输入的任何按键 / 命令
- 服务器主机名 / IP / 用户名的明文（仅上传 SHA256 hash 前 8 位）
- 您的位置信息
- 您的通讯录 / 相册 / 麦克风（除非您主动启用语音输入功能）

## 数据存储位置

- 本地数据：您的设备本地，受设备锁屏保护。
- Sentry 诊断数据：Sentry SaaS 服务器（美国 / 欧盟）。保留期 90 天滚动覆盖。

## 您的控制权

- 在「设置」→「隐私偏好」中可关闭崩溃日志上传。
- 在「设置」→「隐私偏好」中可关闭分析数据上传。
- 您可以通过「撤回同意」按钮完全退出应用，下次启动需重新同意。
- 卸载应用即可删除所有本地数据。

## 第三方 SDK

- **Sentry**（崩溃报告 + 性能分析）：https://sentry.io/privacy/
- **Apple App Store / Google Play 计费 SDK**（仅在您购买时调用）：相关数据由 Apple/Google 各自处理。

## 数据出境声明

**Sentry 数据存储位置：** 美国（Sentry SaaS 主数据中心）/ 欧盟（部分用户可选）。
对于中华人民共和国大陆用户、欧盟用户：使用本应用即表示您同意将上述（脱敏后的）崩溃数据传输至境外服务器。
您可以在"设置 → 隐私"中随时关闭崩溃报告，关闭后不再有任何数据上传。

## 支付信息

FlyTerm Pro 一次性买断由 Apple App Store / Google Play 处理。我们不接触、不存储您的：
- 信用卡号
- Apple ID / Google 账号
- 账单地址

仅会收到 Apple/Google 返回的"购买凭证"（receipt），用于本地解锁 Pro 功能。

## 联系我们

问题与反馈：https://github.com/bytemind-ai/flyterm/issues

安全问题请勿公开提交，请通过私密漏洞报告：https://github.com/bytemind-ai/flyterm/security/advisories/new
''';

  static const String en = '''
# Privacy Policy

**Last updated:** 2026-11-04

FlyTerm ("we", "the App") respects and protects your privacy. This policy explains how we collect, use, store, and share your information.

## What We Collect

**1. Information You Provide**

- Server configuration (host, port, username): stored only in an encrypted local database on your device, never uploaded.
- SSH keys: stored only in your device's secure storage (iOS Keychain / Android Keystore), never uploaded.
- Passwords: same as above.

**2. Automatically Collected Diagnostics (opt-out in settings)**

- Crash logs: when the app crashes, the stack trace, device model, and OS version are uploaded to Sentry for bug fixes.
- App performance data: timing of key operations (connect, disconnect, reconnect) for performance optimization.
- Key business events: connection attempts, paywall display, in-app purchase flow markers, for product improvement.

**3. We Do Not Collect**

- Terminal output (anything returned by the remote server)
- Your keystrokes / commands
- Plaintext server host / IP / username (only SHA256 hash, first 8 hex chars)
- Your location
- Your contacts / photos / microphone (unless you explicitly enable voice input)

## Data Storage

- Local data: on your device, protected by device lock.
- Sentry diagnostics: Sentry SaaS servers (US / EU). 90-day rolling retention.

## Your Controls

- Settings → Privacy Preferences → toggle off crash reports.
- Settings → Privacy Preferences → toggle off analytics.
- "Revoke Consent" button exits the app; next launch requires re-consent.
- Uninstalling the app deletes all local data.

## Third-Party SDKs

- **Sentry** (crash reports + performance): https://sentry.io/privacy/
- **Apple App Store / Google Play Billing SDK** (invoked only when you purchase): handled by Apple / Google respectively.

## International Data Transfer

**Sentry data storage location:** United States (Sentry SaaS primary) / EU (some users opt-in).
For users in Mainland China and the European Union: by using the App you consent to the transfer of the above (scrubbed) crash data to servers outside your jurisdiction.
You can disable crash reporting at any time in Settings → Privacy. No data is uploaded once disabled.

## Payment Information

FlyTerm Pro one-time purchase is handled entirely by Apple App Store / Google Play. We do not touch or store:
- Credit card numbers
- Apple ID / Google account
- Billing address

We only receive the purchase receipt returned by Apple/Google, used locally to unlock Pro features.

## Contact

Questions and feedback: https://github.com/bytemind-ai/flyterm/issues

Please do not report security issues publicly; use private vulnerability reporting: https://github.com/bytemind-ai/flyterm/security/advisories/new
''';
}
