// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:ui' show Color;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'secure_storage.dart';
import 'font_options.dart';
import '../ui/terminal/terminal_themes.dart';

enum SftpDownloadDir { downloads, documents, custom }

enum KeyboardTriggerMode { singleTap, doubleTap, iconButton }

enum TerminalCursorStyle { defaultStyle, block, underline, verticalBar }

class TerminalSettings extends ChangeNotifier {
  static const double defaultFontSize = 8.0;
  static const double minFontSize = 6.0;
  static const double maxFontSize = 28.0;
  static const String defaultFontFamily = 'JetBrainsMono';
  static const double defaultLineHeight = 1.2;
  static const double minLineHeight = 1.0;
  static const double maxLineHeight = 2.0;

  final SecureStorageService _storage;
  double _fontSize = defaultFontSize;
  SftpDownloadDir _sftpDownloadDir = SftpDownloadDir.downloads;
  String? _sftpCustomDownloadPath;
  AppTerminalTheme _terminalTheme = AppTerminalTheme.defaultDark;
  TerminalCursorStyle _cursorStyle = TerminalCursorStyle.defaultStyle;

  /// 光标是否闪烁。iTerm2 的默认是「闪烁」，这里也对齐。
  ///
  /// 为什么做成开关而不是直接沿用引擎默认：闪烁在手机上是个**双面**
  /// 特性 —— 它让光标好找，但在长命令编辑时持续重绘，是省电模式下的
  /// 额外开销。iTerm2 给这个开关，我们跟着给。
  bool _cursorBlink = true;

  /// 选中态颜色。null = 用当前主题的 `selection`；非 null 时覆盖它。
  ///
  /// 存 null 而不是「立刻固化一份副本」：主题换掉时，未自定义的选中色
  /// 应当跟着主题走 —— 否则切到 Solarized Light 会配着一个从暗色主题
  /// 抄来的浅色高亮，看不见。
  Color? _selectionColor;
  bool _dangerousCommandGuard = true;
  // In-memory only — gets reset on app restart. Toggled by tapping the
  // settings version tile 7 times in a row (Android-style "developer mode"
  // gesture).  Renders a floating diagnostic overlay over the active terminal
  // tab when true.
  bool _debugOverlay = false;
  KeyboardTriggerMode _keyboardTrigger = KeyboardTriggerMode.singleTap;
  /// Whether to advertise zlib compression during SSH key exchange.
  /// Default true — saves bandwidth on slow/metered networks (full-
  /// screen redraws, ls/cat output halve in size). Toggle off if the
  /// CPU cost outweighs savings (LAN, very fast Wi-Fi).
  bool _sshCompression = true;
  /// Whether to keep terminal sessions alive in the background via an
  /// Android foreground service. Default false — the foreground-service
  /// notification is mandatory on Android 8.0+ and cannot be hidden
  /// (importance only affects intrusiveness, not visibility in the shade).
  /// A permanent notification on install by default is not acceptable;
  /// users who want background keep-alive opt in explicitly.
  bool _backgroundKeepAlive = false;
  /// Whether to suggest commands from local history + remote `compgen`
  /// while typing. Default true — this is purely local/offline (no AI
  /// provider involved), so there's no reason to gate it behind AI
  /// configuration. This is the only switch for the feature — the old
  /// AI-gated duplicate in settings was removed.
  bool _commandCompletion = true;
  String _fontFamily = defaultFontFamily;
  double _lineHeight = defaultLineHeight;

  // FET (Floating Edge Toggle) fields
  double _fetY = 0.5;
  bool _fetHidden = false;
  double _fetOpacity = 0.6;
  bool _fetAutoFade = true;
  bool _fetEnabled = true;
  bool _fetOnboardingShown = false;

  /// Debounces secure-storage writes for [setFontSize]. Pinch-to-zoom
  /// fires at the touch sample rate (~120 Hz on modern devices); each
  /// FlutterSecureStorage.write is an async platform-channel call to
  /// Android Keystore / iOS Keychain. Without debounce a long pinch
  /// queues thousands of writes, blocks the UI thread, and on top of
  /// xterm's per-frame relayout in alt-buffer mode (e.g. Claude
  /// /resume picker) crashes the app. We notify listeners immediately
  /// (so the UI tracks the gesture) and persist only after 250 ms of
  /// stillness.
  Timer? _fontSaveDebounce;
  Timer? _lineHeightSaveDebounce;

  TerminalSettings(this._storage);

  double get fontSize => _fontSize;

  SftpDownloadDir get sftpDownloadDir => _sftpDownloadDir;
  String? get sftpCustomDownloadPath => _sftpCustomDownloadPath;

  /// True when the "downloads" destination is selected — single-file SFTP
  /// downloads and config exports should be published to the user-visible
  /// public Downloads collection (Download/FlyTerm) rather than left in the
  /// app-private sandbox that resolveDownloadDir() returns.
  bool get downloadsToPublicStore =>
      _sftpDownloadDir == SftpDownloadDir.downloads;
  AppTerminalTheme get terminalTheme => _terminalTheme;
  TerminalCursorStyle get cursorStyle => _cursorStyle;
  bool get cursorBlink => _cursorBlink;
  Color? get selectionColor => _selectionColor;
  bool get dangerousCommandGuard => _dangerousCommandGuard;
  bool get debugOverlay => _debugOverlay;
  KeyboardTriggerMode get keyboardTrigger => _keyboardTrigger;
  bool get sshCompression => _sshCompression;
  bool get backgroundKeepAlive => _backgroundKeepAlive;
  bool get commandCompletion => _commandCompletion;
  String get fontFamily => _fontFamily;
  double get lineHeight => _lineHeight;

  // FET getters
  double get fetY => _fetY;
  bool get fetHidden => _fetHidden;
  double get fetOpacity => _fetOpacity;
  bool get fetAutoFade => _fetAutoFade;
  bool get fetEnabled => _fetEnabled;
  bool get fetOnboardingShown => _fetOnboardingShown;

  /// Toggle the floating debug overlay on/off. In-memory only — no persistence.
  void toggleDebugOverlay() {
    _debugOverlay = !_debugOverlay;
    notifyListeners();
  }

  Future<void> load() async {
    final savedSize = await _storage.loadFontSize();
    if (savedSize != null) {
      _fontSize = savedSize.clamp(minFontSize, maxFontSize);
    }
    final savedDir = await _storage.loadSftpDownloadDir();
    if (savedDir != null) {
      _sftpDownloadDir = SftpDownloadDir.values.firstWhere(
        (e) => e.name == savedDir,
        orElse: () => SftpDownloadDir.downloads,
      );
    }
    _sftpCustomDownloadPath = await _storage.loadSftpCustomDownloadPath();
    final savedTheme = await _storage.loadTerminalTheme();
    if (savedTheme != null) {
      _terminalTheme = AppTerminalTheme.values.firstWhere(
        (e) => e.name == savedTheme,
        orElse: () => AppTerminalTheme.defaultDark,
      );
    }
    final savedCursorStyle = await _storage.loadTerminalCursorStyle();
    if (savedCursorStyle != null) {
      final migrated = await _storage.loadTerminalCursorDefaultMigrationDone();
      // Older cursor builds used verticalBar as the implicit default and wrote
      // it to secure storage during testing.  After reintroducing the original
      // xterm cursor as "Default", migrate that legacy implicit value once so
      // ordinary shell/opencode users get the original cursor back.  If the user
      // selects verticalBar again later, the migration flag prevents changing it.
      if (!migrated && savedCursorStyle == TerminalCursorStyle.verticalBar.name) {
        _cursorStyle = TerminalCursorStyle.defaultStyle;
        await _storage.saveTerminalCursorStyle(_cursorStyle.name);
        await _storage.saveTerminalCursorDefaultMigrationDone();
      } else {
        _cursorStyle = TerminalCursorStyle.values.firstWhere(
          (e) => e.name == savedCursorStyle,
          orElse: () => TerminalCursorStyle.defaultStyle,
        );
        if (!migrated) await _storage.saveTerminalCursorDefaultMigrationDone();
      }
    }
    final savedGuard = await _storage.loadDangerousCommandGuard();
    if (savedGuard != null) _dangerousCommandGuard = savedGuard;

    final savedBlink = await _storage.loadTerminalCursorBlink();
    if (savedBlink != null) _cursorBlink = savedBlink;

    final savedSelection = await _storage.loadTerminalSelectionColor();
    if (savedSelection != null && savedSelection.isNotEmpty) {
      // 存的是 8 位 AARRGGBB。解析失败（旧版本写的脏值 / 手工改坏）
      // 就当没设过 —— 宁可用主题自带的，也不要拿一个乱色值去渲染。
      final parsed = int.tryParse(savedSelection, radix: 16);
      if (parsed != null) _selectionColor = Color(parsed);
    }
    final savedTrigger = await _storage.loadKeyboardTriggerMode();
    if (savedTrigger != null) {
      _keyboardTrigger = KeyboardTriggerMode.values.firstWhere(
        (e) => e.name == savedTrigger,
        orElse: () => KeyboardTriggerMode.singleTap,
      );
    }
    final savedCompression = await _storage.loadSshCompression();
    if (savedCompression != null) _sshCompression = savedCompression;
    final savedKeepAlive = await _storage.loadBackgroundKeepAlive();
    if (savedKeepAlive != null) _backgroundKeepAlive = savedKeepAlive;
    final savedCommandCompletion = await _storage.loadCommandCompletion();
    if (savedCommandCompletion != null) {
      _commandCompletion = savedCommandCompletion;
    }
    final savedFamily = await _storage.loadFontFamily();
    if (savedFamily != null && FontOptions.isBuiltInFamily(savedFamily)) {
      _fontFamily = savedFamily;
    }
    final savedLineHeight = await _storage.loadLineHeight();
    if (savedLineHeight != null) {
      _lineHeight = savedLineHeight.clamp(minLineHeight, maxLineHeight);
    }
    _fetY = double.tryParse(await _storage.loadFetY() ?? '') ?? 0.5;
    _fetHidden = (await _storage.loadFetHidden()) == 'true';
    _fetOpacity = double.tryParse(await _storage.loadFetOpacity() ?? '') ?? 0.6;
    final autoFadeVal = await _storage.loadFetAutoFade();
    _fetAutoFade = autoFadeVal == null ? true : autoFadeVal == 'true';
    final enabledVal = await _storage.loadFetEnabled();
    _fetEnabled = enabledVal == null ? true : enabledVal == 'true';
    _fetOnboardingShown = (await _storage.loadFetOnboardingShown()) == 'true';
    notifyListeners();
  }

  Future<void> setFontSize(double size) async {
    final clamped = size.clamp(minFontSize, maxFontSize);
    if (clamped == _fontSize) return;
    _fontSize = clamped;
    notifyListeners();
    _fontSaveDebounce?.cancel();
    _fontSaveDebounce = Timer(const Duration(milliseconds: 250), () {
      _storage.saveFontSize(_fontSize);
    });
  }

  Future<void> setFontFamily(String family) async {
    if (family == _fontFamily) return;
    _fontFamily = family;
    notifyListeners();
    await _storage.saveFontFamily(family);
  }

  Future<void> setLineHeight(double h) async {
    final clamped = h.clamp(minLineHeight, maxLineHeight);
    if (clamped == _lineHeight) return;
    _lineHeight = clamped;
    notifyListeners();
    _lineHeightSaveDebounce?.cancel();
    _lineHeightSaveDebounce = Timer(const Duration(milliseconds: 250), () {
      _storage.saveLineHeight(_lineHeight);
    });
  }

  @override
  void dispose() {
    if (_fontSaveDebounce?.isActive ?? false) {
      _fontSaveDebounce!.cancel();
      // Best-effort flush of the pending font size — fire-and-forget,
      // since dispose is synchronous. The platform channel will accept
      // it; whether it lands before process exit is up to the OS.
      _storage.saveFontSize(_fontSize);
    }
    if (_lineHeightSaveDebounce?.isActive ?? false) {
      _lineHeightSaveDebounce!.cancel();
      _storage.saveLineHeight(_lineHeight);
    }
    super.dispose();
  }

  Future<void> setSftpDownloadDir(SftpDownloadDir dir) async {
    if (dir == _sftpDownloadDir) return;
    _sftpDownloadDir = dir;
    notifyListeners();
    await _storage.saveSftpDownloadDir(dir.name);
  }

  Future<void> setTerminalTheme(AppTerminalTheme t) async {
    if (t == _terminalTheme) return;
    _terminalTheme = t;
    notifyListeners();
    await _storage.saveTerminalTheme(t.name);
  }

  Future<void> setCursorStyle(TerminalCursorStyle style) async {
    if (style == _cursorStyle) return;
    _cursorStyle = style;
    notifyListeners();
    await _storage.saveTerminalCursorStyle(style.name);
  }

  Future<void> setCursorBlink(bool enabled) async {
    if (enabled == _cursorBlink) return;
    _cursorBlink = enabled;
    notifyListeners();
    await _storage.saveTerminalCursorBlink(enabled);
  }

  /// 设选中态颜色。[color] 为 null 表示「跟随主题」。
  Future<void> setSelectionColor(Color? color) async {
    if (color == _selectionColor) return;
    _selectionColor = color;
    notifyListeners();
    if (color == null) {
      await _storage.saveTerminalSelectionColor('');
    } else {
      // 存 8 位 hex（AARRGGBB）—— 选中色带 alpha，丢精度会让半透明高亮
      // 变成不透明的实心块，把底下的文字遮住。
      await _storage.saveTerminalSelectionColor(
        color.toARGB32().toRadixString(16).padLeft(8, '0'),
      );
    }
  }

  Future<void> setDangerousCommandGuard(bool enabled) async {
    if (enabled == _dangerousCommandGuard) return;
    _dangerousCommandGuard = enabled;
    notifyListeners();
    await _storage.saveDangerousCommandGuard(enabled);
  }

  Future<void> setKeyboardTrigger(KeyboardTriggerMode mode) async {
    if (mode == _keyboardTrigger) return;
    _keyboardTrigger = mode;
    notifyListeners();
    await _storage.saveKeyboardTriggerMode(mode.name);
  }

  Future<void> setSshCompression(bool enabled) async {
    if (enabled == _sshCompression) return;
    _sshCompression = enabled;
    notifyListeners();
    await _storage.saveSshCompression(enabled);
  }

  Future<void> setBackgroundKeepAlive(bool enabled) async {
    if (enabled == _backgroundKeepAlive) return;
    _backgroundKeepAlive = enabled;
    notifyListeners();
    await _storage.saveBackgroundKeepAlive(enabled);
  }

  Future<void> setCommandCompletion(bool enabled) async {
    if (enabled == _commandCompletion) return;
    _commandCompletion = enabled;
    notifyListeners();
    await _storage.saveCommandCompletion(enabled);
  }

  // FET setters
  Future<void> setFetY(double v) async {
    final clamped = v.clamp(0.0, 1.0);
    if (_fetY == clamped) return;
    _fetY = clamped;
    await _storage.saveFetY(clamped);
    notifyListeners();
  }

  Future<void> setFetHidden(bool v) async {
    if (_fetHidden == v) return;
    _fetHidden = v;
    await _storage.saveFetHidden(v);
    notifyListeners();
  }

  Future<void> setFetOpacity(double v) async {
    final clamped = v.clamp(0.4, 0.8);
    if (_fetOpacity == clamped) return;
    _fetOpacity = clamped;
    await _storage.saveFetOpacity(clamped);
    notifyListeners();
  }

  Future<void> setFetAutoFade(bool v) async {
    if (_fetAutoFade == v) return;
    _fetAutoFade = v;
    await _storage.saveFetAutoFade(v);
    notifyListeners();
  }

  Future<void> setFetEnabled(bool v) async {
    if (_fetEnabled == v) return;
    _fetEnabled = v;
    await _storage.saveFetEnabled(v);
    notifyListeners();
  }

  Future<void> setFetOnboardingShown(bool v) async {
    if (_fetOnboardingShown == v) return;
    _fetOnboardingShown = v;
    await _storage.saveFetOnboardingShown(v);
    notifyListeners();
  }

  Future<void> setSftpCustomDownloadPath(String path) async {
    _sftpDownloadDir = SftpDownloadDir.custom;
    _sftpCustomDownloadPath = path;
    notifyListeners();
    await Future.wait([
      _storage.saveSftpDownloadDir(SftpDownloadDir.custom.name),
      _storage.saveSftpCustomDownloadPath(path),
    ]);
  }

  /// Resolves the configured download directory to a concrete [Directory].
  Future<Directory> resolveDownloadDir() async {
    try {
      switch (_sftpDownloadDir) {
        case SftpDownloadDir.downloads:
          return await getDownloadsDirectory() ??
              await getApplicationDocumentsDirectory();
        case SftpDownloadDir.documents:
          return await getApplicationDocumentsDirectory();
        case SftpDownloadDir.custom:
          final path = _sftpCustomDownloadPath;
          if (path != null && path.isNotEmpty) {
            if (!_isValidWritablePath(path)) {
              throw ArgumentError('无效路径：$path\n请使用 /storage/emulated/0/... 格式');
            }
            final dir = Directory(path);
            await dir.create(recursive: true);
            return dir;
          }
          return await getDownloadsDirectory() ??
              await getApplicationDocumentsDirectory();
      }
    } catch (_) {
      return await getApplicationDocumentsDirectory();
    }
  }

  static bool _isValidWritablePath(String path) {
    return path.startsWith('/storage/') ||
        path.startsWith('/sdcard/') ||
        path.startsWith('/data/user/');
  }
}
