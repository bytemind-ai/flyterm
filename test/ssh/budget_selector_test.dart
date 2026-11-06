// test/ssh/budget_selector_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/aqt_transport_factory.dart';
import 'package:flyterm/ssh/aqt/aqt_ffi.dart' show PathStats;
import 'package:flyterm/ssh/reconnect_service.dart';

/// [ReconnectService.debugSelectResumeBudgetForRtt] 只服务 **proactive** 那条
/// 路径（`_selectResumeBudget` 的唯一调用点是 `_doResumeAttemptDetailed`）。
///
/// 曾经短暂地给它单独开过一档 3s（`kDefaultResumeTimeout`），理由是
/// proactive 没有竞速伙伴、等满 budget 是纯呆滞。方向对，取值错 —— 依据是
/// 单张截图里的 `seg hs:360`，而真机 `hs` 段含**服务端序列化 240KB 快照**
/// 的耗时，服务端一忙就涨到 1273ms。3s 的余量从以为的 8 倍缩到 2.2 倍，
/// 再紧一点就会开始砍掉本来能成功的 RESUME。已改回 default 档。
void main() {
  group('selectResumeBudget', () {
    test('rtt 50 ms → default budget', () {
      expect(
        ReconnectService.debugSelectResumeBudgetForRtt(
          const PathStats(rttUs: 50 * 1000),
        ),
        AqtTransportFactory.kDefaultResumeTimeout,
      );
    });

    test('rtt 200 ms (boundary) → default budget', () {
      expect(
        ReconnectService.debugSelectResumeBudgetForRtt(
          const PathStats(rttUs: 200 * 1000),
        ),
        AqtTransportFactory.kDefaultResumeTimeout,
      );
    });

    test('rtt 201 ms → weak-network budget', () {
      expect(
        ReconnectService.debugSelectResumeBudgetForRtt(
          const PathStats(rttUs: 201 * 1000),
        ),
        AqtTransportFactory.kWeakNetworkResumeTimeout,
      );
    });

    test('rtt 1500 ms (mobile worst case) → weak-network budget', () {
      expect(
        ReconnectService.debugSelectResumeBudgetForRtt(
          const PathStats(rttUs: 1500 * 1000),
        ),
        AqtTransportFactory.kWeakNetworkResumeTimeout,
      );
    });

    test('empty PathStats (rtt 0) → default budget', () {
      expect(
        ReconnectService.debugSelectResumeBudgetForRtt(
          PathStats.empty,
        ),
        AqtTransportFactory.kDefaultResumeTimeout,
      );
    });
  });

  group('budget 不得低于观测到的握手耗时', () {
    // 收紧 budget 这条路走过一次，翻车了，这一组是它的护栏。
    //
    // 当时的推理：proactive 路径没有竞速伙伴（工厂层的 `_reconnectRace` 会在
    // `kBootstrapBackupDelay` 处并行拉起 bootstrap，proactive 直接调
    // `tryResumeWithInfoDetailed`，什么都没有），所以等满 budget 是纯呆滞，
    // 收到 3s 能让 SSH 全量链早 2 秒启动。方向是对的。
    //
    // 错在取值的依据 —— 单张截图里的 `seg hs:360`。而 `hs` 段
    // （`markAck - markSent`）里含着**服务端序列化 240KB 快照**的耗时：
    // `serialize_resume` 在 `write_frame(ResumeAck)` **之前**执行
    // （connection.rs:190→272），服务端一忙，这一段就从 360ms 涨到 1273ms。
    // 3s 的余量从以为的 8 倍缩到 2.2 倍。
    //
    // 真正的教训不是「3s 太小」，是**这个数字不该由单点采样决定**。
    test('budget 至少覆盖真机观测到的 hs 段最坏值的 3 倍', () {
      // 真机实测 hs p50：低负载 360ms，服务端负载 10–20 时 1273ms。
      const observedWorstHandshake = Duration(milliseconds: 1273);
      expect(
        AqtTransportFactory.kDefaultResumeTimeout,
        greaterThan(observedWorstHandshake * 3),
        reason: '余量不足时，budget 打满 → FAIL → 转 SSH 全量链，'
            '正好退回收紧 budget 想解决的那个问题',
      );
    });

    test('default 档保持 5s：工厂竞速依赖它与 3s 检查点的 2s 余量', () {
      expect(AqtTransportFactory.kDefaultResumeTimeout,
          const Duration(seconds: 5));
      expect(
        AqtTransportFactory.kDefaultResumeTimeout -
            AqtTransportFactory.kBootstrapBackupDelay,
        const Duration(seconds: 2),
      );
    });

    test('rtt 判据看不见服务端有多忙 —— 这是已知盲区，不是这一组能修的', () {
      // 真机现场：rtt 97ms（比平时的 112ms 还好）而 hs 段 1273ms。慢的是
      // 服务端 CPU 与 240KB 快照的序列化，链路一点问题都没有。
      //
      // 所以 rtt 低**不能**推出「快路径，可以给小 budget」。弱网档 14s 在这
      // 种场景下永远不会被选中。这条断言锁住的就是这个反直觉的事实，免得
      // 下一个人又照着 rtt 去收紧 budget。
      expect(
        ReconnectService.debugSelectResumeBudgetForRtt(
          const PathStats(rttUs: 97 * 1000),
        ),
        AqtTransportFactory.kDefaultResumeTimeout,
        reason: 'rtt 97ms 选 default 档，而真机这一刻的 hs 是 1273ms —— '
            '判据与被判据的量之间没有因果关系',
      );
    });

    test('弱网档不受影响，仍是 14s', () {
      expect(
        ReconnectService.debugSelectResumeBudgetForRtt(
          const PathStats(rttUs: 201 * 1000),
        ),
        AqtTransportFactory.kWeakNetworkResumeTimeout,
      );
      expect(AqtTransportFactory.kWeakNetworkResumeTimeout,
          const Duration(seconds: 14));
    });
  });
}
