// test/ai/agent/builtin_skill_manager_test.dart
import 'dart:convert';

// Uint8List 从 foundation 来 —— 它重新导出了 dart:typed_data，单独再 import
// 一次是冗余（analyzer 的 unnecessary_import）。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/ai/agent/builtin_skill.dart';
import 'package:flyterm/ai/agent/builtin_skill_manager.dart';

/// 注入一份假 bundle，测试不依赖真实 assets —— 真实文件的内容由
/// `builtin_skill_assets_test.dart` 单独钉住，两件事分开测。
class _FakeBundle extends CachingAssetBundle {
  final Map<String, String> files;
  _FakeBundle(this.files);

  @override
  Future<ByteData> load(String key) async {
    final s = files[key];
    if (s == null) throw FlutterError('asset not found: $key');
    final bytes = utf8.encode(s);
    return ByteData.view(Uint8List.fromList(bytes).buffer);
  }
}

String _md(String name, String desc, String body) =>
    '---\nname: $name\ndescription: $desc\n---\n\n$body\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  final bundle = _FakeBundle({
    kBuiltinSkillAssets[0]: _md('alpha', 'A 的说明', 'A 正文'),
    kBuiltinSkillAssets[1]: _md('beta', 'B 的说明', 'B 正文'),
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('load 之后 entries 同步可读 —— systemPromptProvider 就是这样用它的', () async {
    final mgr = BuiltinSkillManager(prefs);
    await mgr.load(bundle: bundle);
    expect(mgr.entries.map((e) => e.name), ['alpha', 'beta']);
    expect(mgr.entries.first.description, 'A 的说明');
    expect(mgr.names, ['alpha', 'beta']);
  });

  test('bodyOf 同步命中内存', () async {
    final mgr = BuiltinSkillManager(prefs);
    await mgr.load(bundle: bundle);
    expect(mgr.bodyOf('alpha'), 'A 正文');
  });

  test('bodyOf 大小写不敏感 —— 与 load_skill 的匹配规则同源', () async {
    final mgr = BuiltinSkillManager(prefs);
    await mgr.load(bundle: bundle);
    expect(mgr.bodyOf('ALPHA'), 'A 正文');
  });

  test('bodyOf 对不存在的名字返回 null', () async {
    final mgr = BuiltinSkillManager(prefs);
    await mgr.load(bundle: bundle);
    expect(mgr.bodyOf('nope'), isNull);
  });

  test('解析失败的那条被跳过，其余照常加载 —— 不让一个坏文件炸掉整个 App', () async {
    final broken = _FakeBundle({
      kBuiltinSkillAssets[0]: '没有 frontmatter 的正文',
      kBuiltinSkillAssets[1]: _md('beta', 'B 的说明', 'B 正文'),
    });
    final mgr = BuiltinSkillManager(prefs);
    await mgr.load(bundle: broken);
    expect(mgr.names, ['beta']);
  });

  test('asset 缺失时不抛，跳过', () async {
    final mgr = BuiltinSkillManager(prefs);
    await mgr.load(bundle: _FakeBundle({}));
    expect(mgr.all, isEmpty);
    expect(mgr.entries, isEmpty);
  });

  test('indexTokenEstimate 随条目增长，空时为 0', () async {
    final empty = BuiltinSkillManager(prefs);
    await empty.load(bundle: _FakeBundle({}));
    expect(empty.indexTokenEstimate, 0);

    final mgr = BuiltinSkillManager(prefs);
    await mgr.load(bundle: bundle);
    expect(mgr.indexTokenEstimate, greaterThan(0));
  });

  test('禁用之后不进索引，但仍在 all 里（设置页要显示它）', () async {
    final mgr = BuiltinSkillManager(prefs);
    await mgr.load(bundle: bundle);
    await mgr.setEnabled('alpha', false);
    expect(mgr.names, ['beta']);
    expect(mgr.all, hasLength(2));
    expect(mgr.isEnabled('alpha'), isFalse);
  });

  test('禁用的技能 bodyOf 返回 null —— 否则那个开关没有意义', () async {
    final mgr = BuiltinSkillManager(prefs);
    await mgr.load(bundle: bundle);
    await mgr.setEnabled('alpha', false);
    expect(mgr.bodyOf('alpha'), isNull);
  });

  test('禁用状态落盘，新实例读得到', () async {
    final first = BuiltinSkillManager(prefs);
    await first.load(bundle: bundle);
    await first.setEnabled('alpha', false);

    final second = BuiltinSkillManager(prefs);
    await second.load(bundle: bundle);
    expect(second.names, ['beta']);
  });

  test('存的是 disabled 列表 —— 将来新增的内置技能默认启用', () async {
    // 模拟"老版本存过一次禁用状态，新版本多了一条技能"：prefs 里只有
    // alpha 被禁，新来的 gamma 不在任何列表里，必须默认启用。
    //
    // 如果实现改成存 enabled 列表，这条会红 —— 而那种实现的失效只在升级后
    // 出现，本地永远复现不了。
    SharedPreferences.setMockInitialValues({
      BuiltinSkillManager.kDisabledPrefsKey: ['alpha'],
    });
    final p = await SharedPreferences.getInstance();
    final mgr = BuiltinSkillManager(p);
    await mgr.load(bundle: _FakeBundle({
      kBuiltinSkillAssets[0]: _md('alpha', 'A', 'AB'),
      kBuiltinSkillAssets[1]: _md('gamma', 'G', 'GB'),
    }));
    expect(mgr.names, ['gamma']);
    expect(mgr.isEnabled('gamma'), isTrue);
  });

  test('setEnabled 会 notifyListeners —— 设置页靠它刷新', () async {
    final mgr = BuiltinSkillManager(prefs);
    await mgr.load(bundle: bundle);
    var notified = 0;
    mgr.addListener(() => notified++);
    await mgr.setEnabled('alpha', false);
    expect(notified, 1);
  });

  test('allNames 含被禁用的 —— 禁用不把名字释放出来', () async {
    // 撞名判定用的是 allNames。若它跟着 names 一起在禁用后收缩，就会开出
    // 这条路径：禁用内置 → 存一条同名的用户技能（此时读得到）→ 重新启用
    // 内置 → 用户那条被永久遮住，而设置页里它还显示「已启用」。
    final mgr = BuiltinSkillManager(prefs);
    await mgr.load(bundle: bundle);
    await mgr.setEnabled('alpha', false);

    expect(mgr.names, ['beta'], reason: '索引里确实要少一条');
    expect(mgr.allNames, ['alpha', 'beta'], reason: '但名字仍然被占着');
  });

  test('真实 assets 全部能加载 —— 出厂技能不能有一份坏的', () async {
    // 与上面几条不同：这里走 **rootBundle** 而不是假 bundle。上面测的是
    // `BuiltinSkillManager` 的逻辑，这条测的是「随包发出去的那几份文件
    // 本身能不能用」—— 与 `builtin_skill_assets_test.dart`（用 dart:io
    // 读仓库磁盘）互补：那条防的是“写坏了”，这条防的是“根本没进包”
    // （pubspec 的 assets 声明漏了、路径拼错）。
    final mgr = BuiltinSkillManager(prefs);
    await mgr.load();

    expect(mgr.all, hasLength(kBuiltinSkillAssets.length),
        reason: '每份 `kBuiltinSkillAssets` 都要能解析出来；少一份就是丢了一个功能');
    expect(mgr.allNames, contains('skill-creator'));
    expect(mgr.allNames, contains('troubleshoot'));
    expect(mgr.allNames, contains('plan-change'));
    // 每份都要有非空 description —— 它是进索引的唯一内容。
    for (final s in mgr.all) {
      expect(s.description.trim(), isNotEmpty, reason: '${s.name} 缺 description');
      expect(s.body.trim(), isNotEmpty, reason: '${s.name} 缺正文');
    }
    expect(mgr.bodyOf('skill-creator'), contains('description'),
        reason: 'skill-creator 的正文里应当教怎么写 description');

    // skill-creator 出现的时机就是「已经确定要存」—— 用户主动调
    // `/skill-creator` 是明说，而它的 description（`Use when writing or
    // updating a skill via save_skill`）也只在模型准备调 `save_skill` 时
    // 被命中。两种情况下“该不该存”都已经定了。
    //
    // 所以正文里**不能**再放“该不该存”的判据：让模型在一个已经决定了的
    // 问题上再想一遍，轻则白烧一串 token，重则把它劝回去不存了。
    //
    // （skill 还是 server_note 的区分由**别的机制**负责：
    // `knowledge_distiller` 自己的 prompt 里就有 `target` 字段，
    // `save_note` 的 tool spec 也写了边界。不归这里管。）
    final sc = mgr.bodyOf('skill-creator')!;
    expect(sc, isNot(contains('whether it is a skill at all')));
    expect(sc, isNot(contains('do not save it')));
    // “问清要存什么”不在此列 —— 那是在“已经要存”之后的下一个问题，
    // 与上面两条防的不是同一件事。
    //
    // 注意不能用“contains('whether to save it at all')” 这种字面断言：
    // 正文里确实会出现这几个词，但是在一个**否定句**里
    //（“Do not ask ... whether to save it at all”）—— 那是在告诉模型
    // 不要回到这个问题，恰恰是我们要的。要钉的是“不是在叫模型重新考虑”。
    expect(sc, contains('Do not ask'),
        reason: 'skill-creator 应当明确叫模型不要回到“该不该存”');
    expect(sc, contains('ask'),
        reason: '但正文里必须有“先问清要存什么”的引导');
  });
}
