// 旧的 foreground watchdog 测试套件（22 个用例，4 个 group）随
// AqtTransport.WatchdogState / effectiveWatchdogAgeMs / 7 个 kWatchdog* 阈值常量
// 一起删除 —— 判活已收敛进 lib/ssh/aqt/conn/ 的状态机。
//
// 原有不变量的新归属：
//
//   group 'WatchdogState (steady-state thresholds)'  (7 例)
//     → test/ssh/aqt/conn/conn_machine_liveness_test.dart
//       live/suspect/probing/dead 四态回路 + 丢 tick 的 death 天花板
//
//   group 'WatchdogState resume-window overrides'    (5 例)
//     → test/ssh/aqt/conn/conn_machine_lifecycle_test.dart
//       固定 8s 的 resume 窗口换成可算的盲区谓词 elevated()，
//       「长后台回前台」那条用例锁住整条联动
//
//   group 'effectiveWatchdogAgeMs'                   (5 例)
//     → test/ssh/aqt/conn/conn_silence_test.dart
//       两层归一化合并成一行 observedSilence()，20000 组穷举证明逐点等价
//
//   group 'never-received sentinel + msSinceConnected clamp' (5 例)
//     → 哨兵常量本身的断言保留在本文件（下方唯一的用例）；
//       其余依赖 effectiveWatchdogAgeMs 的断言并入 conn_silence_test.dart
//
// 这个文件留下来只为一件事：AqtFfi.kNeverReceivedAgeMs 这个常量还在用，
// 它的形状（大的正数哨兵，不是 -1 也不是 0）是状态机判活的前提 ——
// observedSilence 靠"观测窗口夹取"把它读成新鲜，若它变成负数或 0，
// 「刚 RESUME 完的新 handle 不得判死」那条就会静默失效。

import 'package:flyterm/ssh/aqt/aqt_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('kNeverReceivedAgeMs 是一个大的正数哨兵', () {
    expect(AqtFfi.kNeverReceivedAgeMs, greaterThan(0));
    expect(AqtFfi.kNeverReceivedAgeMs, 0x7fffffffffffffff);
  });
}
