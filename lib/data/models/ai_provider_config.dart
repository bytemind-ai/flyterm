// SPDX-License-Identifier: GPL-3.0-or-later
class AIProviderConfig {
  final String id;
  final String name;
  final String type; // 'openai', 'anthropic', 'gemini', 'ollama'
  final String model;
  final String? baseUrl;
  final bool isDefault;
  /// Optional JSON string of extra request body fields, e.g.
  /// '{"reasoning":{"enabled":true},"temperature":0}'
  final String? extraParams;

  const AIProviderConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.model,
    this.baseUrl,
    this.isDefault = false,
    this.extraParams,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'type': type,
        'model': model,
        'base_url': baseUrl,
        'is_default': isDefault ? 1 : 0,
        'extra_params': extraParams,
      };

  factory AIProviderConfig.fromMap(Map<String, dynamic> m) =>
      AIProviderConfig(
        id: m['id'] as String,
        name: m['name'] as String,
        type: m['type'] as String,
        model: m['model'] as String,
        baseUrl: m['base_url'] as String?,
        isDefault: (m['is_default'] as int) == 1,
        extraParams: m['extra_params'] as String?,
      );

  AIProviderConfig copyWith({
    String? name,
    String? type,
    String? model,
    String? baseUrl,
    bool? isDefault,
    String? extraParams,
  }) =>
      AIProviderConfig(
        id: id,
        name: name ?? this.name,
        type: type ?? this.type,
        model: model ?? this.model,
        baseUrl: baseUrl ?? this.baseUrl,
        isDefault: isDefault ?? this.isDefault,
        extraParams: extraParams ?? this.extraParams,
      );
}
