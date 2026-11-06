import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/error_location.dart';

void main() {
  group('extractProjectFrame', () {
    test('picks the first package:flyterm/ frame, dropping the column', () {
      final st = StackTrace.fromString('''
#0      AgentLoop._run (package:flyterm/ai/agent/agent_loop.dart:573:14)
#1      AgentLoop.send (package:flyterm/ai/agent/agent_loop.dart:452:11)
#2      _rootRunUnary (dart:async/zone.dart:1436:47)
''');
      expect(extractProjectFrame(st), equals('lib/ai/agent/agent_loop.dart:573'));
    });

    test('skips leading SDK/framework frames to find the first project one',
        () {
      final st = StackTrace.fromString('''
#0      _CastError._throw (dart:core-patch/errors_patch.dart:36:5)
#1      _TypeError._throwNew (dart:core-patch/errors_patch.dart:52:24)
#2      _StateHandler.build (package:flutter/src/widgets/framework.dart:5000:7)
#3      AgentLoop._executeCommandTool (package:flyterm/ai/agent/agent_loop.dart:666:20)
#4      AgentLoop._executeOne (package:flyterm/ai/agent/agent_loop.dart:588:14)
''');
      expect(extractProjectFrame(st),
          equals('lib/ai/agent/agent_loop.dart:666'));
    });

    test('handles traces missing the column number (seen in some AOT traces)',
        () {
      final st = StackTrace.fromString(
          '#0      level3 (package:flyterm/ai/agent/agent_loop.dart:520)\n');
      expect(extractProjectFrame(st), equals('lib/ai/agent/agent_loop.dart:520'));
    });

    test('returns the first match when there are several project frames',
        () {
      final st = StackTrace.fromString('''
#0      AgentLoop._executeEditFile (package:flyterm/ai/agent/agent_loop.dart:950:7)
#1      AgentLoop._executeOne (package:flyterm/ai/agent/agent_loop.dart:588:14)
#2      AgentLoop._run (package:flyterm/ai/agent/agent_loop.dart:549:31)
''');
      expect(extractProjectFrame(st),
          equals('lib/ai/agent/agent_loop.dart:950'));
    });

    test(
        'degrades to null when no frame names this package '
        '(e.g. a release build with stripped/symbolless traces)', () {
      final st = StackTrace.fromString('''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 12345, tid: 67890, name DartWorker
    #00 abs 00007919d1a105f7 virt 000000000006b5f7 _kDartIsolateSnapshotInstructions+0x308b7
    #01 abs 00007919d1a1b82d virt 000000000007682d _kDartIsolateSnapshotInstructions+0x3baed
''');
      expect(extractProjectFrame(st), isNull);
    });

    test('degrades to null for a purely SDK/framework trace', () {
      final st = StackTrace.fromString('''
#0      _rootRunUnary (dart:async/zone.dart:1436:47)
#1      _CustomZone.runUnary (dart:async/zone.dart:1335:19)
''');
      expect(extractProjectFrame(st), isNull);
    });

    test('returns null for a null stack trace', () {
      expect(extractProjectFrame(null), isNull);
    });

    test('returns null for an empty stack trace string', () {
      expect(extractProjectFrame(StackTrace.fromString('')), isNull);
    });
  });

  group('describeError', () {
    test('appends the location line when a project frame is found', () {
      final st = StackTrace.fromString(
          '#0      AgentLoop._run (package:flyterm/ai/agent/agent_loop.dart:573:14)\n');
      expect(
        describeError('Null check operator used on a null value', st),
        equals('Null check operator used on a null value\n'
            '（at lib/ai/agent/agent_loop.dart:573）'),
      );
    });

    test('returns the message unchanged when no frame can be found', () {
      final st = StackTrace.fromString(
          '#0      _rootRunUnary (dart:async/zone.dart:1436:47)\n');
      expect(describeError('boom', st), equals('boom'));
    });

    test('returns the message unchanged when the stack trace is null', () {
      expect(describeError('boom', null), equals('boom'));
    });
  });
}
