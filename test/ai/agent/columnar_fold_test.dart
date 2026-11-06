import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';

void main() {
  group('foldColumnar —— 结构相同、只有一列不同的行组', () {
    // 现场一：stat -f 的 58 行，每行只有路径不同，信息量其实是 1 行。
    test('58 行只有首列不同 → 折叠', () {
      final raw = [
        for (final p in ['/root/.z', '/root/.ssh', '/root/.kube', '/root/.gcp',
                         '/usr/bin/nvidia-smi', '/usr/lib/libcuda.so'])
          '$p 9256788*4096',
      ].join('\n');

      final out = foldColumnar(raw);
      expect(out.split('\n').length, lessThan(6),
          reason: '6 行只有一列不同，应该被折叠');
      expect(out, contains('9256788*4096'), reason: '恒定部分要保留一次');
      expect(out, contains('/root/.z'), reason: '变化的值要列出来');
      expect(out, contains('6'), reason: '要说明折叠了多少行');
    });

    // 现场二：mount | grep 的 50+ 行 nvidia 绑定挂载。
    test('中间列不同也能折叠', () {
      final raw = [
        for (final p in ['/root/.z', '/root/.ssh', '/root/.kube', '/root/.gcp'])
          '/dev/root on $p type ext4 (rw,relatime,discard)',
      ].join('\n');

      final out = foldColumnar(raw);
      expect(out.split('\n').length, lessThan(4));
      expect(out, contains('/dev/root'));
      expect(out, contains('ext4'));
    });

    test('行数不足阈值时原样返回 —— 折叠两三行不划算', () {
      const raw = 'a 1\nb 1';
      expect(foldColumnar(raw), raw);
    });

    test('列数不一致的行不被合并', () {
      const raw = 'a 1 x\nb 1\nc 1 y\nd 1 z';
      final out = foldColumnar(raw);
      expect(out, contains('b 1'), reason: '列数不同的行必须原样保留');
    });

    // 这条守的是边界：df 的噪音是语义性的（tmpfs 无关磁盘告警），
    // 各列都在变，机械折叠吃不掉也不该硬吃。
    test('各列都在变时不折叠 —— 那是真实信息不是冗余', () {
      const raw = 'overlay 1.5T 790G 53% /\n'
          'tmpfs 64M 0 0% /dev\n'
          'nvme0n2 1.5T 790G 53% /data\n'
          'tmpfs 24G 0 0% /proc/acpi';
      final out = foldColumnar(raw);
      expect(out, equals(raw), reason: '恒定列太少，不该折叠');
    });

    test('空串与单行安全', () {
      expect(foldColumnar(''), '');
      expect(foldColumnar('only one line'), 'only one line');
    });

    test('折叠后变化值过多时截断并标注剩余数', () {
      final raw = [
        for (var i = 0; i < 40; i++) '/path/number$i CONST',
      ].join('\n');
      final out = foldColumnar(raw);
      expect(out, contains('more'), reason: '值列表要截断并说明省略了多少');
      expect(out.length, lessThan(raw.length ~/ 2));
    });

    test('不跨空行分组 —— 空行是语义分段', () {
      final raw = 'a CONST\nb CONST\nc CONST\nd CONST\n'
          '\n'
          'e OTHER\nf OTHER\ng OTHER\nh OTHER';
      final out = foldColumnar(raw);
      expect(out, contains('CONST'));
      expect(out, contains('OTHER'));
      expect(out.split('\n\n').length, 2, reason: '两段应各自折叠，不合并');
    });
  });
}
