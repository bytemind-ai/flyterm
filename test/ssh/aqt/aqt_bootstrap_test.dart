import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AQT line regex accepts valid lines', () {
    final re = RegExp(r'^AQT_(VER|PORT|PUBKEY|TOKEN)=([A-Za-z0-9+/=._-]+)$');
    expect(re.hasMatch('AQT_VER=1'), isTrue);
    expect(re.hasMatch('AQT_PORT=51232'), isTrue);
    expect(re.hasMatch('AQT_PUBKEY=MFowDQ'), isTrue);
    expect(re.hasMatch('AQT_TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'),
        isTrue);
    // invalid
    expect(re.hasMatch('AQT_FOO=bar'), isFalse);
    expect(re.hasMatch(';AQT_VER=1'), isFalse);
    expect(re.hasMatch('echo hello'), isFalse);
  });
}
