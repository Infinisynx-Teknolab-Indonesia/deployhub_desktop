import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Hasil penerapan R8 / shrink resources ke android/app/build.gradle(.kts).
class R8Result {
  R8Result(this.changed, this.message, {this.backupPath = ''});
  final bool changed;
  final String message;
  final String backupPath;
}

const _proguardRules = '''# Dibuat oleh DeployHub — aturan aman untuk Flutter + R8
# Aturan Flutter sudah disertakan otomatis oleh Flutter Gradle plugin — JANGAN tambah
# "-keep class io.flutter.** { *; }" (menurunkan persentase obfuscation & penyusutan).
-dontwarn io.flutter.embedding.**
# Play Core (deferred components) — sering membuat R8 gagal kalau tidak ada
-dontwarn com.google.android.play.core.**
# Model JSON / Firebase / Gson
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses
''';

/// Pastikan build release memakai R8 (minify) + shrink resources + proguard-rules.pro.
/// Membuat backup sebelum mengubah file.
Future<R8Result> ensureR8(String root) async {
  File? gradle;
  for (final g in ['build.gradle.kts', 'build.gradle']) {
    final f = File(p.join(root, 'android', 'app', g));
    if (await f.exists()) {
      gradle = f;
      break;
    }
  }
  if (gradle == null) return R8Result(false, 'android/app/build.gradle not found');
  final kts = gradle.path.endsWith('.kts');
  var s = await gradle.readAsString();

  // proguard-rules.pro
  final rules = File(p.join(root, 'android', 'app', 'proguard-rules.pro'));
  var rulesCreated = false;
  if (!await rules.exists()) {
    await rules.writeAsString(_proguardRules);
    rulesCreated = true;
  } else {
    final cur = await rules.readAsString();
    if (!cur.contains('com.google.android.play.core')) {
      await rules.writeAsString('$cur\n-dontwarn com.google.android.play.core.**\n');
      rulesCreated = true;
    }
  }

  // gradle.properties: R8 mode penuh + penyingkatan resource yang dioptimalkan
  // (dua baris "Konfigurasi R8" di App bundle explorer Play Console).
  final propsFile = File(p.join(root, 'android', 'gradle.properties'));
  if (await propsFile.exists()) {
    var props = await propsFile.readAsString();
    final before = props;
    if (!props.contains('android.enableR8.fullMode')) props += '\nandroid.enableR8.fullMode=true';
    if (!props.contains('android.r8.optimizedResourceShrinking')) props += '\nandroid.r8.optimizedResourceShrinking=true';
    if (props != before) {
      await propsFile.writeAsString('${props.trimRight()}\n');
      rulesCreated = true;
    }
  }

  final bt = s.indexOf('buildTypes');
  if (bt < 0) return R8Result(rulesCreated, 'buildTypes { } not found in ${p.basename(gradle.path)}');
  final relMatch = RegExp(kts ? r'(getByName\("release"\)|release)\s*\{' : r'release\s*\{').firstMatch(s.substring(bt));
  if (relMatch == null) return R8Result(rulesCreated, 'release { } not found in buildTypes');
  final blockStart = bt + relMatch.end; // setelah "{"

  // cari akhir blok release (hitung kurung)
  var depth = 1, i = blockStart;
  while (i < s.length && depth > 0) {
    if (s[i] == '{') depth++;
    if (s[i] == '}') depth--;
    i++;
  }
  final blockEnd = i - 1;
  var block = s.substring(blockStart, blockEnd);
  final original = block;

  if (kts) {
    block = block
        .replaceAll(RegExp(r'isMinifyEnabled\s*=\s*false'), 'isMinifyEnabled = true')
        .replaceAll(RegExp(r'isShrinkResources\s*=\s*false'), 'isShrinkResources = true');
    final add = <String>[
      if (!block.contains('isMinifyEnabled')) 'isMinifyEnabled = true',
      if (!block.contains('isShrinkResources')) 'isShrinkResources = true',
      if (!block.contains('proguardFiles'))
        'proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")',
    ];
    if (add.isNotEmpty) block = '\n            ${add.join('\n            ')}$block';
  } else {
    block = block
        .replaceAll(RegExp(r'minifyEnabled\s+false'), 'minifyEnabled true')
        .replaceAll(RegExp(r'shrinkResources\s+false'), 'shrinkResources true');
    final add = <String>[
      if (!block.contains('minifyEnabled')) 'minifyEnabled true',
      if (!block.contains('shrinkResources')) 'shrinkResources true',
      if (!block.contains('proguardFiles'))
        "proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'",
    ];
    if (add.isNotEmpty) block = '\n            ${add.join('\n            ')}$block';
  }

  if (block == original) {
    return R8Result(rulesCreated, 'R8 + shrinkResources already enabled');
  }
  final backup = '${gradle.path}.deployhub.bak';
  await gradle.copy(backup);
  s = s.replaceRange(blockStart, blockEnd, block);
  await gradle.writeAsString(s);
  return R8Result(true, 'R8 + shrinkResources enabled in ${p.basename(gradle.path)}', backupPath: backup);
}

/// Ukuran (terkompresi) setiap entri di dalam file ZIP/AAB, dibaca dari central directory.
Future<Map<String, int>> zipEntrySizes(File f) async {
  final raf = await f.open();
  try {
    final len = await raf.length();
    final tailLen = len < 66000 ? len : 66000;
    await raf.setPosition(len - tailLen);
    final tail = await raf.read(tailLen);
    int eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 && tail[i + 1] == 0x4b && tail[i + 2] == 0x05 && tail[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) return {};
    final bd = ByteData.sublistView(tail);
    final count = bd.getUint16(eocd + 10, Endian.little);
    final cdSize = bd.getUint32(eocd + 12, Endian.little);
    final cdOffset = bd.getUint32(eocd + 16, Endian.little);
    await raf.setPosition(cdOffset);
    final cd = await raf.read(cdSize);
    final c = ByteData.sublistView(cd);
    final out = <String, int>{};
    var o = 0;
    for (var n = 0; n < count && o + 46 <= cd.length; n++) {
      if (c.getUint32(o, Endian.little) != 0x02014b50) break;
      final comp = c.getUint32(o + 20, Endian.little);
      final nameLen = c.getUint16(o + 28, Endian.little);
      final extraLen = c.getUint16(o + 30, Endian.little);
      final commentLen = c.getUint16(o + 32, Endian.little);
      final name = String.fromCharCodes(cd.sublist(o + 46, o + 46 + nameLen));
      out[name] = comp;
      o += 46 + nameLen + extraLen + commentLen;
    }
    return out;
  } finally {
    await raf.close();
  }
}

/// Perkiraan ukuran yang diunduh HP arm64 dari AAB: buang library CPU lain dan
/// BUNDLE-METADATA (mapping & debug symbols tidak dikirim ke HP).
Future<int?> estimateArm64Download(File aab) async {
  final entries = await zipEntrySizes(aab);
  if (entries.isEmpty) return null;
  var total = 0;
  entries.forEach((name, size) {
    if (name.startsWith('BUNDLE-METADATA/')) return;
    final m = RegExp(r'^[^/]+/lib/([^/]+)/').firstMatch(name);
    if (m != null && m.group(1) != 'arm64-v8a') return;
    total += size;
  });
  return total;
}

/// Cari mapping.txt hasil R8 untuk diupload ke Play (deobfuscation file).
Future<File?> findR8Mapping(String root) async {
  final f = File(p.join(root, 'build', 'app', 'outputs', 'mapping', 'release', 'mapping.txt'));
  return await f.exists() ? f : null;
}

/// Hasil "Perbaiki otomatis" optimasi R8.
class R8FixResult {
  final changes = <String>[]; // apa saja yang diubah
  final disabledRules = <String>[]; // aturan -keep/-dont* yang dimatikan
  String backup = '';
  String error = '';
}

/// Naikkan persentase pengoptimalan / obfuscation / penyusutan R8:
///  1. R8 + shrinkResources + proguard-rules.pro di build.gradle (ensureR8)
///  2. gradle.properties: R8 mode penuh + optimizedResourceShrinking (ensureR8)
///  3. proguard-rules.pro: matikan aturan yang membuat R8 tidak bekerja
///     (-dontobfuscate / -dontshrink / -dontoptimize, -keep seluruh paket, -keep io.flutter.**)
///     lalu tambahkan -repackageclasses & -allowaccessmodification.
/// Semua file dibackup (*.deployhub.bak) sebelum diubah.
Future<R8FixResult> fixR8(String root, {String packageName = ''}) async {
  final res = R8FixResult();
  if (root.isEmpty || !await Directory(p.join(root, 'android')).exists()) {
    res.error = 'Folder project Android tidak ditemukan: $root';
    return res;
  }
  final g = await ensureR8(root);
  if (g.changed) res.changes.add(g.message);

  final rulesFile = File(p.join(root, 'android', 'app', 'proguard-rules.pro'));
  if (!await rulesFile.exists()) await rulesFile.writeAsString(_proguardRules);
  final original = await rulesFile.readAsString();

  // Prefix paket aplikasi sendiri, mis. com.fjbbatam.app → com.fjbbatam
  final pkgParts = packageName.split('.');
  final pkgPrefix = pkgParts.length >= 2 ? '${pkgParts[0]}\\.${pkgParts[1]}' : '';
  final broad = <RegExp>[
    RegExp(r'^\s*-dont(obfuscate|shrink|optimize)\b'),
    RegExp(r'^\s*-keep\w*\s+(public\s+)?(class|interface)\s+(\*\*|\*|\*\.\*\*|\*\*\.\*\*)\s*(\{\s*\*\s*;?\s*\})?\s*$'),
    RegExp(r'^\s*-keep\w*\s+(public\s+)?class\s+io\.flutter\.[\w.]*\*\*\s*\{\s*\*\s*;?\s*\}'),
    RegExp(r'^\s*-keep\w*\s+(public\s+)?class\s+(com|org|id|net|androidx|android)\.\*\*\s*\{\s*\*\s*;?\s*\}'),
    if (pkgPrefix.isNotEmpty) RegExp('^\\s*-keep\\w*\\s+(public\\s+)?class\\s+$pkgPrefix(\\.[\\w]+)*\\.\\*\\*\\s*\\{\\s*\\*\\s*;?\\s*\\}'),
  ];
  final out = <String>[];
  for (final line in original.split('\n')) {
    if (broad.any((r) => r.hasMatch(line))) {
      res.disabledRules.add(line.trim());
      out.add('# [DeployHub] dinonaktifkan (menurunkan optimasi R8): ${line.trim()}');
    } else {
      out.add(line);
    }
  }
  var rules = out.join('\n');
  if (!RegExp(r'^\s*-repackageclasses', multiLine: true).hasMatch(rules)) {
    rules = '${rules.trimRight()}\n\n# [DeployHub] kemas ulang kelas → obfuscation lebih tinggi\n-repackageclasses\n';
    res.changes.add('proguard-rules.pro: + -repackageclasses');
  }
  if (!rules.contains('-allowaccessmodification')) {
    rules = '${rules.trimRight()}\n-allowaccessmodification\n';
    res.changes.add('proguard-rules.pro: + -allowaccessmodification');
  }
  if (rules != original) {
    res.backup = '${rulesFile.path}.deployhub.bak';
    await rulesFile.copy(res.backup);
    await rulesFile.writeAsString(rules);
    if (res.disabledRules.isNotEmpty) {
      res.changes.add('proguard-rules.pro: ${res.disabledRules.length} aturan terlalu luas dinonaktifkan');
    }
  }
  return res;
}
