import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/resume_issue_log.dart';

// `appendResumeIssue` 曾经带 `lastOutOff` / `ringTailHash` 两个参数：埋点本身
// 就是为了分辨"哪个发起点带了哪一代 offset"（见 resume_issue_log.dart 文件头
// 那次 2 秒内三个世代的事故）。RESUME 帧不再携带任何位置信息之后，那两个参数
// 没有值可传了，连带 COLD 标记（off=0 曾经代表"冷启动"）和 hash 十六进制记录
// 一起从签名里删掉。
void main() {
  setUp(resetResumeIssueLog);

  group('appendResumeIssue', () {
    test('序号从 1 开始且单调递增', () {
      expect(appendResumeIssue(site: 'a', tabId: 'tab-1'), 1);
      expect(appendResumeIssue(site: 'b', tabId: 'tab-2'), 2);
    });

    test('tabId 截断到 4 位，与 ReconnectService._shortTabId 对齐', () {
      appendResumeIssue(site: 'x', tabId: 'abcdef-1234');
      expect(resumeIssueLog.single, contains('[abcd]'));
      expect(resumeIssueLog.single, isNot(contains('abcde')));
    });

    test('短于 4 位的 tabId 原样保留，不越界', () {
      appendResumeIssue(site: 'x', tabId: 'ab');
      expect(resumeIssueLog.single, contains('[ab]'));
    });
  });

  group('appendResumeNote', () {
    // 这是 appendResumeNote 单独存在的全部理由：它记的是"没往线上发东西"，
    // 若复用 appendResumeIssue 就会跟真正发出去的 RESUME 混在一起——那正是
    // 当前要排查的现象，混淆代价很高。
    test('产生的记录带 SKIP 文案', () {
      appendResumeNote('prewarm SKIP (claimed) [abcd]');
      expect(resumeIssueLog.single, contains('SKIP'));
    });

    test('不消耗序号', () {
      appendResumeNote('skip');
      expect(appendResumeIssue(site: 'x', tabId: 'tab-1'), 1);
    });
  });

  group('appendResumeResult', () {
    test('用同一序号与 issue 配对', () {
      final seq = appendResumeIssue(site: 'preSsh', tabId: 'tab-1');
      appendResumeResult(seq: seq, outcome: 'OK', replayBytes: 1234);
      expect(resumeIssueLog[0], contains('#1→'));
      expect(resumeIssueLog[1], contains('#1←'));
      expect(resumeIssueLog[1], contains('replay=1234'));
    });

    test('replayBytes 省略时不输出 replay 字段', () {
      appendResumeResult(seq: 7, outcome: 'FAIL sessionNotFound');
      expect(resumeIssueLog.single, isNot(contains('replay=')));
      expect(resumeIssueLog.single, contains('FAIL sessionNotFound'));
    });

    test('并发交错时靠序号仍能配对', () {
      // 这是这套埋点存在的目的：生产日志里出现过 2 秒内三条 RESUME 并发，
      // ISSUE 和它的 RESULT 中间隔着别人的记录，靠相邻位置认不出来。
      final a = appendResumeIssue(site: 'prewarm', tabId: 'tab-1');
      final b = appendResumeIssue(site: 'coldHydrate', tabId: 'tab-1');
      appendResumeResult(seq: b, outcome: 'OK', replayBytes: 20);
      appendResumeResult(seq: a, outcome: 'FAIL busy');

      expect(resumeIssueLog[2], contains('#$b←'));
      expect(resumeIssueLog[3], contains('#$a←'));
    });
  });

  group('环形缓冲', () {
    test('超过容量后丢最旧的，保留最新 20 条', () {
      for (var i = 0; i < 25; i++) {
        appendResumeNote('note-$i');
      }
      expect(resumeIssueLog.length, 20);
      expect(resumeIssueLog.first, contains('note-5'));
      expect(resumeIssueLog.last, contains('note-24'));
    });

    test('裁剪不影响序号继续递增', () {
      for (var i = 0; i < 25; i++) {
        appendResumeIssue(site: 's', tabId: 'tab-1');
      }
      expect(resumeIssueLog.last, contains('#25→'));
    });
  });

  test('resetResumeIssueLog 同时清缓冲和序号', () {
    appendResumeIssue(site: 'x', tabId: 'tab-1');
    resetResumeIssueLog();
    expect(resumeIssueLog, isEmpty);
    expect(appendResumeIssue(site: 'x', tabId: 'tab-1'), 1);
  });
}
