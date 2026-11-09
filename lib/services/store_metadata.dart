import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';

/// Struktur folder `store/` di project aplikasi:
///
/// store/
///   details.json                 kontak & bahasa default
///   data_safety.csv              hasil "Export to CSV" dari Keamanan Data
///   android/<bahasa>/            mis. id-ID, en-US
///     title.txt                  maks 30 karakter
///     short_description.txt      maks 80 karakter
///     full_description.txt       maks 4000 karakter
///     video.txt                  (opsional) link YouTube
///     images/icon.png            512 x 512
///     images/featureGraphic.png  1024 x 500
///     images/phoneScreenshots/   2–8 gambar
///     images/sevenInchScreenshots/, images/tenInchScreenshots/ (opsional)
class StoreListing {
  StoreListing(this.language, this.dir);
  final String language;
  final Directory dir;
  String title = '';
  String shortDescription = '';
  String fullDescription = '';
  String video = '';
  File? icon;
  File? featureGraphic;
  final Map<String, List<File>> screenshots = {};
}

class StoreMeta {
  StoreMeta(this.root);
  final Directory root;
  Map<String, dynamic> details = {};
  File? dataSafety;
  final List<StoreListing> listings = [];
}

const screenshotTypes = ['phoneScreenshots', 'sevenInchScreenshots', 'tenInchScreenshots'];

String storeDir(Project pr) => p.join(pr.localPath, 'store');

Future<String> _txt(Directory d, String name) async {
  final f = File(p.join(d.path, name));
  return await f.exists() ? (await f.readAsString()).trim() : '';
}

Future<File?> _image(Directory d, String base) async {
  for (final ext in ['png', 'jpg', 'jpeg']) {
    final f = File(p.join(d.path, '$base.$ext'));
    if (await f.exists()) return f;
  }
  return null;
}

Future<StoreMeta?> loadStoreMeta(Project pr) async {
  final root = Directory(storeDir(pr));
  if (!await root.exists()) return null;
  final meta = StoreMeta(root);

  final details = File(p.join(root.path, 'details.json'));
  if (await details.exists()) {
    try {
      meta.details = Map<String, dynamic>.from(jsonDecode(await details.readAsString()));
    } catch (_) {
      meta.details = {'_error': 'details.json bukan JSON yang valid'};
    }
  }
  final csv = File(p.join(root.path, 'data_safety.csv'));
  if (await csv.exists()) meta.dataSafety = csv;

  final android = Directory(p.join(root.path, 'android'));
  if (await android.exists()) {
    final langs = await android.list().where((e) => e is Directory).cast<Directory>().toList();
    langs.sort((a, b) => a.path.compareTo(b.path));
    for (final d in langs) {
      final l = StoreListing(p.basename(d.path), d);
      l.title = await _txt(d, 'title.txt');
      l.shortDescription = await _txt(d, 'short_description.txt');
      l.fullDescription = await _txt(d, 'full_description.txt');
      l.video = await _txt(d, 'video.txt');
      final img = Directory(p.join(d.path, 'images'));
      l.icon = await _image(img, 'icon');
      l.featureGraphic = await _image(img, 'featureGraphic');
      for (final t in screenshotTypes) {
        final sd = Directory(p.join(img.path, t));
        if (!await sd.exists()) continue;
        final files = await sd
            .list()
            .where((e) => e is File && RegExp(r'\.(png|jpe?g)$', caseSensitive: false).hasMatch(e.path))
            .cast<File>()
            .toList();
        files.sort((a, b) => a.path.compareTo(b.path));
        if (files.isNotEmpty) l.screenshots[t] = files;
      }
      meta.listings.add(l);
    }
  }
  return meta;
}

/// Ukuran gambar PNG/JPEG (lebar, tinggi) tanpa library tambahan.
Future<(int, int)?> imageSize(File f) async {
  final raf = await f.open();
  try {
    final head = await raf.read(32);
    // PNG
    if (head.length >= 24 && head[0] == 0x89 && head[1] == 0x50) {
      int u32(int o) => (head[o] << 24) | (head[o + 1] << 16) | (head[o + 2] << 8) | head[o + 3];
      return (u32(16), u32(20));
    }
    // JPEG: cari marker SOF
    if (head.length >= 2 && head[0] == 0xFF && head[1] == 0xD8) {
      final bytes = await f.readAsBytes();
      var i = 2;
      while (i + 9 < bytes.length) {
        if (bytes[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = bytes[i + 1];
        final len = (bytes[i + 2] << 8) | bytes[i + 3];
        if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
          final h = (bytes[i + 5] << 8) | bytes[i + 6];
          final w = (bytes[i + 7] << 8) | bytes[i + 8];
          return (w, h);
        }
        i += 2 + len;
      }
    }
  } finally {
    await raf.close();
  }
  return null;
}

/// Buat template folder store/ di project (tidak menimpa file yang sudah ada).
Future<List<String>> createStoreTemplate(Project pr) async {
  final created = <String>[];
  Future<void> write(String rel, String content) async {
    final f = File(p.join(storeDir(pr), rel));
    if (await f.exists()) return;
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    created.add(rel);
  }

  await write(
    'details.json',
    const JsonEncoder.withIndent('  ').convert({
      'contactEmail': 'support@contoh.com',
      'contactWebsite': 'https://contoh.com',
      'contactPhone': '',
      'defaultLanguage': 'id-ID',
    }),
  );
  await write('android/id-ID/title.txt', pr.name);
  await write('android/id-ID/short_description.txt',
      'Deskripsi singkat ${pr.name} (maksimal 80 karakter)');
  await write('android/id-ID/full_description.txt',
      '${pr.name} adalah ...\n\nFitur utama:\n• ...\n• ...\n• ...\n');
  await write('android/id-ID/images/LETAKKAN_GAMBAR_DI_SINI.txt',
      'icon.png             → 512 x 512 px\n'
      'featureGraphic.png   → 1024 x 500 px\n'
      'phoneScreenshots/    → 2 sampai 8 screenshot HP (mis. 1080 x 1920)\n'
      'sevenInchScreenshots/, tenInchScreenshots/ → opsional (tablet)\n');
  await Directory(p.join(storeDir(pr), 'android', 'id-ID', 'images', 'phoneScreenshots'))
      .create(recursive: true);
  await write('BACA_SAYA.txt',
      'Folder ini disinkron otomatis oleh DeployHub ke Google Play.\n\n'
      'data_safety.csv: isi Keamanan Data sekali di Play Console, lalu klik "Export to CSV"\n'
      'dan simpan di sini dengan nama data_safety.csv. Setelah itu perubahan cukup di file ini.\n\n'
      'Tambah bahasa lain: salin folder android/id-ID menjadi android/en-US lalu terjemahkan.\n');
  return created;
}
