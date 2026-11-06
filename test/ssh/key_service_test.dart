import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/key_service.dart';

void main() {
  test('generates ed25519 key pair with public key in OpenSSH format',
      () async {
    final pair = await KeyService.generateEd25519();
    expect(pair.publicKeyOpenSSH, startsWith('ssh-ed25519 '));
    expect(pair.privateKeyPem, contains('BEGIN OPENSSH PRIVATE KEY'));
  });

  test('parses imported PEM and returns public key', () async {
    final pair = await KeyService.generateEd25519();
    final reimported = await KeyService.importFromPem(pair.privateKeyPem);
    expect(reimported.publicKeyOpenSSH, equals(pair.publicKeyOpenSSH));
  });
}
