import 'package:flyterm/ssh/aqt/aqt_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// 幻影停滞（phantom stall）判据。
///
/// 现场（a4.jpg）：两条 RESUME 先后都拿到 ACK，客户端只留下一条，服务端的
/// PTY 流留在了另一条上。留下的 transport QUIC 层完全健康（connected /
/// rtt 89ms / loss 0%），write() 也发得出去，但永远收不到回音 —— 用户看到
/// 的是「连接在，输入不了，渲染也不对」。
///
/// 判据的形状换过一次，原因值得记下来：
///
/// 旧判据是「距上次收到 PTY 数据超过 45s」。它的毛病是把**空闲**也算成了
/// 幻影 —— `lastPtyDataAge` 只在服务端有输出时才归零，而交互式终端里读屏
/// 幕、思考、等 API 回包停上 45 秒完全正常。旧实现之所以没暴露，是因为它
/// 判出幻影后会被 softReconnect 短路成 2 秒空转（除了横幅闪没有副作用）；
/// 一旦短路被堵上，每个空闲会话就会每 45 秒被真的重连一次。
///
/// 新判据问的是「我发出去的字节有没有回音」：幻影的可观测定义本就是
/// 「写得进、收不到」。没敲过键的会话不会被判 —— 空闲误判在语义上就消
/// 失了，不需要靠调阈值去躲。
void main() {
  group('AqtTransport.isPhantomStall', () {
    test('写入之后超过阈值一点回音都没有 → 幻影', () {
      expect(
        AqtTransport.isPhantomStall(
          wasResumed: true,
          connected: true,
          sinceLastWrite: const Duration(seconds: 25),
          ptyDataAge: const Duration(seconds: 90),
        ),
        isTrue,
      );
    });

    test('从没写过 → 永远不判幻影（这一条就是空闲误判的解药）', () {
      expect(
        AqtTransport.isPhantomStall(
          wasResumed: true,
          connected: true,
          sinceLastWrite: null,
          ptyDataAge: const Duration(hours: 1),
        ),
        isFalse,
        reason: '没发过输入就没有理由期待输出；静默只是空闲，不是坏死',
      );
    });

    test('写入之后收到过回音 → 不是幻影', () {
      expect(
        AqtTransport.isPhantomStall(
          wasResumed: true,
          connected: true,
          sinceLastWrite: const Duration(seconds: 25),
          ptyDataAge: const Duration(seconds: 24),
        ),
        isFalse,
        reason: 'ptyDataAge 比 sinceLastWrite 更近，说明那次写入之后服务端说过话',
      );
    });

    test('写入之后还没等够阈值 → 不判，先给服务端时间', () {
      expect(
        AqtTransport.isPhantomStall(
          wasResumed: true,
          connected: true,
          sinceLastWrite: const Duration(seconds: 19),
          ptyDataAge: const Duration(minutes: 5),
        ),
        isFalse,
      );
    });

    test('阈值本身不算（严格大于）', () {
      expect(
        AqtTransport.isPhantomStall(
          wasResumed: true,
          connected: true,
          sinceLastWrite: AqtTransport.kUnansweredWriteStall,
          ptyDataAge: const Duration(minutes: 5),
        ),
        isFalse,
      );
    });

    test('HELLO 新连接不判幻影 —— 它本来就还没开始收数据', () {
      expect(
        AqtTransport.isPhantomStall(
          wasResumed: false,
          connected: true,
          sinceLastWrite: const Duration(minutes: 5),
          ptyDataAge: const Duration(minutes: 5),
        ),
        isFalse,
        reason: '幻影是 RESUME 竞态的产物；新握手连接的静默只是还没开始',
      );
    });

    test('未连上的 transport 不判幻影 —— 那是 isDead 的职责', () {
      expect(
        AqtTransport.isPhantomStall(
          wasResumed: true,
          connected: false,
          sinceLastWrite: const Duration(minutes: 5),
          ptyDataAge: const Duration(minutes: 5),
        ),
        isFalse,
      );
    });

    test('阈值可注入，便于调用方按场景收紧', () {
      expect(
        AqtTransport.isPhantomStall(
          wasResumed: true,
          connected: true,
          sinceLastWrite: const Duration(seconds: 6),
          ptyDataAge: const Duration(seconds: 30),
          threshold: const Duration(seconds: 5),
        ),
        isTrue,
      );
    });

    test('阈值是 20s —— 压不到 10s 是因为有合法的「敲了键但不回显」', () {
      expect(AqtTransport.kUnansweredWriteStall, const Duration(seconds: 20));
    }, skip: false);
  });

  group('AqtTransport.canSoftReconnect', () {
    test('全健康 → 允许 roam', () {
      expect(
        AqtTransport.canSoftReconnect(
          pathDied: false,
          failedOrClosed: false,
          phantomStalled: false,
        ),
        isTrue,
      );
    });

    test('幻影停滞 → 拒绝 —— 这一条就是 07:49 那段死循环的解药', () {
      expect(
        AqtTransport.canSoftReconnect(
          pathDied: false,
          failedOrClosed: false,
          phantomStalled: true,
        ),
        isFalse,
        reason: '返回 true 会让 _reconnect 在 2s 后报「成功」却不换 transport，'
            'lastPtyDataAge 不归零，下一个 sweep 立刻重新判出幻影',
      );
    });

    test('路径已死 / 状态失败或关闭 → 各自拒绝', () {
      expect(
        AqtTransport.canSoftReconnect(
          pathDied: true,
          failedOrClosed: false,
          phantomStalled: false,
        ),
        isFalse,
      );
      expect(
        AqtTransport.canSoftReconnect(
          pathDied: false,
          failedOrClosed: true,
          phantomStalled: false,
        ),
        isFalse,
      );
    });
  });
}
