import '../theme/dh_theme.dart';
import 'i18n_en.dart';

/// Bahasa tampilan (Pengaturan → Tampilan & Bahasa):
///   'id'   = Bahasa Indonesia
///   'en'   = English
///   'both' = Bilingual: label pendek "English / Indonesia", teks panjang dua baris.
String get appLang => ThemeCtl.instance.lang;
bool get isEnglish => appLang == 'en';
bool get isBilingual => appLang == 'both';

final _ph = RegExp(r'\{\{|\}\}|\{(\d+)\}');

String _fill(String t, List<Object?> args) {
  if (!t.contains('{')) return t;
  return t.replaceAllMapped(_ph, (m) {
    final s = m.group(0)!;
    if (s == '{{') return '{';
    if (s == '}}') return '}';
    final i = int.parse(m.group(1)!);
    return i < args.length ? '${args[i] ?? ''}' : s;
  });
}

/// Terjemahkan teks tampilan. [id] = teks Indonesia (juga kunci kamus),
/// [args] mengisi {0}, {1}, ... Teks yang belum ada terjemahannya tampil apa adanya.
String tr(String id, [List<Object?> args = const []]) {
  final en = kEn[id];
  switch (appLang) {
    case 'en':
      return _fill(en ?? id, args);
    case 'both':
      if (en == null || en == id) return _fill(id, args);
      final a = _fill(en, args), b = _fill(id, args);
      return id.length > 42 ? '$a\n$b' : '$a / $b';
    default:
      return _fill(id, args);
  }
}

/// Satu bahasa saja (untuk log pipeline & pesan panjang): English bila dipilih
/// English, selain itu Bahasa Indonesia.
String trL(String id, [List<Object?> args = const []]) =>
    _fill(isEnglish ? (kEn[id] ?? id) : id, args);
