// SPDX-License-Identifier: GPL-3.0-or-later
class SSHKey {
  final String id;
  final String name;
  final String type; // 'ed25519' | 'rsa'
  final String publicKey; // OpenSSH public key string

  const SSHKey({
    required this.id,
    required this.name,
    required this.type,
    required this.publicKey,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'type': type,
        'public_key': publicKey,
      };

  factory SSHKey.fromMap(Map<String, dynamic> map) => SSHKey(
        id: map['id'] as String,
        name: map['name'] as String,
        type: map['type'] as String,
        publicKey: map['public_key'] as String,
      );
}
