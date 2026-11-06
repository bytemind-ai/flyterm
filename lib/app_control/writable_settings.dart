// SPDX-License-Identifier: GPL-3.0-or-later
/// agent 可读写的 `TerminalSettings` 键。
///
/// **白名单而非黑名单**：新增设置项默认不可写，这样以后加设置不会悄悄开出
/// 提权口子。想开放必须显式加进来，并同步改 `writable_settings_test.dart`。
///
/// 读写共用这一张表 —— 两张表迟早分叉，而分叉方向必然是读的那张更宽。
///
/// 刻意排除在外的键及其理由（**不要**图方便加进来）：
///
/// | 键 | 排除理由 |
/// |----|----------|
/// | `dangerousCommandGuard` | 危险命令守卫。AI 关掉它 = 给自己解开 rm -rf 的刹车 |
/// | `sftpDownloadDir` / `sftpCustomDownloadPath` | 指向本机文件系统，改了影响后续下载落点 |
/// | `debugOverlay` | 无害但无意义，且它本就不持久化 |
/// | `fetOnboardingShown` | 引导状态，不是用户偏好 |
const Set<String> kAgentWritableSettings = {
  'fontSize',
  'fontFamily',
  'lineHeight',
  'terminalTheme',
  'cursorStyle',
  'keyboardTrigger',
  'commandCompletion',
  'sshCompression',
  'backgroundKeepAlive',
  'fetY',
  'fetHidden',
  'fetOpacity',
  'fetAutoFade',
  'fetEnabled',
};

/// **前缀**匹配组：这些是命名空间，只在键的开头有判别力。
const List<String> _forbiddenPrefixes = [
  'agent.',
  'agent_',
  'ai.',
  'ai_',
  'aiprovider',
  'provider.',
];

/// **子串**匹配组：这些词出现在键的任何位置都是危险信号。
const List<String> _forbiddenSubstrings = [
  'apikey',
  'secret',
  'token',
  'password',
];

/// 硬禁区判定 —— 命中即拒，**连读都不给**。
///
/// 与白名单是两道独立的闸：白名单防遗漏（没列的写不了），硬禁区防绕过
/// （就算将来谁手滑把 `agent.defaultMode` 加进白名单，这里仍然拦住）。
///
/// 若 `app_settings_set` 能写 `agent.defaultMode`，模型就能把自己从 ask
/// 提到 bypass，整套权限模型当场归零。
///
/// 归一化（小写 + 去 `.`/`_`/`-`）是刻意的：`Agent.defaultMode` /
/// `AI_API_KEY` / `aiApiKey` 应当一视同仁地被拦住，否则「换个写法」就是
/// 一条绕过路径。
///
/// **前缀组不做子串匹配**：`ai` 只有两个字母，拿它去 contains 会误伤任何
/// 含这两个相邻字母的键（`mailAddress`、`detailLevel`、`keychainMode`），
/// 把合法的观感设置判成禁区。短 token 只在开头有判别力。
bool isForbiddenSettingKey(String key) {
  final k = key.toLowerCase();
  final squashed = k.replaceAll(RegExp(r'[._\-]'), '');
  for (final p in _forbiddenPrefixes) {
    final ps = p.replaceAll(RegExp(r'[._\-]'), '');
    if (k.startsWith(p) || squashed.startsWith(ps)) return true;
  }
  for (final s in _forbiddenSubstrings) {
    if (squashed.contains(s)) return true;
  }
  return false;
}
