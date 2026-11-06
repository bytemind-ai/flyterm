import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/font_options.dart';

void main() {
  group('FontOptions', () {
    // 与 pubspec.yaml 的 fonts 段一一对应。7975e5bc 为省 2.4 MB APK 删掉了
    // CascadiaCode / Hack / FiraCode，这里跟着收——列表多一项而 assets 里没有
    // 对应字体，设置页就会给出一个选了没效果的选项。
    test('builtInFamilies is the shipped set + system sentinel', () {
      expect(FontOptions.builtInFamilies, [
        'JetBrainsMono',
        'CourierPrime',
        'system',
      ]);
    });

    test('isBuiltInFamily accepts valid + rejects invalid', () {
      expect(FontOptions.isBuiltInFamily('JetBrainsMono'), isTrue);
      expect(FontOptions.isBuiltInFamily('CourierPrime'), isTrue);
      expect(FontOptions.isBuiltInFamily('system'), isTrue);
      expect(FontOptions.isBuiltInFamily('Comic Sans'), isFalse);
    });

    test('familyDisplayName humanizes ids', () {
      expect(FontOptions.familyDisplayName('JetBrainsMono'), 'JetBrains Mono');
      expect(FontOptions.familyDisplayName('CourierPrime'), 'Courier Prime');
      expect(FontOptions.familyDisplayName('system'), '系统默认');
    });

    // 被删掉的那三个字体和纯未知 id 走同一条回退。老用户的 prefs 里可能还存着
    // 'CascadiaCode'，那时设置页显示原始 id 而不是抛异常。
    test('familyDisplayName falls back to id for removed and unknown fonts',
        () {
      expect(FontOptions.familyDisplayName('CascadiaCode'), 'CascadiaCode');
      expect(FontOptions.familyDisplayName('FiraCode'), 'FiraCode');
      expect(FontOptions.familyDisplayName('UnknownFont'), 'UnknownFont');
    });
  });
}
