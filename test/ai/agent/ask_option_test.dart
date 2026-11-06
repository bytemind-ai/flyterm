import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/ask_option.dart';

void main() {
  test('正常解析 label 与 description', () {
    final r = parseAskOptions([
      {'label': '3306', 'description': '生产实例'},
      {'label': '3307'},
    ]);
    expect(r.error, isNull);
    expect(r.options, hasLength(2));
    expect(r.options[0].label, '3306');
    expect(r.options[0].description, '生产实例');
    expect(r.options[1].description, isNull);
  });

  test('少于两项报错 —— 只有一个答案就不该问', () {
    final r = parseAskOptions([
      {'label': '唯一选项'},
    ]);
    expect(r.options, isEmpty);
    expect(r.error, contains('at least two'));
  });

  test('空列表报错', () {
    final r = parseAskOptions(const []);
    expect(r.error, contains('at least two'));
  });

  test('超过四项截断到四项，并在 note 里说明', () {
    final r = parseAskOptions([
      for (var i = 0; i < 7; i++) {'label': 'opt$i'},
    ]);
    expect(r.error, isNull);
    expect(r.options, hasLength(4));
    expect(r.note, contains('4'));
    expect(r.options.last.label, 'opt3');
  });

  test('label 为空的项被丢弃，丢到不足两项就报错', () {
    final r = parseAskOptions([
      {'label': '  '},
      {'label': 'ok'},
    ]);
    expect(r.error, contains('at least two'));
  });

  test('label 两端空白被 trim', () {
    final r = parseAskOptions([
      {'label': '  a  '},
      {'label': 'b'},
    ]);
    expect(r.options[0].label, 'a');
  });

  test('非 Map 的项被丢弃而不是抛异常', () {
    final r = parseAskOptions(['字符串', 42, {'label': 'a'}, {'label': 'b'}]);
    expect(r.error, isNull);
    expect(r.options, hasLength(2));
  });
}
