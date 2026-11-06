// SPDX-License-Identifier: GPL-3.0-or-later
import '../../data/models/favorite_command.dart';

/// 参数值允许的字符：字母、数字、空格，以及 . - _ / : = , @ +
///
/// ## 为什么是白名单，为什么不复用 `hasShellMetachar`
///
/// `shell_guard.dart` 的那个正则是 `[;|`><&\n\r]|\$\(` —— 它**不拦引号**，
/// 而引号足以在不出现任何元字符的情况下改变命令结构：
///
/// ```
/// 模板：  echo "{{msg}}"
/// 参数：  msg = 'a" -x "b'
/// 展开：  echo "a" -x "b"      ← 结构变了，第二层的 checkCommand 会放行
/// ```
///
/// 所以这一层必须独立且更严格。
///
/// **用白名单而不是黑名单，是因为失败方向不同。** 黑名单漏一个字符 = 一个
/// 可利用的洞，而且要随 shell 特性不断补；白名单漏一个字符 = 一次「参数被
/// 拒」的报错，用户看得见、模型能自纠。默认拒绝才是安全默认。
///
/// 需要 glob 的场景在模板里写死：`ls {{dir}}/*.log`，而不是让模型传 `*`。
///
/// **注意：这里用字面空格 ` `，不用 `\s`。** Dart 正则里 `\s` 会匹配
/// `\n`、`\r`、`\t` 等——用它会放行 `a\nrm -rf /` 这种换行注入（多行会被
/// shell 当成第二条命令）。只有单个空格才是「参数里带个词组」的合法需求。
final RegExp _safeParamRe = RegExp(r'^[\w .\-/:=,@+]*$', unicode: true);

/// 一次参数校验的结果。
class CommandParamCheck {
  /// 非 null = 这次调用要被拒，内容直接回填给模型。
  final String? error;

  /// 模型传了、但模板里没有的键。**不是错误** —— 它们不参与 `expand()`，
  /// 碰不到命令。但要在回填里提一句：静默忽略会让模型以为生效了。
  final List<String> extraKeys;

  const CommandParamCheck({this.error, this.extraKeys = const []});
}

/// 校验模型传来的参数能否安全地填进 [cmd] 的占位符。
///
/// 这是双层校验的**第一层**，只管一件事：**参数不能改变命令的结构**。
/// 「这条命令能不能跑」是第二层 `checkCommand` 的事。两层缺一不可 ——
/// 只有第二层，含管道的模板每次都因元字符弹卡、用户点习惯了同意，注入照样
/// 生效；只有第一层，`rm -rf {{path}}` 传 `path=/var` 完全合法地通过。
CommandParamCheck validateCommandParams(
  FavoriteCommand cmd,
  Map<String, String> params,
) {
  final needed = cmd.params;

  // 完整性：每个占位符都要有非空值。
  //
  // 空串必须算缺失 —— `expand()` 对缺键和空串的处理是一样的（都替换成
  // 空字符串），会产出 `--version ` 这种语法完整、语义错误的命令，并且
  // 真的执行。
  final missing = needed
      .where((p) => (params[p] ?? '').trim().isEmpty)
      .toList(growable: false);
  if (missing.isNotEmpty) {
    return CommandParamCheck(
        error: 'Missing required parameter(s): ${missing.join(', ')}. '
            'This command needs: ${needed.join(', ')}.');
  }

  // 白名单：只校验真正会被填进命令的那些。
  for (final p in needed) {
    final v = params[p]!;
    if (!_safeParamRe.hasMatch(v)) {
      return CommandParamCheck(
          error: 'Parameter `$p` contains characters that are not allowed. '
              'Only letters, digits, spaces and . - _ / : = , @ + are '
              'accepted. If you need shell syntax, use the `bash` tool '
              'instead.');
    }
    // `..` 单独拦：它完全符合上面的白名单（点和斜杠都是允许的），但
    // `cat /var/log/{{f}}` 配上 `f=../../etc/shadow` 能穿出目录，而默认
    // allowlist 里有 `cat *`，第二层也不会拦。合法用途几乎没有 —— 想引用
    // 上级目录在模板里写死就行。
    if (v.contains('..')) {
      return CommandParamCheck(
          error: 'Parameter `$p` contains `..`, which is not allowed '
              '(path traversal). Pass an absolute path instead.');
    }
  }

  final extra = params.keys.where((k) => !needed.contains(k)).toList()..sort();
  return CommandParamCheck(extraKeys: extra);
}
