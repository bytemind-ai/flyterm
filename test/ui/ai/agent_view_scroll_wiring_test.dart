// 接线护栏：每个 `AgentView(...)` 构造点都必须传 `scrollController`。
//
// ## 为什么要有这条
//
// `AgentView._scrollToBottom` 的第一行是：
//
// ```dart
// final sc = widget.scrollController;
// if (sc == null || !sc.hasClients) return;
// ```
//
// 不传 controller = 自动滚动整条路径是**死代码**：agent 流式输出时面板停在
// 用户上次的位置，得手动往下拖。而 `scrollController` 是可空参数，漏传在
// 类型层面完全合法 —— 编译器一句话都不会说。
//
// 真实事故：终端页的内嵌面板一早就传了（借 `DraggableScrollableSheet` 的
// controller），底部 tab 的全局 AI 页漏了。同一个 widget、同一个功能，两个
// 入口表现不一致，而代码读起来完全正常。用户报的正是「上滑看历史后，执行时
// 不会自动滚动到最新内容」。
//
// 这是一条**源码级**断言而不是 widget 测试：装配一个 agent 模式的
// `GlobalAIScreen` 要 provider 树 + loop 工厂 + server 仓储，成本远高于它
// 想守的东西；而要守的其实就是「这一行参数在不在」。与
// `builtin_skill_assets_test.dart` 直接读磁盘同一个思路。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('每个 AgentView( 都传了 scrollController', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      var idx = 0;
      while (true) {
        final at = src.indexOf('AgentView(', idx);
        if (at < 0) break;
        idx = at + 1;
        // 跳过类声明与构造函数本身。
        if (src.substring(at, at + 14).contains('class ')) continue;
        if (src.startsWith('AgentView({', at)) continue; // 构造函数定义

        // 取这次构造的实参区间：从 `AgentView(` 到配对的 `)`。
        // 简单括号配对足够 —— 实参里不会有未配对的裸括号（Dart 语法层面）。
        var depth = 0;
        var end = -1;
        for (var i = at + 'AgentView'.length; i < src.length; i++) {
          if (src[i] == '(') depth++;
          if (src[i] == ')') {
            depth--;
            if (depth == 0) {
              end = i;
              break;
            }
          }
        }
        if (end < 0) continue;
        final args = src.substring(at, end);
        if (!args.contains('scrollController:')) {
          final line = '\n'.allMatches(src.substring(0, at)).length + 1;
          offenders.add('${entity.path}:$line');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些 AgentView 构造点没传 scrollController，自动滚动在里面是'
          '死代码（见本文件顶部说明）：$offenders',
    );
  });
}