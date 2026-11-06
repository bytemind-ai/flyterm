import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/dead_ssh_clients.dart';

void main() {
  group('DeadSshClients', () {
    test('mark 之后 isMarked 为 true', () {
      final client = Object();
      DeadSshClients.mark(client);
      expect(DeadSshClients.isMarked(client), isTrue);
    });

    test('没 mark 过的对象 isMarked 为 false', () {
      final client = Object();
      expect(DeadSshClients.isMarked(client), isFalse);
    });

    test('clearForTest 之后回到 false', () {
      final client = Object();
      DeadSshClients.mark(client);
      expect(DeadSshClients.isMarked(client), isTrue);
      DeadSshClients.clearForTest(client);
      expect(DeadSshClients.isMarked(client), isFalse);
    });

    test('两个不同对象互不影响', () {
      final a = Object();
      final b = Object();
      DeadSshClients.mark(a);
      expect(DeadSshClients.isMarked(a), isTrue);
      expect(DeadSshClients.isMarked(b), isFalse);
    });
  });
}
