import 'core/i18n.dart';

String two(int n) => n.toString().padLeft(2, '0');

String fmtTime(DateTime t) =>
    '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';

String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return trL('baru saja');
  if (d.inHours < 1) return trL('{0} menit lalu', [d.inMinutes]);
  if (d.inDays < 1) return trL('{0} jam lalu', [d.inHours]);
  return trL('{0} hari lalu', [d.inDays]);
}

String fmtMb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

List<String> splitArgs(String s) =>
    s.trim().isEmpty ? <String>[] : s.trim().split(RegExp(r'\s+'));

/// Quote aman untuk shell POSIX (zsh/bash di Mac).
String shq(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// Quote path di Mac, tetap mendukung awalan ~/
String shPath(String path) {
  if (path == '~') return '~';
  if (path.startsWith('~/')) return '~/${shq(path.substring(2))}';
  return shq(path);
}
