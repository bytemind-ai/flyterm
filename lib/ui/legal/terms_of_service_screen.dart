// SPDX-License-Identifier: GPL-3.0-or-later
// lib/ui/legal/terms_of_service_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../l10n/l10n.dart';
import '../../legal/terms_of_service.dart';

class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final markdown = locale.languageCode == 'zh' ? TermsOfService.zh : TermsOfService.en;
    return Scaffold(
      appBar: AppBar(title: Text(l.termsOfServiceTitle)),
      body: Markdown(data: markdown, padding: const EdgeInsets.all(16), selectable: true),
    );
  }
}
