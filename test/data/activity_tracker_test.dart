import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/activity_tracker.dart';

void main() {
  group('ActivityTracker', () {
    test('initial state: not active', () {
      final t = ActivityTracker.testInstance();
      expect(t.active, isFalse);
    });

    test('recordInput sets active=true', () {
      final t = ActivityTracker.testInstance();
      t.recordInput();
      expect(t.active, isTrue);
    });

    test('active decays to false after 30s of no input', () {
      fakeAsync((async) {
        final t = ActivityTracker.testInstance();
        t.recordInput();
        expect(t.active, isTrue);
        async.elapse(const Duration(seconds: 31));
        expect(t.active, isFalse);
      });
    });

    test('recordInput within window keeps active=true', () {
      fakeAsync((async) {
        final t = ActivityTracker.testInstance();
        t.recordInput();
        async.elapse(const Duration(seconds: 20));
        t.recordInput();
        async.elapse(const Duration(seconds: 20));
        expect(t.active, isTrue);
        async.elapse(const Duration(seconds: 11));
        expect(t.active, isFalse);
      });
    });
  });
}
