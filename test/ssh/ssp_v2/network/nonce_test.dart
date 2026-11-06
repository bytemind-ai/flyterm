import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/ssp_v2/network/nonce.dart';

void main() {
  test('emits 12 bytes, monotonically increasing low 64 bits', () {
    final g = NonceGenerator(direction: NonceDirection.client);
    final a = g.next();
    final b = g.next();
    expect(a.length, 12);
    expect(b.length, 12);
    int aLow = 0, bLow = 0;
    for (var i = 4; i < 12; i++) {
      aLow = (aLow << 8) | a[i];
      bLow = (bLow << 8) | b[i];
    }
    expect(bLow, greaterThan(aLow));
  });

  test('client and server directions differ in top bit of byte 4', () {
    final c = NonceGenerator(direction: NonceDirection.client).next();
    final s = NonceGenerator(direction: NonceDirection.server).next();
    expect(c[4] & 0x80, 0);
    expect(s[4] & 0x80, 0x80);
    // First 4 bytes are always zero (mosh-server reads only out[4..12]).
    for (var i = 0; i < 4; i++) {
      expect(c[i], 0);
      expect(s[i], 0);
    }
  });
}
