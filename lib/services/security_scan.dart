import 'dart:io';

import 'package:path/path.dart' as p;

import 'tool_env.dart';

/// Hasil security scan sederhana (tanpa alat tambahan).
class ScanFinding {
  ScanFinding(this.level, this.text);
  final String level; // fail | warn
  final String text;
}

/// Cari rahasia yang tertulis di kode, file rahasia yang ikut ke git, dan URL http:// tanpa enkripsi.
Future<List<ScanFinding>> securityScan(String root, {String git = 'git'}) async {
  final out = <ScanFinding>[];
  final patterns = <String, RegExp>{
    'Private key': RegExp(r'-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'Google service account': RegExp(r'"type"\s*:\s*"service_account"'),
    'AWS access key': RegExp(r'AKIA[0-9A-Z]{16}'),
    'Stripe secret key': RegExp(r'sk_live_[0-9a-zA-Z]{20,}'),
    'GitHub token': RegExp(r'gh[pousr]_[0-9A-Za-z]{30,}|github_pat_[0-9A-Za-z_]{40,}'),
    'Slack token': RegExp(r'xox[baprs]-[0-9A-Za-z-]{10,}'),
    'Password di kode': RegExp(r'''(password|passwd|secret|api_?key)\s*[:=]\s*['"][^'"\s]{8,}['"]''', caseSensitive: false),
  };
  final dirs = ['lib', p.join('android', 'app', 'src')];
  for (final d in dirs) {
    final dir = Directory(p.join(root, d));
    if (!await dir.exists()) continue;
    await for (final e in dir.list(recursive: true)) {
      if (e is! File) continue;
      final ext = p.extension(e.path);
      if (!['.dart', '.kt', '.java', '.xml', '.json', '.properties', '.yaml'].contains(ext)) continue;
      if (p.basename(e.path) == 'google-services.json') continue; // API key Firebase memang publik
      String s;
      try {
        s = await e.readAsString();
      } catch (_) {
        continue;
      }
      final rel = p.relative(e.path, from: root);
      for (final entry in patterns.entries) {
        final m = entry.value.firstMatch(s);
        if (m == null) continue;
        final line = '\n'.allMatches(s.substring(0, m.start)).length + 1;
        out.add(ScanFinding(entry.key == 'Password di kode' ? 'warn' : 'fail', '${entry.key} tertulis di $rel:$line'));
      }
      if (ext == '.dart') {
        final http = RegExp(r'''['"]http://(?!localhost|127\.0\.0\.1|10\.0\.2\.2)[^'"\s]+''').firstMatch(s);
        if (http != null) {
          final line = '\n'.allMatches(s.substring(0, http.start)).length + 1;
          out.add(ScanFinding('warn', 'URL tanpa enkripsi (http://) di $rel:$line — Android memblokir http biasa di versi release'));
        }
      }
    }
  }
  // File rahasia yang ikut ke git
  try {
    final r = await Process.run(git, ['ls-files'], workingDirectory: root, runInShell: true, environment: ToolEnv.env());
    if (r.exitCode == 0) {
      for (final f in '${r.stdout}'.split('\n').map((x) => x.trim()).where((x) => x.isNotEmpty)) {
        final b = p.basename(f).toLowerCase();
        if (b == 'key.properties' || b.endsWith('.jks') || b.endsWith('.keystore') || b.endsWith('.p8') || b == '.env') {
          out.add(ScanFinding('fail', '$f ikut ke git! Hapus dari repo: git rm --cached "$f" lalu tambahkan ke .gitignore'));
        }
      }
    }
  } catch (_) {}
  return out;
}
