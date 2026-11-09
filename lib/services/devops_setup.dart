import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'tool_env.dart';

/// Penyiapan "praktik DevOps" di project aplikasi (semua file lama dibackup ke *.deployhub.bak):
///  • Lingkungan dev / staging / prod (--dart-define-from-file) + lib/config/env.dart
///  • Test dasar + coverage
///  • Firebase Crashlytics (laporan crash dari HP pengguna)

class SetupResult {
  final changes = <String>[];
  final notes = <String>[];
  String error = '';
  bool get ok => error.isEmpty;
}

Future<void> _backup(File f) async {
  if (await f.exists() && !await File('${f.path}.deployhub.bak').exists()) await f.copy('${f.path}.deployhub.bak');
}

/// Persentase baris yang dites dari coverage/lcov.info (null kalau tidak ada).
Future<double?> lcovPercent(File f) async {
  if (!await f.exists()) return null;
  var lf = 0, lh = 0;
  for (final l in await f.readAsLines()) {
    if (l.startsWith('LF:')) lf += int.tryParse(l.substring(3)) ?? 0;
    if (l.startsWith('LH:')) lh += int.tryParse(l.substring(3)) ?? 0;
  }
  return lf == 0 ? null : lh * 100 / lf;
}

// ───────────────────────── Lingkungan dev / staging / prod
/// [urls]: env → URL API backend (mis. dev: http://10.0.2.2:8000, staging: https://staging-api..., prod: https://api...).
Future<SetupResult> setupEnvironments(String root, Map<String, String> urls) async {
  final r = SetupResult();
  final envDir = Directory(p.join(root, 'env'));
  await envDir.create(recursive: true);
  for (final e in urls.entries) {
    final f = File(p.join(envDir.path, '${e.key}.json'));
    Map<String, dynamic> j = {};
    if (await f.exists()) {
      try {
        j = Map<String, dynamic>.from(jsonDecode(await f.readAsString()));
      } catch (_) {}
    }
    j['APP_ENV'] = e.key;
    j['API_URL'] = e.value;
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(j));
    r.changes.add('env/${e.key}.json');
  }
  final cfg = File(p.join(root, 'lib', 'config', 'env.dart'));
  if (!await cfg.exists()) {
    await cfg.parent.create(recursive: true);
    await cfg.writeAsString('''/// Lingkungan aplikasi — nilainya diisi saat build:
///   flutter run   --dart-define-from-file=env/dev.json
///   flutter build appbundle --dart-define-from-file=env/prod.json   (DeployHub otomatis)
/// Pakai di kode: `Env.apiUrl` menggantikan URL server yang ditulis langsung.
class Env {
  Env._();

  /// dev | staging | prod
  static const name = String.fromEnvironment('APP_ENV', defaultValue: 'dev');
  static const apiUrl = String.fromEnvironment('API_URL', defaultValue: '${urls['dev'] ?? 'http://10.0.2.2:8000'}');

  static bool get isProd => name == 'prod';
  static bool get isStaging => name == 'staging';
  static bool get isDev => name == 'dev';
}
''');
    r.changes.add('lib/config/env.dart');
  }
  // VS Code: tombol Run untuk tiap lingkungan
  final launch = File(p.join(root, '.vscode', 'launch.json'));
  if (!await launch.exists()) {
    await launch.parent.create(recursive: true);
    await launch.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'version': '0.2.0',
      'configurations': [
        for (final e in urls.keys)
          {'name': 'Flutter ($e)', 'request': 'launch', 'type': 'dart', 'args': ['--dart-define-from-file=env/$e.json']},
      ],
    }));
    r.changes.add('.vscode/launch.json');
  }
  r.notes.add('Ganti URL server yang ditulis langsung di kode dengan Env.apiUrl (import \'package:<app>/config/env.dart\').');
  r.notes.add('Isi env/*.json tidak boleh berisi password / secret — nilainya ikut masuk ke aplikasi.');
  return r;
}

// ───────────────────────── Test dasar
Future<SetupResult> createBasicTests(String root) async {
  final r = SetupResult();
  final pub = await File(p.join(root, 'pubspec.yaml')).readAsString().catchError((_) => '');
  final pkg = RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(pub)?.group(1) ?? 'app';
  final dir = Directory(p.join(root, 'test'));
  await dir.create(recursive: true);
  final hasEnv = await File(p.join(root, 'lib', 'config', 'env.dart')).exists();
  final f = File(p.join(dir.path, 'deployhub_basic_test.dart'));
  if (await f.exists()) {
    r.notes.add('test/deployhub_basic_test.dart sudah ada');
  } else {
    await f.writeAsString('''// Dibuat DeployHub — test dasar supaya CI benar-benar menguji kode, bukan hanya build.
// Jalankan: flutter test --coverage
import 'package:flutter_test/flutter_test.dart';
${hasEnv ? "import 'package:$pkg/config/env.dart';\n" : ''}
void main() {
${hasEnv ? '''  group('Env', () {
    test('lingkungan bawaan saat test adalah dev', () {
      expect(Env.name, 'dev');
      expect(Env.isProd, isFalse);
    });
    test('URL API valid', () {
      final uri = Uri.parse(Env.apiUrl);
      expect(uri.hasScheme, isTrue);
      expect(uri.host, isNotEmpty);
    });
  });

''' : ''}  group('Contoh test logika (ganti dengan fungsi aplikasimu)', () {
    // Contoh pola: test fungsi murni (format, validasi, hitungan) — paling mudah & paling berguna.
    String formatRupiah(int v) {
      final s = v.toString().replaceAllMapped(RegExp(r'\\B(?=(\\d{3})+(?!\\d))'), (m) => '.');
      return 'Rp \$s';
    }

    bool emailValid(String e) => RegExp(r'^[^@\\s]+@[^@\\s]+\\.[^@\\s]+\$').hasMatch(e);

    test('format rupiah', () {
      expect(formatRupiah(1500000), 'Rp 1.500.000');
      expect(formatRupiah(0), 'Rp 0');
    });
    test('validasi email login', () {
      expect(emailValid('test@gmail.com'), isTrue);
      expect(emailValid('salah@'), isFalse);
    });
  });

  // TODO yang disarankan untuk aplikasi chat:
  //  • fungsi parsing pesan dari server (JSON → model) — test dengan contoh JSON asli
  //  • validasi form login / register
  //  • format waktu pesan ("baru saja", "5 menit lalu")
  //  • widget test halaman login: tombol nonaktif saat input kosong
}
''');
    r.changes.add('test/deployhub_basic_test.dart');
  }
  // test template Flutter (Counter) yang selalu gagal → hapus (backup)
  final w = File(p.join(dir.path, 'widget_test.dart'));
  if (await w.exists() && (await w.readAsString()).contains('Counter increments smoke test')) {
    await _backup(w);
    await w.delete();
    r.changes.add('test/widget_test.dart (test template counter) dihapus — backup: widget_test.dart.deployhub.bak');
  }
  if (!RegExp(r'^\s+flutter_test:', multiLine: true).hasMatch(pub)) {
    r.notes.add('Tambahkan di pubspec.yaml → dev_dependencies:  flutter_test: { sdk: flutter }');
  }
  r.notes.add('Coverage tampil di pipeline (flutter test --coverage). Atur batas minimal di Edit proyek → Kualitas.');
  return r;
}

// ───────────────────────── Firebase Crashlytics
Future<SetupResult> setupCrashlytics(String root, String flutterCmd, void Function(String) log) async {
  final r = SetupResult();
  final pubFile = File(p.join(root, 'pubspec.yaml'));
  final pub = await pubFile.readAsString();
  if (!pub.contains('firebase_core')) {
    r.error = 'Proyek belum memakai Firebase (firebase_core). Jalankan Setup Firebase dulu.';
    return r;
  }
  // 1. dependency (versi dipilih otomatis yang cocok dengan firebase_core)
  if (!RegExp(r'^\s+firebase_crashlytics\s*:', multiLine: true).hasMatch(pub)) {
    await _backup(pubFile);
    log('\$ flutter pub add firebase_crashlytics');
    final res = await Process.run(flutterCmd, ['pub', 'add', 'firebase_crashlytics'], workingDirectory: root, runInShell: true, environment: ToolEnv.env());
    log('${res.stdout}${res.stderr}'.trim().split('\n').last);
    if (res.exitCode != 0) {
      r.error = 'flutter pub add firebase_crashlytics gagal — lihat log';
      return r;
    }
    r.changes.add('pubspec.yaml: + firebase_crashlytics');
  }
  // 2. plugin Gradle Crashlytics
  for (final kts in [true, false]) {
    final settings = File(p.join(root, 'android', kts ? 'settings.gradle.kts' : 'settings.gradle'));
    final app = File(p.join(root, 'android', 'app', kts ? 'build.gradle.kts' : 'build.gradle'));
    if (!await settings.exists() || !await app.exists()) continue;
    var st = await settings.readAsString();
    if (!st.contains('com.google.firebase.crashlytics')) {
      final line = kts ? '    id("com.google.firebase.crashlytics") version "3.0.2" apply false' : '    id "com.google.firebase.crashlytics" version "3.0.2" apply false';
      final m = RegExp(r'plugins\s*\{\s*\n').firstMatch(st.substring(st.indexOf('plugins') < 0 ? 0 : st.indexOf('plugins')));
      if (m != null) {
        final at = st.indexOf('plugins') + m.end;
        st = '${st.substring(0, at)}$line\n${st.substring(at)}';
        await _backup(settings);
        await settings.writeAsString(st);
        r.changes.add('${p.basename(settings.path)}: + plugin crashlytics 3.0.2');
      } else {
        r.notes.add('Tambahkan plugin com.google.firebase.crashlytics di ${p.basename(settings.path)} secara manual');
      }
    }
    var ap = await app.readAsString();
    if (!ap.contains('com.google.firebase.crashlytics')) {
      final line = kts ? '    id("com.google.firebase.crashlytics")' : '    id "com.google.firebase.crashlytics"';
      final m = RegExp(r'plugins\s*\{\s*\n').firstMatch(ap);
      if (m != null) {
        ap = '${ap.substring(0, m.end)}$line\n${ap.substring(m.end)}';
        await _backup(app);
        await app.writeAsString(ap);
        r.changes.add('android/app/${p.basename(app.path)}: + plugin crashlytics');
      }
    }
    break;
  }
  // 3. main.dart: kirim semua error ke Crashlytics
  final mainFile = File(p.join(root, 'lib', 'main.dart'));
  var main = await mainFile.readAsString();
  if (!main.contains('FirebaseCrashlytics')) {
    final init = RegExp(r'await\s+Firebase\.initializeApp\([^;]*\);').firstMatch(main);
    if (init == null) {
      r.notes.add('Firebase.initializeApp tidak ditemukan di lib/main.dart — tambahkan manual setelah inisialisasi Firebase:\n'
          '  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;\n'
          '  PlatformDispatcher.instance.onError = (e, s) { FirebaseCrashlytics.instance.recordError(e, s, fatal: true); return true; };');
    } else {
      const hook = '\n  // Crashlytics: semua error Flutter & Dart dikirim ke Firebase Console → Crashlytics\n'
          '  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;\n'
          '  PlatformDispatcher.instance.onError = (error, stack) {\n'
          '    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);\n'
          '    return true;\n'
          '  };';
      main = '${main.substring(0, init.end)}$hook${main.substring(init.end)}';
      final imports = ["import 'dart:ui';", "import 'package:firebase_crashlytics/firebase_crashlytics.dart';"];
      for (final i in imports.reversed) {
        if (!main.contains(i)) main = '$i\n$main';
      }
      await _backup(mainFile);
      await mainFile.writeAsString(main);
      r.changes.add('lib/main.dart: error dikirim ke Crashlytics');
    }
  }
  r.notes.add('Build dengan --obfuscate: DeployHub mengupload simbol ke Crashlytics otomatis setiap build produksi supaya stack trace terbaca.');
  r.notes.add('Aktifkan Crashlytics sekali di Firebase Console → Crashlytics → Enable.');
  return r;
}

/// App ID Firebase (1:xxx:android:yyy) untuk package dari google-services.json.
Future<String?> firebaseAndroidAppId(String root, String package) async {
  final f = File(p.join(root, 'android', 'app', 'google-services.json'));
  if (!await f.exists()) return null;
  try {
    final j = jsonDecode(await f.readAsString());
    for (final c in (j['client'] as List? ?? const [])) {
      if (c['client_info']?['android_client_info']?['package_name'] == package) return '${c['client_info']['mobilesdk_app_id']}';
    }
  } catch (_) {}
  return null;
}

Future<bool> usesCrashlytics(String root) async =>
    RegExp(r'^\s+firebase_crashlytics\s*:', multiLine: true).hasMatch(await File(p.join(root, 'pubspec.yaml')).readAsString().catchError((_) => ''));
