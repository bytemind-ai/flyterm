import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/providers/strict_schema.dart';

void main() {
  group('toStrictSchema', () {
    // read_file 的真实形状：一个必填 + 三个可选。
    final readFile = {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Absolute path.'},
        'offset': {'type': 'integer', 'description': 'Start line.'},
        'limit': {'type': 'integer', 'description': 'Max lines.'},
        'server': {'type': 'string', 'description': 'Other server.'},
      },
      'required': ['path'],
    };

    test('所有 properties 都进 required', () {
      final out = toStrictSchema(readFile);
      expect(out['required'], containsAll(['path', 'offset', 'limit', 'server']));
      expect((out['required'] as List), hasLength(4));
    });

    test('additionalProperties 设为 false', () {
      expect(toStrictSchema(readFile)['additionalProperties'], isFalse);
    });

    // 「可省略」在 strict 里的唯一表达方式就是「可以是 null」。翻错了模型
    // 就没法表达「我不指定这个参数」。
    test('原本可选的字段 type 变成 [原类型, null]', () {
      final props = toStrictSchema(readFile)['properties'] as Map;
      expect((props['offset'] as Map)['type'], ['integer', 'null']);
      expect((props['server'] as Map)['type'], ['string', 'null']);
    });

    // 给 path 加上 'null' 等于允许模型传 null 路径 —— 把一个 schema 层
    // 本来能挡住的错误放了过去。
    test('原本必填的字段 type 不变', () {
      final props = toStrictSchema(readFile)['properties'] as Map;
      expect((props['path'] as Map)['type'], 'string');
    });

    test('description 原样保留', () {
      final props = toStrictSchema(readFile)['properties'] as Map;
      expect((props['path'] as Map)['description'], 'Absolute path.');
    });

    // 防止将来链路上多调一次就把 type 变成 ['string','null','null']。
    test('幂等：转换两次结果相同', () {
      final once = toStrictSchema(readFile);
      final twice = toStrictSchema(once);
      expect(twice.toString(), once.toString());
    });

    test('没有 required 字段时，全部都变可空', () {
      final schema = {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
          'b': {'type': 'integer'},
        },
      };
      final out = toStrictSchema(schema);
      expect(out['required'], containsAll(['a', 'b']));
      expect(((out['properties'] as Map)['a'] as Map)['type'], ['string', 'null']);
    });

    test('没有 properties 的无参工具不抛', () {
      final out = toStrictSchema({'type': 'object', 'properties': {}});
      expect(out['required'], isEmpty);
      expect(out['additionalProperties'], isFalse);
    });

    test('数组参数的 items 原样保留', () {
      final schema = {
        'type': 'object',
        'properties': {
          'paths': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        'required': ['paths'],
      };
      final props = toStrictSchema(schema)['properties'] as Map;
      expect((props['paths'] as Map)['items'], {'type': 'string'});
      expect((props['paths'] as Map)['type'], 'array');
    });

    test('enum 原样保留', () {
      final schema = {
        'type': 'object',
        'properties': {
          'mode': {'type': 'string', 'enum': ['a', 'b']},
        },
        'required': ['mode'],
      };
      final props = toStrictSchema(schema)['properties'] as Map;
      expect((props['mode'] as Map)['enum'], ['a', 'b']);
    });

    // 不改入参：ToolSpec.parameters 是共享的 const map，被 Anthropic 那条
    // 路径同时使用。就地修改会让 Anthropic 也收到全量 required。
    test('不修改入参', () {
      final original = {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
        },
        'required': <String>[],
      };
      final snapshot = original.toString();
      toStrictSchema(original);
      expect(original.toString(), snapshot);
    });
  });
}
