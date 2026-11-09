// Contoh integration test login untuk dipakai DeployHub.
// Salin ke project aplikasi kamu: <project>/integration_test/login_test.dart
//
// pubspec.yaml aplikasi:
//   dev_dependencies:
//     integration_test:
//       sdk: flutter
//     flutter_test:
//       sdk: flutter
//
// DeployHub menjalankan:
//   flutter test integration_test --dart-define=TEST_USER=... --dart-define=TEST_PASS=...
//
// Sesuaikan Key widget di bawah dengan halaman login aplikasi kamu, mis.
//   TextField(key: const Key('login_user'), ...)
//   TextField(key: const Key('login_password'), ...)
//   ElevatedButton(key: const Key('login_button'), ...)
//   dan halaman setelah login punya widget dengan Key('home_page').

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:batamchitchat/main.dart' as app; // ganti sesuai nama package

const testUser = String.fromEnvironment('TEST_USER');
const testPass = String.fromEnvironment('TEST_PASS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Akun demo reviewer bisa login', (tester) async {
    expect(testUser, isNotEmpty, reason: 'TEST_USER belum dikirim');
    expect(testPass, isNotEmpty, reason: 'TEST_PASS belum dikirim');

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    await tester.enterText(find.byKey(const Key('login_user')), testUser);
    await tester.enterText(find.byKey(const Key('login_password')), testPass);
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle(const Duration(seconds: 8));

    expect(find.byKey(const Key('home_page')), findsOneWidget,
        reason: 'Setelah login, halaman utama tidak muncul');
  });
}
