import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/skill.dart';

/// 附件路径校验的单元测试。
///
/// `path` 是**模型提供的字符串**，会被拼进远端绝对路径。校验函数是唯一的
/// 防线，所以这里把每种逃逸形状都单列一条 —— 混在一条用例里，将来某一条
/// 分支被改坏时看不出是哪条。
void main() {
  group('isSafeAssetPath 接受', () {
    test('简单的相对路径', () {
      expect(isSafeAssetPath('scripts/check.sh'), isTrue);
    });

    test('多级相对路径', () {
      expect(isSafeAssetPath('a/b/c/d.txt'), isTrue);
    });

    test('单段文件名（无目录）', () {
      expect(isSafeAssetPath('nginx.conf'), isTrue);
    });

    test('含点、连字符、下划线、空格的文件名', () {
      expect(isSafeAssetPath('scripts/my-check_v2.0 final.sh'), isTrue);
    });

    test('含非 ASCII 的文件名', () {
      expect(isSafeAssetPath('脚本/检查.sh'), isTrue);
    });

    test('以点开头的隐藏文件（裸点段不算逃逸）', () {
      expect(isSafeAssetPath('scripts/.env.example'), isTrue);
    });
  });

  group('isSafeAssetPath 拒绝', () {
    test('绝对路径', () {
      expect(isSafeAssetPath('/etc/passwd'), isFalse);
    });

    test('开头的 .. 逃逸', () {
      expect(isSafeAssetPath('../evil.sh'), isFalse);
    });

    test('中间的 .. 逃逸', () {
      expect(isSafeAssetPath('scripts/../../evil.sh'), isFalse);
    });

    test('裸 .. 段', () {
      expect(isSafeAssetPath('..'), isFalse);
    });

    test('反斜杠（Windows 分隔符，在 POSIX 里是合法文件名字符但会造成歧义）',
        () {
      expect(isSafeAssetPath(r'scripts\evil.sh'), isFalse);
    });

    test('空字符串', () {
      expect(isSafeAssetPath(''), isFalse);
    });

    test('全是空白', () {
      expect(isSafeAssetPath('   '), isFalse);
    });

    test('前导空白', () {
      expect(isSafeAssetPath(' scripts/x.sh'), isFalse);
    });

    test('尾随空白', () {
      expect(isSafeAssetPath('scripts/x.sh '), isFalse);
    });

    test('空段（连续斜杠）', () {
      expect(isSafeAssetPath('scripts//x.sh'), isFalse);
    });

    test('尾随斜杠', () {
      expect(isSafeAssetPath('scripts/'), isFalse);
    });

    test('单点段', () {
      expect(isSafeAssetPath('./scripts/x.sh'), isFalse);
    });

    test('NUL 控制字符', () {
      expect(isSafeAssetPath('scripts/x\u0000.sh'), isFalse);
    });

    test('换行', () {
      expect(isSafeAssetPath('scripts/x\n.sh'), isFalse);
    });
  });

  group('parseAssetPath 规范化', () {
    test('首尾空白拒绝（所见即所得，不静默改写）', () {
      expect(parseAssetPath('  scripts/x.sh  '), isNull);
    });

    test('拒绝时返回 null', () {
      expect(parseAssetPath('../x.sh'), isNull);
    });
  });
}
