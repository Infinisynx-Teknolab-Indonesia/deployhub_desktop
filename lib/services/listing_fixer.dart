import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../models.dart';
import 'ai_fixer.dart';
import 'firebase_tool.dart';
import 'store_metadata.dart';
import 'tool_env.dart';

/// Perbaikan untuk baris merah "Cek kelayakan" yang bukan masalah kode:
/// listing Play Store (teks, email, ikon, feature graphic, screenshot) & SHA-1 di Firebase.

Directory listingDir(Project pr, String lang) => Directory(p.join(storeDir(pr), 'android', lang));

Future<String> _read(File f) async => await f.exists() ? (await f.readAsString()).trim() : '';

/// Nilai listing saat ini (kosong kalau masih template).
Future<Map<String, String>> readListing(Project pr, String lang) async {
  final d = listingDir(pr, lang);
  String clean(String v) => (v.contains('(maksimal') || v.endsWith('...')) ? '' : v;
  final details = File(p.join(storeDir(pr), 'details.json'));
  Map j = {};
  try {
    if (await details.exists()) j = jsonDecode(await details.readAsString()) as Map;
  } catch (_) {}
  String email = '${j['contactEmail'] ?? ''}';
  if (email.contains('contoh.com')) email = '';
  return {
    'title': clean(await _read(File(p.join(d.path, 'title.txt')))),
    'short': clean(await _read(File(p.join(d.path, 'short_description.txt')))),
    'full': clean(await _read(File(p.join(d.path, 'full_description.txt')))),
    'email': email,
    'website': '${j['contactWebsite'] ?? ''}',
    'phone': '${j['contactPhone'] ?? ''}',
  };
}

Future<void> writeListing(Project pr, String lang, Map<String, String> v) async {
  final d = listingDir(pr, lang);
  await Directory(p.join(d.path, 'images', 'phoneScreenshots')).create(recursive: true);
  await File(p.join(d.path, 'title.txt')).writeAsString(v['title']!.trim());
  await File(p.join(d.path, 'short_description.txt')).writeAsString(v['short']!.trim());
  await File(p.join(d.path, 'full_description.txt')).writeAsString(v['full']!.trim());
  final details = File(p.join(storeDir(pr), 'details.json'));
  Map<String, dynamic> j = {};
  try {
    if (await details.exists()) j = Map<String, dynamic>.from(jsonDecode(await details.readAsString()));
  } catch (_) {}
  j
    ..['contactEmail'] = v['email']!.trim()
    ..['contactWebsite'] = v['website']!.trim()
    ..['contactPhone'] = v['phone']!.trim()
    ..putIfAbsent('defaultLanguage', () => lang);
  j.removeWhere((k, val) => val is String && val.isEmpty && k != 'contactEmail');
  await details.writeAsString(const JsonEncoder.withIndent('  ').convert(j));
}

/// Ikon aplikasi terbesar yang ada di project (sumber ikon 512 & feature graphic).
Future<File?> findAppIcon(Project pr) async {
  final cands = <File>[];
  for (final dir in ['assets', 'assets/icons', 'assets/images', 'ios/Runner/Assets.xcassets/AppIcon.appiconset', 'android/app/src/main/res/mipmap-xxxhdpi']) {
    final d = Directory(p.join(pr.localPath, dir));
    if (!await d.exists()) continue;
    await for (final e in d.list()) {
      final n = p.basename(e.path).toLowerCase();
      if (e is File && n.endsWith('.png') && (n.contains('icon') || n.contains('logo') || n.startsWith('ic_launcher') || n.contains('1024'))) cands.add(e);
    }
  }
  File? best;
  var bestPx = 0;
  for (final f in cands) {
    final im = img.decodeImage(await f.readAsBytes());
    if (im == null) continue;
    final px = im.width < im.height ? im.width : im.height;
    if (px > bestPx && (im.width - im.height).abs() <= im.width * 0.05) {
      bestPx = px;
      best = f;
    }
  }
  return best;
}

/// Ikon 512 x 512 PNG (dipotong persegi dari tengah).
Future<String> setIcon(Project pr, String lang, File src) async {
  final im = img.decodeImage(await src.readAsBytes());
  if (im == null) throw Exception('Gambar tidak terbaca');
  final side = im.width < im.height ? im.width : im.height;
  var sq = img.copyCrop(im, x: (im.width - side) ~/ 2, y: (im.height - side) ~/ 2, width: side, height: side);
  sq = img.copyResize(sq, width: 512, height: 512, interpolation: img.Interpolation.cubic);
  final out = File(p.join(listingDir(pr, lang).path, 'images', 'icon.png'));
  await out.parent.create(recursive: true);
  await out.writeAsBytes(img.encodePng(sq));
  return '${side < 512 ? '⚠ sumber hanya ${side}px — ikon diperbesar, hasilnya bisa buram. ' : ''}icon.png 512 x 512';
}

int _textWidth(img.BitmapFont f, String s) => s.codeUnits.fold(0, (w, c) => w + (f.characters[c]?.xAdvance ?? f.size ~/ 2));

/// Feature graphic 1024 x 500: warna dasar dari ikon + ikon + nama aplikasi + tagline.
Future<String> generateFeatureGraphic(Project pr, String lang, File icon, String title, String tagline) async {
  final ic = img.decodeImage(await icon.readAsBytes());
  if (ic == null) throw Exception('Ikon tidak terbaca');
  // warna rata-rata ikon (piksel tidak transparan) → latar gradasi
  var r = 0, g = 0, b = 0, n = 0;
  final small = img.copyResize(ic, width: 64, height: 64);
  for (final px in small) {
    if (px.a < 128) continue;
    r += px.r.toInt();
    g += px.g.toInt();
    b += px.b.toInt();
    n++;
  }
  if (n == 0) n = 1;
  final base = [r ~/ n, g ~/ n, b ~/ n];
  final dark = base.map((c) => (c * 0.45).round()).toList();
  final canvas = img.Image(width: 1024, height: 500);
  for (var x = 0; x < 1024; x++) {
    final t = x / 1023;
    final col = img.ColorRgb8(
      (dark[0] + (base[0] - dark[0]) * t).round().clamp(0, 255).toInt(),
      (dark[1] + (base[1] - dark[1]) * t).round().clamp(0, 255).toInt(),
      (dark[2] + (base[2] - dark[2]) * t).round().clamp(0, 255).toInt(),
    );
    img.drawLine(canvas, x1: x, y1: 0, x2: x, y2: 499, color: col);
  }
  final iconSz = 260;
  img.compositeImage(canvas, img.copyResize(ic, width: iconSz, height: iconSz, interpolation: img.Interpolation.cubic), dstX: 90, dstY: (500 - iconSz) ~/ 2);
  final white = img.ColorRgb8(255, 255, 255);
  var t1 = title.trim();
  while (t1.length > 3 && _textWidth(img.arial48, t1) > 560) {
    t1 = t1.substring(0, t1.length - 1);
  }
  img.drawString(canvas, t1, font: img.arial48, x: 400, y: 185, color: white);
  if (tagline.trim().isNotEmpty) {
    var t2 = tagline.trim();
    while (t2.length > 3 && _textWidth(img.arial24, t2) > 560) {
      t2 = t2.substring(0, t2.length - 1);
    }
    img.drawString(canvas, t2, font: img.arial24, x: 402, y: 255, color: img.ColorRgba8(255, 255, 255, 220));
  }
  final out = File(p.join(listingDir(pr, lang).path, 'images', 'featureGraphic.png'));
  await out.parent.create(recursive: true);
  await out.writeAsBytes(img.encodePng(canvas));
  return 'featureGraphic.png 1024 x 500';
}

/// Feature graphic dari gambar sendiri (dipotong / diperkecil ke 1024 x 500).
Future<String> setFeatureGraphic(Project pr, String lang, File src) async {
  final im = img.decodeImage(await src.readAsBytes());
  if (im == null) throw Exception('Gambar tidak terbaca');
  final out = _cover(im, 1024, 500);
  final f = File(p.join(listingDir(pr, lang).path, 'images', 'featureGraphic.png'));
  await f.parent.create(recursive: true);
  await f.writeAsBytes(img.encodePng(out));
  return 'featureGraphic.png 1024 x 500';
}

img.Image _cover(img.Image im, int w, int h) {
  final scale = (w / im.width) > (h / im.height) ? w / im.width : h / im.height;
  final r = img.copyResize(im, width: (im.width * scale).ceil(), height: (im.height * scale).ceil(), interpolation: img.Interpolation.cubic);
  return img.copyCrop(r, x: (r.width - w) ~/ 2, y: (r.height - h) ~/ 2, width: w, height: h);
}

/// Screenshot HP: maks 8, sisi 320–3840 px, rasio sisi panjang ≤ 2x sisi pendek (aturan Play).
/// Gambar yang terlalu panjang (mis. screenshot HP modern 9:20) diberi latar supaya jadi 9:16.
Future<List<String>> addScreenshots(Project pr, String lang, List<File> files, {bool replace = true}) async {
  final dir = Directory(p.join(listingDir(pr, lang).path, 'images', 'phoneScreenshots'));
  await dir.create(recursive: true);
  if (replace) {
    await for (final e in dir.list()) {
      if (e is File) await e.delete();
    }
  }
  final notes = <String>[];
  var i = 0;
  for (final f in files.take(8)) {
    var im = img.decodeImage(await f.readAsBytes());
    if (im == null) {
      notes.add('✖ ${p.basename(f.path)}: tidak terbaca');
      continue;
    }
    final portrait = im.height >= im.width;
    final lo = portrait ? im.width : im.height, hi = portrait ? im.height : im.width;
    if (hi > lo * 2) {
      // tambah latar di sisi pendek → rasio 9:16
      final targetLo = (hi * 9 / 16).ceil();
      final bg = img.Image(width: portrait ? targetLo : hi, height: portrait ? hi : targetLo);
      img.fill(bg, color: img.ColorRgb8(18, 18, 22));
      img.compositeImage(bg, im, dstX: (bg.width - im.width) ~/ 2, dstY: (bg.height - im.height) ~/ 2);
      im = bg;
      notes.add('${p.basename(f.path)}: terlalu panjang → diberi latar (9:16)');
    }
    final big = im.width > im.height ? im.width : im.height;
    if (big > 3840) im = im.width >= im.height ? img.copyResize(im, width: 3840) : img.copyResize(im, height: 3840);
    final small = im.width < im.height ? im.width : im.height;
    if (small < 320) {
      notes.add('✖ ${p.basename(f.path)}: terlalu kecil (${im.width}x${im.height})');
      continue;
    }
    i++;
    await File(p.join(dir.path, '$i.png')).writeAsBytes(img.encodePng(im));
  }
  notes.insert(0, '$i screenshot tersimpan${i < 2 ? ' — minimal 2!' : ''}');
  return notes;
}

/// Tulis judul + deskripsi dengan AI (kalau AI diaktifkan di Pengaturan).
Future<Map<String, String>> aiListing(Project pr, String hint) async {
  final ai = AiFixer.instance;
  if (!ai.ready) throw Exception('Aktifkan AI di Pengaturan → AI perbaikan otomatis');
  final ans = await ai.chat(
      'Kamu copywriter Play Store berbahasa Indonesia. Patuhi kebijakan Google Play: tanpa klaim "terbaik/#1", tanpa emoji berlebihan, tanpa kata kunci berulang. '
      'Balas HANYA JSON: {"title":"maks 30 karakter","short":"maks 80 karakter","full":"maks 3500 karakter, paragraf + poin fitur"}',
      'Aplikasi: ${pr.name} (${pr.packageName}). ${pr.isSocialApp ? 'Aplikasi chat/sosial. ' : ''}Keterangan dari developer: $hint',
      maxTokens: 3000);
  final m = RegExp(r'\{[\s\S]*\}').firstMatch(ans.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), ''));
  if (m == null) throw Exception('Jawaban AI tidak bisa dibaca');
  final j = jsonDecode(m.group(0)!) as Map;
  String cut(String s, int n) => s.length > n ? s.substring(0, n).trim() : s.trim();
  return {'title': cut('${j['title']}', 30), 'short': cut('${j['short']}', 80), 'full': cut('${j['full']}', 4000)};
}

// ───────────────────────── SHA-1 → Firebase
Future<String?> uploadKeySha1(Project pr, String keytool) async {
  final kp = File(p.join(pr.localPath, 'android', 'key.properties'));
  if (!await kp.exists()) return null;
  final props = <String, String>{};
  for (final line in await kp.readAsLines()) {
    final i = line.indexOf('=');
    if (i > 0) props[line.substring(0, i).trim()] = line.substring(i + 1).trim();
  }
  final storeFile = props['storeFile'];
  if (storeFile == null) return null;
  var ks = p.isAbsolute(storeFile) ? storeFile : p.join(pr.localPath, 'android', 'app', storeFile);
  if (!await File(ks).exists()) ks = p.join(pr.localPath, 'android', storeFile);
  final r = await Process.run(keytool, ['-list', '-v', '-keystore', ks, '-alias', props['keyAlias'] ?? '', '-storepass', props['storePassword'] ?? ''],
      runInShell: true, environment: ToolEnv.env());
  return RegExp(r'SHA1:\s*([0-9A-Fa-f:]+)').firstMatch('${r.stdout}')?.group(1);
}

/// Daftarkan SHA-1 upload key (+ App signing key Play) ke Firebase, lalu unduh ulang google-services.json.
Future<bool> fixFirebaseSha(Project pr, AppSettings s, {String playSha = '', required void Function(String) log}) async {
  final jsonPath = pr.googleServicesJsonPath.isNotEmpty ? pr.googleServicesJsonPath : p.join(pr.localPath, 'android', 'app', 'google-services.json');
  final j = jsonDecode(await File(jsonPath).readAsString()) as Map;
  final projectId = '${j['project_info']?['project_id'] ?? ''}';
  if (projectId.isEmpty) throw Exception('project_id tidak ada di google-services.json');
  final fb = FirebaseTool(flutterCmd: s.flutterCmd, log: log);
  if (await fb.loginEmail() == null) throw Exception('Belum login Firebase — buka Proyek → Setup Firebase, klik Login');
  final appId = await fb.androidAppId(projectId, pr.packageName);
  if (appId == null) throw Exception('Aplikasi ${pr.packageName} tidak ada di Firebase project $projectId');
  final shas = <String>{
    if ((await uploadKeySha1(pr, s.keytoolCmd)) case final u?) u,
    if (playSha.trim().isNotEmpty) playSha.trim().toUpperCase(),
    if (pr.playSigningSha1.isNotEmpty) pr.playSigningSha1.toUpperCase(),
  };
  if (shas.isEmpty) throw Exception('SHA-1 upload key tidak terbaca (cek android/key.properties)');
  for (final sha in shas) {
    final ok = await fb.addSha(projectId, appId, sha);
    log('${ok ? '✔' : '⚠'} SHA-1 $sha ${ok ? 'ditambahkan' : '(mungkin sudah ada)'}');
  }
  final ok = await fb.downloadAndroidConfig(projectId, appId, jsonPath);
  log(ok ? '✔ google-services.json diperbarui: $jsonPath' : '✖ gagal mengunduh google-services.json');
  return ok;
}
