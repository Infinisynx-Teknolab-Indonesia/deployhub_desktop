import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Angka optimasi R8 — dihitung di PC SEBELUM upload, mirip "App bundle explorer" Play Console
/// (Persentase pengoptimalan / obfuscation / penyusutan + Konfigurasi R8).
///
/// - Obfuscation %: dari mapping R8 di dalam AAB (BUNDLE-METADATA/…/proguard.map) —
///   berapa persen class + method + field yang namanya diacak.
/// - Penyusutan %: dari usage.txt hasil build (daftar kode yang DIBUANG R8) dibanding kode
///   yang tersisa di mapping. Butuh folder project / file usage.txt di sebelah AAB.
/// - Pengoptimalan %: perkiraan (rata-rata penyusutan & obfuscation). Angka persis
///   dihitung Google setelah upload.
class R8Metrics {
  double? obfuscation;
  double? shrinking;
  double? optimization;
  int keptItems = 0;
  int removedItems = 0;
  String compiler = ''; // mis. "R8 8.9.27"
  String usageFile = '';
  String projectRoot = ''; // folder project yang dipakai membaca konfigurasi (kosong = tidak ditemukan)

  // Konfigurasi R8 (null = tidak diketahui karena folder project tidak ada)
  bool? fullMode;
  bool? shrinkResources;
  bool? optimizedResourceShrinking;
  bool? repackageClasses;
  String agpVersion = '';

  Map<String, dynamic> toJson() => {
        'obfuscation': obfuscation,
        'shrinking': shrinking,
        'optimization': optimization,
        'keptItems': keptItems,
        'removedItems': removedItems,
        'compiler': compiler,
        'usageFile': usageFile,
        'projectRoot': projectRoot,
        'fullMode': fullMode,
        'shrinkResources': shrinkResources,
        'optimizedResourceShrinking': optimizedResourceShrinking,
        'repackageClasses': repackageClasses,
        'agpVersion': agpVersion,
      };

  static R8Metrics fromJson(Map<String, dynamic> j) => R8Metrics()
    ..obfuscation = (j['obfuscation'] as num?)?.toDouble()
    ..shrinking = (j['shrinking'] as num?)?.toDouble()
    ..optimization = (j['optimization'] as num?)?.toDouble()
    ..keptItems = (j['keptItems'] as num?)?.toInt() ?? 0
    ..removedItems = (j['removedItems'] as num?)?.toInt() ?? 0
    ..compiler = j['compiler'] ?? ''
    ..usageFile = j['usageFile'] ?? ''
    ..projectRoot = j['projectRoot'] ?? ''
    ..fullMode = j['fullMode'] as bool?
    ..shrinkResources = j['shrinkResources'] as bool?
    ..optimizedResourceShrinking = j['optimizedResourceShrinking'] as bool?
    ..repackageClasses = j['repackageClasses'] as bool?
    ..agpVersion = j['agpVersion'] ?? '';

  /// Persentase terendah yang diketahui (untuk peringatan < 50%).
  double? get lowest {
    final v = [obfuscation, shrinking, optimization].whereType<double>().toList();
    if (v.isEmpty) return null;
    v.sort();
    return v.first;
  }
}

/// Hitung obfuscation dari isi proguard.map (mapping.txt).
void applyMapping(R8Metrics m, String mapping) {
  var total = 0, renamed = 0;
  var cls = '';
  final seen = <String>{};
  for (final line in const LineSplitter().convert(mapping)) {
    if (line.startsWith('#')) {
      final c = RegExp(r'^#\s*compiler:\s*(\S+)').firstMatch(line);
      if (c != null) m.compiler = c.group(1)!;
      final v = RegExp(r'^#\s*compiler_version:\s*(\S+)').firstMatch(line);
      if (v != null) m.compiler = '${m.compiler} ${v.group(1)}'.trim();
      continue;
    }
    final arrow = line.indexOf(' -> ');
    if (arrow < 0) continue;
    if (!line.startsWith(' ')) {
      // class: "com.foo.Bar -> a.b:"
      final orig = line.substring(0, arrow).trim();
      final now = line.substring(arrow + 4).replaceAll(':', '').trim();
      cls = orig;
      total++;
      if (orig != now) renamed++;
    } else {
      // member: "    1:2:void doIt(int):3:4 -> a"  /  "    int count -> b"
      final left = line.substring(0, arrow).trim();
      final now = line.substring(arrow + 4).trim();
      // buang nomor baris "1:2:" di depan dan ":3:4" di belakang
      final sig = left.replaceFirst(RegExp(r'^\d+:\d+:'), '').replaceFirst(RegExp(r':\d+(:\d+)?$'), '');
      final nameMatch = RegExp(r'([\w$<>.]+)\(').firstMatch(sig);
      final orig = nameMatch?.group(1) ?? sig.split(' ').last;
      // frame inline (method kelas lain yang di-inline: namanya memakai titik) bukan anggota sendiri
      if (orig.contains('.')) continue;
      if (orig == '<init>' || orig == '<clinit>') continue; // konstruktor tidak pernah diganti nama
      if (!seen.add('$cls#$sig')) continue; // satu method bisa muncul berkali-kali (rentang baris)
      total++;
      if (orig != now) renamed++;
    }
  }
  m.keptItems = total;
  m.obfuscation = total == 0 ? 0 : renamed * 100 / total;
}

/// Cari usage.txt (kode yang dibuang R8) untuk AAB ini.
Future<File?> findUsageFile(File aab, {String projectRoot = ''}) async {
  final cands = <String>[
    if (projectRoot.isNotEmpty) p.join(projectRoot, 'build', 'app', 'outputs', 'mapping', 'release', 'usage.txt'),
    p.join(aab.parent.path, 'usage.txt'),
  ];
  // AAB di <root>/build/app/outputs/bundle/release/ → naik ke <root>
  var dir = aab.parent;
  for (var i = 0; i < 7; i++) {
    cands.add(p.join(dir.path, 'build', 'app', 'outputs', 'mapping', 'release', 'usage.txt'));
    cands.add(p.join(dir.path, 'outputs', 'mapping', 'release', 'usage.txt'));
    cands.add(p.join(dir.path, 'mapping', 'release', 'usage.txt'));
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  final aabTime = await aab.lastModified();
  for (final c in cands) {
    final f = File(c);
    if (!await f.exists()) continue;
    // usage.txt harus dari build yang sama (selisih waktu < 3 jam)
    final diff = (await f.lastModified()).difference(aabTime).abs();
    if (diff < const Duration(hours: 3)) return f;
  }
  return null;
}

/// Hitung penyusutan dari usage.txt.
void applyUsage(R8Metrics m, String usage, String path) {
  var removed = 0;
  String? lastClass;
  var classHasMembers = false;
  for (final line in const LineSplitter().convert(usage)) {
    if (line.trim().isEmpty) continue;
    if (line.startsWith(' ') || line.startsWith('\t')) {
      removed++;
      classHasMembers = true;
    } else {
      // baris class: dihitung kalau class itu dibuang seluruhnya (tidak diikuti member)
      if (lastClass != null && !classHasMembers) removed++;
      lastClass = line;
      classHasMembers = false;
    }
  }
  if (lastClass != null && !classHasMembers) removed++;
  m.removedItems = removed;
  m.usageFile = path;
  final all = removed + m.keptItems;
  m.shrinking = all == 0 ? null : removed * 100 / all;
}

/// Baca konfigurasi R8 dari folder project Flutter.
Future<void> applyProjectConfig(R8Metrics m, String root) async {
  if (root.isEmpty || !await Directory(p.join(root, 'android')).exists()) return;
  m.projectRoot = root;
  String read(String rel) {
    final f = File(p.join(root, 'android', rel));
    return f.existsSync() ? f.readAsStringSync() : '';
  }

  final props = read('gradle.properties');
  final app = read(p.join('app', 'build.gradle.kts')) + read(p.join('app', 'build.gradle'));
  final settings = read('settings.gradle.kts') + read('settings.gradle') + read('build.gradle') + read('build.gradle.kts');
  final rules = read(p.join('app', 'proguard-rules.pro'));

  m.agpVersion = RegExp(r'''com\.android\.application["']?\)?\s*version\s*["']([\d.]+)''').firstMatch(settings)?.group(1) ??
      RegExp(r'''com\.android\.tools\.build:gradle:([\d.]+)''').firstMatch(settings)?.group(1) ??
      '';
  final major = int.tryParse(m.agpVersion.split('.').first) ?? 8;
  final minor = m.agpVersion.split('.').length > 1 ? int.tryParse(m.agpVersion.split('.')[1]) ?? 0 : 0;

  final fm = RegExp(r'android\.enableR8\.fullMode\s*=\s*(\w+)').firstMatch(props)?.group(1);
  m.fullMode = fm == null ? major >= 8 : fm == 'true';
  m.shrinkResources = RegExp(r'(isShrinkResources\s*=\s*true|shrinkResources\s*(=\s*)?true)').hasMatch(app);
  final ors = RegExp(r'android\.r8\.optimizedResourceShrinking\s*=\s*(\w+)').firstMatch(props)?.group(1);
  m.optimizedResourceShrinking = ors == null ? major >= 9 : (ors == 'true' && (major > 8 || minor >= 6));
  m.repackageClasses = RegExp(r'^\s*-repackageclasses', multiLine: true).hasMatch(rules);
}
