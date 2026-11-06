// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/repositories/agent_session_repository.dart' as repo
    show kGlobalServerId;
import 'ai_provider.dart';

/// 把 data 层的定义再导出一次，所以直接 import 本文件也能拿到
/// `kGlobalServerId`。
export '../data/repositories/agent_session_repository.dart'
    show kGlobalServerId;

export 'ai_message.dart';

class AIEngine extends ChangeNotifier {
  final SharedPreferences _prefs;
  final String serverId;

  final List<AIMessage> _history = [];
  String? _streamingContent;

  static const _kMaxMessages = 50;
  static const _kLegacyKey = 'ai_chat_history';

  /// 全局 AI tab 用的保留 serverId。
  ///
  /// 它不对应任何真实服务器——history 落在 `ai_chat_history___global__`，
  /// 与按真实 serverId 分片的那些互不干扰。真实 serverId 是 uuid v4
  /// （只含 hex 与连字符），不可能撞上带下划线的这个。
  ///
  /// 走这条路而不是新开一张表 / 加一个字段：**零 schema 改动、零 migration**。
  ///
  /// **值本身定义在 `agent_session_repository.dart`**（2026-10-13）：会话的
  /// 存储配额按它分档（见 `sessionQuotaFor`），而配额属于 data 层。定义留在
  /// 这里会让 data 层反过来 import ai 层 —— 依赖方向逆转，而且
  /// `ai_engine.dart` 拖着 shared_preferences / flutter/foundation，对一个纯
  /// DB 层太重。
  ///
  /// 这个别名保留着，所以既有的 `AIEngine.kGlobalServerId` 写法全部不用改。
  static const kGlobalServerId = repo.kGlobalServerId;

  String get _historyKey => 'ai_chat_history_$serverId';

  AIEngine(this._prefs, {required this.serverId}) {
    _migrate();
    _loadHistory();
  }

  List<AIMessage> get history => List.unmodifiable(_history);

  /// Non-null while a streaming reply is in progress.
  String? get streamingContent => _streamingContent;

  void _migrate() {
    if (_prefs.containsKey(_kLegacyKey)) {
      _prefs.remove(_kLegacyKey);
    }
  }

  void _loadHistory() {
    final raw = _prefs.getString(_historyKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final e in list) {
        try {
          _history.add(AIMessage.fromJson((e as Map).cast<String, dynamic>()));
        } catch (_) {
          // 单条坏消息只丢它自己。整段历史是用户的东西，不能因为一条
          // 畸形记录就全部沉默丢弃。
        }
      }
    } catch (_) {
      // 整个 JSON 都解析不了才走到这里 —— 此时确实没有可恢复的内容。
    }
  }

  void _saveHistory() {
    final messages = _history.where((m) => m.role != 'system').toList();
    // Keep most recent _kMaxMessages entries
    final trimmed = messages.length > _kMaxMessages
        ? messages.sublist(messages.length - _kMaxMessages)
        : messages;
    _prefs.setString(
        _historyKey, jsonEncode(trimmed.map((m) => m.toJson()).toList()));
  }

  void clearHistory() {
    _history.clear();
    _prefs.remove(_historyKey);
    notifyListeners();
  }

  /// 弹出最后一轮：最后一条 user 消息，以及它之后的所有内容。
  ///
  /// 「重试」与「编辑重发」共用这一个操作，区别只在拿到返回值之后做什么
  /// —— 重试立刻原样发回去，编辑重发把它放进输入框等用户改。两者都必须
  /// 先把旧的那条 user 消息删掉：[query] 会自己往历史尾部追加一条 user，
  /// 留着旧的就会得到两条一模一样的提问。
  ///
  /// **只弹最后一轮，不支持回退到任意一条。** 回退中间某条会静默丢掉它
  /// 之后的全部对话，而手机上没有撤销路径，这个 engine 也不保留分支。
  /// UI 因此只在最后一轮上给这两个按钮，两边的约定要对齐。
  ///
  /// system 消息不会被碰到：它固定在 0 位（[query] 里 removeWhere +
  /// insert(0) 保证只有一条且在头部），而 user 消息必然在它之后。删掉它
  /// 的后果是下一次 [query] 在没有 context 的分支里补一条**不带终端快照**
  /// 的 system，重试出来的回答会比原来的更差。
  ///
  /// 返回 `prompt` 与 `displayText` 两个值而不只是前者：像「会话摘要」那种
  /// 提问，prompt 里塞着整个终端输出、displayText 才是那句短标签。只带回
  /// prompt 去重发，屏幕上会突然摊开几百行终端内容。
  ///
  /// 没有可弹的轮次（历史空、或只有 system）时返回 null。
  ({String prompt, String? displayText})? popLastTurn() {
    final lastUser = _history.lastIndexWhere((m) => m.role == 'user');
    if (lastUser < 0) return null;
    final m = _history[lastUser];
    _history.removeRange(lastUser, _history.length);
    _saveHistory();
    notifyListeners();
    return (prompt: m.content, displayText: m.displayText);
  }

  @override
  void dispose() {
    _saveHistory();
    super.dispose();
  }

  /// Send [prompt] to the AI using [provider].
  /// [silent] skips streaming updates — the panel stays in loading state
  /// and renders the final result once (used when autoExecute is on).
  /// Optional [context] is appended to the system message.
  /// Optional [displayText] is stored on the history entry shown in the chat
  /// UI; [prompt] (which may contain large terminal output) is still sent to
  /// the provider unchanged.
  Future<void> query(
    String prompt, {
    required AIProvider provider,
    String? context,
    bool silent = false,
    String? displayText,
  }) async {
    const baseSystemPrompt =
        'You are a terminal assistant. Choose your response format based on intent:\n'
        '- COMMAND request (do/find/list/kill/check/run something): '
        'start with ```bash code block```, then ≤15 words explanation. '
        'No preamble before the code block.\n'
        '- KNOWLEDGE question (what is X / how does Y work / explain Z / '
        'what does this parameter mean): answer directly in ≤3 sentences. '
        'Add a command only if it helps verify or demonstrate.\n'
        '- ERROR analysis (why did this fail / what does this error mean): '
        'one-line diagnosis first, then a fix command if applicable.\n'
        '- MULTI-STEP task: each step in its own ```bash``` block, '
        'one sentence per block, in order.\n'
        '- AMBIGUOUS: default to command format.\n'
        'Never add "Sure", "根据您的情况", or any filler preamble.';

    if (context != null && context.isNotEmpty) {
      // Always refresh the system message with the latest terminal output so
      // error analysis works even when a prior conversation history exists.
      _history.removeWhere((m) => m.role == 'system');
      _history.insert(
          0,
          AIMessage(
            role: 'system',
            content: '$baseSystemPrompt\n\n$context',
          ));
    } else if (!_history.any((m) => m.role == 'system')) {
      _history.insert(0, const AIMessage(role: 'system', content: baseSystemPrompt));
    }

    _history.add(AIMessage(role: 'user', content: prompt, displayText: displayText));
    _streamingContent = silent ? null : '';
    notifyListeners();

    try {
      final String result;
      if (silent) {
        result = await provider
            .complete(_history)
            .timeout(const Duration(seconds: 120));
      } else {
        final buffer = StringBuffer();
        await provider
            .completeStream(_history)
            .forEach((chunk) {
              buffer.write(chunk);
              _streamingContent = buffer.toString();
              notifyListeners();
            })
            .timeout(const Duration(seconds: 120));
        result = buffer.toString();
      }
      _history.add(AIMessage(role: 'assistant', content: result));
      _saveHistory();
    } on TimeoutException {
      throw Exception('AI 响应超时（120 秒），请重试');
    } finally {
      _streamingContent = null;
      notifyListeners();
    }
  }

  static bool looksLikeError(String line) =>
      _errorPatterns.any((p) => p.hasMatch(line));

  static final _errorPatterns = [
    RegExp(r'\berror\b', caseSensitive: false),
    RegExp(r'\bfatal\b', caseSensitive: false),
    RegExp(r'\bfailed\b', caseSensitive: false),
    RegExp(r'\bpermission denied\b', caseSensitive: false),
    RegExp(r'\bcommand not found\b', caseSensitive: false),
    RegExp(r'\bno such file\b', caseSensitive: false),
    RegExp(r'\bsegmentation fault\b', caseSensitive: false),
  ];
}
