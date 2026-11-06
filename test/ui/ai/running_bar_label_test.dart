// 运行条文案的纯函数测试。
//
// 抽成纯函数而不是直接测 widget，有两个原因：`_RunningBar` 是私有类，
// 测试构造不出来；而这里真正要锁死的是「哪个状态配哪句话、秒数带不带」
// 这套分支，不是像素。widget 层只需验证「它把这个字符串渲染出来了」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/widgets/running_bar_label.dart';

late AppLocalizations l;

Future<void> _loadL10n() async {
  l = await AppLocalizations.delegate.load(const Locale('zh'));
}

void main() {
  setUpAll(_loadL10n);

  group('runningBarLabel', () {
    test('thinking 带秒数', () {
      expect(
        runningBarLabel(l,
            state: AgentLoopState.thinking,
            elapsed: const Duration(seconds: 12),
            runningCommands: const [],
            rateLimitRemaining: null),
        '思考中 12s',
      );
    });

    // 本轮调用次数是**后缀**，与「卡在哪一阶段」并列，不是二选一。
    group('本轮工具调用次数后缀', () {
      test('>0 时拼在主干后面', () {
        expect(
          runningBarLabel(l,
              state: AgentLoopState.thinking,
              elapsed: const Duration(seconds: 12),
              runningCommands: const [],
              rateLimitRemaining: null,
              runToolCalls: 7),
          '思考中 12s · 已调用 7 次',
        );
      });

      test('=0 时不拼 —— 「已调用 0 次」是噪音', () {
        expect(
          runningBarLabel(l,
              state: AgentLoopState.thinking,
              elapsed: const Duration(seconds: 12),
              runningCommands: const [],
              rateLimitRemaining: null,
              runToolCalls: 0),
          '思考中 12s',
        );
      });

      test('executing 多条时也带后缀', () {
        expect(
          runningBarLabel(l,
              state: AgentLoopState.executing,
              elapsed: const Duration(seconds: 5),
              runningCommands: const ['a', 'b'],
              rateLimitRemaining: null,
              runToolCalls: 3),
          '执行 2 个命令 5s · 已调用 3 次',
        );
      });

      test('等你确认那档也带后缀 —— 那时已经调过工具了', () {
        expect(
          runningBarLabel(l,
              state: AgentLoopState.awaitingApproval,
              elapsed: const Duration(seconds: 5),
              runningCommands: const [],
              rateLimitRemaining: null,
              runToolCalls: 4),
          '等你确认 · 已调用 4 次',
        );
      });

      test('rateLimited 不带后缀 —— 倒计时是唯一要紧的事', () {
        expect(
          runningBarLabel(l,
              state: AgentLoopState.rateLimited,
              elapsed: null,
              runningCommands: const [],
              rateLimitRemaining: const Duration(seconds: 3),
              runToolCalls: 4),
          '已被限流，3 秒后重试',
        );
      });
    });

    test('thinking 无 elapsed 时退回不带秒数的旧文案', () {
      expect(
        runningBarLabel(l,
            state: AgentLoopState.thinking,
            elapsed: null,
            runningCommands: const [],
            rateLimitRemaining: null),
        '思考中…',
      );
    });

    // 单条时**不写命令**：那条命令正完整显示在工具卡上，运行条重复一遍
    // 既冗余、又会因为单行宽度被砍掉尾部（而路径参数都在尾部）。
    test('executing 单条只报秒数，不写命令', () {
      expect(
        runningBarLabel(l,
            state: AgentLoopState.executing,
            elapsed: const Duration(seconds: 8),
            runningCommands: const ['journalctl -u nginx'],
            rateLimitRemaining: null),
        '执行中 8s',
      );
    });

    // 卡片还没进事件流的时序缝隙。秒数是准的，照样报。
    test('executing 没有运行中命令时仍报秒数', () {
      expect(
        runningBarLabel(l,
            state: AgentLoopState.executing,
            elapsed: const Duration(seconds: 8),
            runningCommands: const [],
            rateLimitRemaining: null),
        '执行中 8s',
      );
    });

    test('executing 多条显示条数', () {
      expect(
        runningBarLabel(l,
            state: AgentLoopState.executing,
            elapsed: const Duration(seconds: 8),
            runningCommands: const ['a', 'b', 'c'],
            rateLimitRemaining: null),
        '执行 3 个命令 8s',
      );
    });

    // 起点未知（loop 刚构造还没进过任何阶段）时不编秒数。
    test('executing 无 elapsed 时退回不带秒数的文案', () {
      expect(
        runningBarLabel(l,
            state: AgentLoopState.executing,
            elapsed: null,
            runningCommands: const [],
            rateLimitRemaining: null),
        '执行中…',
      );
    });

    // 等审批是人类时间，不是系统耗时，显示秒数只会变成催促。
    test('awaitingApproval 不带秒数', () {
      expect(
        runningBarLabel(l,
            state: AgentLoopState.awaitingApproval,
            elapsed: const Duration(seconds: 90),
            runningCommands: const [],
            rateLimitRemaining: null),
        '等你确认',
      );
    });

    test('rateLimited 显示倒计时且向上取整', () {
      expect(
        runningBarLabel(l,
            state: AgentLoopState.rateLimited,
            elapsed: const Duration(seconds: 5),
            runningCommands: const [],
            rateLimitRemaining: const Duration(milliseconds: 22400)),
        '已被限流，23 秒后重试',
      );
    });
  });

  group('formatTurnDuration', () {
    test('不足一分钟只给秒', () {
      expect(formatTurnDuration(42000), '42s');
    });

    test('超过一分钟给分加秒', () {
      expect(formatTurnDuration(222000), '3m42s');
    });

    test('整分钟不省略秒', () {
      expect(formatTurnDuration(120000), '2m0s');
    });

    test('不足一秒向下取整到 0s', () {
      expect(formatTurnDuration(400), '0s');
    });
  });
}
