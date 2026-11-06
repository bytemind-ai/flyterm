import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/command_history_service.dart';

void main() {
  test('records normal commands for prefix completion', () {
    final service = CommandHistoryService();

    service.recordCommand('git status');

    expect(service.filter('gi'), ['git status']);
  });

  test('filters terminal device/status responses from history', () {
    final service = CommandHistoryService();

    service.recordCommand('?1;2c>0;0;0c?1;2c>0;0;0c');
    service.recordCommand('>0;0;0c');
    service.recordCommand('\x1b[?1;2c');
    service.recordCommand('git status');

    expect(service.filter('?1'), isEmpty);
    expect(service.filter('>0'), isEmpty);
    expect(service.filter('gi'), ['git status']);
  });
}
