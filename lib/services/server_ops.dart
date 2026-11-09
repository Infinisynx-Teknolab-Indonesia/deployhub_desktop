import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'ai_fixer.dart';
import 'integrations.dart';
import 'mac_service.dart';
import 'storage.dart';

/// Otomatisasi Deployment & Infrastruktur (Pengaturan → Server & infrastruktur).
///
/// Untuk server backend (VPS / cloud: FastAPI, MySQL, Docker / Portainer):
///  • Deploy: SSH → git pull → docker compose up -d --build → restart layanan
///  • Backup database terjadwal (+ salin ke PC lewat SFTP) dan restore
///  • Health check: URL /health + CPU/RAM/disk/container → alert Telegram/Discord/Slack
///  • Ekspor skrip Python (Fabric) yang sama untuk dijalankan lewat cron / Task Scheduler
class ServerTarget {
  ServerTarget({
    required this.id,
    this.name = '',
    this.host = '',
    this.port = 22,
    this.user = 'root',
    this.keyPath = '',
    this.workdir = '',
    this.branch = 'main',
    this.deployCmd = 'git pull origin {branch} && docker compose up -d --build && docker image prune -f',
    this.backupCmd = '',
    this.restoreCmd = '',
    this.healthUrl = '',
    this.autoDeploy = false,
    this.backupDaily = false,
    this.backupHour = 2,
    this.backupKeepDays = 7,
    this.downloadBackup = true,
    this.healthOn = false,
    this.healthMinutes = 5,
    this.selfHeal = true,
    this.autoRollback = true,
    this.aiRemediate = true,
    this.aiRunCommands = false,
    this.monitoringOn = false,
    this.provider = '',
  });

  final String id;
  String name, host, user, keyPath, workdir, branch, deployCmd, backupCmd, restoreCmd, healthUrl;
  int port, backupHour, backupKeepDays, healthMinutes;
  bool autoDeploy, backupDaily, downloadBackup, healthOn;
  bool selfHeal, autoRollback, aiRemediate, aiRunCommands, monitoringOn;
  String provider; // digitalocean / aws / gcp (kalau dibuat lewat Terraform)

  // status terakhir (tidak disimpan)
  String lastHealth = '';
  bool? healthy;
  String lastCommit = '';

  String get secretKey => 'server_pw_$id';

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'host': host, 'port': port, 'user': user, 'keyPath': keyPath, 'workdir': workdir,
        'branch': branch, 'deployCmd': deployCmd, 'backupCmd': backupCmd, 'restoreCmd': restoreCmd, 'healthUrl': healthUrl,
        'autoDeploy': autoDeploy, 'backupDaily': backupDaily, 'backupHour': backupHour, 'backupKeepDays': backupKeepDays,
        'downloadBackup': downloadBackup, 'healthOn': healthOn, 'healthMinutes': healthMinutes,
        'selfHeal': selfHeal, 'autoRollback': autoRollback, 'aiRemediate': aiRemediate, 'aiRunCommands': aiRunCommands,
        'monitoringOn': monitoringOn, 'provider': provider,
      };

  factory ServerTarget.fromJson(Map<String, dynamic> j) => ServerTarget(
        id: j['id'],
        name: j['name'] ?? '',
        host: j['host'] ?? '',
        port: (j['port'] as num?)?.toInt() ?? 22,
        user: j['user'] ?? 'root',
        keyPath: j['keyPath'] ?? '',
        workdir: j['workdir'] ?? '',
        branch: j['branch'] ?? 'main',
        deployCmd: j['deployCmd'] ?? '',
        backupCmd: j['backupCmd'] ?? '',
        restoreCmd: j['restoreCmd'] ?? '',
        healthUrl: j['healthUrl'] ?? '',
        autoDeploy: j['autoDeploy'] == true,
        backupDaily: j['backupDaily'] == true,
        backupHour: (j['backupHour'] as num?)?.toInt() ?? 2,
        backupKeepDays: (j['backupKeepDays'] as num?)?.toInt() ?? 7,
        downloadBackup: j['downloadBackup'] != false,
        healthOn: j['healthOn'] == true,
        healthMinutes: (j['healthMinutes'] as num?)?.toInt() ?? 5,
        selfHeal: j['selfHeal'] != false,
        autoRollback: j['autoRollback'] != false,
        aiRemediate: j['aiRemediate'] != false,
        aiRunCommands: j['aiRunCommands'] == true,
        monitoringOn: j['monitoringOn'] == true,
        provider: j['provider'] ?? '',
      );
}

/// Template perintah backup / restore yang umum.
const backupTemplates = <String, (String, String)>{
  'MySQL (Docker)': (
    'mkdir -p ~/backups && docker exec {container} sh -c \'exec mysqldump -uroot -p"\$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction\' | gzip > ~/backups/db_\$(date +%F_%H%M).sql.gz',
    'gunzip -c {file} | docker exec -i {container} sh -c \'exec mysql -uroot -p"\$MYSQL_ROOT_PASSWORD"\'',
  ),
  'PostgreSQL (Docker)': (
    'mkdir -p ~/backups && docker exec {container} pg_dumpall -U postgres | gzip > ~/backups/db_\$(date +%F_%H%M).sql.gz',
    'gunzip -c {file} | docker exec -i {container} psql -U postgres',
  ),
  'MySQL (langsung di server)': (
    'mkdir -p ~/backups && mysqldump --all-databases --single-transaction | gzip > ~/backups/db_\$(date +%F_%H%M).sql.gz',
    'gunzip -c {file} | mysql',
  ),
  'Folder (tar)': (
    'mkdir -p ~/backups && tar czf ~/backups/files_\$(date +%F_%H%M).tar.gz -C {workdir} .',
    'tar xzf {file} -C {workdir}',
  ),
};

class ServerOps {
  ServerOps._();
  static final ServerOps instance = ServerOps._();

  bool on = false; // saklar utama "Otomatisasi Deployment & Infrastruktur"
  List<ServerTarget> servers = [];
  final _timers = <Timer>[];
  final _badCommits = <String, String>{}; // commit yang gagal & sudah di-rollback (tidak dideploy ulang)

  Future<void> _saveBad() => Storage.writeJson('servers_bad_commits.json', _badCommits);
  final _lastBackupDay = <String, String>{};

  Future<void> load() async {
    final j = await Storage.readJson('servers.json');
    if (j is! Map) return;
    on = j['on'] == true;
    servers = [for (final s in (j['servers'] as List? ?? const [])) ServerTarget.fromJson(Map<String, dynamic>.from(s))];
    final bad = await Storage.readJson('servers_bad_commits.json');
    if (bad is Map) _badCommits.addAll(bad.map((k, v) => MapEntry('$k', '$v')));
  }

  Future<void> save() => Storage.writeJson('servers.json', {'on': on, 'servers': servers.map((s) => s.toJson()).toList()});

  // ───────────────────────── SSH
  Future<SSHClient> connect(ServerTarget s) async {
    final socket = await SSHSocket.connect(s.host, s.port, timeout: const Duration(seconds: 12));
    final pw = await Storage.secret(s.secretKey);
    List<SSHIdentity>? ids;
    if (s.keyPath.isNotEmpty) {
      ids = [...SSHKeyPair.fromPem(await File(s.keyPath).readAsString(), pw.isEmpty ? null : pw)];
    }
    final c = SSHClient(socket, username: s.user, identities: ids, onPasswordRequest: pw.isEmpty ? null : () => pw);
    await c.authenticated;
    return c;
  }

  String _fill(ServerTarget s, String cmd) => cmd
      .replaceAll('{branch}', s.branch)
      .replaceAll('{workdir}', s.workdir.isEmpty ? '.' : s.workdir);

  /// Jalankan perintah di server (di folder kerja), stream output ke [log]. Mengembalikan exit code.
  Future<int> exec(ServerTarget s, String cmd, void Function(String) log, {bool inWorkdir = true}) async {
    final c = await connect(s);
    try {
      final full = inWorkdir && s.workdir.isNotEmpty ? 'cd ${_q(s.workdir)} && ${_fill(s, cmd)}' : _fill(s, cmd);
      log('\$ ${_fill(s, cmd)}');
      return await MacService.run(c, 'bash -lc ${_q(full)}', log);
    } finally {
      c.close();
    }
  }

  Future<String> test(ServerTarget s) async {
    final lines = <String>[];
    final code = await exec(s, 'echo "\$(hostname) • \$(uname -sr)"; docker --version 2>/dev/null; git --version 2>/dev/null', lines.add, inWorkdir: false);
    if (code != 0) throw Exception(lines.join('\n'));
    return lines.where((l) => !l.startsWith('\$ ')).join(' • ');
  }

  /// Deploy: git pull + build ulang container + restart layanan.
  /// Gagal (perintah error / health check gagal) → rollback otomatis ke commit sebelumnya,
  /// lalu (kalau AI aktif) AI mendiagnosis log deploy.
  Future<bool> deploy(ServerTarget s, void Function(String) log) async {
    log('🚀 Deploy ${s.name} (${s.host})');
    var prev = '';
    if (s.autoRollback && s.workdir.isNotEmpty) {
      final l = <String>[];
      await exec(s, 'git rev-parse HEAD 2>/dev/null', l.add);
      prev = l.map((x) => x.trim()).firstWhere((x) => RegExp(r'^[0-9a-f]{40}$').hasMatch(x), orElse: () => '');
      if (prev.isNotEmpty) log('📌 Commit sekarang: ${prev.substring(0, 7)} (titik rollback)');
    }
    final out = <String>[];
    void both(String l) {
      out.add(l);
      log(l);
    }

    final code = await exec(s, s.deployCmd, both);
    var ok = code == 0;
    var newHead = '';
    if (s.workdir.isNotEmpty) {
      final l = <String>[];
      await exec(s, 'git rev-parse HEAD 2>/dev/null', l.add);
      newHead = l.map((x) => x.trim()).firstWhere((x) => RegExp(r'^[0-9a-f]{40}$').hasMatch(x), orElse: () => '');
    }
    var health = '';
    if (ok && (s.healthUrl.isNotEmpty || s.healthOn)) {
      // aplikasi butuh waktu untuk siap setelah container start → coba ulang sampai ±60 detik
      // (tanpa ini, versi yang sebenarnya baik bisa ikut di-rollback)
      var h = false;
      for (var i = 1; i <= 7 && !h; i++) {
        await Future.delayed(Duration(seconds: i == 1 ? 5 : 10));
        h = await healthCheck(s, log: i == 7 ? log : null, notifyOnFail: false, heal: false);
        if (!h && i < 7) log('   …aplikasi belum siap, cek lagi ($i/6)');
      }
      health = h ? ' • health OK' : ' • ⚠ health GAGAL';
      ok = h;
    }
    var rolled = '';
    if (!ok && prev.isNotEmpty) {
      log('');
      log('⏪ Deploy gagal → rollback otomatis ke ${prev.substring(0, 7)}');
      final redeploy = s.deployCmd.replaceAll(RegExp(r'git pull[^&;]*(&&|;)\s*'), '');
      final rc = await exec(s, 'git reset --hard $prev && $redeploy', log);
      rolled = rc == 0 ? ' • ⏪ dikembalikan ke ${prev.substring(0, 7)}' : ' • ⏪ rollback GAGAL';
      // commit rusak ini jangan dideploy ulang otomatis — tunggu commit perbaikan berikutnya
      if (newHead.isNotEmpty && newHead != prev) {
        s.lastCommit = newHead;
        _badCommits[s.id] = newHead;
        await _saveBad();
      }
    }
    if (!ok) await _aiRemediate(s, 'Deploy gagal (kode $code). Output deploy:\n${out.takeLast(150).join('\n')}', log);
    await Integrations.instance.notify('${ok ? '✅' : '❌'} Deploy server ${s.name} ${ok ? 'berhasil' : 'GAGAL (kode $code)'}$health$rolled');
    return ok;
  }

  /// Backup DB → ~/backups di server, hapus backup lama, opsional unduh ke PC.
  Future<String?> backup(ServerTarget s, void Function(String) log) async {
    if (s.backupCmd.trim().isEmpty) throw Exception('Perintah backup belum diisi');
    log('💾 Backup ${s.name}');
    final code = await exec(s, s.backupCmd, log);
    if (code != 0) {
      await Integrations.instance.notify('❌ Backup ${s.name} GAGAL (kode $code)');
      throw Exception('Backup gagal (kode $code)');
    }
    final lines = <String>[];
    await exec(s, 'find ~/backups -type f -mtime +${s.backupKeepDays} -delete; ls -t ~/backups | head -1', lines.add, inWorkdir: false);
    final latest = lines.where((l) => !l.startsWith('\$ ') && l.trim().isNotEmpty).lastOrNull?.trim();
    String? local;
    if (latest != null && s.downloadBackup) {
      local = await downloadFile(s, '~/backups/$latest', log);
    }
    await Integrations.instance.notify('💾 Backup ${s.name} selesai: ${latest ?? '-'}${local == null ? '' : ' (salinan di PC)'}');
    return local ?? latest;
  }

  Future<List<String>> listBackups(ServerTarget s) async {
    final lines = <String>[];
    await exec(s, 'ls -t ~/backups 2>/dev/null | head -20', lines.add, inWorkdir: false);
    return lines.where((l) => !l.startsWith('\$ ') && l.trim().isNotEmpty).toList();
  }

  Future<bool> restore(ServerTarget s, String file, void Function(String) log) async {
    if (s.restoreCmd.trim().isEmpty) throw Exception('Perintah restore belum diisi');
    log('♻ Restore ${s.name} dari $file');
    final code = await exec(s, s.restoreCmd.replaceAll('{file}', '~/backups/$file'), log);
    await Integrations.instance.notify('${code == 0 ? '♻ Restore berhasil' : '❌ Restore GAGAL'}: ${s.name} ← $file');
    return code == 0;
  }

  /// Unduh file dari server ke folder backups/<server> di PC (disaster recovery: salinan di luar server).
  Future<String> downloadFile(ServerTarget s, String remote, void Function(String) log) async {
    final c = await connect(s);
    try {
      final sftp = await c.sftp();
      var path = remote;
      if (path.startsWith('~/')) {
        final home = utf8.decode(await c.run('echo \$HOME')).trim();
        path = '$home/${path.substring(2)}';
      }
      final dir = Directory(p.join(Storage.dir.path, 'backups', s.name.isEmpty ? s.host : s.name));
      await dir.create(recursive: true);
      final local = File(p.join(dir.path, p.basename(path)));
      final f = await sftp.open(path);
      final sink = local.openWrite();
      await for (final chunk in f.read()) {
        sink.add(chunk);
      }
      await sink.close();
      await f.close();
      log('⬇ ${local.path} (${(await local.length()) ~/ 1024} KB)');
      return local.path;
    } finally {
      c.close();
    }
  }

  static const _probe = r"""echo "load $(cut -d' ' -f1 /proc/loadavg)"
free -m | awk '/Mem:/{printf "RAM %d%%\n", $3*100/$2}'
df -P / | awk 'NR==2{print "disk "$5}'
echo "container jalan $(docker ps -q 2>/dev/null | wc -l)"
for c in $(docker ps -a --filter status=exited --filter status=restarting --format '{{.Names}}' 2>/dev/null); do
  pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)
  case "$pol" in always|unless-stopped|on-failure) echo "⚠ mati: $c";; esac
done | head -5
if curl -s -m 4 http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
  curl -s -m 5 http://127.0.0.1:9090/api/v1/alerts | python3 -c "import sys,json
a=[x['labels'].get('alertname','?') for x in json.load(sys.stdin)['data']['alerts'] if x.get('state')=='firing']
print('🔥 alert: '+', '.join(sorted(set(a)))) if a else None" 2>/dev/null
fi""";

  /// Health check: HTTP + kondisi server (+ alert Prometheus kalau monitoring terpasang). true = sehat.
  /// [heal] = jalankan self-healing kalau tidak sehat (setting "Perbaiki otomatis").
  Future<bool> healthCheck(ServerTarget s, {void Function(String)? log, bool notifyOnFail = true, bool heal = true}) async {
    final parts = <String>[];
    var ok = true;
    var httpOk = true;
    var disk = 0;
    final dead = <String>[];
    if (s.healthUrl.isNotEmpty) {
      final t = DateTime.now();
      try {
        final r = await http.get(Uri.parse(s.healthUrl)).timeout(const Duration(seconds: 15));
        final ms = DateTime.now().difference(t).inMilliseconds;
        parts.add('HTTP ${r.statusCode} • ${ms}ms');
        if (r.statusCode >= 500 || r.statusCode == 404) httpOk = false;
      } catch (e) {
        parts.add('HTTP gagal: ${'$e'.split('\n').first}');
        httpOk = false;
      }
      if (!httpOk) ok = false;
    }
    if (s.host.isNotEmpty) {
      try {
        final lines = <String>[];
        await exec(s, _probe, lines.add, inWorkdir: false);
        final info = lines.where((l) => !l.startsWith('\$ ') && l.trim().isNotEmpty).toList();
        parts.addAll(info);
        disk = int.tryParse(RegExp(r'disk (\d+)%').firstMatch(info.join(' '))?.group(1) ?? '') ?? 0;
        if (disk >= 90) ok = false;
        dead.addAll(info.where((l) => l.startsWith('⚠ mati: ')).map((l) => l.substring(8).trim()));
        if (dead.isNotEmpty) ok = false;
        if (info.any((l) => l.startsWith('🔥 alert'))) ok = false;
      } catch (e) {
        parts.add('SSH gagal: ${'$e'.split('\n').first}');
        ok = false;
      }
    }
    log?.call('${ok ? '💚' : '🔴'} ${s.name}: ${parts.join(' • ')}');

    // ── Self-healing: perbaiki sendiri lalu cek ulang
    if (!ok && heal && s.selfHeal && !_healing.contains(s.id)) {
      _healing.add(s.id);
      try {
        final did = await _heal(s, httpOk: httpOk, disk: disk, dead: dead, log: log ?? (_) {});
        if (did.isNotEmpty) {
          await Future.delayed(const Duration(seconds: 20));
          final again = await healthCheck(s, log: log, notifyOnFail: false, heal: false);
          await Integrations.instance.notify(again
              ? '🩹 Server ${s.name} bermasalah (${parts.join(' • ')}) → diperbaiki otomatis: ${did.join(', ')} → SEHAT lagi'
              : '🔴 Server ${s.name} masih bermasalah setelah perbaikan otomatis (${did.join(', ')}): ${s.lastHealth}');
          if (!again) await _aiRemediate(s, 'Health check gagal: ${parts.join(' • ')}', log ?? (_) {});
          return again;
        }
      } finally {
        _healing.remove(s.id);
      }
    }

    final was = s.healthy;
    s.healthy = ok;
    s.lastHealth = '${DateTime.now().toString().substring(11, 16)} • ${parts.join(' • ')}';
    // alert hanya saat status berubah (tidak spam tiap 5 menit)
    if (notifyOnFail && was != ok && (was != null || !ok)) {
      await Integrations.instance.notify(ok ? '💚 Server ${s.name} pulih: ${parts.join(' • ')}' : '🔴 Server ${s.name} BERMASALAH: ${parts.join(' • ')}');
    }
    return ok;
  }

  final _healing = <String>{};

  /// Langkah perbaikan otomatis yang aman (tidak pernah menghapus data / volume).
  Future<List<String>> _heal(ServerTarget s, {required bool httpOk, required int disk, required List<String> dead, required void Function(String) log}) async {
    final did = <String>[];
    log('🩹 Self-healing ${s.name}…');
    if (dead.isNotEmpty) {
      final cmd = [
        if (s.workdir.isNotEmpty) 'cd ${_q(s.workdir)} && docker compose up -d 2>/dev/null; cd ~',
        for (final c in dead) 'docker start ${_q(c)}',
      ].join('; ');
      await exec(s, cmd, log, inWorkdir: false);
      did.add('start container ${dead.join(', ')}');
    }
    if (!httpOk && s.workdir.isNotEmpty && dead.isEmpty) {
      await exec(s, 'docker compose up -d && docker compose restart', log);
      did.add('restart layanan (docker compose restart)');
    }
    if (disk >= 90) {
      await exec(
          s,
          'docker image prune -af; docker builder prune -af; docker container prune -f; '
          'sudo -n journalctl --vacuum-size=200M 2>/dev/null || journalctl --vacuum-size=200M 2>/dev/null; '
          'find ~/backups -type f -mtime +${s.backupKeepDays} -delete 2>/dev/null; '
          'sudo -n apt-get clean 2>/dev/null; df -h /',
          log,
          inWorkdir: false);
      did.add('bersihkan disk (image lama, cache build, log journal, backup lama)');
    }
    return did;
  }

  /// AI mendiagnosis log server & menjalankan perintah perbaikan yang lolos saringan keamanan.
  Future<void> _aiRemediate(ServerTarget s, String problem, void Function(String) log) async {
    final ai = AiFixer.instance;
    if (!s.aiRemediate || !ai.ready) return;
    try {
      final ctx = <String>[];
      await exec(
          s,
          'echo "== docker ps =="; docker ps -a --format "{{.Names}} | {{.Status}} | {{.Image}}" | head -30; '
          'echo "== logs =="; for c in \$(docker ps -a --format "{{.Names}}" | head -8); do echo "--- \$c"; docker logs --tail 40 "\$c" 2>&1 | tail -40; done; '
          'echo "== disk =="; df -h /; echo "== mem =="; free -m; echo "== git =="; git log --oneline -3 2>/dev/null',
          ctx.add);
      log('🤖 AI menganalisis server ${s.name}…');
      final d = await ai.diagnoseServer(s.name, 'MASALAH: $problem\n\n${ctx.takeLast(400).join('\n')}');
      log('💬 ${d.explanation}');
      final ran = <String>[];
      for (final c in d.commands) {
        if (_dangerous.hasMatch(c)) {
          log('⛔ ditolak (berbahaya): $c');
          continue;
        }
        if (!s.aiRunCommands) {
          log('💡 saran AI: $c');
          continue;
        }
        await exec(s, 'timeout 300 bash -c ${_q(c)}', log);
        ran.add(c);
      }
      await Integrations.instance.notify('🤖 AI • ${s.name}: ${d.explanation}'
          '${ran.isNotEmpty ? '\nDijalankan: ${ran.join(' ; ')}' : d.commands.isNotEmpty ? '\nSaran: ${d.commands.join(' ; ')}' : ''}');
    } catch (e) {
      log('✖ AI: $e');
    }
  }

  /// Perintah yang TIDAK PERNAH dijalankan otomatis.
  static final _dangerous = RegExp(
      r'rm\s+-[a-z]*r[a-z]*f?\s+(/|~|\*|\$HOME)(\s|$)|rm\s+-rf\s+/(?!tmp)|mkfs|\bdd\s+if=|shutdown|reboot|poweroff|\bhalt\b|:\(\)\s*\{|'
      r'drop\s+(database|table|schema)|truncate\s|delete\s+from|docker\s+volume\s+(rm|prune)|--volumes|docker\s+system\s+prune|'
      r'userdel|passwd|chpasswd|chmod\s+-R\s+777|>\s*/dev/sd|(curl|wget)[^|]*\|\s*(sudo\s+)?(ba|z)?sh|iptables\s+-F|ufw\s+(disable|reset)|'
      r'sshd_config|authorized_keys|git\s+push|crontab\s+-r|kill\s+-9\s+1\b',
      caseSensitive: false);

  // ───────────────────────── jadwal
  void restart() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    if (!on) return;
    for (final s in servers) {
      if (s.healthOn) {
        _timers.add(Timer.periodic(Duration(minutes: s.healthMinutes.clamp(1, 1440).toInt()), (_) => healthCheck(s).catchError((_) => false)));
      }
    }
    // backup harian + deploy otomatis saat commit baru: dicek tiap menit / 3 menit
    _timers.add(Timer.periodic(const Duration(minutes: 1), (_) => _tickBackup()));
    if (servers.any((s) => s.autoDeploy)) {
      _timers.add(Timer.periodic(const Duration(minutes: 3), (_) => _tickDeploy()));
    }
  }

  Future<void> _tickBackup() async {
    final now = DateTime.now();
    final day = now.toIso8601String().substring(0, 10);
    for (final s in servers.where((s) => s.backupDaily && s.backupCmd.isNotEmpty)) {
      if (now.hour == s.backupHour && _lastBackupDay[s.id] != day) {
        _lastBackupDay[s.id] = day;
        try {
          await backup(s, (_) {});
        } catch (_) {}
      }
    }
  }

  /// Commit baru di branch (dicek di server: git fetch) → deploy otomatis.
  Future<void> _tickDeploy() async {
    for (final s in servers.where((s) => s.autoDeploy && s.workdir.isNotEmpty)) {
      try {
        final lines = <String>[];
        await exec(s, 'git fetch -q origin ${s.branch} && git rev-parse HEAD origin/${s.branch}', lines.add);
        final h = lines.where((l) => RegExp(r'^[0-9a-f]{40}$').hasMatch(l.trim())).map((l) => l.trim()).toList();
        if (h.length == 2 && h[0] != h[1] && s.lastCommit != h[1] && _badCommits[s.id] != h[1]) {
          s.lastCommit = h[1];
          await Integrations.instance.notify('🔔 Commit baru ${h[1].substring(0, 7)} di ${s.name} → deploy otomatis');
          await deploy(s, (_) {});
        }
      } catch (_) {}
    }
  }

  // ───────────────────────── skrip Python (Fabric)
  /// Skrip Python dengan Fabric + Paramiko — sama persis dengan yang dikerjakan DeployHub,
  /// untuk dijalankan terjadwal tanpa DeployHub (cron di Linux / Task Scheduler di Windows).
  String pythonScript(ServerTarget s) => '''#!/usr/bin/env python3
r"""Otomatisasi server ${s.name} — dibuat DeployHub.

Pasang (tanpa venv):
    D:\\python3.12\\python.exe -m pip install fabric requests
Jalankan:
    python deploy_${_slug(s.name)}.py deploy     # git pull + docker compose build + restart
    python deploy_${_slug(s.name)}.py backup     # backup database + unduh ke PC
    python deploy_${_slug(s.name)}.py health     # cek kesehatan server
Password / passphrase dibaca dari environment variable SERVER_PASSWORD (jangan ditulis di file ini).
"""
import os
import sys
import datetime
import time
import requests
from fabric import Connection

HOST = "${s.host}"
PORT = ${s.port}
USER = "${s.user}"
KEY_FILE = r"${s.keyPath}" or None
WORKDIR = "${s.workdir}"
BRANCH = "${s.branch}"
DEPLOY_CMD = ${jsonEncode(_fill(s, s.deployCmd))}
BACKUP_CMD = ${jsonEncode(_fill(s, s.backupCmd))}
HEALTH_URL = "${s.healthUrl}"
KEEP_DAYS = ${s.backupKeepDays}


def conn():
    kw = {}
    pw = os.environ.get("SERVER_PASSWORD")
    if KEY_FILE:
        kw["key_filename"] = KEY_FILE
        if pw:
            kw["passphrase"] = pw
    elif pw:
        kw["password"] = pw
    return Connection(HOST, user=USER, port=PORT, connect_kwargs=kw)


def deploy():
    with conn() as c:
        with c.cd(WORKDIR):
            c.run(DEPLOY_CMD, pty=True)
    if HEALTH_URL:
        time.sleep(5)
        health(retries=7)  # beri waktu aplikasi siap (±60 detik)


def backup():
    if not BACKUP_CMD:
        sys.exit("BACKUP_CMD kosong")
    with conn() as c:
        c.run(BACKUP_CMD, pty=True)
        c.run(f"find ~/backups -type f -mtime +{KEEP_DAYS} -delete")
        latest = c.run("ls -t ~/backups | head -1", hide=True).stdout.strip()
        home = c.run("echo \$HOME", hide=True).stdout.strip()
        os.makedirs("backups", exist_ok=True)
        c.get(f"{home}/backups/{latest}", local=os.path.join("backups", latest))
        print("Backup tersimpan:", os.path.join("backups", latest))


def health(retries=1):
    ok = True
    if HEALTH_URL:
        for i in range(retries):
            try:
                r = requests.get(HEALTH_URL, timeout=15)
                print("HTTP", r.status_code, f"{r.elapsed.total_seconds() * 1000:.0f}ms")
                ok = r.status_code < 500
            except Exception as e:  # noqa: BLE001
                print("HTTP gagal:", e)
                ok = False
            if ok or i == retries - 1:
                break
            print(f"...aplikasi belum siap, cek lagi ({i + 1}/{retries - 1})")
            time.sleep(10)
    with conn() as c:
        c.run("uptime; free -m; df -h /; docker ps --format '{{.Names}}: {{.Status}}'")
    print(datetime.datetime.now(), "SEHAT" if ok else "BERMASALAH")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    from invoke.exceptions import UnexpectedExit
    action = {"deploy": deploy, "backup": backup, "health": health}.get(sys.argv[1] if len(sys.argv) > 1 else "")
    if action is None:
        sys.exit(__doc__)
    try:
        action()
    except UnexpectedExit as e:
        print(f"\\nGAGAL: perintah '{e.result.command}' keluar dengan kode {e.result.exited}", file=sys.stderr)
        sys.exit(e.result.exited or 1)
''';

  static String _slug(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '').ifEmpty('server');
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

extension _TakeLast<T> on List<T> {
  List<T> takeLast(int n) => length <= n ? this : sublist(length - n);
}
