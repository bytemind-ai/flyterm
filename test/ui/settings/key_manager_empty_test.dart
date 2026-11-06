import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show Database;

import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/ssh_key.dart';
import 'package:flyterm/data/repositories/ssh_key_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/settings/key_manager_screen.dart';

/// Fake repo whose findAll resolves on a microtask (Future.value), so the
/// screen's FutureBuilder settles under the normal test clock — the real
/// sqflite-ffi future uses the wall clock and would hang pumpAndSettle.
class _FakeKeyRepo extends SSHKeyRepository {
  _FakeKeyRepo(super.db, this._keys);
  final List<SSHKey> _keys;
  @override
  Future<List<SSHKey>> findAll() => Future.value(_keys);
}

/// Regression for a.jpg: the empty state showed its own centered "add key"
/// CTA *and* the floating action button — two identical entries. The FAB must
/// be hidden while there are no keys, and appear once keys exist.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
  });
  tearDown(() async => db.close());

  Future<void> pump(WidgetTester tester, List<SSHKey> keys) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SSHKeyRepository>.value(value: _FakeKeyRepo(db, keys)),
          Provider<SecureStorageService>.value(value: SecureStorageService()),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: KeyManagerScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty state hides the FAB (only the centered CTA remains)',
      (tester) async {
    await pump(tester, []);
    // Empty state actually rendered (not stuck on the loading spinner).
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.vpn_key_outlined), findsOneWidget);
    // The fix: the FAB is hidden so the centered CTA is the only add entry.
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('FAB appears once at least one key exists', (tester) async {
    await pump(tester, const [
      SSHKey(id: 'k1', name: 'K', type: 'ed25519', publicKey: 'ssh-ed25519 AAAA'),
    ]);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });
}
