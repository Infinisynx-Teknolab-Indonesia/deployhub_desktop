import 'dart:io';

import 'package:path/path.dart' as p;

import 'keystore_tool.dart';
import 'tool_env.dart';

/// Perbaikan otomatis android/app/build.gradle(.kts) sebelum build release.
/// Setiap perubahan dibackup ke *.deployhub.bak. Mengembalikan daftar yang diubah / peringatan.
class GradleFixResult {
  final fixed = <String>[];
  final warnings = <String>[];
}

Future<GradleFixResult> fixGradle(String root, {String packageName = ''}) async {
  final res = GradleFixResult();

  // 1) Kotlin DSL: java.util.Properties() tanpa import → "Unresolved reference 'util' / 'io'"
  final kts = await fixGradleKtsImports(root);
  if (kts != null) res.fixed.add(kts);

  // 1b) Windows: project di drive lain dari Pub Cache (mis. D: vs C:) → Kotlin incremental
  //     compile gagal "Could not close incremental caches". Matikan incremental Kotlin.
  if (Platform.isWindows) {
    final pubCache = Platform.environment['PUB_CACHE'] ?? '${Platform.environment['LOCALAPPDATA'] ?? 'C:'}\\Pub\\Cache';
    final projDrive = p.rootPrefix(p.absolute(root)).toUpperCase();
    final cacheDrive = p.rootPrefix(pubCache).toUpperCase();
    if (projDrive.isNotEmpty && cacheDrive.isNotEmpty && projDrive != cacheDrive) {
      final m = await setKotlinIncrementalOff(root);
      if (m != null) res.fixed.add('$m (project di $projDrive, Pub Cache di $cacheDrive)');
    }
  }

  // 2) applicationId harus sama dengan package di Google Play / Firebase
  File? g;
  for (final n in ['build.gradle.kts', 'build.gradle']) {
    final f = File(p.join(root, 'android', 'app', n));
    if (await f.exists()) {
      g = f;
      break;
    }
  }
  if (g == null) {
    res.warnings.add('android/app/build.gradle tidak ditemukan');
    return res;
  }
  var s = await g.readAsString();
  final isKts = g.path.endsWith('.kts');
  final idRe = RegExp(r'''applicationId\s*=?\s*["']([^"']+)["']''');
  final cur = idRe.firstMatch(s)?.group(1) ?? '';
  if (packageName.isNotEmpty && cur.isNotEmpty && cur != packageName) {
    await g.copy('${g.path}.deployhub.bak');
    s = s.replaceFirst(idRe, isKts ? 'applicationId = "$packageName"' : 'applicationId "$packageName"');
    await g.writeAsString(s);
    res.fixed.add('applicationId: $cur → $packageName (sesuai package di Google Play / Firebase)');
  } else if (cur.startsWith('com.example')) {
    res.warnings.add('applicationId masih "$cur" — Google Play menolak com.example. Isi Package name di Edit proyek.');
  }

  // 2b) AndroidManifest (main): izin INTERNET wajib — template Flutter hanya menaruhnya di debug,
  //     jadi versi release tidak bisa konek ke server. AdMob wajib APPLICATION_ID (kalau tidak, crash saat dibuka).
  final man = File(p.join(root, 'android', 'app', 'src', 'main', 'AndroidManifest.xml'));
  if (await man.exists()) {
    var m = await man.readAsString();
    if (!m.contains('android.permission.INTERNET')) {
      await man.copy('${man.path}.deployhub.bak');
      m = m.replaceFirstMapped(RegExp(r'<manifest[^>]*>'),
          (x) => '${x.group(0)}\n    <uses-permission android:name="android.permission.INTERNET"/>');
      await man.writeAsString(m);
      res.fixed.add('AndroidManifest.xml: + izin INTERNET (tanpa ini versi release tidak bisa konek ke server)');
    }
    final pub = await File(p.join(root, 'pubspec.yaml')).readAsString().catchError((_) => '');
    if (pub.contains('google_mobile_ads') && !m.contains('com.google.android.gms.ads.APPLICATION_ID')) {
      res.warnings.add('AndroidManifest.xml belum punya meta-data com.google.android.gms.ads.APPLICATION_ID — aplikasi dengan google_mobile_ads CRASH saat dibuka. Tambahkan App ID dari AdMob di dalam <application>.');
    }
  }

  // 3) google-services.json harus punya client untuk package ini
  final gs = File(p.join(root, 'android', 'app', 'google-services.json'));
  final pkg = packageName.isNotEmpty ? packageName : cur;
  if (await gs.exists() && pkg.isNotEmpty && s.contains('google-services')) {
    final j = await gs.readAsString();
    if (!j.contains('"package_name": "$pkg"') && !j.contains('"package_name":"$pkg"')) {
      res.warnings.add(
          'google-services.json belum berisi package $pkg — build akan gagal "No matching client found". Buka Edit proyek → Firebase → Siapkan Firebase (langkah 4 Buat konfigurasi).');
    }
  }
  return res;
}

/// android/gradle.properties: kotlin.incremental=false. Mengembalikan pesan kalau diubah.
Future<String?> setKotlinIncrementalOff(String root) async {
  final f = File(p.join(root, 'android', 'gradle.properties'));
  final cur = await f.exists() ? await f.readAsString() : '';
  if (RegExp(r'^\s*kotlin\.incremental\s*=\s*false', multiLine: true).hasMatch(cur)) return null;
  final next = cur.contains('kotlin.incremental=')
      ? cur.replaceAll(RegExp(r'^\s*kotlin\.incremental\s*=.*$', multiLine: true), 'kotlin.incremental=false')
      : '${cur.trimRight()}\n# [DeployHub] Kotlin incremental gagal kalau project & Pub Cache beda drive (Windows)\nkotlin.incremental=false\n';
  await f.writeAsString(next);
  return 'gradle.properties: kotlin.incremental=false';
}

/// Tambahkan blok di android/build.gradle(.kts) yang memaksa compileSdk [sdk] untuk semua plugin
/// (library Android). Cara aman untuk plugin lama yang masih compileSdk 33/34.
Future<String?> forcePluginCompileSdk(String root, int sdk) async {
  File? f;
  for (final n in ['build.gradle.kts', 'build.gradle']) {
    final x = File(p.join(root, 'android', n));
    if (await x.exists()) {
      f = x;
      break;
    }
  }
  if (f == null) return null;
  var s = await f.readAsString();
  if (s.contains('[DeployHub] compileSdk plugin')) {
    s = s.replaceAll(RegExp(r'compileSdkVersion\(\d+\) // \[DeployHub\]'), 'compileSdkVersion($sdk) // [DeployHub]');
    await f.writeAsString(s);
    return 'compileSdk plugin = $sdk';
  }
  final kts = f.path.endsWith('.kts');
  final block = kts
      ? '''
// [DeployHub] compileSdk plugin: paksa semua plugin memakai compileSdk $sdk
subprojects {
    afterEvaluate {
        val ext = extensions.findByName("android")
        if (ext is com.android.build.gradle.BaseExtension) {
            ext.compileSdkVersion($sdk) // [DeployHub]
        }
    }
}
'''
      : '''
// [DeployHub] compileSdk plugin: paksa semua plugin memakai compileSdk $sdk
subprojects {
    afterEvaluate { project ->
        if (project.hasProperty("android")) {
            project.android { compileSdkVersion($sdk) } // [DeployHub]
        }
    }
}
''';
  // Harus SEBELUM evaluationDependsOn(":app"), kalau tidak afterEvaluate terlambat dipasang.
  final idx = s.indexOf(RegExp(r'subprojects\s*\{\s*\n?\s*project\.evaluationDependsOn'));
  await f.copy('${f.path}.deployhub.bak');
  s = idx >= 0 ? s.replaceRange(idx, idx, '$block\n') : '$s\n$block';
  await f.writeAsString(s);
  return 'android/${p.basename(f.path)}: compileSdk semua plugin dipaksa $sdk';
}

/// Kenali error Gradle yang umum dari output build → saran perbaikan (untuk ditampilkan di log).
String? explainGradleError(List<String> logs) {
  final t = logs.join('\n');
  if (t.contains('No matching client found for package name')) {
    final m = RegExp(r"No matching client found for package name '([^']+)'").firstMatch(t);
    return 'google-services.json tidak punya package ${m?.group(1) ?? ''}. Jalankan Edit proyek → Firebase → Siapkan Firebase → Buat konfigurasi, lalu Jalankan ulang.';
  }
  if (t.contains('Keystore file') && t.contains('not found')) {
    return 'File keystore di key.properties tidak ditemukan. Cek storeFile di android/key.properties (path relatif dari folder android/app).';
  }
  if (t.contains('Keystore was tampered with, or password was incorrect')) {
    return 'Password keystore di android/key.properties salah.';
  }
  if (t.contains('Missing classes detected while running R8')) {
    return 'R8 menemukan class yang hilang. Salin aturan -dontwarn dari build/app/outputs/mapping/release/missing_rules.txt ke android/app/proguard-rules.pro, lalu Jalankan ulang.';
  }
  if (t.contains('requires Android SDK version') || t.contains('compileSdk')) {
    return 'Plugin butuh compileSdk lebih tinggi. Upgrade Flutter (flutter upgrade) atau set compileSdk = 36 di build.gradle.';
  }
  if (t.contains('Could not close incremental caches')) {
    return 'Kotlin incremental gagal (project & Pub Cache beda drive). Tambahkan kotlin.incremental=false di android/gradle.properties, flutter clean, lalu build lagi — atau klik "Perbaiki otomatis".';
  }
  final plug = RegExp(r"Pub[\\/]Cache[\\/]hosted[\\/][^\\/]+[\\/]([a-z0-9_]+)-([0-9][^\\/]*)[\\/]android", caseSensitive: false).firstMatch(t);
  if (plug != null) {
    return 'Plugin ${plug.group(1)} ${plug.group(2)} tidak cocok dengan Gradle sekarang. Upgrade: flutter pub upgrade --major-versions ${plug.group(1)} (atau klik "Perbaiki otomatis").';
  }
  if (t.contains('Could not resolve all') || t.contains('Could not GET')) {
    return 'Gradle gagal mengunduh dependency — cek koneksi internet / proxy, lalu Jalankan ulang.';
  }
  return null;
}

/// Satu perbaikan otomatis yang bisa dijalankan dari panel "Pipeline gagal".
class AutoFix {
  AutoFix(this.problem, this.action, this.run);
  final String problem; // apa yang salah (bahasa biasa)
  final String action; // apa yang akan dilakukan tombol
  final Future<List<String>> Function() run; // jalankan perbaikan → daftar perubahan
}

/// Baca log pipeline yang gagal → daftar perbaikan yang bisa dilakukan otomatis.
List<AutoFix> autoFixesFromLog(List<String> logs, {required String root, String packageName = '', String flutterCmd = 'flutter'}) {
  final t = logs.join('\n');
  final out = <AutoFix>[];

  // Plugin Flutter versi lama yang build.gradle-nya tidak cocok dengan Gradle / AGP baru, mis.
  // "Build file '...\Pub\Cache\hosted\pub.dev\google_mobile_ads-5.3.1\android\build.gradle'"
  final pluginRe = RegExp(r"Build file '[^']*[\\/]Pub[\\/]Cache[\\/]hosted[\\/][^\\/]+[\\/]([a-z0-9_]+)-([0-9][^\\/]*)[\\/]android[\\/]build\.gradle", caseSensitive: false);
  final plugins = <String, String>{for (final m in pluginRe.allMatches(t)) m.group(1)!: m.group(2)!};
  // ":file_picker is currently compiled against android-34" → paksa compileSdk semua plugin
  // (tanpa mengubah versi paket — upgrade paket sering bentrok, mis. win32 5 vs 6).
  final low = RegExp(r':([a-z0-9_]+) is currently compiled against android-(\d+)').allMatches(t).map((m) => m.group(1)!).toSet();
  final need = int.tryParse(RegExp(r'compile against version (\d+) or later').firstMatch(t)?.group(1) ?? '') ?? 36;
  if (low.isNotEmpty) {
    out.add(AutoFix(
      'Plugin ${low.join(', ')} masih dikompilasi untuk Android API lama, padahal butuh API $need',
      'Paksa compileSdk $need untuk semua plugin di android/build.gradle(.kts) — versi paket tidak diubah (backup dibuat)',
      () async {
        final m = await forcePluginCompileSdk(root, need);
        return [m ?? 'compileSdk plugin sudah dipaksa $need'];
      },
    ));
  }
  for (final e in plugins.entries) {
    out.add(AutoFix(
      'Plugin ${e.key} ${e.value} terlalu lama untuk versi Gradle/Android Gradle Plugin sekarang (error di build.gradle milik plugin itu)',
      'Upgrade ${e.key} ke versi terbaru: flutter pub upgrade --major-versions ${e.key} (pubspec.yaml ikut diperbarui, backup dibuat)',
      () async {
        final pub = File(p.join(root, 'pubspec.yaml'));
        if (await pub.exists()) await pub.copy('${pub.path}.deployhub.bak');
        Future<ProcessResult> up(List<String> pkgs) => Process.run(flutterCmd, ['pub', 'upgrade', '--major-versions', ...pkgs],
            workingDirectory: root, runInShell: true, environment: ToolEnv.env());
        var r = await up([e.key]);
        var txt = '${r.stdout}${r.stderr}';
        // Bentrok versi ("depends on both A ^x and B ^y") → upgrade keduanya bersamaan
        final both = RegExp(r'depends on both ([a-z0-9_]+) \S+ and ([a-z0-9_]+) ').firstMatch(txt);
        if ((r.exitCode != 0 || txt.contains('version solving failed')) && both != null) {
          final pkgs = {e.key, both.group(1)!, both.group(2)!}.toList();
          r = await up(pkgs);
          txt = '${r.stdout}${r.stderr}';
        }
        // Masih gagal → pakai saran pub sendiri ("flutter pub add file_picker:^11.0.3")
        final sug = RegExp(r'flutter pub add ([a-z0-9_]+:\^?[0-9][^\s]*)').firstMatch(txt);
        if ((r.exitCode != 0 || txt.contains('version solving failed')) && sug != null) {
          r = await Process.run(flutterCmd, ['pub', 'add', sug.group(1)!],
              workingDirectory: root, runInShell: true, environment: ToolEnv.env());
          txt = '${r.stdout}${r.stderr}';
        }
        final changed = RegExp('${e.key}[^\n]*→[^\n]*|${e.key}: \\^[0-9.]+[^\n]*').allMatches(txt).map((m) => m.group(0)!.trim()).toList();
        return [
          if (r.exitCode == 0) '${e.key} diupgrade${changed.isEmpty ? '' : ' (${changed.first})'}' else '✖ pub upgrade ${e.key} gagal: ${txt.split('\n').where((l) => l.trim().isNotEmpty).take(3).join(' ')}',
          'Cek kode yang memakai ${e.key}: versi mayor baru kadang mengganti nama class/parameter.',
        ];
      },
    ));
  }

  final ktsImport = t.contains("Unresolved reference 'util'") || t.contains("Unresolved reference 'io'");
  final idMismatch = RegExp(r"No matching client found for package name '([^']+)'").firstMatch(t);
  if (ktsImport || (idMismatch != null && packageName.isNotEmpty && idMismatch.group(1) != packageName)) {
    out.add(AutoFix(
      ktsImport
          ? 'build.gradle.kts memakai java.util.Properties / java.io.FileInputStream tanpa import (Unresolved reference)'
          : 'applicationId (${idMismatch!.group(1)}) berbeda dengan package proyek ($packageName)',
      'Perbaiki build.gradle.kts: tambah import, samakan applicationId (backup dibuat)',
      () async {
        final r = await fixGradle(root, packageName: packageName);
        return [...r.fixed, ...r.warnings.map((w) => '⚠ $w')];
      },
    ));
  }

  if (t.contains('Could not close incremental caches') || t.contains('this and base files have different roots')) {
    out.add(AutoFix(
      'Kompilasi Kotlin gagal: "Could not close incremental caches" (biasanya project di drive D: sedangkan Pub Cache di C:)',
      'Matikan Kotlin incremental (kotlin.incremental=false di android/gradle.properties) + hapus cache build lama',
      () async {
        final m = await setKotlinIncrementalOff(root);
        // cache Kotlin yang rusak
        for (final d in ['build', p.join('android', '.gradle'), p.join('android', 'app', 'build')]) {
          final dir = Directory(p.join(root, d));
          try {
            if (await dir.exists()) await dir.delete(recursive: true);
          } catch (_) {}
        }
        return [m ?? 'kotlin.incremental sudah false', 'folder build/ & android/.gradle dibersihkan'];
      },
    ));
  }

  if (t.contains('Missing classes detected while running R8')) {
    out.add(AutoFix(
      'R8 menemukan class yang hilang (Missing classes detected while running R8)',
      'Salin aturan dari missing_rules.txt ke proguard-rules.pro',
      () async {
        final miss = File(p.join(root, 'build', 'app', 'outputs', 'mapping', 'release', 'missing_rules.txt'));
        final rules = File(p.join(root, 'android', 'app', 'proguard-rules.pro'));
        if (!await miss.exists()) return ['⚠ missing_rules.txt tidak ditemukan'];
        final add = await miss.readAsString();
        final cur = await rules.exists() ? await rules.readAsString() : '';
        await rules.writeAsString('${cur.trimRight()}\n\n# [DeployHub] dari missing_rules.txt\n$add\n');
        return ['proguard-rules.pro: + ${add.split('\n').where((l) => l.trim().startsWith('-')).length} aturan -dontwarn'];
      },
    ));
  }

  if (t.contains("The name 'MyApp' isn't a class") && t.contains('widget_test.dart')) {
    out.add(AutoFix(
      'test/widget_test.dart masih contoh template Flutter (MyApp tidak ada)',
      'Ganti nama jadi widget_test.dart.bak (tidak dijalankan lagi)',
      () async {
        final f = File(p.join(root, 'test', 'widget_test.dart'));
        if (await f.exists()) await f.rename('${f.path}.bak');
        return ['test/widget_test.dart → widget_test.dart.bak'];
      },
    ));
  }

  // ── Plugin lama tanpa namespace (AGP 8+): "Namespace not specified"
  if (t.contains('Namespace not specified')) {
    out.add(AutoFix(
      'Plugin lama belum punya "namespace" (wajib sejak Android Gradle Plugin 8)',
      'Isi namespace otomatis untuk semua plugin di android/build.gradle(.kts)',
      () async => [await addSubprojectsFix(root, 'namespace') ?? 'namespace sudah diatur'],
    ));
  }

  // ── JVM target Java vs Kotlin beda
  if (t.contains('Inconsistent JVM-target compatibility')) {
    out.add(AutoFix(
      'Target JVM Java dan Kotlin di salah satu plugin tidak sama (Inconsistent JVM-target compatibility)',
      'gradle.properties: kotlin.jvm.target.validation.mode=warning',
      () async => [await setGradleProperty(root, 'kotlin.jvm.target.validation.mode', 'warning') ?? 'sudah diatur'],
    ));
  }

  // ── minSdk aplikasi lebih kecil dari yang diminta library
  final minSdk = RegExp(r'minSdk(?:Version)? (\d+) cannot be smaller than version (\d+)').firstMatch(t);
  if (minSdk != null) {
    final need = minSdk.group(2)!;
    out.add(AutoFix(
      'minSdk aplikasi (${minSdk.group(1)}) lebih kecil dari yang dibutuhkan plugin ($need)',
      'Set minSdk = $need di android/app/build.gradle(.kts)',
      () async => [await setAppMinSdk(root, int.parse(need)) ?? 'minSdk sudah $need'],
    ));
  }

  // ── Kotlin Gradle Plugin terlalu lama
  if (t.contains('requires a newer version of the Kotlin Gradle plugin') || t.contains('supports only Kotlin Gradle plugin version')) {
    final want = RegExp(r'supports only Kotlin Gradle plugin version ([0-9.]+)').firstMatch(t)?.group(1) ?? '2.1.0';
    out.add(AutoFix(
      'Versi Kotlin Gradle Plugin di settings.gradle terlalu lama',
      'Naikkan org.jetbrains.kotlin.android ke $want',
      () async => [await bumpKotlinPlugin(root, want) ?? 'versi Kotlin sudah cukup'],
    ));
  }

  // ── Gradle kehabisan memori
  if (t.contains('OutOfMemoryError') || t.contains('Java heap space') || t.contains('Gradle build daemon disappeared')) {
    out.add(AutoFix(
      'Gradle kehabisan memori (OutOfMemory / daemon berhenti)',
      'Atur org.gradle.jvmargs=-Xmx4G dan hentikan daemon Gradle lama',
      () async {
        final m = await setGradleProperty(root, 'org.gradle.jvmargs', '-Xmx4G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=512m -XX:+HeapDumpOnOutOfMemoryError');
        await _gradleStop(root);
        return [m ?? 'jvmargs sudah benar', 'daemon Gradle dihentikan'];
      },
    ));
  }

  // ── Lisensi Android SDK belum diterima
  if (t.contains('not accepted the license agreements') || t.contains('licences have not been accepted')) {
    out.add(AutoFix(
      'Lisensi Android SDK belum diterima',
      'Jalankan flutter doctor --android-licenses dan jawab "y" otomatis',
      () async {
        final pr = await Process.start(flutterCmd, ['doctor', '--android-licenses'], runInShell: true, environment: ToolEnv.env());
        for (var i = 0; i < 30; i++) {
          pr.stdin.writeln('y');
        }
        await pr.stdin.close();
        final code = await pr.exitCode.timeout(const Duration(minutes: 3), onTimeout: () => -1);
        return [code == 0 ? 'Lisensi Android SDK diterima' : '⚠ flutter doctor --android-licenses keluar dengan kode $code'];
      },
    ));
  }

  // ── File terkunci / cache Gradle rusak
  if (t.contains('Timeout waiting to lock') || t.contains('Could not read workspace metadata') ||
      t.contains('Unable to delete directory') || t.contains('being used by another process')) {
    out.add(AutoFix(
      'Cache Gradle terkunci atau rusak (file dipakai proses lain)',
      'Hentikan daemon Gradle dan hapus folder build/ & android/.gradle',
      () async {
        await _gradleStop(root);
        for (final d in ['build', p.join('android', '.gradle'), p.join('android', 'app', 'build')]) {
          try {
            final dir = Directory(p.join(root, d));
            if (await dir.exists()) await dir.delete(recursive: true);
          } catch (_) {}
        }
        return ['daemon Gradle dihentikan, cache build dibersihkan'];
      },
    ));
  }

  // ── pub get gagal karena bentrok versi → pakai saran pub
  final pubSug = RegExp(r'flutter pub add ([a-z0-9_]+:\^?[0-9][^\s]*)').firstMatch(t);
  if (t.contains('version solving failed') && pubSug != null) {
    out.add(AutoFix(
      'Versi paket di pubspec.yaml saling bentrok (version solving failed)',
      'Jalankan saran pub: flutter pub add ${pubSug.group(1)} (backup pubspec.yaml dibuat)',
      () async {
        final pub = File(p.join(root, 'pubspec.yaml'));
        if (await pub.exists()) await pub.copy('${pub.path}.deployhub.bak');
        final r = await Process.run(flutterCmd, ['pub', 'add', pubSug.group(1)!], workingDirectory: root, runInShell: true, environment: ToolEnv.env());
        return [r.exitCode == 0 ? 'pubspec.yaml: ${pubSug.group(1)}' : '✖ pub add gagal: ${'${r.stdout}${r.stderr}'.split('\n').where((l) => l.trim().isNotEmpty).take(2).join(' ')}'];
      },
    ));
  }
  return out;
}

Future<void> _gradleStop(String root) async {
  final w = File(p.join(root, 'android', Platform.isWindows ? 'gradlew.bat' : 'gradlew'));
  if (!await w.exists()) return;
  try {
    await Process.run(w.path, ['--stop'], workingDirectory: p.join(root, 'android'), runInShell: true, environment: ToolEnv.env())
        .timeout(const Duration(minutes: 1));
  } catch (_) {}
}

/// Set / ganti satu baris di android/gradle.properties. Mengembalikan pesan kalau berubah.
Future<String?> setGradleProperty(String root, String key, String value) async {
  final f = File(p.join(root, 'android', 'gradle.properties'));
  final cur = await f.exists() ? await f.readAsString() : '';
  final line = '$key=$value';
  if (cur.split('\n').any((l) => l.trim() == line)) return null;
  final re = RegExp('^\\s*${RegExp.escape(key)}\\s*=.*\$', multiLine: true);
  final next = re.hasMatch(cur) ? cur.replaceAll(re, line) : '${cur.trimRight()}\n$line\n';
  if (await f.exists()) await f.copy('${f.path}.deployhub.bak');
  await f.writeAsString(next);
  return 'gradle.properties: $line';
}

/// minSdk di android/app/build.gradle(.kts) minimal [sdk].
Future<String?> setAppMinSdk(String root, int sdk) async {
  for (final n in ['build.gradle.kts', 'build.gradle']) {
    final f = File(p.join(root, 'android', 'app', n));
    if (!await f.exists()) continue;
    var s = await f.readAsString();
    final kts = n.endsWith('.kts');
    final re = RegExp(r'minSdk(?:Version)?\s*=?\s*[^\n]+');
    final m = re.firstMatch(s);
    if (m == null) return null;
    final cur = int.tryParse(RegExp(r'(\d+)').firstMatch(m.group(0)!)?.group(1) ?? '');
    if (cur != null && cur >= sdk) return null;
    await f.copy('${f.path}.deployhub.bak');
    s = s.replaceFirst(re, kts ? 'minSdk = $sdk' : 'minSdkVersion $sdk');
    await f.writeAsString(s);
    return 'android/app/$n: minSdk = $sdk';
  }
  return null;
}

/// Naikkan versi plugin Kotlin di android/settings.gradle(.kts).
Future<String?> bumpKotlinPlugin(String root, String minVer) async {
  for (final n in ['settings.gradle.kts', 'settings.gradle']) {
    final f = File(p.join(root, 'android', n));
    if (!await f.exists()) continue;
    var s = await f.readAsString();
    final re = RegExp('(org\\.jetbrains\\.kotlin\\.android["\']?\\)?\\s*version\\s*\\(?["\'])([0-9.]+)');
    final m = re.firstMatch(s);
    if (m == null) return null;
    List<int> v(String x) => x.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final a = v(m.group(2)!), b = v(minVer);
    var lower = false;
    for (var i = 0; i < 3; i++) {
      final ai = i < a.length ? a[i] : 0, bi = i < b.length ? b[i] : 0;
      if (ai != bi) {
        lower = ai < bi;
        break;
      }
    }
    if (!lower) return null;
    await f.copy('${f.path}.deployhub.bak');
    s = s.replaceFirstMapped(re, (x) => '${x.group(1)}$minVer');
    await f.writeAsString(s);
    return 'android/$n: Kotlin ${m.group(2)} → $minVer';
  }
  return null;
}

/// Blok subprojects di android/build.gradle(.kts) untuk plugin lama tanpa namespace.
Future<String?> addSubprojectsFix(String root, String kind) async {
  File? f;
  for (final n in ['build.gradle.kts', 'build.gradle']) {
    final x = File(p.join(root, 'android', n));
    if (await x.exists()) {
      f = x;
      break;
    }
  }
  if (f == null) return null;
  var s = await f.readAsString();
  final tag = '[DeployHub] $kind plugin';
  if (s.contains(tag)) return null;
  final kts = f.path.endsWith('.kts');
  final block = kts
      ? '// $tag: plugin lama tanpa namespace -> pakai group plugin itu\n'
          'subprojects {\n'
          '    afterEvaluate {\n'
          '        val ext = extensions.findByName("android")\n'
          '        if (ext is com.android.build.gradle.BaseExtension && ext.namespace == null) {\n'
          '            ext.namespace = project.group.toString()\n'
          '        }\n'
          '    }\n'
          '}\n'
      : '// $tag: plugin lama tanpa namespace -> pakai group plugin itu\n'
          'subprojects {\n'
          '    afterEvaluate { project ->\n'
          '        if (project.hasProperty("android") && project.android.namespace == null) {\n'
          '            project.android.namespace = project.group\n'
          '        }\n'
          '    }\n'
          '}\n';
  final idx = s.indexOf(RegExp(r'subprojects\s*\{\s*\n?\s*project\.evaluationDependsOn'));
  await f.copy('${f.path}.deployhub.bak');
  s = idx >= 0 ? s.replaceRange(idx, idx, '$block\n') : '$s\n$block';
  await f.writeAsString(s);
  return 'android/${p.basename(f.path)}: namespace otomatis untuk plugin lama';
}
