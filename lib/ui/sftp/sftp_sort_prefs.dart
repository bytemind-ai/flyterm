// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:shared_preferences/shared_preferences.dart';

import '../../sftp/sftp_name_sort.dart';

/// 排序偏好的持久化。
///
/// **全局一份，不按服务器分。** 排序偏好是**用户习惯**而非**机器属性** ——
/// 习惯按时间排序找最新日志的人，不会希望换个服务器就变回按名称。
/// 存 shared_preferences 而不进数据库：它不属于任何一台机器，也不值得一次
/// schema 演进。
class SftpSortPrefs {
  static const _kKey = 'sftp_sort_key';
  static const _kAsc = 'sftp_sort_ascending';

  static Future<({SortKey key, bool ascending})> load() async {
    final p = await SharedPreferences.getInstance();
    final name = p.getString(_kKey);
    final key = SortKey.values.firstWhere(
      (k) => k.name == name,
      orElse: () => SortKey.name,
    );
    return (key: key, ascending: p.getBool(_kAsc) ?? true);
  }

  static Future<void> save({
    required SortKey key,
    required bool ascending,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kKey, key.name);
    await p.setBool(_kAsc, ascending);
  }
}
