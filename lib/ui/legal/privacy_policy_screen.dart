// SPDX-License-Identifier: GPL-3.0-or-later
// lib/ui/legal/privacy_policy_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../l10n/l10n.dart';
import '../../legal/privacy_policy.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final markdown = locale.languageCode == 'zh' ? PrivacyPolicy.zh : PrivacyPolicy.en;
    return Scaffold(
      appBar: AppBar(title: Text(l.privacyPolicyTitle)),
      body: Markdown(data: markdown, padding: const EdgeInsets.all(16), selectable: true),
    );
  }
}
