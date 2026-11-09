import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'aab_report.dart';
import 'build_optimizer.dart';
import 'tool_env.dart';

/// Tombol "Optimalkan" di Laporan AAB — setiap tindakan yang direkomendasikan Play Console
/// diperbaiki langsung di folder project. File yang diubah dibackup ke *.deployhub.bak.
/// Setelah itu cukup build ulang (Jalankan ulang).
enum AabAction { edgeToEdge, edgeApis, images, r8, ndkSymbols, plugins16k }

/// Tindakan untuk satu temuan (null = tidak bisa diperbaiki otomatis).
AabAction? actionFor(AabFinding f) {
  if (f.level == 'pass' || f.level == 'info') return null;
  final t = f.title.toLowerCase();
  if (t.contains('layar penuh mungkin') || t.contains('edge-to-edge may')) return AabAction.edgeToEdge;
  if (t.contains('api layar penuh') || (t.contains('deprecated') && t.contains('edge'))) return AabAction.edgeApis;
  if (t.contains('bitmap')) return AabAction.images;
  if (t.contains('r8')) return AabAction.r8;
  if (t.contains('simbol debug') || t.contains('debug symbol')) return AabAction.ndkSymbols;
  if (t.contains('16 kb')) return AabAction.plugins16k;
  return null;
}

class OptimizeResult {
  final changes = <String>[];
  final notes = <String>[];
  String error = '';
  bool get ok => error.isEmpty;
}

Future<OptimizeResult> runAabAction(AabAction a, AabReport r, String root, {String flutterCmd = 'flutter'}) async {
  final res = OptimizeResult();
  if (root.isEmpty || !await Directory(p.join(root, 'android')).exists()) {
    res.error = 'Folder project Flutter tidak ditemukan ($root)';
    return res;
  }
  try {
    switch (a) {
      case AabAction.edgeToEdge:
        await _edgeToEdge(root, r.packageName, res);
      case AabAction.edgeApis:
        await _pub(root, flutterCmd, ['pub', 'upgrade'], res);
        res.notes.add('setStatusBarColor / setNavigationBarColor juga dipanggil oleh engine Flutter sendiri (PlatformPlugin). '
            'Kalau peringatan ini tetap muncul setelah build ulang, sumbernya engine Flutter — aman, Google hanya memberi saran dan tidak memblokir rilis. '
            'Upgrade Flutter (flutter upgrade) untuk versi engine yang lebih baru.');
        await _edgeToEdge(root, r.packageName, res); // edge-to-edge resmi menggantikan API lama
      case AabAction.images:
        await _images(root, r.largeImages, res);
      case AabAction.r8:
        final f = await fixR8(root, packageName: r.packageName);
        if (f.error.isNotEmpty) res.error = f.error;
        res.changes.addAll(f.changes);
        if (f.changes.isEmpty) res.notes.add('Konfigurasi R8 sudah maksimal — build ulang dengan mode Produksi.');
      case AabAction.ndkSymbols:
        await _ndkSymbols(root, res);
      case AabAction.plugins16k:
        await _pub(root, flutterCmd, ['pub', 'upgrade'], res);
        res.notes.add('Kalau masih ada library belum 16 KB: jalankan "flutter upgrade" (engine Flutter 3.32+ sudah 16 KB) lalu build ulang.');
    }
  } catch (e) {
    res.error = '$e';
  }
  return res;
}

Future<void> _backup(File f) async {
  final b = File('${f.path}.deployhub.bak');
  if (!await b.exists()) await f.copy(b.path);
}

// ───────────────────────── Edge-to-edge (Android 15+)
Future<void> _edgeToEdge(String root, String pkg, OptimizeResult res) async {
  final src = Directory(p.join(root, 'android', 'app', 'src', 'main'));
  File? main;
  await for (final e in src.list(recursive: true)) {
    if (e is File && RegExp(r'MainActivity\.(kt|java)$').hasMatch(e.path)) {
      main = e;
      break;
    }
  }
  if (main == null) {
    res.error = 'MainActivity.kt tidak ditemukan';
    return;
  }
  var c = await main.readAsString();
  final orig = c;
  if (c.contains('enableEdgeToEdge') || c.contains('EdgeToEdge.enable')) {
    res.notes.add('MainActivity sudah memanggil enableEdgeToEdge()');
  } else if (main.path.endsWith('.kt')) {
    c = c.replaceAll('io.flutter.embedding.android.FlutterActivity', 'io.flutter.embedding.android.FlutterFragmentActivity');
    c = c.replaceAll(RegExp(r':\s*FlutterActivity\s*\(\s*\)'), ': FlutterFragmentActivity()');
    final imports = ['import android.os.Bundle', 'import androidx.activity.enableEdgeToEdge'];
    for (final i in imports.reversed) {
      if (!c.contains(i)) c = c.replaceFirstMapped(RegExp(r'^(package [^\n]+\n)', multiLine: true), (m) => '${m[1]}\n$i');
    }
    if (RegExp(r'override fun onCreate\(').hasMatch(c)) {
      c = c.replaceFirstMapped(RegExp(r'(override fun onCreate\([^)]*\)\s*\{\s*\n)'), (m) => '${m[1]}        enableEdgeToEdge()\n');
    } else {
      // tambahkan onCreate di awal badan class
      c = c.replaceFirstMapped(RegExp(r'(class MainActivity\s*:\s*FlutterFragmentActivity\(\)\s*)(\{)?'), (m) {
        final body = '    override fun onCreate(savedInstanceState: Bundle?) {\n'
            '        enableEdgeToEdge() // Android 15+: layar penuh resmi (Play Console)\n'
            '        super.onCreate(savedInstanceState)\n'
            '    }\n';
        return m[2] == null ? '${m[1]!.trimRight()} {\n$body}\n' : '${m[1]}{\n$body';
      });
    }
  } else {
    c = c.replaceAll('io.flutter.embedding.android.FlutterActivity', 'io.flutter.embedding.android.FlutterFragmentActivity');
    c = c.replaceAll(RegExp(r'extends\s+FlutterActivity\b'), 'extends FlutterFragmentActivity');
    for (final i in ['import android.os.Bundle;', 'import androidx.activity.EdgeToEdge;']) {
      if (!c.contains(i)) c = c.replaceFirstMapped(RegExp(r'^(package [^\n]+\n)', multiLine: true), (m) => '${m[1]}\n$i');
    }
    if (c.contains('void onCreate(')) {
      c = c.replaceFirstMapped(RegExp(r'(void onCreate\([^)]*\)\s*\{\s*\n)'), (m) => '${m[1]}    EdgeToEdge.enable(this);\n');
    } else {
      c = c.replaceFirstMapped(RegExp(r'(class MainActivity\s+extends\s+FlutterFragmentActivity\s*\{)'), (m) =>
          '${m[1]}\n  @Override\n  protected void onCreate(Bundle savedInstanceState) {\n    EdgeToEdge.enable(this);\n    super.onCreate(savedInstanceState);\n  }\n');
    }
  }
  if (c != orig) {
    await _backup(main);
    await main.writeAsString(c);
    res.changes.add('${p.basename(main.path)}: FlutterFragmentActivity + enableEdgeToEdge() sebelum super.onCreate');
  }
  // dependensi androidx.activity (enableEdgeToEdge ada di activity 1.8+)
  for (final name in ['build.gradle.kts', 'build.gradle']) {
    final g = File(p.join(root, 'android', 'app', name));
    if (!await g.exists()) continue;
    var t = await g.readAsString();
    if (t.contains('androidx.activity:activity')) break;
    final kts = name.endsWith('.kts');
    final dep = kts ? '    implementation("androidx.activity:activity-ktx:1.10.1")' : "    implementation 'androidx.activity:activity-ktx:1.10.1'";
    if (RegExp(r'^dependencies\s*\{', multiLine: true).hasMatch(t)) {
      t = t.replaceFirstMapped(RegExp(r'^(dependencies\s*\{\s*\n)', multiLine: true), (m) => '${m[1]}$dep\n');
    } else {
      t = '${t.trimRight()}\n\ndependencies {\n$dep\n}\n';
    }
    await _backup(g);
    await g.writeAsString(t);
    res.changes.add('$name: + androidx.activity:activity-ktx (enableEdgeToEdge)');
    break;
  }
  res.notes.add('Pastikan halaman dibungkus SafeArea (atau Scaffold + AppBar) supaya isi tidak tertutup status bar di Android 15+.');
}

// ───────────────────────── gambar bitmap > 300 KB
Future<void> _images(String root, List<String> large, OptimizeResult res) async {
  final names = large.map((s) => s.replaceFirst(RegExp(r'\s*\(\d+ KB\)$'), '').trim()).toSet();
  final dirs = ['assets', 'images', 'lib', p.join('android', 'app', 'src', 'main', 'res')]
      .map((d) => Directory(p.join(root, d)))
      .where((d) => d.existsSync());
  final files = <File>[];
  for (final d in dirs) {
    await for (final e in d.list(recursive: true)) {
      if (e is! File) continue;
      final n = p.basename(e.path);
      final ext = p.extension(n).toLowerCase();
      if (!['.png', '.jpg', '.jpeg'].contains(ext) || n.endsWith('.9.png')) continue;
      if (names.contains(n) || (names.isEmpty && await e.length() > 300 * 1024)) files.add(e);
    }
  }
  if (files.isEmpty) {
    res.error = 'Gambar ${names.join(', ')} tidak ditemukan di assets/ atau android/app/src/main/res';
    return;
  }
  for (final f in files) {
    final before = await f.length();
    final im = img.decodeImage(await f.readAsBytes());
    if (im == null) continue;
    var out = im;
    // Ikon / logo tidak perlu lebih dari 1024 px (Play Store icon = 512 px)
    final maxSide = p.basename(f.path).toLowerCase().contains(RegExp('icon|logo')) ? 512 : 1280;
    if (im.width > maxSide || im.height > maxSide) {
      out = im.width >= im.height ? img.copyResize(im, width: maxSide, interpolation: img.Interpolation.average)
          : img.copyResize(im, height: maxSide, interpolation: img.Interpolation.average);
    }
    final isJpg = f.path.toLowerCase().endsWith('.jpg') || f.path.toLowerCase().endsWith('.jpeg');
    List<int> bytes = isJpg ? img.encodeJpg(out, quality: 82) : img.encodePng(out, level: 9);
    if (!isJpg && bytes.length > 300 * 1024 && out.numChannels < 4) {
      // masih besar → kurangi jumlah warna (PNG 8-bit) — biasanya tidak terlihat bedanya untuk logo / ikon
      bytes = img.encodePng(img.quantize(out, numberOfColors: 256, method: img.QuantizeMethod.octree), level: 9);
    }
    if (bytes.length >= before) {
      res.notes.add('${p.basename(f.path)}: sudah optimal (${before ~/ 1024} KB)');
      continue;
    }
    await _backup(f);
    await f.writeAsBytes(bytes);
    res.changes.add('${p.relative(f.path, from: root)}: ${before ~/ 1024} KB → ${bytes.length ~/ 1024} KB'
        '${out.width != im.width ? ' (${im.width}px → ${out.width}px)' : ''}');
  }
  res.notes.add('Nama file tetap sama, jadi kode & pubspec tidak perlu diubah. File asli disimpan di *.deployhub.bak.');
}

// ───────────────────────── simbol debug native
Future<void> _ndkSymbols(String root, OptimizeResult res) async {
  for (final name in ['build.gradle.kts', 'build.gradle']) {
    final g = File(p.join(root, 'android', 'app', name));
    if (!await g.exists()) continue;
    var t = await g.readAsString();
    if (t.contains('debugSymbolLevel')) {
      res.notes.add('debugSymbolLevel sudah ada di $name');
      return;
    }
    final kts = name.endsWith('.kts');
    final line = kts ? '            ndk { debugSymbolLevel = "SYMBOL_TABLE" }' : "            ndk { debugSymbolLevel 'SYMBOL_TABLE' }";
    final re = kts ? RegExp(r'(getByName\("release"\)|release)\s*\{\s*\n') : RegExp(r'release\s*\{\s*\n');
    final bt = t.indexOf('buildTypes');
    final m = bt < 0 ? null : re.firstMatch(t.substring(bt));
    if (m == null) {
      res.error = 'Blok buildTypes { release { … } } tidak ditemukan di $name';
      return;
    }
    final at = bt + m.end;
    t = '${t.substring(0, at)}$line\n${t.substring(at)}';
    await _backup(g);
    await g.writeAsString(t);
    res.changes.add('$name: buildTypes.release + ndk { debugSymbolLevel = SYMBOL_TABLE }');
    return;
  }
  res.error = 'android/app/build.gradle(.kts) tidak ditemukan';
}

Future<void> _pub(String root, String flutterCmd, List<String> args, OptimizeResult res) async {
  final r = await Process.run(flutterCmd, args, workingDirectory: root, runInShell: true, environment: ToolEnv.env());
  final out = '${r.stdout}${r.stderr}';
  final changed = RegExp(r'^[>+] .*$', multiLine: true).allMatches(out).map((m) => m[0]!.trim()).take(10).toList();
  if (r.exitCode != 0) {
    res.notes.add('flutter ${args.join(' ')} gagal: ${out.trim().split('\n').last}');
  } else {
    res.changes.add(changed.isEmpty ? 'flutter ${args.join(' ')}: semua plugin sudah versi terbaru yang cocok' : 'flutter ${args.join(' ')}: ${changed.join(', ')}');
  }
}
