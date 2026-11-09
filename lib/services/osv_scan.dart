import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Kerentanan yang diketahui di library (database OSV — osv.dev, sama dengan OSV-Scanner Google).
class Vuln {
  Vuln(this.package, this.version, this.id, {this.severity = 'UNKNOWN', this.summary = '', this.fixed = ''});
  final String package, version, id;
  String severity, summary, fixed;

  int get rank => const {'CRITICAL': 4, 'HIGH': 3, 'MEDIUM': 2, 'LOW': 1}[severity] ?? 0;
  bool get serious => rank >= 3;

  String get line => '$severity  $package $version — $id${fixed.isEmpty ? '' : ' → naikkan ke $fixed'}${summary.isEmpty ? '' : '\n      $summary'}';
}

/// pubspec.lock → [(nama, versi)] untuk paket dari pub.dev (paket git / path dilewati).
List<(String, String)> parsePubspecLock(String text) {
  final out = <(String, String)>[];
  String? name, source;
  for (final line in const LineSplitter().convert(text)) {
    final m = RegExp(r'^  ([A-Za-z0-9_]+):\s*$').firstMatch(line);
    if (m != null) {
      name = m.group(1);
      source = null;
      continue;
    }
    if (name == null) continue;
    final s = RegExp(r'^    source:\s*"?(\w+)"?').firstMatch(line);
    if (s != null) source = s.group(1);
    final v = RegExp(r'^    version:\s*"?([^"\s]+)"?').firstMatch(line);
    if (v != null && (source == null || source == 'hosted')) {
      out.add((name, v.group(1)!));
      name = null;
    }
  }
  return out;
}

String _severity(Map d) {
  final s = '${(d['database_specific'] as Map?)?['severity'] ?? ''}'.toUpperCase();
  if (s == 'MODERATE') return 'MEDIUM';
  if (const {'CRITICAL', 'HIGH', 'MEDIUM', 'LOW'}.contains(s)) return s;
  for (final sv in (d['severity'] as List? ?? const [])) {
    final n = double.tryParse('${(sv as Map)['score']}');
    if (n != null) return n >= 9 ? 'CRITICAL' : n >= 7 ? 'HIGH' : n >= 4 ? 'MEDIUM' : 'LOW';
  }
  return 'UNKNOWN';
}

String _fixed(Map d, String pkg) {
  for (final a in (d['affected'] as List? ?? const [])) {
    if ((a as Map)['package']?['name'] != pkg) continue;
    for (final r in (a['ranges'] as List? ?? const [])) {
      for (final e in ((r as Map)['events'] as List? ?? const [])) {
        if ((e as Map)['fixed'] != null) return '${e['fixed']}';
      }
    }
  }
  return '';
}

/// Scan pubspec.lock proyek. Hanya nama paket + versi yang dikirim ke api.osv.dev.
Future<({int packages, List<Vuln> vulns})> osvScan(String root, {http.Client? client}) async {
  final lock = File(p.join(root, 'pubspec.lock'));
  if (!await lock.exists()) return (packages: 0, vulns: <Vuln>[]);
  final pk = parsePubspecLock(await lock.readAsString());
  final c = client ?? http.Client();
  final found = <Vuln>[];
  try {
    for (var i = 0; i < pk.length; i += 500) {
      final chunk = pk.sublist(i, (i + 500).clamp(0, pk.length));
      final r = await c
          .post(Uri.parse('https://api.osv.dev/v1/querybatch'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'queries': [
                  for (final (n, v) in chunk) {'package': {'ecosystem': 'Pub', 'name': n}, 'version': v}
                ]
              }))
          .timeout(const Duration(seconds: 40));
      if (r.statusCode != 200) throw HttpException('osv.dev HTTP ${r.statusCode}');
      final res = (jsonDecode(r.body)['results'] as List? ?? const []);
      for (var j = 0; j < res.length && j < chunk.length; j++) {
        for (final v in ((res[j] as Map)['vulns'] as List? ?? const [])) {
          found.add(Vuln(chunk[j].$1, chunk[j].$2, '${(v as Map)['id']}'));
        }
      }
    }
    final cache = <String, Map>{};
    for (final f in found) {
      var d = cache[f.id];
      if (d == null) {
        try {
          final r = await c.get(Uri.parse('https://api.osv.dev/v1/vulns/${f.id}')).timeout(const Duration(seconds: 20));
          d = r.statusCode == 200 ? jsonDecode(r.body) as Map : {};
        } catch (_) {
          d = {};
        }
        cache[f.id] = d;
      }
      f
        ..severity = _severity(d)
        ..summary = '${d['summary'] ?? ''}'.trim()
        ..fixed = _fixed(d, f.package);
    }
  } finally {
    if (client == null) c.close();
  }
  found.sort((a, b) => b.rank - a.rank);
  return (packages: pk.length, vulns: found);
}
