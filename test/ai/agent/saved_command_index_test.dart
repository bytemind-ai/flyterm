import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/saved_command_index.dart';
import 'package:flyterm/data/models/favorite_command.dart';

void main() {
  FavoriteCommand c(String name, String command) =>
      FavoriteCommand(id: name, name: name, command: command, aiEnabled: true);

  test('空清单返回 null —— 调用方据此整段跳过', () {
    expect(composeSavedCommandIndex(const []), isNull);
  });

  test('三段：名字 [参数] 命令模板', () {
    final out = composeSavedCommandIndex([
      c('部署服务',
          'deploy-cli deploy --service {{service}} --version {{version}}'),
    ])!;
    expect(out, contains('部署服务 [service, version]: deploy-cli deploy'));
  });

  test('无参数的显示成空方括号', () {
    final out = composeSavedCommandIndex([c('重启网关', 'systemctl restart gw')])!;
    expect(out, contains('重启网关 []: systemctl restart gw'));
  });

  test('标题里点名 run_saved_command', () {
    expect(composeSavedCommandIndex([c('a', 'ls')])!,
        contains('run_saved_command'));
  });

  test('保持传入顺序', () {
    final out = composeSavedCommandIndex([c('first', 'ls'), c('second', 'ps')])!;
    expect(out.indexOf('first'), lessThan(out.indexOf('second')));
  });

  test('超长模板截断并留省略号', () {
    final long = 'awk ${'x' * 400}';
    final out = composeSavedCommandIndex([c('big', long)])!;
    expect(out.length, lessThan(long.length));
    expect(out, contains('…'));
  });

  test('截断只影响索引，不影响原对象', () {
    final long = 'awk ${'x' * 400}';
    final cmd = c('big', long);
    composeSavedCommandIndex([cmd]);
    expect(cmd.command, equals(long), reason: '执行要用完整模板');
  });

  test('多字节字符卡在截断点时不留残缺字节', () {
    final long = '中' * 300; // 每个 3 字节，必然切断
    final out = composeSavedCommandIndex([c('cjk', long)])!;
    expect(out, isNot(contains('\u{FFFD}')));
  });
}
