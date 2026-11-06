// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  final FlutterSecureStorage _storage;

  SecureStorageService([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _keyPrefix = 'ssh_key_';
  static const _aiKeyPrefix = 'ai_key_';
  static const _passwordPrefix = 'server_pw_';

  Future<void> savePrivateKey(String keyId, String pem) =>
      _storage.write(key: '$_keyPrefix$keyId', value: pem);

  Future<String?> loadPrivateKey(String keyId) =>
      _storage.read(key: '$_keyPrefix$keyId');

  Future<void> deletePrivateKey(String keyId) =>
      _storage.delete(key: '$_keyPrefix$keyId');

  /// Load PEMs for all given key IDs. Returns only non-null results.
  Future<List<String>> loadPrivateKeys(List<String> keyIds) async {
    final results = await Future.wait(keyIds.map(loadPrivateKey));
    return results.whereType<String>().toList();
  }

  Future<void> savePassword(String serverId, String password) =>
      _storage.write(key: '$_passwordPrefix$serverId', value: password);

  Future<String?> loadPassword(String serverId) =>
      _storage.read(key: '$_passwordPrefix$serverId');

  Future<void> deletePassword(String serverId) =>
      _storage.delete(key: '$_passwordPrefix$serverId');

  Future<void> saveFontSize(double size) =>
      _storage.write(key: 'terminal_font_size', value: size.toString());

  Future<double?> loadFontSize() async {
    final s = await _storage.read(key: 'terminal_font_size');
    return s != null ? double.tryParse(s) : null;
  }

  Future<void> saveAIKey(String providerId, String apiKey) =>
      _storage.write(key: '$_aiKeyPrefix$providerId', value: apiKey);

  Future<String?> loadAIKey(String providerId) =>
      _storage.read(key: '$_aiKeyPrefix$providerId');

  Future<void> deleteAIKey(String providerId) =>
      _storage.delete(key: '$_aiKeyPrefix$providerId');

  Future<void> saveSftpDownloadDir(String value) =>
      _storage.write(key: 'sftp_download_dir', value: value);

  Future<String?> loadSftpDownloadDir() =>
      _storage.read(key: 'sftp_download_dir');

  Future<void> saveSftpCustomDownloadPath(String value) =>
      _storage.write(key: 'sftp_custom_download_path', value: value);

  Future<String?> loadSftpCustomDownloadPath() =>
      _storage.read(key: 'sftp_custom_download_path');

  Future<void> saveTerminalTheme(String value) =>
      _storage.write(key: 'terminal_theme', value: value);

  Future<String?> loadTerminalTheme() =>
      _storage.read(key: 'terminal_theme');

  Future<void> saveTerminalCursorStyle(String value) =>
      _storage.write(key: 'terminal_cursor_style', value: value);

  Future<String?> loadTerminalCursorStyle() =>
      _storage.read(key: 'terminal_cursor_style');

  /// 光标闪烁开关。存 'true'/'false' —— 未存过时读取返回 null，由
  /// `TerminalSettings` 用默认值兜底。
  Future<void> saveTerminalCursorBlink(bool value) =>
      _storage.write(key: 'terminal_cursor_blink', value: value.toString());

  Future<bool?> loadTerminalCursorBlink() async {
    final v = await _storage.read(key: 'terminal_cursor_blink');
    if (v == null) return null;
    return v == 'true';
  }

  /// 选中态颜色开关。'false' 表示用主题自带的 selection 色。
  Future<void> saveTerminalSelectionColor(String value) =>
      _storage.write(key: 'terminal_selection_color', value: value);

  Future<String?> loadTerminalSelectionColor() =>
      _storage.read(key: 'terminal_selection_color');

  Future<void> saveTerminalCursorDefaultMigrationDone() =>
      _storage.write(key: 'terminal_cursor_default_migration_v1', value: 'true');

  Future<bool> loadTerminalCursorDefaultMigrationDone() async {
    final s = await _storage.read(key: 'terminal_cursor_default_migration_v1');
    return s == 'true';
  }

  Future<void> saveDangerousCommandGuard(bool enabled) =>
      _storage.write(key: 'dangerous_cmd_guard', value: enabled.toString());

  Future<bool?> loadDangerousCommandGuard() async {
    final s = await _storage.read(key: 'dangerous_cmd_guard');
    return s != null ? s == 'true' : null;
  }

  Future<void> saveKeyboardTriggerMode(String value) =>
      _storage.write(key: 'keyboard_trigger_mode', value: value);

  Future<String?> loadKeyboardTriggerMode() =>
      _storage.read(key: 'keyboard_trigger_mode');

  Future<void> saveSshCompression(bool enabled) =>
      _storage.write(key: 'ssh_compression', value: enabled.toString());

  Future<bool?> loadSshCompression() async {
    final s = await _storage.read(key: 'ssh_compression');
    return s != null ? s == 'true' : null;
  }

  Future<void> saveBackgroundKeepAlive(bool enabled) =>
      _storage.write(key: 'background_keep_alive', value: enabled.toString());

  Future<bool?> loadBackgroundKeepAlive() async {
    final s = await _storage.read(key: 'background_keep_alive');
    return s != null ? s == 'true' : null;
  }

  Future<void> saveCommandCompletion(bool enabled) =>
      _storage.write(key: 'command_completion', value: enabled.toString());

  Future<bool?> loadCommandCompletion() async {
    final s = await _storage.read(key: 'command_completion');
    return s != null ? s == 'true' : null;
  }

  Future<void> saveFontFamily(String family) =>
      _storage.write(key: 'terminal_font_family', value: family);

  Future<String?> loadFontFamily() =>
      _storage.read(key: 'terminal_font_family');

  Future<void> saveLineHeight(double h) =>
      _storage.write(key: 'terminal_line_height', value: h.toString());

  Future<double?> loadLineHeight() async {
    final s = await _storage.read(key: 'terminal_line_height');
    return s != null ? double.tryParse(s) : null;
  }

  // FET (Floating Edge Toggle) persistence
  Future<void> saveFetY(double v) =>
      _storage.write(key: 'fet_y', value: v.toString());

  Future<String?> loadFetY() => _storage.read(key: 'fet_y');

  Future<void> saveFetHidden(bool v) =>
      _storage.write(key: 'fet_hidden', value: v.toString());

  Future<String?> loadFetHidden() => _storage.read(key: 'fet_hidden');

  Future<void> saveFetOpacity(double v) =>
      _storage.write(key: 'fet_opacity', value: v.toString());

  Future<String?> loadFetOpacity() => _storage.read(key: 'fet_opacity');

  Future<void> saveFetAutoFade(bool v) =>
      _storage.write(key: 'fet_auto_fade', value: v.toString());

  Future<String?> loadFetAutoFade() => _storage.read(key: 'fet_auto_fade');

  Future<void> saveFetEnabled(bool v) =>
      _storage.write(key: 'fet_enabled', value: v.toString());

  Future<String?> loadFetEnabled() => _storage.read(key: 'fet_enabled');

  Future<void> saveFetOnboardingShown(bool v) =>
      _storage.write(key: 'fet_onboarding_shown', value: v.toString());

  Future<String?> loadFetOnboardingShown() =>
      _storage.read(key: 'fet_onboarding_shown');
}
