
import '../models.dart';
import 'hub_client.dart';
import 'storage.dart';

/// Sinkron dua arah antara DeployHub desktop (PC) dan DeployHub Server.
///
/// • PC → server: deploy Android yang sukses dari PC dilaporkan ke server
///   (`POST /api/projects/{id}/external-deploy`, butuh server ≥ 1.3.1). Kalau server mati / tidak
///   terjangkau, laporan disimpan di antrean (hub_outbox.json) dan dikirim ulang nanti.
/// • Server → PC: deploy yang dijalankan server (otomatis / manual) ditarik ke Riwayat deploy di PC.
class HubSync {
  HubSync._();
  static final HubSync instance = HubSync._();

  static const _outboxFile = 'hub_outbox.json';
  static const _ignoredFile = 'hub_ignored.json';
  bool _busy = false;

  /// Catatan server yang sengaja dihapus dari riwayat PC → jangan ditarik lagi.
  Future<void> ignore(Iterable<String> ids) async {
    final cur = (await _ignored()).toSet()..addAll(ids.where((e) => e.startsWith('srv-')));
    if (cur.isNotEmpty) await Storage.writeJson(_ignoredFile, cur.toList());
  }

  Future<List<String>> _ignored() async {
    final j = await Storage.readJson(_ignoredFile);
    return j is List ? [for (final x in j) '$x'] : [];
  }

  /// Versi dari "1.1.2+24" → 24 (0 kalau tidak ada).
  static int versionCodeOf(String version) {
    final i = version.indexOf('+');
    return i < 0 ? 0 : int.tryParse(version.substring(i + 1).trim()) ?? 0;
  }

  /// Hanya deploy Android yang benar-benar terupload ke Google Play.
  static bool reportable(RunRecord r) =>
      r.platform == 'android' && r.status == 'success' && r.track.isNotEmpty && versionCodeOf(r.version) > 0;

  Map<String, dynamic> _payload(RunRecord r) {
    // "production 10%" dsb. dari ringkasan pipeline → staged rollout
    final m = RegExp(r'(\d{1,2})\s*%').firstMatch(r.summary);
    final pct = m == null ? null : int.tryParse(m.group(1)!);
    final staged = r.track == 'production' && pct != null && pct > 0 && pct < 100;
    return {
      'projectId': r.projectId,
      'body': {
        'version': r.version,
        'version_code': versionCodeOf(r.version),
        'track': r.track,
        'status': staged ? 'inProgress' : 'completed',
        if (staged) 'fraction': pct! / 100,
        'source': 'pc',
        'started': r.startedAt.millisecondsSinceEpoch / 1000,
        'finished': r.finishedAt.millisecondsSinceEpoch / 1000,
      },
    };
  }

  /// Laporkan satu deploy dari PC. Aman dipanggil kapan saja: gagal → masuk antrean.
  Future<void> report(RunRecord r) async {
    final hub = Hub.instance;
    if (!hub.ready || !reportable(r) || !hub.projects.containsKey(r.projectId)) return;
    final p = _payload(r);
    if (!await _send(p)) {
      final q = await _readOutbox();
      q.add(p);
      await Storage.writeJson(_outboxFile, q);
    }
  }

  /// true = selesai (terkirim ATAU ditolak permanen — tidak perlu diulang); false = coba lagi nanti.
  Future<bool> _send(Map<String, dynamic> p) async {
    try {
      await Hub.instance.req('POST', '/api/projects/${p['projectId']}/external-deploy', body: p['body']);
      return true;
    } catch (e) {
      final msg = '$e';
      // 4xx (proyek belum dikirim ke server, server versi lama, tidak ada izin) → jangan diulang terus
      return RegExp(r'Server HTTP 4\d\d').hasMatch(msg);
    }
  }

  Future<List<Map<String, dynamic>>> _readOutbox() async {
    final j = await Storage.readJson(_outboxFile);
    if (j is! List) return [];
    return [for (final x in j) if (x is Map) Map<String, dynamic>.from(x)];
  }

  /// Kirim ulang laporan yang tertunda.
  Future<void> flush() async {
    if (!Hub.instance.ready) return;
    final q = await _readOutbox();
    if (q.isEmpty) return;
    final left = <Map<String, dynamic>>[];
    for (final p in q) {
      if (!await _send(p)) left.add(p);
    }
    await Storage.writeJson(_outboxFile, left);
  }

  /// Tarik deploy yang dijalankan SERVER ke riwayat PC. Mengembalikan jumlah catatan baru.
  Future<int> pull(List<RunRecord> history, Set<String> projectIds, Map<String, String> names) async {
    final hub = Hub.instance;
    if (!hub.ready) return 0;
    final jobs = await hub.req('GET', '/api/jobs?kind=deploy&limit=50') as List;
    final have = history.map((e) => e.id).toSet()..addAll(await _ignored());
    var added = 0;
    for (final x in jobs) {
      final j = Map<String, dynamic>.from(x as Map);
      final pid = '${j['project_id']}';
      if (j['status'] != 'success' || j['trigger'] == 'pc' || !projectIds.contains(pid)) continue;
      final id = 'srv-${j['id']}';
      if (have.contains(id)) continue;
      final summary = '${j['summary'] ?? ''}';
      final track = summary.split(' • ').first.trim();
      final t0 = DateTime.fromMillisecondsSinceEpoch((((j['started'] ?? j['created']) as num) * 1000).round());
      final t1 = DateTime.fromMillisecondsSinceEpoch((((j['finished'] ?? j['started'] ?? j['created']) as num) * 1000).round());
      history.add(RunRecord(
        id: id,
        projectId: pid,
        projectName: names[pid] ?? pid,
        platform: 'android',
        status: 'success',
        version: '${j['version'] ?? ''}',
        summary: '$summary • server',
        track: track,
        startedAt: t0,
        finishedAt: t1,
        logPath: '',
      ));
      added++;
    }
    if (added > 0) history.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return added;
  }

  /// Satu putaran sinkron penuh. Tidak pernah melempar error (server mati = diam saja).
  Future<bool> run(List<RunRecord> history, Set<String> projectIds, Map<String, String> names) async {
    if (_busy || !Hub.instance.ready) return false;
    _busy = true;
    try {
      await flush();
      return await pull(history, projectIds, names) > 0;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
    }
  }
}
