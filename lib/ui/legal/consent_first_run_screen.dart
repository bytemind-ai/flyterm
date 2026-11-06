// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../consent/consent_manager.dart';
import '../../l10n/l10n.dart';
import 'privacy_policy_screen.dart';
import 'terms_of_service_screen.dart';

/// 首次启动同意页 — Industrial Monitor Console 风格，致敬终端工具范式。
/// 严格模式：用户必须 Agree 或 Decline=退出（PopScope 阻止返回手势）。
///
/// 视觉结构：
///   • Hero logo (Icons.terminal_outlined + mint accent 方块)
///   • 主标题 + 柔化副标题
///   • 3 个 highlight card（icon + title + desc）信息扫读
///   • 隐私/ToS 链接降级为 inline underline
///   • Crash opt-in 单行 checkbox
///   • FilledButton "Continue" 主操作（mint accent）
///   • 底部小字 outlined "Don't agree? Exit" 弱化 decline
class ConsentFirstRunScreen extends StatefulWidget {
  const ConsentFirstRunScreen({super.key});

  @override
  State<ConsentFirstRunScreen> createState() => _ConsentFirstRunScreenState();
}

class _ConsentFirstRunScreenState extends State<ConsentFirstRunScreen> {
  static const _accent = Color(0xFF00C896);
  bool _crashOptIn = true;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Hero logo
                Center(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: _accent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _accent, width: 1),
                    ),
                    child: const Icon(
                      Icons.terminal_outlined,
                      size: 32,
                      color: _accent,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                // 主标题
                Text(
                  l.consentTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                // 副标题
                Text(
                  l.consentSubtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurface.withOpacity(0.6),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 28),
                // 3 个 highlight card
                _HighlightGroup(
                  items: [
                    _HighlightItem(
                      icon: Icons.lock_outline,
                      title: l.consentHighlightKeysTitle,
                      desc: l.consentHighlightKeysDesc,
                    ),
                    _HighlightItem(
                      icon: Icons.bug_report_outlined,
                      title: l.consentHighlightCrashTitle,
                      desc: l.consentHighlightCrashDesc,
                    ),
                    _HighlightItem(
                      icon: Icons.tune,
                      title: l.consentHighlightControlTitle,
                      desc: l.consentHighlightControlDesc,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // 隐私/ToS inline 链接（boilerplate 文案）
                Text.rich(
                  TextSpan(
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurface.withOpacity(0.65),
                      height: 1.45,
                    ),
                    children: [
                      TextSpan(text: '${l.consentAgreeBoilerplate} '),
                      _linkSpan(
                        context,
                        l.consentPrivacyLink,
                        const PrivacyPolicyScreen(),
                      ),
                      TextSpan(text: ' ${l.consentAgreeBoilerplateAnd} '),
                      _linkSpan(
                        context,
                        l.consentTosLink,
                        const TermsOfServiceScreen(),
                      ),
                      const TextSpan(text: '.'),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                // 极简 checkbox 一行
                InkWell(
                  onTap: () => setState(() => _crashOptIn = !_crashOptIn),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Checkbox(
                          value: _crashOptIn,
                          onChanged: (v) =>
                              setState(() => _crashOptIn = v ?? true),
                          visualDensity: VisualDensity.compact,
                          activeColor: _accent,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            l.consentCrashOptIn,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurface.withOpacity(0.8),
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // 主按钮 Continue（FilledButton + mint）
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _onAccept,
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      l.consentAcceptButton,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // 弱化 decline 行
                Center(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        l.consentDeclineHint,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: cs.onSurface.withOpacity(0.5),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _onDecline,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          l.consentDeclineExit,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: cs.error.withOpacity(0.85),
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InlineSpan _linkSpan(BuildContext ctx, String label, Widget page) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: GestureDetector(
        onTap: () => Navigator.of(ctx).push(
          MaterialPageRoute(builder: (_) => page),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            color: _accent,
            decoration: TextDecoration.underline,
            decorationColor: _accent.withOpacity(0.6),
          ),
        ),
      ),
    );
  }

  Future<void> _onAccept() async {
    await ConsentManager.instance.accept();
    await ConsentManager.instance.setCrashReportingEnabled(_crashOptIn);
    // This screen is the *content* of the app's single initial route (a
    // Consumer<ConsentManager> in app.dart) — it is not pushed. accept() fires
    // notifyListeners(), so the Consumer rebuilds into HomeScreen on its own.
    // An unconditional pop() here would pop that only route and leave an empty
    // navigator → a pure-black screen. Only pop when this screen was actually
    // pushed on top of something (canPop == true).
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  void _onDecline() {
    SystemNavigator.pop();
  }
}

class _HighlightGroup extends StatelessWidget {
  const _HighlightGroup({required this.items});
  final List<_HighlightItem> items;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceVariant.withOpacity(0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: cs.onSurface.withOpacity(0.08),
          width: 0.5,
        ),
      ),
      child: Column(
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.5,
                indent: 56,
                color: cs.onSurface.withOpacity(0.08),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: const Color(0xFF00C896).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      items[i].icon,
                      size: 16,
                      color: const Color(0xFF00C896),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          items[i].title,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          items[i].desc,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: cs.onSurface.withOpacity(0.6),
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HighlightItem {
  const _HighlightItem({
    required this.icon,
    required this.title,
    required this.desc,
  });
  final IconData icon;
  final String title;
  final String desc;
}
