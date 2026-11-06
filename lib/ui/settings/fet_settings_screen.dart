// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';

class FetSettingsScreen extends StatelessWidget {
  const FetSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    return Scaffold(
      appBar: AppBar(
        title: Text(l.fetSettingsTitle),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        children: [
          _SectionHeader(l.fetSettingsTitle),
          SwitchListTile(
            title: Text(l.fetSettingsShow),
            subtitle: Text(
              l.fetSettingsShowSubtitle,
              style: const TextStyle(fontSize: 11.5),
            ),
            value: settings.fetEnabled,
            onChanged: (v) => settings.setFetEnabled(v),
            dense: true,
            visualDensity: VisualDensity.compact,
          ),
          SwitchListTile(
            title: Text(l.fetSettingsAutoHide),
            subtitle: Text(
              l.fetSettingsAutoHideSubtitle,
              style: const TextStyle(fontSize: 11.5),
            ),
            value: settings.fetAutoFade,
            onChanged:
                settings.fetEnabled
                    ? (v) => settings.setFetAutoFade(v)
                    : null,
            dense: true,
            visualDensity: VisualDensity.compact,
          ),
          ListTile(
            title: Text(l.fetSettingsOpacity),
            enabled: settings.fetEnabled,
            subtitle: Slider(
              value: settings.fetOpacity,
              min: 0.4,
              max: 0.8,
              divisions: 8,
              label: '${(settings.fetOpacity * 100).round()}%',
              onChanged:
                  settings.fetEnabled
                      ? (v) => settings.setFetOpacity(v)
                      : null,
            ),
            dense: true,
            visualDensity: VisualDensity.compact,
          ),
          ListTile(
            title: Text(l.fetSettingsResetPosition),
            subtitle: Text(
              l.fetSettingsResetPositionSubtitle,
              style: const TextStyle(fontSize: 11.5),
            ),
            enabled: settings.fetEnabled,
            trailing: const Icon(Icons.refresh, size: 20),
            dense: true,
            visualDensity: VisualDensity.compact,
            onTap:
                settings.fetEnabled
                    ? () async {
                      await settings.setFetY(0.5);
                      await settings.setFetHidden(false);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l.fetSettingsResetDone)),
                        );
                      }
                    }
                    : null,
          ),
        ],
      ),
    );
  }
}

/// JetBrainsMono uppercase 小标题，复用 Industrial Console 范式。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  static bool _isAscii(String s) {
    for (final c in s.codeUnits) {
      if (c > 0x7E) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final ascii = _isAscii(label);
    final color = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        ascii ? label.toUpperCase() : label,
        style: TextStyle(
          fontFamily: ascii ? 'JetBrainsMono' : null,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: ascii ? 1.2 : 0,
          height: 1.0,
        ),
      ),
    );
  }
}
