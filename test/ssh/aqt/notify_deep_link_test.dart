import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/notify_deep_link.dart';

void main() {
  group('NotifyDeepLink.resolveTargetTabId', () {
    test('protocolTabId 精确匹配同服务器某个候选 → 返回该 tab', () {
      final candidates = [
        const TabCandidate(tabId: 'a', serverId: 'srv1', protocolTabId: 1),
        const TabCandidate(tabId: 'b', serverId: 'srv1', protocolTabId: 2),
        const TabCandidate(tabId: 'c', serverId: 'srv2', protocolTabId: 2),
      ];
      expect(
        NotifyDeepLink.resolveTargetTabId(
            candidates: candidates, serverId: 'srv1', protocolTabId: 2),
        'b',
      );
    });

    test('不会跨服务器误匹配相同的 protocolTabId', () {
      final candidates = [
        const TabCandidate(tabId: 'a', serverId: 'srv1', protocolTabId: 5),
        const TabCandidate(tabId: 'c', serverId: 'srv2', protocolTabId: 5),
      ];
      expect(
        NotifyDeepLink.resolveTargetTabId(
            candidates: candidates, serverId: 'srv2', protocolTabId: 5),
        'c',
      );
    });

    test('protocolTabId 为 null（tmux 环境变量过期）→ 退化为该服务器最后一个 tab', () {
      final candidates = [
        const TabCandidate(tabId: 'a', serverId: 'srv1', protocolTabId: 1),
        const TabCandidate(tabId: 'b', serverId: 'srv1', protocolTabId: 2),
      ];
      expect(
        NotifyDeepLink.resolveTargetTabId(
            candidates: candidates, serverId: 'srv1', protocolTabId: null),
        'b',
      );
    });

    test('protocolTabId 非 null 但没有任何候选匹配 → 退化为该服务器最后一个 tab', () {
      final candidates = [
        const TabCandidate(tabId: 'a', serverId: 'srv1', protocolTabId: 1),
        const TabCandidate(tabId: 'b', serverId: 'srv1', protocolTabId: 2),
      ];
      expect(
        NotifyDeepLink.resolveTargetTabId(
            candidates: candidates, serverId: 'srv1', protocolTabId: 999),
        'b',
      );
    });

    test('该服务器一个 tab 都没有 → 返回 null', () {
      final candidates = [
        const TabCandidate(tabId: 'c', serverId: 'srv2', protocolTabId: 1),
      ];
      expect(
        NotifyDeepLink.resolveTargetTabId(
            candidates: candidates, serverId: 'srv1', protocolTabId: null),
        isNull,
      );
    });
  });

  group('NotifyDeepLink.decideAction', () {
    test('目标 tab 已关闭 → tabNotFound', () {
      expect(
        NotifyDeepLink.decideAction(
          targetTabId: 'a',
          targetTabExists: false,
          visibleTabIds: const {'a'},
        ),
        NotifyDeepLinkAction.tabNotFound,
      );
    });

    test('目标 tab 存在且已在可见集合里 → alreadyVisible（不重排）', () {
      expect(
        NotifyDeepLink.decideAction(
          targetTabId: 'b',
          targetTabExists: true,
          visibleTabIds: const {'a', 'b'},
        ),
        NotifyDeepLinkAction.alreadyVisible,
      );
    });

    test('目标 tab 存在但不在可见集合里 → promoteToActive', () {
      expect(
        NotifyDeepLink.decideAction(
          targetTabId: 'c',
          targetTabExists: true,
          visibleTabIds: const {'a', 'b'},
        ),
        NotifyDeepLinkAction.promoteToActive,
      );
    });

    test('可见集合为空且目标存在 → promoteToActive', () {
      expect(
        NotifyDeepLink.decideAction(
          targetTabId: 'a',
          targetTabExists: true,
          visibleTabIds: const {},
        ),
        NotifyDeepLinkAction.promoteToActive,
      );
    });
  });
}
