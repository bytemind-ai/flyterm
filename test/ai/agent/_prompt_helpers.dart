/// 抽出 `... do NOT take \`server\` ...` 那一条里的工具名清单（已带反引号），
/// 拼成一行字符串供断言使用。找不到该句时返回空串。
///
/// **为什么不能直接对全文 `contains`**：全文里 `run_background` 等名字到处
/// 都有（用法引导、并发引导），对全文断言「不含 `run_background`」必假，而
/// 对全文断言「含 do NOT take server」又只验了句子存在、名单里点了谁全然
/// 未测。只有把那一句从 prompt 里切出来看成员，才能真的检出名单漂移。
///
/// 两条守卫（`agent_single_server_test.dart` 的固定名单、`agent_prompt_test.dart`
/// 的通用守卫）共用这一份实现：句子措辞一旦调整，两处必须同步；各写一份的话
/// 漏改的那一份会退化成「永远返回空串」，反而静默放行。调用方在「名单不该为
/// 空」的场景里要额外断言非空，避免空串导致的假通过。
///
/// 找不到该句时返回空串 —— 调用方（空名单用例）正是拿这一点断言「没输出」。
String noServerSentence(String prompt) {
  for (final line in prompt.split('\n')) {
    if (line.contains('do NOT take `server`') ||
        line.contains('does NOT take `server`')) {
      return line;
    }
  }
  return '';
}

/// 抽出全局会话里那句「This session is not attached to any machine. Every call
/// to ... MUST pass `server` ...」的整行。找不到该句时返回空串。
///
/// **为什么要切出这一行而不是对全文 `contains`**：`noServerSentence` 的注释里
/// 讲过的坑在这里一样成立，而且更隐蔽 —— `bash` / `glob` 这些名字在 prompt 的
/// 用法引导、并发引导里到处出现，对全文断言「名字在里面」几乎恒真。曾经正是
/// 全文 `contains` 让 `agent_prompt_test.dart` 那条归类守卫漏掉了
/// `install_skill_assets` / `save_note` / `tunnel_create` / `session_open`：
/// 它们在别处出现过，于是「schema 要必填 server」这件事从没被真正验过。
///
/// 只对切出来的这一行做成员检查，才能检出名单漂移。
///
/// 调用方在「名单不该为空」的场景里要额外断言非空，避免空串导致的假通过
/// （空串对「不含某工具名」恒真）。
String mustPassServerSentence(String prompt) {
  for (final line in prompt.split('\n')) {
    if (line.contains('not attached to any machine') &&
        line.contains('MUST pass `server`')) {
      return line;
    }
  }
  return '';
}
