// SPDX-License-Identifier: GPL-3.0-or-later
// lib/legal/terms_of_service.dart

/// 服务条款 markdown 静态文案。中英双语。
abstract class TermsOfService {
  static const String zh = '''
# 服务条款

**最后更新日期：** 2026-11-04

欢迎使用 FlyTerm。使用本应用即表示您同意以下条款。

## 1. 服务说明

FlyTerm 是一款移动 SSH / Mosh / QUIC 终端应用，提供：
- 远程服务器连接管理
- 终端会话与多标签
- 文件传输（SFTP）
- 端口转发（Tunnel）
- AI 辅助（Pro 功能）

## 2. 用户责任

您同意：
- 仅将本应用用于合法目的，遵守目标服务器所在地及您所在地的法律法规
- 不利用本应用进行未授权的远程访问、入侵或数据窃取
- 妥善保管您的 SSH 密钥与密码，本应用不对密钥泄漏导致的损失负责

## 3. 内购与退款

- FlyTerm Pro 为一次性买断（\$14.99 或对应区域价格）
- 购买后永久解锁 Pro 功能
- 退款政策依 Apple App Store / Google Play 各自规则
- 我们不存储您的支付信息，全部由 Apple / Google 处理

## 4. 知识产权

本应用及其内容归 FlyTerm 团队所有。您获得的是有限的、非独占的、不可转让的使用许可。

## 5. 免责声明

本应用按"现状"提供，我们不保证：
- 应用永远无错误或无中断
- 远程服务器连接成功率
- 任何特定功能在所有环境下可用

我们不对因使用本应用造成的任何直接、间接、附带、特殊损失负责。

## 6. 终止

我们保留在您违反本条款时终止服务的权利。您可以随时卸载应用终止使用。

## 7. 条款变更

我们可能更新本条款。重大变更时会通过应用内弹窗通知，您需要重新同意。

## 9. 出口管制 / 合规

FlyTerm 遵守美国 BIS 出口管制规则（ECCN 5D992.c）。您**不得**从以下国家或地区使用、下载本应用：
- 古巴、伊朗、朝鲜、叙利亚、克里米亚地区
- 美国 OFAC SDN 制裁名单上的实体或个人

您同时不得使用本应用接入位于上述国家或地区的服务器。

## 10. SSH 远程访问的合法使用

本应用是一个 SSH/Mosh/QUIC 客户端工具。您对您所连接的远程服务器需具备：
- 合法的访问授权（账号 / 私钥 / 服务器管理员授权）
- 遵守目标服务器所在地的法律法规

FlyTerm 团队不对您的连接目标做任何审查或限制；同样，您因未授权访问、突破访问控制、绕过防火墙、数据窃取等行为造成的法律后果，由您本人承担。

## 11. 适用法律

本条款受中华人民共和国法律管辖（适用于中国大陆用户）/ 适用您所在地的法律（其他地区用户）。

## 12. 联系方式

https://github.com/bytemind-ai/flyterm/issues
''';

  static const String en = '''
# Terms of Service

**Last updated:** 2026-11-04

Welcome to FlyTerm. By using the App you agree to these terms.

## 1. Service Description

FlyTerm is a mobile SSH / Mosh / QUIC terminal app providing:
- Remote server connection management
- Terminal sessions and multi-tab
- File transfer (SFTP)
- Port forwarding (Tunnel)
- AI assistance (Pro feature)

## 2. User Responsibilities

You agree:
- To use the App only for lawful purposes, complying with applicable laws of both your jurisdiction and the target server's jurisdiction
- Not to use the App for unauthorized remote access, intrusion, or data theft
- To safeguard your SSH keys and passwords; the App is not liable for losses from key leaks

## 3. In-App Purchases and Refunds

- FlyTerm Pro is a one-time purchase (\$14.99 or regional equivalent)
- Pro features are unlocked permanently after purchase
- Refunds follow Apple App Store / Google Play policies
- We do not store your payment info; handled entirely by Apple / Google

## 4. Intellectual Property

The App and its contents are owned by the FlyTerm team. You receive a limited, non-exclusive, non-transferable license to use.

## 5. Disclaimer

The App is provided "as is". We do not warrant:
- Bug-free or uninterrupted operation
- Connection success rate to remote servers
- Availability of any specific feature in all environments

We are not liable for any direct, indirect, incidental, or special damages from using the App.

## 6. Termination

We reserve the right to terminate service if you violate these terms. You may uninstall the App to terminate use at any time.

## 7. Changes to Terms

We may update these terms. Material changes will be notified via in-app dialog, requiring re-consent.

## 9. Export Control / Compliance

FlyTerm complies with U.S. BIS export control regulations (ECCN 5D992.c). You **must not** use or download the App from:
- Cuba, Iran, North Korea, Syria, Crimea
- Entities or individuals on the U.S. OFAC SDN List

You also must not use the App to connect to servers located in the above jurisdictions.

## 10. Lawful Use of SSH Remote Access

The App is an SSH/Mosh/QUIC client tool. You are responsible for ensuring you have:
- Lawful authorization to access the target server (account / private key / admin consent)
- Compliance with applicable laws in the target server's jurisdiction

The FlyTerm team does not audit or restrict your connection targets. Legal consequences from unauthorized access, breaking access controls, bypassing firewalls, or data theft are entirely your responsibility.

## 11. Governing Law

These terms are governed by the laws of the People's Republic of China (for Mainland China users) / the laws of your jurisdiction (other regions).

## 12. Contact

https://github.com/bytemind-ai/flyterm/issues
''';
}
