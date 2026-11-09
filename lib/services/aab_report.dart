import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/i18n.dart';
import '../utils.dart';
import 'aab_inspect.dart';
import 'r8_metrics.dart';
import 'storage.dart';

/// Satu temuan di laporan (fail = Google pasti menolak / blokir rilis).
class AabFinding {
  AabFinding(this.level, this.group, this.title, this.detail, [this.fix = '']);
  final String level; // pass | warn | fail | info
  final String group;
  final String title;
  final String detail;
  final String fix;

  Map<String, dynamic> toJson() => {'level': level, 'group': group, 'title': title, 'detail': detail, 'fix': fix};
  factory AabFinding.fromJson(Map<String, dynamic> j) =>
      AabFinding(j['level'] ?? 'info', j['group'] ?? '', j['title'] ?? '', j['detail'] ?? '', j['fix'] ?? '');
}

/// Ringkasan isi AAB — mirip yang ditampilkan Play Console setelah upload.
class AabReport {
  AabReport();

  String file = '';
  String packageName = '';
  String versionName = '';
  String versionCode = '';
  int minSdk = 0;
  int targetSdk = 0;
  List<String> abis = [];
  int nativeLibs = 0;
  int dexFiles = 0;
  int aabSize = 0;
  Map<String, int> downloadByAbi = {}; // perkiraan unduhan per jenis CPU
  List<String> permissions = [];
  List<String> features = [];
  bool hasR8Mapping = false;
  bool hasNativeSymbols = false;
  List<String> misaligned16k = [];
  String track = '';
  List<AabFinding> findings = [];
  // Seperti "App bundle explorer" Play Console
  R8Metrics r8 = R8Metrics();
  int dexUncompressed = 0;
  bool glEsDeclared = false;
  List<String> screenLayouts = const ['small', 'normal', 'large', 'xlarge'];
  List<String> deprecatedEdgeApis = [];
  bool hasEdgeToEdgeCall = false;
  List<String> largeImages = [];

  /// Ada persentase R8 yang di bawah 50%?
  bool get lowOptimization => (r8.lowest ?? 0) < 50;

  int get failCount => findings.where((f) => f.level == 'fail').length;
  int get warnCount => findings.where((f) => f.level == 'warn').length;

  Map<String, dynamic> toJson() => {
        'file': file,
        'packageName': packageName,
        'versionName': versionName,
        'versionCode': versionCode,
        'minSdk': minSdk,
        'targetSdk': targetSdk,
        'abis': abis,
        'nativeLibs': nativeLibs,
        'dexFiles': dexFiles,
        'aabSize': aabSize,
        'downloadByAbi': downloadByAbi,
        'permissions': permissions,
        'features': features,
        'hasR8Mapping': hasR8Mapping,
        'hasNativeSymbols': hasNativeSymbols,
        'misaligned16k': misaligned16k,
        'track': track,
        'findings': findings.map((f) => f.toJson()).toList(),
        'r8': r8.toJson(),
        'dexUncompressed': dexUncompressed,
        'glEsDeclared': glEsDeclared,
        'screenLayouts': screenLayouts,
        'deprecatedEdgeApis': deprecatedEdgeApis,
        'hasEdgeToEdgeCall': hasEdgeToEdgeCall,
        'largeImages': largeImages,
      };

  factory AabReport.fromJson(Map<String, dynamic> j) => AabReport()
    ..file = j['file'] ?? ''
    ..packageName = j['packageName'] ?? ''
    ..versionName = j['versionName'] ?? ''
    ..versionCode = j['versionCode'] ?? ''
    ..minSdk = (j['minSdk'] as num?)?.toInt() ?? 0
    ..targetSdk = (j['targetSdk'] as num?)?.toInt() ?? 0
    ..abis = List<String>.from(j['abis'] ?? const [])
    ..nativeLibs = (j['nativeLibs'] as num?)?.toInt() ?? 0
    ..dexFiles = (j['dexFiles'] as num?)?.toInt() ?? 0
    ..aabSize = (j['aabSize'] as num?)?.toInt() ?? 0
    ..downloadByAbi = Map<String, int>.from((j['downloadByAbi'] as Map? ?? const {}).map((k, v) => MapEntry('$k', (v as num).toInt())))
    ..permissions = List<String>.from(j['permissions'] ?? const [])
    ..features = List<String>.from(j['features'] ?? const [])
    ..hasR8Mapping = j['hasR8Mapping'] == true
    ..hasNativeSymbols = j['hasNativeSymbols'] == true
    ..misaligned16k = List<String>.from(j['misaligned16k'] ?? const [])
    ..track = j['track'] ?? ''
    ..findings = (j['findings'] as List? ?? const []).map((e) => AabFinding.fromJson(Map<String, dynamic>.from(e))).toList()
    ..r8 = j['r8'] is Map ? R8Metrics.fromJson(Map<String, dynamic>.from(j['r8'])) : R8Metrics()
    ..dexUncompressed = (j['dexUncompressed'] as num?)?.toInt() ?? 0
    ..glEsDeclared = j['glEsDeclared'] == true
    ..screenLayouts = List<String>.from(j['screenLayouts'] ?? const ['small', 'normal', 'large', 'xlarge'])
    ..deprecatedEdgeApis = List<String>.from(j['deprecatedEdgeApis'] ?? const [])
    ..hasEdgeToEdgeCall = j['hasEdgeToEdgeCall'] == true
    ..largeImages = List<String>.from(j['largeImages'] ?? const []);
}

const _androidNames = {
  21: '5.0', 22: '5.1', 23: '6', 24: '7.0', 25: '7.1', 26: '8.0', 27: '8.1', 28: '9', 29: '10', 30: '11',
  31: '12', 32: '12L', 33: '13', 34: '14', 35: '15', 36: '16', 37: '17',
};
String androidName(int api) => _androidNames[api] == null ? 'API $api' : 'Android ${_androidNames[api]} (API $api)';

/// Izin yang butuh deklarasi / formulir khusus di Play Console.
Map<String, String> get _sensitive => {
      'android.permission.READ_SMS': trL('SMS — hanya untuk aplikasi SMS bawaan; wajib formulir deklarasi'),
      'android.permission.SEND_SMS': trL('SMS — hanya untuk aplikasi SMS bawaan; wajib formulir deklarasi'),
      'android.permission.RECEIVE_SMS': trL('SMS — hanya untuk aplikasi SMS bawaan; wajib formulir deklarasi'),
      'android.permission.READ_CALL_LOG': trL('Log panggilan — wajib formulir deklarasi'),
      'android.permission.ACCESS_BACKGROUND_LOCATION': trL('Lokasi di latar belakang — wajib deklarasi + video demo'),
      'android.permission.QUERY_ALL_PACKAGES': trL('Melihat semua aplikasi terpasang — wajib deklarasi'),
      'android.permission.MANAGE_EXTERNAL_STORAGE': trL('Akses semua file — wajib deklarasi'),
      'android.permission.REQUEST_INSTALL_PACKAGES': trL('Memasang aplikasi lain — wajib deklarasi'),
      'android.permission.READ_MEDIA_IMAGES': trL('Foto & video — wajib deklarasi; kalau hanya memilih foto, pakai Photo Picker'),
      'android.permission.READ_MEDIA_VIDEO': trL('Foto & video — wajib deklarasi; kalau hanya memilih video, pakai Photo Picker'),
      'android.permission.USE_FULL_SCREEN_INTENT': trL('Notifikasi layar penuh — wajib deklarasi (hanya alarm / panggilan)'),
      'android.permission.SCHEDULE_EXACT_ALARM': trL('Alarm tepat waktu — wajib deklarasi kalau bukan aplikasi alarm/kalender'),
      'android.permission.FOREGROUND_SERVICE_CAMERA': trL('Foreground service — wajib deklarasi jenis layanan di Play Console'),
      'android.permission.FOREGROUND_SERVICE_MICROPHONE': trL('Foreground service — wajib deklarasi jenis layanan di Play Console'),
      'android.permission.FOREGROUND_SERVICE_LOCATION': trL('Foreground service — wajib deklarasi jenis layanan di Play Console'),
      'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION': trL('Foreground service — wajib deklarasi jenis layanan di Play Console'),
      'android.permission.FOREGROUND_SERVICE_PHONE_CALL': trL('Foreground service — wajib deklarasi jenis layanan di Play Console'),
      'android.permission.FOREGROUND_SERVICE_DATA_SYNC': trL('Foreground service — wajib deklarasi jenis layanan di Play Console'),
      'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK': trL('Foreground service — wajib deklarasi jenis layanan di Play Console'),
      'android.permission.FOREGROUND_SERVICE_SPECIAL_USE': trL('Foreground service — wajib deklarasi jenis layanan di Play Console'),
    };

/// Semua nilai atribut [attr] di AndroidManifest format proto.
List<String> _protoAttrAll(Uint8List b, String attr) {
  final key = [0x12, attr.length, ...latin1.encode(attr), 0x1a];
  final out = <String>[];
  outer:
  for (var i = 0; i + key.length + 1 < b.length; i++) {
    for (var k = 0; k < key.length; k++) {
      if (b[i + k] != key[k]) continue outer;
    }
    final lenPos = i + key.length;
    final len = b[lenPos];
    if (len == 0 || len > 120 || lenPos + 1 + len > b.length) continue;
    out.add(latin1.decode(b.sublist(lenPos + 1, lenPos + 1 + len)));
  }
  return out;
}

/// Nilai p_align terkecil dari segmen LOAD di file ELF (.so). null kalau bukan ELF 64-bit.
int? _minLoadAlign(Uint8List b) {
  if (b.length < 64 || b[0] != 0x7f || b[1] != 0x45 || b[2] != 0x4c || b[3] != 0x46) return null;
  if (b[4] != 2) return null; // hanya ELF64 (arm64-v8a, x86_64) yang terkena aturan 16 KB
  final bd = ByteData.sublistView(b);
  final phoff = bd.getUint64(32, Endian.little);
  final phentsize = bd.getUint16(54, Endian.little);
  final phnum = bd.getUint16(56, Endian.little);
  int? minAlign;
  for (var i = 0; i < phnum; i++) {
    final o = phoff + i * phentsize;
    if (o + 56 > b.length) break;
    if (bd.getUint32(o, Endian.little) != 1) continue; // PT_LOAD
    final align = bd.getUint64(o + 48, Endian.little);
    if (minAlign == null || align < minAlign) minAlign = align;
  }
  return minAlign;
}

/// Analisa AAB tanpa tool tambahan. [track] = track tujuan (untuk info waktu tunggu).
Future<AabReport> analyzeAab(File f, {String track = '', int minTargetSdk = 36, String projectRoot = ''}) async {
  final r = AabReport()
    ..file = f.path
    ..track = track
    ..aabSize = await f.length();
  final raf = await f.open();
  try {
    final entries = await readZipEntries(raf);
    final gApp = tr('Aplikasi'), gDev = tr('Perangkat yang didukung'), gOpt = tr('Optimasi (R8 & ukuran)'),
        gPerm = tr('Izin & deklarasi'), gRel = tr('Rilis & waktu tunggu');

    // ---- manifest
    final man = entries.where((e) => e.name == 'base/manifest/AndroidManifest.xml').firstOrNull;
    if (man == null) {
      r.findings.add(AabFinding('fail', gApp, tr('File AAB'), trL('base/manifest/AndroidManifest.xml tidak ditemukan — ini bukan AAB yang valid')));
      return r;
    }
    final m = await readZipData(raf, man) ?? Uint8List(0);
    String first(String a) {
      final v = _protoAttrAll(m, a);
      return v.isEmpty ? '' : v.first;
    }

    r.packageName = first('package');
    r.versionCode = first('versionCode');
    r.versionName = first('versionName');
    r.minSdk = int.tryParse(first('minSdkVersion')) ?? 0;
    r.targetSdk = int.tryParse(first('targetSdkVersion')) ?? 0;
    final names = _protoAttrAll(m, 'name');
    r.permissions = names.where((n) => RegExp(r'^[\w.]+\.permission\.[A-Z0-9_]+$').hasMatch(n)).toSet().toList()..sort();
    r.features = names.where((n) => n.startsWith('android.hardware.')).toSet().toList()..sort();

    // ---- isi bundle
    final libs = entries.where((e) => RegExp(r'^[^/]+/lib/[^/]+/[^/]+\.so$').hasMatch(e.name)).toList();
    r.nativeLibs = libs.length;
    r.abis = libs.map((e) => e.name.split('/')[2]).toSet().toList()..sort();
    r.dexFiles = entries.where((e) => RegExp(r'^[^/]+/dex/classes\d*\.dex$').hasMatch(e.name)).length;
    r.hasR8Mapping = entries.any((e) => e.name.startsWith('BUNDLE-METADATA/com.android.tools.build.obfuscation/'));
    r.hasNativeSymbols = entries.any((e) => e.name.startsWith('BUNDLE-METADATA/com.android.tools.build.debugsymbols/'));
    for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
      if (!r.abis.contains(abi) && r.nativeLibs > 0) continue;
      var total = 0;
      for (final e in entries) {
        if (e.name.startsWith('BUNDLE-METADATA/') || e.name == 'BundleConfig.pb' || e.name.startsWith('META-INF/')) continue;
        final mm = RegExp(r'^[^/]+/lib/([^/]+)/').firstMatch(e.name);
        if (mm != null && mm.group(1) != abi) continue;
        total += e.compSize;
      }
      r.downloadByAbi[abi] = total;
    }

    // ---- 16 KB page size (library 64-bit)
    for (final e in libs.where((e) => e.name.contains('/arm64-v8a/') || e.name.contains('/x86_64/'))) {
      final data = await readZipData(raf, e);
      if (data == null) continue;
      final a = _minLoadAlign(data);
      if (a != null && a < 16384) r.misaligned16k.add('${p.basename(e.name)} (${e.name.split('/')[2]}, align ${a ~/ 1024} KB)');
    }

    // ---- App bundle explorer: DEX, layar, OpenGL, gambar besar, API layar penuh
    final dexEntries = entries.where((e) => RegExp(r'^[^/]+/dex/classes\d*\.dex$').hasMatch(e.name)).toList();
    r.dexUncompressed = dexEntries.fold(0, (a, e) => a + e.size);
    r.glEsDeclared = latin1.decode(m, allowInvalid: true).contains('glEsVersion');
    const deprecated = ['setStatusBarColor', 'setNavigationBarColor', 'setNavigationBarDividerColor', 'setDecorFitsSystemWindows'];
    for (final e in dexEntries) {
      final d = await readZipData(raf, e);
      if (d == null) continue;
      final txt = latin1.decode(d, allowInvalid: true);
      for (final api in deprecated) {
        if (txt.contains(api) && !r.deprecatedEdgeApis.contains(api)) r.deprecatedEdgeApis.add(api);
      }
      if (txt.contains('enableEdgeToEdge') || txt.contains('androidx/activity/EdgeToEdge')) r.hasEdgeToEdgeCall = true;
    }
    for (final e in entries) {
      final n = e.name.toLowerCase();
      final img = n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.gif');
      if (img && !n.endsWith('.9.png') && e.size > 300 * 1024 && (n.contains('/res/') || n.contains('/assets/'))) {
        r.largeImages.add('${p.basename(e.name)} (${(e.size / 1024).round()} KB)');
      }
    }

    // ---- R8: obfuscation (mapping di AAB), penyusutan (usage.txt), konfigurasi (folder project)
    final mapEntry = entries.where((e) => e.name.startsWith('BUNDLE-METADATA/com.android.tools.build.obfuscation/')).firstOrNull;
    if (mapEntry != null) {
      final md = await readZipData(raf, mapEntry);
      if (md != null) applyMapping(r.r8, utf8.decode(md, allowMalformed: true));
    } else {
      r.r8.obfuscation = 0;
      r.r8.shrinking = 0;
    }
    var root = projectRoot;
    if (root.isEmpty) {
      var dir = f.parent;
      for (var i = 0; i < 7; i++) {
        if (await File(p.join(dir.path, 'pubspec.yaml')).exists() && await Directory(p.join(dir.path, 'android')).exists()) {
          root = dir.path;
          break;
        }
        if (dir.parent.path == dir.path) break;
        dir = dir.parent;
      }
    }
    if (mapEntry != null) {
      final usage = await findUsageFile(f, projectRoot: root);
      if (usage != null) applyUsage(r.r8, await usage.readAsString(), usage.path);
    }
    await applyProjectConfig(r.r8, root);
    final known = [r.r8.obfuscation, r.r8.shrinking].whereType<double>().toList();
    if (known.isNotEmpty) r.r8.optimization = known.reduce((a, b) => a + b) / known.length;

    r.findings.add(AabFinding('info', gApp, tr('Paket & versi'),
        '${r.packageName.isEmpty ? '?' : r.packageName} • ${r.versionName} (versionCode ${r.versionCode}) • ${fmtMb(r.aabSize)}'));

    // SDK
    if (r.targetSdk == 0) {
      r.findings.add(AabFinding('warn', gApp, 'targetSdk', trL('Tidak terbaca dari AAB')));
    } else if (r.targetSdk < minTargetSdk) {
      r.findings.add(AabFinding('fail', gApp, 'targetSdk', trL('{0} — Google Play mewajibkan minimal {1}. Upload akan ditolak.', [androidName(r.targetSdk), androidName(minTargetSdk)]),
          trL('Naikkan targetSdk di android/app/build.gradle atau upgrade Flutter, lalu build ulang')));
    } else {
      r.findings.add(AabFinding('pass', gApp, 'targetSdk', androidName(r.targetSdk)));
    }

    // Perangkat
    if (r.minSdk > 0) {
      r.findings.add(AabFinding('info', gDev, tr('Versi Android minimal'), trL('{0} ke atas. HP dengan Android lebih lama tidak bisa menginstall.', [androidName(r.minSdk)])));
    }
    if (r.nativeLibs == 0) {
      r.findings.add(AabFinding('pass', gDev, tr('Jenis CPU (ABI)'), trL('Tanpa kode native — jalan di semua jenis CPU')));
    } else {
      if (!r.abis.contains('arm64-v8a')) {
        r.findings.add(AabFinding('fail', gDev, tr('Jenis CPU (ABI)'), trL('Ada kode native tapi tidak ada arm64-v8a. Google Play mewajibkan versi 64-bit.'),
            trL('Build ulang dengan flutter build appbundle (bawaan sudah menyertakan arm64-v8a)')));
      } else {
        r.findings.add(AabFinding('pass', gDev, tr('Jenis CPU (ABI)'), r.abis.join(', ')));
      }
      if (!r.abis.contains('armeabi-v7a')) {
        r.findings.add(AabFinding('warn', gDev, tr('HP 32-bit lama'), trL('Tidak ada armeabi-v7a — HP lama yang hanya 32-bit tidak bisa menginstall.')));
      }
    }
    if (r.features.isNotEmpty) {
      r.findings.add(AabFinding('info', gDev, tr('Fitur hardware dideklarasikan'),
          trL('{0}. Kalau ditandai required="true", HP tanpa fitur itu tidak bisa menginstall.', [r.features.map((f) => f.replaceFirst('android.hardware.', '')).join(', ')])));
    }
    r.findings.add(AabFinding('info', gDev, tr('Jumlah perangkat yang didukung'),
        trL('Angka persisnya hanya ada di Play Console → Uji dan rilis → App bundle explorer (Google tidak menyediakan API-nya). Faktor yang mempengaruhi: versi Android minimal, jenis CPU, dan fitur hardware di atas.')));

    // 16 KB
    if (r.nativeLibs > 0) {
      if (r.misaligned16k.isEmpty) {
        r.findings.add(AabFinding('pass', gDev, tr('Halaman memori 16 KB'), trL('Semua library 64-bit sudah mendukung 16 KB')));
      } else {
        r.findings.add(AabFinding(r.targetSdk >= 35 ? 'fail' : 'warn', gDev, tr('Halaman memori 16 KB'),
            trL('{0} library belum mendukung 16 KB: {1}. Sejak 1 Nov 2025, update aplikasi yang target Android 15+ wajib mendukung 16 KB.', [r.misaligned16k.length, r.misaligned16k.take(4).join(', ')]),
            trL('Upgrade Flutter ke versi terbaru dan update plugin yang berisi kode native (lalu flutter pub upgrade), build ulang')));
      }
    }

    // Optimasi
    r.findings.add(r.hasR8Mapping
        ? AabFinding('pass', gOpt, tr('R8 (minify + obfuscate)'), trL('Aktif — file mapping ikut di AAB, crash report di Play Console tetap terbaca'))
        : AabFinding('warn', gOpt, tr('R8 (minify + obfuscate)'), trL('File mapping R8 tidak ada di AAB — R8 kemungkinan belum aktif, aplikasi lebih besar dan kode mudah dibaca'),
            trL('Deploy dengan mode Produksi (R8 + shrink resources otomatis)')));
    String pct(double? v) => v == null ? '?' : '${v.round()}%';
    final low = r.r8.lowest;
    r.findings.add(AabFinding(
      low == null ? 'info' : (low < 50 ? 'warn' : 'pass'),
      gOpt,
      tr('Persentase optimasi R8'),
      trL('Pengoptimalan ≈{0} • Obfuscation {1} • Penyusutan {2}{3}', [
        pct(r.r8.optimization),
        pct(r.r8.obfuscation),
        pct(r.r8.shrinking),
        r.r8.shrinking == null ? trL(' (penyusutan butuh usage.txt dari build yang sama)') : '',
      ]),
      trL('Target minimal 50%. Naikkan dengan: mode Produksi (R8 + shrinkResources), android.r8.optimizedResourceShrinking=true, -repackageclasses di proguard-rules.pro, dan hapus aturan -keep yang terlalu luas (mis. -keep class io.flutter.** { *; }).'),
    ));
    if (r.r8.agpVersion.isNotEmpty && (int.tryParse(r.r8.agpVersion.split('.').first) ?? 9) < 9) {
      r.findings.add(AabFinding('info', gOpt, tr('Versi Android Gradle Plugin'),
          trL('AGP {0}. Play Console menyarankan upgrade ke AGP 9.0 untuk performa R8 terbaik.', [r.r8.agpVersion])));
    }
    if (r.nativeLibs > 0) {
      r.findings.add(r.hasNativeSymbols
          ? AabFinding('pass', gOpt, tr('Simbol debug native'), trL('Ikut di AAB — crash native di Play Console terbaca'))
          : AabFinding('warn', gOpt, tr('Simbol debug native'),
              trL('Play Console akan memberi peringatan: "AAB berisi kode native tapi simbol debug belum diupload". Crash native jadi sulit dibaca.'),
              trL('Tambahkan di android/app/build.gradle → buildTypes.release: ndk { debugSymbolLevel = "SYMBOL_TABLE" }')));
    }
    final arm64 = r.downloadByAbi['arm64-v8a'] ?? r.downloadByAbi.values.firstOrNull;
    if (arm64 != null && arm64 > 0) {
      r.findings.add(AabFinding('info', gOpt, tr('Perkiraan ukuran download'),
          [for (final e in r.downloadByAbi.entries) '${e.key}: ~${fmtMb(e.value)}'].join(' • ') +
              trL(' (file AAB {0}; Google Play hanya mengirim bagian yang cocok untuk HP)', [fmtMb(r.aabSize)])));
    }
    r.findings.add(AabFinding('info', gOpt, tr('Isi aplikasi'), trL('{0} file dex, {1} library native', [r.dexFiles, r.nativeLibs])));

    // Tindakan direkomendasikan (seperti dasbor rilis Play Console)
    final gAct = tr('Tindakan direkomendasikan');
    if (r.targetSdk >= 35 && !r.hasEdgeToEdgeCall) {
      r.findings.add(AabFinding('warn', gAct, tr('Layar penuh mungkin tidak ditampilkan untuk semua pengguna'),
          trL('Aplikasi target Android 15+ otomatis tampil edge-to-edge (layar penuh sampai belakang status bar). Bagian atas/bawah bisa tertutup status bar atau tombol navigasi.'),
          trL('Bungkus halaman dengan SafeArea dan uji di HP Android 15+. Di MainActivity.kt bisa panggil enableEdgeToEdge() (androidx.activity) sebelum super.onCreate.')));
    }
    if (r.deprecatedEdgeApis.isNotEmpty) {
      r.findings.add(AabFinding('warn', gAct, tr('Aplikasi menggunakan API layar penuh yang tidak digunakan lagi'),
          trL('Ditemukan: {0}. API ini tidak berfungsi lagi di Android 15+.', [r.deprecatedEdgeApis.join(', ')]),
          trL('Biasanya dari plugin lama (mis. status bar / splash). Jalankan flutter pub upgrade --major-versions, atau ganti warna status bar dengan SystemChrome.setSystemUIOverlayStyle + edge-to-edge.')));
    }
    if (r.largeImages.isNotEmpty) {
      r.findings.add(AabFinding('warn', gAct, tr('Tingkatkan performa dengan pengoptimalan gambar bitmap'),
          trL('{0} gambar lebih dari 300 KB: {1}', [r.largeImages.length, r.largeImages.take(6).join(', ')]),
          trL('Ubah ke WebP dan perkecil resolusinya (mis. squoosh.app atau Android Studio → Convert to WebP).')));
    }
    if (!r.hasR8Mapping || (r.r8.lowest ?? 100) < 50) {
      r.findings.add(AabFinding('warn', gAct, tr('Tingkatkan memori dan performa aplikasi dengan pengoptimalan R8'),
          trL('Optimasi R8 di bawah 50% (terendah {0}).', [pct(r.r8.lowest)]),
          trL('Build ulang dengan mode Produksi di DeployHub — R8, shrinkResources, dan optimizedResourceShrinking diaktifkan otomatis.')));
    }

    // Izin
    final sens = r.permissions.where(_sensitive.containsKey).toList();
    for (final s in sens) {
      r.findings.add(AabFinding('warn', gPerm, s.replaceFirst('android.permission.', ''), _sensitive[s]!,
          trL('Isi deklarasinya di Play Console → Konten aplikasi, atau hapus izin ini kalau tidak dipakai')));
    }
    if (r.permissions.contains('com.google.android.gms.permission.AD_ID')) {
      r.findings.add(AabFinding('info', gPerm, 'AD_ID', trL('Aplikasi memakai ID iklan — isi "ID iklan" di Play Console → Konten aplikasi dan Keamanan Data')));
    }
    r.findings.add(AabFinding(sens.isEmpty ? 'pass' : 'info', gPerm, tr('Semua izin'),
        r.permissions.isEmpty ? '-' : r.permissions.map((x) => x.split('.').last).join(', ')));

    // Rilis
    r.findings.add(AabFinding('info', gRel, tr('Waktu tunggu'), releaseWaitText(track)));
    return r;
  } catch (e) {
    r.findings.add(AabFinding('fail', tr('Aplikasi'), tr('File AAB'), '$e'));
    return r;
  } finally {
    await raf.close();
  }
}

/// Perkiraan waktu sampai rilis bisa dipakai, per track.
String releaseWaitText(String track) => switch (track) {
      'internal' => trL('Pengujian internal: biasanya tersedia untuk tester dalam beberapa menit.'),
      'alpha' => trL('Pengujian tertutup: direview Google dulu — biasanya beberapa jam sampai beberapa hari.'),
      'beta' => trL('Pengujian terbuka: direview Google dulu — biasanya beberapa jam sampai beberapa hari.'),
      'production' => trL('Production: direview Google — biasanya beberapa jam sampai 7 hari, aplikasi atau akun baru bisa lebih lama. Setelah lolos, update tersebar ke HP pengguna bertahap dalam beberapa jam.'),
      _ => trL('Belum diupload. Internal: beberapa menit • tertutup/terbuka: beberapa jam–hari • production: beberapa jam–7 hari.'),
    };

/// Simpan / baca laporan per pipeline run.
String reportPath(String runId) => p.join(Storage.logsDir, '$runId.aab.json');

Future<void> saveReport(String runId, AabReport r) async =>
    File(reportPath(runId)).writeAsString(const JsonEncoder.withIndent('  ').convert(r.toJson()));

Future<AabReport?> loadReport(String runId) async {
  final f = File(reportPath(runId));
  if (!await f.exists()) return null;
  try {
    return AabReport.fromJson(Map<String, dynamic>.from(jsonDecode(await f.readAsString())));
  } catch (_) {
    return null;
  }
}

/// Tulis laporan ke log pipeline.
void logReport(AabReport r, void Function(String) log) {
  log(trL('Laporan AAB: {0} gagal, {1} peringatan', [r.failCount, r.warnCount]));
  for (final f in r.findings) {
    final icon = switch (f.level) { 'pass' => '✔', 'warn' => '⚠', 'fail' => '✖', _ => 'ℹ' };
    log('$icon [${f.group}] ${f.title} — ${f.detail}');
    if (f.fix.isNotEmpty && f.level != 'pass') log('   ↳ ${trL('Solusi')}: ${f.fix}');
  }
}
