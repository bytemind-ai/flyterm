import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/update/version_compare.dart';

void main() {
  group('VersionCompare', () {
    test('newer patch is greater', () {
      expect(VersionCompare.isNewer('2.3.11', current: '2.3.10'), isTrue);
    });
    test('same version is not newer', () {
      expect(VersionCompare.isNewer('2.3.10', current: '2.3.10'), isFalse);
    });
    test('older version is not newer', () {
      expect(VersionCompare.isNewer('2.3.9', current: '2.3.10'), isFalse);
    });
    test('newer minor beats older patch', () {
      expect(VersionCompare.isNewer('2.4.0', current: '2.3.99'), isTrue);
    });
    test('newer major beats older minor', () {
      expect(VersionCompare.isNewer('3.0.0', current: '2.99.99'), isTrue);
    });
    test('v prefix is stripped', () {
      expect(VersionCompare.isNewer('v2.3.11', current: 'v2.3.10'), isTrue);
    });
    test('malformed version returns false (defensive)', () {
      expect(VersionCompare.isNewer('garbage', current: '2.3.10'), isFalse);
      expect(VersionCompare.isNewer('2.3.11', current: 'garbage'), isFalse);
    });
    test('extra suffix is ignored', () {
      expect(VersionCompare.isNewer('2.3.11+8', current: '2.3.10+5'), isTrue);
      expect(VersionCompare.isNewer('2.3.11-beta', current: '2.3.10'), isTrue);
    });
  });
}
