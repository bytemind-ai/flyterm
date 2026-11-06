import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/ui/terminal/split_manager.dart';
import 'package:flyterm/ssh/session_manager.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/ssh/ssh_connection.dart';
import 'package:xterm/xterm.dart';

SessionTab _makeTab(String id, SharedPreferences prefs) => SessionTab(
      id: id,
      server: Server(
        id: id, name: id, host: 'h', port: 22,
        username: 'u', authType: 'password',
      ),
      connection: SSHConnection(),
      terminal: Terminal(),
      sessionKey: id,
      aiEngine: AIEngine(prefs, serverId: id),
    );

void main() {
  group('SplitManager', () {
    late SplitManager mgr;
    late SessionTab tabA;
    late SessionTab tabB;
    late SessionTab tabC;
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      mgr = SplitManager();
      tabA = _makeTab('a', prefs);
      tabB = _makeTab('b', prefs);
      tabC = _makeTab('c', prefs);
    });

    test('initial state is off', () {
      expect(mgr.splitMode, SplitMode.off);
      expect(mgr.secondarySession, isNull);
      expect(mgr.floatingSession, isNull);
      expect(mgr.splitRatio, 0.5);
    });

    test('setSplitMode sets mode', () {
      mgr.setSplitMode(SplitMode.horizontal);
      expect(mgr.splitMode, SplitMode.horizontal);
    });

    test('setSecondary sets secondarySession', () {
      mgr.setSecondary(tabB);
      expect(mgr.secondarySession, tabB);
    });

    test('setSecondary rejects floatingSession', () {
      mgr.setFloating(tabB);
      expect(() => mgr.setSecondary(tabB), throwsArgumentError);
    });

    test('setSecondary rejects primarySession', () {
      expect(() => mgr.setSecondary(tabA, primary: tabA), throwsArgumentError);
    });

    test('setFloating rejects secondarySession', () {
      mgr.setSecondary(tabB);
      expect(() => mgr.setFloating(tabB), throwsArgumentError);
    });

    test('clearSplit resets splitMode and secondarySession', () {
      mgr.setSplitMode(SplitMode.vertical);
      mgr.setSecondary(tabB);
      mgr.clearSplit();
      expect(mgr.splitMode, SplitMode.off);
      expect(mgr.secondarySession, isNull);
    });

    test('clearFloating resets floatingSession', () {
      mgr.setFloating(tabC);
      mgr.clearFloating();
      expect(mgr.floatingSession, isNull);
    });

    test('setSplitRatio clamps to 0.25..0.75', () {
      mgr.setSplitRatio(0.1);
      expect(mgr.splitRatio, 0.25);
      mgr.setSplitRatio(0.9);
      expect(mgr.splitRatio, 0.75);
      mgr.setSplitRatio(0.6);
      expect(mgr.splitRatio, 0.6);
    });

    test('onTabClosed: secondary closed → split cleared', () {
      mgr.setSplitMode(SplitMode.horizontal);
      mgr.setSecondary(tabB);
      mgr.onTabClosed(tabB);
      expect(mgr.splitMode, SplitMode.off);
      expect(mgr.secondarySession, isNull);
    });

    test('onTabClosed: floating closed → floating cleared', () {
      mgr.setFloating(tabC);
      mgr.onTabClosed(tabC);
      expect(mgr.floatingSession, isNull);
    });

    test('onTabClosed: unrelated tab → no change', () {
      mgr.setSplitMode(SplitMode.horizontal);
      mgr.setSecondary(tabB);
      mgr.setFloating(tabC);
      mgr.onTabClosed(tabA);
      expect(mgr.splitMode, SplitMode.horizontal);
      expect(mgr.secondarySession, tabB);
      expect(mgr.floatingSession, tabC);
    });

    test('isAvailableForSplit returns false for primary or floating', () {
      mgr.setFloating(tabC);
      expect(mgr.isAvailableForSplit(tabA, primary: tabA), isFalse);
      expect(mgr.isAvailableForSplit(tabC, primary: tabA), isFalse);
      expect(mgr.isAvailableForSplit(tabB, primary: tabA), isTrue);
    });

    test('isAvailableForFloat returns false for primary or secondary', () {
      mgr.setSecondary(tabB);
      expect(mgr.isAvailableForFloat(tabA, primary: tabA), isFalse);
      expect(mgr.isAvailableForFloat(tabB, primary: tabA), isFalse);
      expect(mgr.isAvailableForFloat(tabC, primary: tabA), isTrue);
    });

    test('setSplitRatio notifies listeners', () {
      int callCount = 0;
      mgr.addListener(() => callCount++);
      mgr.setSplitRatio(0.4);
      expect(callCount, 1);
      // same value → no second notification
      mgr.setSplitRatio(0.4);
      expect(callCount, 1);
    });

    group('visibleTabIds', () {
      test('只有 activeTab，无分屏无悬浮 → 集合只含 activeTab', () {
        expect(mgr.visibleTabIds('a'), {'a'});
      });

      test('activeTab 为 null（比如服务器列表页）→ 空集合', () {
        expect(mgr.visibleTabIds(null), isEmpty);
      });

      test('分屏开启且有副屏 → 副屏 id 也在可见集合里', () {
        mgr.setSplitMode(SplitMode.horizontal);
        mgr.setSecondary(tabB);
        expect(mgr.visibleTabIds('a'), {'a', 'b'});
      });

      test('副屏引用存在但 splitMode 是 off → 副屏不算可见', () {
        // 复现"退出分屏但引用未清"的边界情况：secondarySession 字段可能
        // 残留（例如仅调用 setSplitMode(off) 而未调用 clearSplit()），
        // 此时屏幕上其实只剩单栏，不该把它算作可见。
        mgr.setSplitMode(SplitMode.horizontal);
        mgr.setSecondary(tabB);
        mgr.setSplitMode(SplitMode.off);
        expect(mgr.visibleTabIds('a'), {'a'});
      });

      test('悬浮窗打开 → 悬浮 tab id 在可见集合里，且与 splitMode 无关', () {
        mgr.setFloating(tabC);
        expect(mgr.visibleTabIds('a'), {'a', 'c'});
      });

      test('分屏 + 悬浮同时存在 → 三者都可见', () {
        mgr.setSplitMode(SplitMode.vertical);
        mgr.setSecondary(tabB);
        mgr.setFloating(tabC);
        expect(mgr.visibleTabIds('a'), {'a', 'b', 'c'});
      });
    });
  });
}
