// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../ssh/host_key_verifier.dart';

/// Modal dialog used by [DefaultHostKeyVerifier]'s prompt path. Two
/// flavours selected by [kind]:
///
///   • [HostKeyPromptKind.trustOnFirstUse] — neutral confirmation,
///     shows the (host, port, type) and the new fingerprint.
///   • [HostKeyPromptKind.mismatch] — red warning that the host key
///     differs from the stored one, side-by-side fingerprints. The
///     primary action is intentionally "拒绝" to nudge users away
///     from blindly accepting (could be MITM).
class HostKeyDialog extends StatelessWidget {
  final String host;
  final int port;
  final String keyType;
  final String fingerprintMd5;
  final HostKeyPromptKind kind;
  final String? expectedFingerprintMd5;

  const HostKeyDialog({
    super.key,
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprintMd5,
    required this.kind,
    this.expectedFingerprintMd5,
  });

  static Future<HostKeyDecision> show(BuildContext context, {
    required String host,
    required int port,
    required String keyType,
    required String fingerprintMd5,
    required HostKeyPromptKind kind,
    String? expectedFingerprintMd5,
  }) async {
    final result = await showDialog<HostKeyDecision>(
      context: context,
      barrierDismissible: false,
      builder: (_) => HostKeyDialog(
        host: host,
        port: port,
        keyType: keyType,
        fingerprintMd5: fingerprintMd5,
        kind: kind,
        expectedFingerprintMd5: expectedFingerprintMd5,
      ),
    );
    return result ?? HostKeyDecision.reject;
  }

  bool get _isMismatch => kind == HostKeyPromptKind.mismatch;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final color = _isMismatch ? theme.colorScheme.error : theme.colorScheme.primary;
    return AlertDialog(
      icon: Icon(
        _isMismatch ? Icons.warning_amber_rounded : Icons.shield_outlined,
        color: color,
        size: 36,
      ),
      title: Text(
        _isMismatch ? l.hostKeyMismatchTitle : l.hostKeyTofuTitle,
        style: TextStyle(color: color),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isMismatch)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                l.hostKeyMismatchBody,
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(l.hostKeyTofuBody),
            ),
          _kv(l.hostKeyHost, '$host:$port'),
          _kv(l.hostKeyType, keyType),
          if (_isMismatch && expectedFingerprintMd5 != null) ...[
            const SizedBox(height: 8),
            _kv(l.hostKeyExpected, expectedFingerprintMd5!,
                mono: true, color: theme.colorScheme.outline),
            _kv(l.hostKeyActual, fingerprintMd5,
                mono: true, color: color),
          ] else ...[
            const SizedBox(height: 8),
            _kv(l.hostKeyFingerprint, fingerprintMd5, mono: true),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(HostKeyDecision.reject),
          child: Text(l.hostKeyReject),
        ),
        TextButton(
          style: _isMismatch
              ? null
              : TextButton.styleFrom(foregroundColor: theme.colorScheme.primary),
          onPressed: () =>
              Navigator.of(context).pop(HostKeyDecision.accept),
          child: Text(_isMismatch ? l.hostKeyAcceptAnyway : l.hostKeyAccept),
        ),
      ],
    );
  }

  Widget _kv(String label, String value, {bool mono = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: color,
              fontFamily: mono ? 'JetBrainsMono' : null,
              fontFamilyFallback: mono ? const ['monospace'] : null,
            ),
            softWrap: true,
          ),
        ],
      ),
    );
  }
}
