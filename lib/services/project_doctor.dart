import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'gradle_fixer.dart';
import 'keystore_tool.dart';
import 'storage.dart';
import 'tool_env.dart';

/// Hasil pemeriksaan file project.
class DoctorResult {
  final fixed = <String>[]; // diperbaiki / dibuat ulang otomatis
  final warnings = <String>[]; // perlu tindakan manual (tidak aman diubah otomatis)
  final ok = <String>[]; // sudah benar
}

String keystoreSecretKey(String projectId) => 'keystore_pw_$projectId';

/// Periksa & perbaiki semua file penting project Flutter Android sebelum build:
/// keystore + key.properties, local.properties, pubspec.yaml, Gradle, AndroidManifest.
/// Semua file yang diubah dibackup ke *.deployhub.bak.
///
/// [allowNewKeystore] = boleh membuat upload keystore BARU kalau keystore & key.properties
/// sama-sama tidak ada (hanya aman untuk aplikasi yang belum pernah diupload ke Google Play).
Future<DoctorResult> projectDoctor(
  String root, {
  String packageName = '',
  String projectId = '',
  String projectName = '',
  String flutterCmd = 'flutter',
  String keytool = 'keytool',
  bool allowNewKeystore = false,
}) async {
  final res = DoctorResult();
  final android = p.join(root, 'android');
  if (!await Directory(android).exists()) {
    res.warnings.add('Folder android/ tidak ada — jalankan: flutter create --platforms=android .');
    return res;
  }

  await _pubspec(root, res);
  await _localProperties(root, flutterCmd, res);
  await _keystore(root, res,
      projectId: projectId, projectName: projectName, keytool: keytool, allowNew: allowNewKeystore);

  final g = await fixGradle(root, packageName: packageName);
  res.fixed.addAll(g.fixed);
  res.warnings.addAll(g.warnings);
  return res;
}

// ───────────────────────── pubspec.yaml
Future<void> _pubspec(String root, DoctorResult res) async {
  final f = File(p.join(root, 'pubspec.yaml'));
  if (!await f.exists()) {
    res.warnings.add('pubspec.yaml tidak ditemukan');
    return;
  }
  var s = await f.readAsString();
  final orig = s;

  // version: wajib "x.y.z+N"
  final v = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(s);
  if (v == null) {
    s = s.replaceFirstMapped(RegExp(r'^(description:[^\n]*\n)', multiLine: true), (m) => '${m.group(1)}version: 1.0.0+1\n');
    if (!s.contains('version:')) s = 'version: 1.0.0+1\n$s';
    res.fixed.add('pubspec.yaml: baris version tidak ada → version: 1.0.0+1');
  } else if (!v.group(1)!.contains('+')) {
    s = s.replaceFirst(v.group(0)!, 'version: ${v.group(1)}+1');
    res.fixed.add('pubspec.yaml: version tanpa build number → ${v.group(1)}+1');
  }

  // assets yang filenya tidak ada → build gagal "No file or variants found for asset"
  final lines = s.split('\n');
  var inAssets = false, changed = false;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (RegExp(r'^\s{2,4}assets:\s*$').hasMatch(l)) {
      inAssets = true;
      continue;
    }
    if (inAssets) {
      final m = RegExp(r'^(\s+)-\s+(.+?)\s*$').firstMatch(l);
      if (m == null) {
        if (l.trim().isNotEmpty && !l.trim().startsWith('#')) inAssets = false;
        continue;
      }
      final path = m.group(2)!.replaceAll('"', '').replaceAll("'", '');
      final exists = path.endsWith('/')
          ? await Directory(p.join(root, path)).exists()
          : await File(p.join(root, path)).exists();
      if (!exists) {
        lines[i] = '${m.group(1)}# [DeployHub] file tidak ada: - $path';
        res.fixed.add('pubspec.yaml: aset tidak ada dinonaktifkan → $path');
        changed = true;
      }
    }
  }
  if (changed) s = lines.join('\n');

  if (s != orig) {
    await f.copy('${f.path}.deployhub.bak');
    await f.writeAsString(s);
  } else {
    res.ok.add('pubspec.yaml');
  }
}

// ───────────────────────── android/local.properties (path Flutter SDK & Android SDK)
Future<void> _localProperties(String root, String flutterCmd, DoctorResult res) async {
  final f = File(p.join(root, 'android', 'local.properties'));
  final cur = await f.exists() ? await f.readAsString() : '';
  String? prop(String k) => RegExp('^${RegExp.escape(k)}=(.*)\$', multiLine: true).firstMatch(cur)?.group(1)?.trim();
  String unesc(String v) => v.replaceAll(r'\\', r'\').replaceAll(r'\:', ':');
  String esc(String v) => Platform.isWindows ? v.replaceAll(r'\', r'\\').replaceAll(':', r'\:') : v;

  var flutterSdk = prop('flutter.sdk');
  var sdkDir = prop('sdk.dir');
  final changes = <String>[];

  if (flutterSdk == null || !await Directory(unesc(flutterSdk)).exists()) {
    try {
      final r = await Process.run(flutterCmd, ['--version', '--machine'], runInShell: true, environment: ToolEnv.env());
      final j = jsonDecode('${r.stdout}'.substring('${r.stdout}'.indexOf('{')));
      final fr = '${j['flutterRoot'] ?? ''}';
      if (fr.isNotEmpty) {
        flutterSdk = esc(fr);
        changes.add('flutter.sdk = $fr');
      }
    } catch (_) {}
  }
  if (sdkDir == null || !await Directory(unesc(sdkDir)).exists()) {
    final e = Platform.environment;
    final home = e['HOME'] ?? e['USERPROFILE'] ?? '';
    final cands = [
      e['ANDROID_HOME'], e['ANDROID_SDK_ROOT'],
      if (e['LOCALAPPDATA'] != null) p.join(e['LOCALAPPDATA']!, 'Android', 'Sdk'),
      for (final d in 'CDEF'.split('')) '$d:\\Android\\Sdk',
      p.join(home, 'Library', 'Android', 'sdk'),
      p.join(home, 'Android', 'Sdk'),
    ].whereType<String>();
    for (final c in cands) {
      if (await Directory(p.join(c, 'platform-tools')).exists() || await Directory(p.join(c, 'platforms')).exists()) {
        sdkDir = esc(c);
        changes.add('sdk.dir = $c');
        break;
      }
    }
  }
  if (changes.isEmpty) {
    res.ok.add('local.properties');
    return;
  }
  var next = cur;
  void put(String k, String? v) {
    if (v == null) return;
    final re = RegExp('^${RegExp.escape(k)}=.*\$', multiLine: true);
    next = re.hasMatch(next) ? next.replaceAll(re, '$k=$v') : '${next.trimRight()}\n$k=$v\n';
  }

  put('sdk.dir', sdkDir);
  put('flutter.sdk', flutterSdk);
  if (await f.exists()) await f.copy('${f.path}.deployhub.bak');
  await f.writeAsString(next.trimLeft());
  res.fixed.add('android/local.properties dibuat ulang: ${changes.join(', ')}');
}

// ───────────────────────── keystore + key.properties
Map<String, String> _readProps(String s) => {
      for (final l in const LineSplitter().convert(s))
        if (l.contains('=') && !l.trimLeft().startsWith('#'))
          l.substring(0, l.indexOf('=')).trim(): l.substring(l.indexOf('=') + 1).trim(),
    };

Future<void> _keystore(
  String root,
  DoctorResult res, {
  required String projectId,
  required String projectName,
  required String keytool,
  required bool allowNew,
}) async {
  final android = p.join(root, 'android');
  final propsFile = File(p.join(android, 'key.properties'));

  // Semua keystore yang ada di project
  final stores = <File>[];
  for (final d in [android, p.join(android, 'app'), root]) {
    final dir = Directory(d);
    if (!await dir.exists()) continue;
    await for (final e in dir.list()) {
      if (e is File && (e.path.endsWith('.jks') || e.path.endsWith('.keystore')) && !p.basename(e.path).startsWith('debug')) {
        stores.add(e);
      }
    }
  }

  if (!await propsFile.exists()) {
    if (stores.isNotEmpty) {
      // Keystore ada tapi key.properties hilang → coba password yang tersimpan di DeployHub
      final saved = projectId.isEmpty ? '' : await Storage.secret(keystoreSecretKey(projectId));
      if (saved.isNotEmpty) {
        final rel = p.relative(stores.first.path, from: p.join(android, 'app')).replaceAll('\\', '/');
        await propsFile.writeAsString('storePassword=$saved\nkeyPassword=$saved\nkeyAlias=upload\nstoreFile=$rel\n');
        res.fixed.add('android/key.properties dibuat ulang dari password tersimpan (keystore: ${p.basename(stores.first.path)})');
      } else {
        res.warnings.add('Keystore ${p.basename(stores.first.path)} ada tapi android/key.properties hilang. Buat ulang key.properties berisi storePassword, keyPassword, keyAlias, storeFile — password tidak bisa ditebak otomatis.');
        return;
      }
    } else if (allowNew) {
      // Belum pernah ada keystore & aplikasi belum pernah diupload → buat baru, password acak disimpan aman
      final rnd = Random.secure();
      const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
      final pw = List.generate(24, (_) => chars[rnd.nextInt(chars.length)]).join();
      final r = await createUploadKeystore(
          root: root, keytool: keytool, password: pw, name: projectName.isEmpty ? 'Upload' : projectName, organization: projectName);
      if (!r.ok) {
        res.warnings.add('Gagal membuat keystore otomatis: ${r.log.join(' ')}');
        return;
      }
      if (projectId.isNotEmpty) await Storage.setSecret(keystoreSecretKey(projectId), pw);
      res.fixed.add('Upload keystore BARU dibuat (android/upload-keystore.jks + key.properties). Password acak disimpan di Credential Manager. '
          'BACKUP file .jks ini — kalau hilang, update aplikasi tidak bisa diupload.');
      return;
    } else {
      res.warnings.add('Keystore & android/key.properties belum ada. Aplikasi ini sudah pernah diupload ke Google Play, jadi WAJIB memakai keystore lama '
          '(cari file .jks lama), atau minta reset upload key di Play Console → Integritas aplikasi.');
      return;
    }
  }

  var text = await propsFile.readAsString();
  final props = _readProps(text);
  final changes = <String>[];

  // keyPassword kosong → biasanya sama dengan storePassword (keystore PKCS12)
  if ((props['keyPassword'] ?? '').isEmpty && (props['storePassword'] ?? '').isNotEmpty) {
    props['keyPassword'] = props['storePassword']!;
    changes.add('keyPassword = storePassword');
  }

  // storeFile tidak ketemu → cari keystore yang ada
  final sf = props['storeFile'] ?? '';
  final resolved = sf.isEmpty ? '' : (p.isAbsolute(sf) ? sf : p.normalize(p.join(android, 'app', sf)));
  if (resolved.isEmpty || !await File(resolved).exists()) {
    if (stores.length == 1) {
      final rel = p.relative(stores.first.path, from: p.join(android, 'app')).replaceAll('\\', '/');
      props['storeFile'] = rel;
      changes.add('storeFile → $rel');
    } else if (stores.isEmpty) {
      res.warnings.add('storeFile "$sf" di key.properties tidak ditemukan, dan tidak ada file .jks di project. Salin keystore upload ke folder android/.');
    } else {
      res.warnings.add('storeFile "$sf" tidak ditemukan. Ada beberapa keystore: ${stores.map((s) => p.basename(s.path)).join(', ')} — pilih yang benar di key.properties.');
    }
  }

  // Password & alias benar? (keytool -list)
  final store = props['storeFile'] ?? '';
  final storePath = store.isEmpty ? '' : (p.isAbsolute(store) ? store : p.normalize(p.join(android, 'app', store)));
  if (storePath.isNotEmpty && await File(storePath).exists() && (props['storePassword'] ?? '').isNotEmpty) {
    try {
      final r = await Process.run(keytool, ['-list', '-keystore', storePath, '-storepass', props['storePassword']!],
          runInShell: true, environment: ToolEnv.env());
      final out = '${r.stdout}${r.stderr}';
      if (out.contains('password was incorrect') || out.contains('keystore password was incorrect')) {
        res.warnings.add('Password keystore di android/key.properties SALAH (storePassword). Isi password yang benar.');
      } else if (r.exitCode == 0) {
        final aliases = RegExp(r'^([^,\n]+),\s*\d', multiLine: true).allMatches(out).map((m) => m.group(1)!.trim()).toList();
        final alias = props['keyAlias'] ?? '';
        if (aliases.isNotEmpty && !aliases.any((a) => a.toLowerCase() == alias.toLowerCase())) {
          if (aliases.length == 1) {
            props['keyAlias'] = aliases.first;
            changes.add('keyAlias "$alias" → "${aliases.first}" (alias yang ada di keystore)');
          } else {
            res.warnings.add('keyAlias "$alias" tidak ada di keystore. Alias tersedia: ${aliases.join(', ')}');
          }
        } else {
          res.ok.add('keystore & password');
        }
      }
    } catch (_) {}
  }

  if (changes.isNotEmpty) {
    await propsFile.copy('${propsFile.path}.deployhub.bak');
    text = props.entries.map((e) => '${e.key}=${e.value}').join('\n');
    await propsFile.writeAsString('$text\n');
    res.fixed.add('android/key.properties: ${changes.join(', ')}');
  }

  // signing release di build.gradle
  if (!await hasReleaseSigning(root)) {
    final g = await appGradle(root);
    if (g != null) {
      final pw = props['storePassword'] ?? '';
      if (pw.isNotEmpty) {
        // createUploadKeystore tidak menimpa jks/properties yang sudah ada — hanya memasang signingConfigs
        final r = await createUploadKeystore(root: root, keytool: keytool, password: pw, name: projectName, organization: projectName);
        res.fixed.add('build.gradle: signingConfigs release dipasang (${r.log.where((l) => !l.startsWith('ℹ')).join(' ')})');
      }
    }
  }

  // .gitignore: rahasia tidak boleh ikut ke GitHub
  final gi = File(p.join(android, '.gitignore'));
  final cur = await gi.exists() ? await gi.readAsString() : '';
  final need = [for (final x in ['key.properties', '*.jks', '*.keystore']) if (!cur.split('\n').map((l) => l.trim()).contains(x)) x];
  if (need.isNotEmpty) {
    await gi.writeAsString('${cur.trimRight()}\n${need.join('\n')}\n');
    res.fixed.add('android/.gitignore: + ${need.join(', ')}');
  }
}
