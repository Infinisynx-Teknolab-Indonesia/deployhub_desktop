import 'dart:io';

import 'package:path/path.dart' as p;
import 'tool_env.dart';

/// Apakah build release Android sudah ditandatangani dengan upload key
/// (key.properties ada DAN build.gradle membaca key.properties).
Future<bool> hasReleaseSigning(String root) async {
  if (!await File(p.join(root, 'android', 'key.properties')).exists()) return false;
  final g = await appGradle(root);
  if (g == null) return false;
  final s = await g.readAsString();
  return s.contains('key.properties') && RegExp(r'signingConfigs\.(release|getByName\("release"\))').hasMatch(s);
}

Future<File?> appGradle(String root) async {
  for (final n in ['build.gradle.kts', 'build.gradle']) {
    final f = File(p.join(root, 'android', 'app', n));
    if (await f.exists()) return f;
  }
  return null;
}

class KeystoreResult {
  KeystoreResult(this.ok, this.log);
  final bool ok;
  final List<String> log;
}

/// Buat upload keystore + android/key.properties + atur signingConfigs release
/// di android/app/build.gradle(.kts) + tambah ke .gitignore.
Future<KeystoreResult> createUploadKeystore({
  required String root,
  required String keytool,
  required String password,
  required String name,
  required String organization,
}) async {
  final log = <String>[];
  final android = p.join(root, 'android');
  final jks = File(p.join(android, 'upload-keystore.jks'));
  final props = File(p.join(android, 'key.properties'));

  if (await jks.exists()) {
    log.add('ℹ upload-keystore.jks already exists — not overwritten');
  } else {
    String esc(String v) => v.replaceAll(',', r'\,');
    final r = await Process.run(
      keytool,
      [
        '-genkeypair', '-noprompt', '-v',
        '-keystore', jks.path,
        '-alias', 'upload',
        '-keyalg', 'RSA', '-keysize', '2048', '-validity', '10000',
        '-storepass', password, '-keypass', password,
        '-dname', 'CN=${esc(name)}, O=${esc(organization)}, C=ID',
      ],
      runInShell: true,
      environment: ToolEnv.env(),
    );
    if (r.exitCode != 0 || !await jks.exists()) {
      log.add('✖ keytool: ${r.stderr}${r.stdout}'.trim());
      return KeystoreResult(false, log);
    }
    log.add('✔ ${jks.path}');
  }

  if (await props.exists()) {
    log.add('ℹ key.properties already exists — not overwritten');
  } else {
    await props.writeAsString('storePassword=$password\nkeyPassword=$password\nkeyAlias=upload\nstoreFile=../upload-keystore.jks\n');
    log.add('✔ ${props.path}');
  }

  final g = await appGradle(root);
  if (g == null) {
    log.add('✖ android/app/build.gradle not found');
    return KeystoreResult(false, log);
  }
  final patched = await _patchGradle(g);
  log.add(patched ?? 'ℹ ${p.basename(g.path)}: signing release already set');

  // jangan sampai keystore & password ikut ke git
  final gi = File(p.join(android, '.gitignore'));
  final cur = await gi.exists() ? await gi.readAsString() : '';
  final add = [for (final x in ['key.properties', '*.jks', '*.keystore']) if (!cur.split('\n').contains(x)) x];
  if (add.isNotEmpty) {
    await gi.writeAsString('${cur.isEmpty || cur.endsWith('\n') ? cur : '$cur\n'}${add.join('\n')}\n');
    log.add('✔ android/.gitignore: ${add.join(', ')}');
  }
  return KeystoreResult(true, log);
}

/// Ubah build.gradle supaya release memakai key.properties. Mengembalikan pesan, atau null kalau sudah benar.
Future<String?> _patchGradle(File g) async {
  var s = await g.readAsString();
  if (s.contains('keystoreProperties')) return null;
  final kts = g.path.endsWith('.kts');
  await g.copy('${g.path}.deployhub.bak');

  final loader = kts
      ? '''
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
'''
      : '''
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}
''';
  final signing = kts
      ? '''
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }
'''
      : '''
    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
            storePassword keystoreProperties['storePassword']
        }
    }
''';

  // 0) Kotlin DSL: "java.util.Properties()" tidak bisa dipakai langsung (nama "java" tertutup
  //    extension Gradle) → pakai import di baris paling atas.
  if (kts) s = _ktsImports(s);

  // 1) loader sebelum "android {"
  final androidIdx = RegExp(r'^android\s*\{', multiLine: true).firstMatch(s);
  if (androidIdx == null) return 'android { } not found';
  s = s.replaceRange(androidIdx.start, androidIdx.start, '$loader\n');

  // 2) signingConfigs sebelum buildTypes
  final bt = RegExp(r'^\s*buildTypes\s*\{', multiLine: true).firstMatch(s);
  if (bt == null) return 'buildTypes { } not found';
  s = s.replaceRange(bt.start, bt.start, '\n$signing');

  // 3) release memakai signing release (ganti signing debug bawaan Flutter)
  if (kts) {
    s = s.replaceAll('signingConfig = signingConfigs.getByName("debug")', 'signingConfig = signingConfigs.getByName("release")');
  } else {
    s = s.replaceAll('signingConfig signingConfigs.debug', 'signingConfig signingConfigs.release');
  }
  final rel = RegExp(kts ? r'(getByName\("release"\)|release)\s*\{' : r'release\s*\{')
      .allMatches(s)
      .where((m) => m.start > s.indexOf('buildTypes'))
      .firstOrNull;
  if (rel != null) {
    var depth = 1, i = rel.end;
    while (i < s.length && depth > 0) {
      if (s[i] == '{') depth++;
      if (s[i] == '}') depth--;
      i++;
    }
    final block = s.substring(rel.end, i - 1);
    if (!block.contains('signingConfig')) {
      final line = kts ? 'signingConfig = signingConfigs.getByName("release")' : 'signingConfig signingConfigs.release';
      s = s.replaceRange(rel.end, rel.end, '\n            $line');
    }
  }
  await g.writeAsString(s);
  return '✔ ${p.basename(g.path)}: signingConfigs.release (backup: ${p.basename(g.path)}.deployhub.bak)';
}

/// SHA-1 upload key dari android/key.properties (lewat keytool). null kalau tidak bisa dibaca.
Future<String?> uploadKeySha1(String root, String keytool) async {
  final kp = File(p.join(root, 'android', 'key.properties'));
  if (!await kp.exists()) return null;
  final props = <String, String>{};
  for (final line in await kp.readAsLines()) {
    final i = line.indexOf('=');
    if (i > 0) props[line.substring(0, i).trim()] = line.substring(i + 1).trim();
  }
  final storeFile = props['storeFile'];
  if (storeFile == null) return null;
  var ks = p.isAbsolute(storeFile) ? storeFile : p.join(root, 'android', 'app', storeFile);
  if (!await File(ks).exists()) ks = p.join(root, 'android', storeFile);
  try {
    final r = await Process.run(keytool,
        ['-list', '-v', '-keystore', ks, '-alias', props['keyAlias'] ?? '', '-storepass', props['storePassword'] ?? ''],
        runInShell: true, environment: ToolEnv.env());
    return RegExp(r'SHA1:\s*([0-9A-Fa-f:]+)').firstMatch('${r.stdout}')?.group(1);
  } catch (_) {
    return null;
  }
}


String _ktsImports(String s) {
  final need = <String>[
    if (!RegExp(r'^import java\.util\.Properties', multiLine: true).hasMatch(s)) 'import java.util.Properties',
    if (!RegExp(r'^import java\.io\.FileInputStream', multiLine: true).hasMatch(s)) 'import java.io.FileInputStream',
  ];
  return need.isEmpty ? s : '${need.join('\n')}\n$s';
}

/// Perbaiki build.gradle.kts yang memakai java.util.Properties() / java.io.FileInputStream(...)
/// tanpa import (error "Unresolved reference 'util'" / "'io'"). Mengembalikan pesan kalau diubah.
Future<String?> fixGradleKtsImports(String root) async {
  final g = File(p.join(root, 'android', 'app', 'build.gradle.kts'));
  if (!await g.exists()) return null;
  final s = await g.readAsString();
  if (!s.contains('java.util.Properties(') && !s.contains('java.io.FileInputStream(')) return null;
  var out = s.replaceAll('java.util.Properties(', 'Properties(').replaceAll('java.io.FileInputStream(', 'FileInputStream(');
  out = _ktsImports(out);
  await g.copy('${g.path}.deployhub.bak');
  await g.writeAsString(out);
  return 'build.gradle.kts: import java.util.Properties + java.io.FileInputStream ditambahkan (backup: build.gradle.kts.deployhub.bak)';
}
