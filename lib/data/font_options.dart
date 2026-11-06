// SPDX-License-Identifier: GPL-3.0-or-later
class FontOptions {
  /// Family ids; order matters (used by Settings dropdown).
  /// 'system' is a sentinel that maps to 'monospace' in TextStyle/TerminalStyle
  /// (Flutter resolves to platform default monospace).
  /// 'CourierPrime' is an OFL-licensed Courier-style monospace bundled in
  /// assets/fonts/ (chosen over Microsoft's "Courier New" which is non-free
  /// and not present on Android by default).
  static const builtInFamilies = <String>[
    'JetBrainsMono',
    'CourierPrime',
    'system',
  ];

  static bool isBuiltInFamily(String id) => builtInFamilies.contains(id);

  static String familyDisplayName(String id) {
    switch (id) {
      case 'JetBrainsMono':
        return 'JetBrains Mono';
      case 'CourierPrime':
        return 'Courier Prime';
      case 'system':
        return '系统默认';
      default:
        return id;
    }
  }
}
