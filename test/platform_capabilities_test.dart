// PlatformCapabilities 的回归护栏。
//
// 这份文件守的是「iOS 上到底哪些功能开着」这一事实清单 —— 它是
// `lib/platform_capabilities.dart` 存在的全部理由：把散落在 lib/ 里的
// `Platform.isIOS` 判定收敛成一个可注入的真相点，让 Linux 上的
// `flutter test` 能覆盖 iOS 行为。
//
// 两组断言：
//   1. Android 具名构造器 —— 全功能，五个字段都为 true。
//   2. limited 具名构造器 —— iOS 首发的能力面，五个字段都为 false。
//      这一组是**契约**：iOS 缺的是「平台做不了」而不是「还没做」，
//      任何字段被悄悄改成 true 都意味着一处平台守卫被绕过。
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/platform_capabilities.dart';

void main() {
  group('PlatformCapabilities.android()', () {
    test('全功能平台：五个能力全开', () {
      const caps = PlatformCapabilities.android();
      expect(caps.hasLocalShell, isTrue);
      expect(caps.hasMediaStoreDownload, isTrue);
      expect(caps.hasNativeSpeechChannel, isTrue);
      expect(caps.hasForegroundService, isTrue);
      expect(caps.hasInAppUpdate, isTrue);
    });
  });

  group('PlatformCapabilities.limited() —— iOS 首发能力面（契约）', () {
    test('五个能力全关', () {
      const caps = PlatformCapabilities.limited();
      expect(caps.hasLocalShell, isFalse,
          reason: 'iOS 沙盒禁 fork/exec + 指南 2.5.2 禁止执行非自带代码，'
              '本地 shell 是永久缺失，不是待办');
      expect(caps.hasMediaStoreDownload, isFalse,
          reason: 'iOS 没有系统 Downloads 概念，publish() 返回 null');
      expect(caps.hasNativeSpeechChannel, isFalse,
          reason: 'iOS 无 System/InlineSpeechPlugin 的 Swift 实现，'
              '走 speech_to_text → Apple Speech 另一条路径');
      expect(caps.hasForegroundService, isFalse,
          reason: '前台服务是 Android 语义；本项目后台保活已休眠');
      expect(caps.hasInAppUpdate, isFalse,
          reason: '站外更新引导违反审核指南 3.1.1，iOS 走 App Store 自身');
    });
  });

  group('copyWith', () {
    test('只覆盖指定字段，其余保持', () {
      const base = PlatformCapabilities.android();
      final mod = base.copyWith(hasLocalShell: false);

      expect(mod.hasLocalShell, isFalse);
      expect(mod.hasMediaStoreDownload, isTrue,
          reason: 'copyWith 不该连带改掉没点名的字段');
      expect(mod.hasNativeSpeechChannel, isTrue);
      expect(mod.hasForegroundService, isTrue);
      expect(mod.hasInAppUpdate, isTrue);
    });

    test('无参数时是恒等副本', () {
      const base = PlatformCapabilities.limited();
      final copy = base.copyWith();
      expect(copy.hasLocalShell, base.hasLocalShell);
      expect(copy.hasMediaStoreDownload, base.hasMediaStoreDownload);
      expect(copy.hasNativeSpeechChannel, base.hasNativeSpeechChannel);
      expect(copy.hasForegroundService, base.hasForegroundService);
      expect(copy.hasInAppUpdate, base.hasInAppUpdate);
    });
  });

  group('PlatformCapabilities.instance()', () {
    test('在测试宿主（linux）上不抛异常，且返回的都是 bool', () {
      // 不断言具体值 —— 测试宿主是 linux，`Platform.isAndroid` 为 false，
      // 断言具体值会让这份测试变成「linux 不是 android」的同义反复。
      // 只保证它可调用、可返回，不会因为 `Platform` 未初始化而炸。
      final caps = PlatformCapabilities.instance();
      expect(caps.hasLocalShell, anyOf(isTrue, isFalse));
      expect(caps.hasMediaStoreDownload, anyOf(isTrue, isFalse));
      expect(caps.hasNativeSpeechChannel, anyOf(isTrue, isFalse));
      expect(caps.hasForegroundService, anyOf(isTrue, isFalse));
      expect(caps.hasInAppUpdate, anyOf(isTrue, isFalse));
    });

    test('在 linux 宿主上五个能力都为 false（非 Android）', () {
      // 这一条是「默认行为按平台判定」的正面验证：linux 不是 android，
      // 所以 instance() 必须给出 limited 那一套 —— 也就是 iOS 的能力面。
      // 若哪天有人把 instance() 写死成 android()，这里会立刻红。
      final caps = PlatformCapabilities.instance();
      expect(caps.hasLocalShell, isFalse);
      expect(caps.hasMediaStoreDownload, isFalse);
      expect(caps.hasNativeSpeechChannel, isFalse);
      expect(caps.hasForegroundService, isFalse);
      expect(caps.hasInAppUpdate, isFalse);
    });
  });
}
