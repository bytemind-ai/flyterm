import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/keybar_config.dart';

void main() {
  test('attachFile 进了默认右侧按钮 —— 存量用户靠这个自动拿到新按钮', () {
    // KeybarSettings 的 forward-compat 逻辑（keybar_settings.dart:78-87）会把
    // 「defaultRightButtons() 里有、用户存储里没有」的按钮追加进去。所以只要
    // 加进这个列表，存量用户就会自动看到，不需要写迁移代码。
    final types = defaultRightButtons().map((e) => e.type).toList();
    expect(types, contains(RightButton.attachFile));
  });

  test('默认是启用的', () {
    final item = defaultRightButtons()
        .firstWhere((e) => e.type == RightButton.attachFile);
    expect(item.enabled, isTrue);
  });

  test('序列化往返', () {
    const item = RightButtonItem(type: RightButton.attachFile, enabled: true);
    final back = RightButtonItem.fromJson(item.toJson());
    expect(back.type, RightButton.attachFile);
    expect(back.enabled, isTrue);
  });
}
