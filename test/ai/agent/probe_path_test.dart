import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/shell_guard.dart';
import 'package:flyterm/ai/agent/file_edit.dart';
import 'package:flyterm/ai/agent/skill.dart';

void main() {
  test('probe: HOME 开头的 installDir 被如何引用', () {
    // installDir 的实际形状（skill_executors.dart:267 用 \$HOME 字面量）
    const installDir = r'$HOME/.flyterm/skills/check-deploy';
    print('installDir          = $installDir');
    print('shellQuotePath(dir) = ${shellQuotePath(installDir)}');

    final cmd = buildInstallAssetsCommand(installDir, [
      const AgentSkillAsset(path: 'scripts/check.sh', content: 'echo hi\n'),
    ]);
    print('COMMAND = $cmd');
  });
}
