// SPDX-License-Identifier: GPL-3.0-or-later
/// 把标准 JSON Schema 翻译成 OpenAI structured-outputs 的 strict 子集。
///
/// ## 为什么要翻译，而不是直接把 schema 写成 strict 形状
///
/// `ToolSpec.parameters` 是**两个 provider 共用**的。strict 要求「所有
/// properties 都出现在 `required` 里」，而 Anthropic 按标准语义读它 ——
/// 直接改共享定义会让 Anthropic 以为 `read_file` 的 `offset`/`limit`/
/// `server` 全是必填。转换只能发生在 OpenAI 这一侧。
///
/// ## 三条硬约束
///
/// 1. `additionalProperties: false`
/// 2. 所有 `properties` 都必须在 `required` 里
/// 3. 「可选」只能表达成 `"type": ["string", "null"]`，不能靠「不在 required 里」
///
/// 第 3 条是这个函数的核心：把「可省略」翻译成「可以是 null」。翻译之后
/// 模型会传 `"server": null` 而不是省略该字段 —— 而 `resolveServerTarget`
/// （`server_targets.dart:69`）第一行就是 `if (raw == null)`，那正是
/// 「用当前会话机」的语义，所以解析侧不需要任何改动。
///
/// **纯函数，不修改入参**：入参是共享的 const map。
Map<String, dynamic> toStrictSchema(Map<String, dynamic> schema) {
  final props = schema['properties'];
  if (props is! Map) {
    return {...schema, 'additionalProperties': false};
  }

  final required = <String>{
    ...?(schema['required'] as List?)?.whereType<String>(),
  };

  final newProps = <String, dynamic>{};
  props.forEach((key, value) {
    final name = key as String;
    if (value is! Map) {
      newProps[name] = value;
      return;
    }
    final field = Map<String, dynamic>.from(value);
    // 原本必填的保持原样 —— 给它加上 'null' 等于允许模型传 null，把一个
    // schema 层能挡住的错误放过去。
    if (!required.contains(name)) {
      field['type'] = _nullable(field['type']);
    }
    newProps[name] = field;
  });

  return {
    ...schema,
    'properties': newProps,
    // strict 要求全部 properties 都在 required 里。「可选」的语义已经由
    // 上面的 nullable 类型承载。
    'required': props.keys.map((k) => k as String).toList(),
    'additionalProperties': false,
  };
}

/// 把类型变成「可为 null」。**幂等** —— 已经含 `null` 的原样返回，否则
/// 链路上多调一次就会变成 `['string','null','null']`。
Object? _nullable(Object? type) {
  if (type is String) return [type, 'null'];
  if (type is List) {
    return type.contains('null') ? type : [...type, 'null'];
  }
  return type;
}
