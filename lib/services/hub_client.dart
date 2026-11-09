import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models.dart';
import 'github_service.dart';
import 'integrations.dart';
import 'ready_builds.dart';
import 'play_auth.dart';
import 'storage.dart';

/// Pengaturan per proyek di DeployHub Server.
class HubProject {
  bool autoBuild = true; // build otomatis setiap push (webhook / polling)
  String autoDeployTrack = ''; // '' = deploy manual • internal / alpha = langsung upload
  bool rolloutAuto = true; // production: naik % otomatis kalau crash/ANR aman
  List<int> steps = [10, 20, 50, 100];
  int minHours = 24;
  List<String> healthUrls = [];
  bool prChecks = true; // cek otomatis Pull Request → ✔/✖ "DeployHub CI" di GitHub
  String vulnBlock = 'critical'; // off | critical | high | medium — tingkat kerentanan yang menggagalkan build
  String syncedAt = '';

  Map<String, dynamic> toJson() => {
        'autoBuild': autoBuild, 'autoDeployTrack': autoDeployTrack, 'rolloutAuto': rolloutAuto,
        'steps': steps, 'minHours': minHours, 'healthUrls': healthUrls, 'syncedAt': syncedAt,
        'prChecks': prChecks, 'vulnBlock': vulnBlock,
      };
  static HubProject fromJson(Map j) => HubProject()
    ..autoBuild = j['autoBuild'] != false
    ..autoDeployTrack = j['autoDeployTrack'] ?? ''
    ..rolloutAuto = j['rolloutAuto'] != false
    ..steps = [for (final s in (j['steps'] as List? ?? const [10, 20, 50, 100])) (s as num).toInt()]
    ..minHours = (j['minHours'] as num?)?.toInt() ?? 24
    ..healthUrls = List<String>.from(j['healthUrls'] ?? const [])
    ..prChecks = j['prChecks'] != false
    ..vulnBlock = j['vulnBlock'] ?? 'critical'
    ..syncedAt = j['syncedAt'] ?? '';
}

/// Klien REST DeployHub Server (PC / VPS). DeployHub desktop = panel kontrol.
class Hub {
  Hub._();
  static final Hub instance = Hub._();
  static const kToken = 'hub_token';

  bool on = false;
  String url = '';
  String username = ''; // kosong = login dengan token server (admin) // mis. http://localhost:8787 atau https://deployhub.domainmu.com
  final projects = <String, HubProject>{};

  bool get ready => on && url.isNotEmpty;
  String get _base => url.trim().replaceAll(RegExp(r'/+$'), '');

  Future<void> load() async {
    final j = await Storage.readJson('hub.json');
    if (j is! Map) return;
    on = j['on'] == true;
    url = j['url'] ?? '';
    username = j['username'] ?? '';
    projects.clear();
    (j['projects'] as Map? ?? {}).forEach((k, v) => projects['$k'] = HubProject.fromJson(v as Map));
  }

  Future<void> save() => Storage.writeJson('hub.json', {
        'on': on,
        'url': url,
        'username': username,
        'projects': {for (final e in projects.entries) e.key: e.value.toJson()},
      });

  HubProject cfg(String pid) => projects[pid] ??= HubProject();

  Future<dynamic> req(String method, String path, {Object? body, Duration timeout = const Duration(seconds: 30)}) async {
    final token = await Storage.secret(kToken);
    final uri = Uri.parse('$_base$path');
    final h = {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
    final b = body == null ? null : jsonEncode(body);
    final r = await switch (method) {
      'GET' => http.get(uri, headers: h),
      'POST' => http.post(uri, headers: h, body: b),
      'PUT' => http.put(uri, headers: h, body: b),
      'DELETE' => http.delete(uri, headers: h),
      _ => throw ArgumentError(method),
    }
        .timeout(timeout);
    if (r.statusCode == 401) {
      throw Exception(username.isEmpty ? 'Token DeployHub Server salah' : 'Sesi login DeployHub Server habis — masuk lagi dengan username & password');
    }
    if (r.statusCode >= 300) {
      var msg = r.body;
      try {
        msg = '${jsonDecode(r.body)['detail']}';
      } catch (_) {}
      throw Exception('Server HTTP ${r.statusCode}: $msg');
    }
    return r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// Login dengan akun server (multi-user + audit log). Token sesi disimpan terenkripsi, password tidak disimpan.
  Future<Map<String, dynamic>> login(String user, String password) async {
    final r = await http
        .post(Uri.parse('$_base/api/login'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'username': user, 'password': password}))
        .timeout(const Duration(seconds: 20));
    final d = r.body.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bodyBytes)));
    if (r.statusCode == 404) throw Exception('Server versi lama (belum ada login) — pakai token, atau update DeployHub Server ke 1.2');
    if (r.statusCode != 200) throw Exception('${d['detail'] ?? 'HTTP ${r.statusCode}'}');
    await Storage.setSecret(kToken, '${d['token']}');
    username = '${d['username']}';
    await save();
    return d;
  }

  Future<void> logout() async {
    try {
      await req('POST', '/api/logout');
    } catch (_) {}
    await Storage.setSecret(kToken, '');
    username = '';
    await save();
  }

  Future<void> changePassword(String old, String nw) => req('POST', '/api/me/password', body: {'old': old, 'new': nw});

  Future<List<Map<String, dynamic>>> audit({int limit = 200}) async =>
      [for (final x in await req('GET', '/api/audit?limit=$limit') as List) Map<String, dynamic>.from(x)];

  Future<Map<String, dynamic>> info() async => Map<String, dynamic>.from(await req('GET', '/api/info'));
  Future<List<Map<String, dynamic>>> serverProjects() async => [for (final x in await req('GET', '/api/projects') as List) Map<String, dynamic>.from(x)];
  Future<List<Map<String, dynamic>>> builds(String pid) async => [for (final x in await req('GET', '/api/projects/$pid/builds?limit=5') as List) Map<String, dynamic>.from(x)];
  Future<List<Map<String, dynamic>>> jobs(String pid) async => [for (final x in await req('GET', '/api/jobs?project=$pid&limit=5') as List) Map<String, dynamic>.from(x)];
  Future<List<Map<String, dynamic>>> rollouts(String pid) async => [for (final x in await req('GET', '/api/projects/$pid/rollouts') as List) Map<String, dynamic>.from(x)];
  Future<int> build(String pid, {String env = 'prod'}) async => (await req('POST', '/api/projects/$pid/build', body: {'env': env}))['job_id'] as int;
  /// → id job, atau null kalau deploy perlu persetujuan admin dulu (server 1.3+: role user → beta/produksi).
  Future<int?> deploy(String pid, int buildId, {String track = 'internal', double? fraction, String notes = ''}) async {
    final r = await req('POST', '/api/projects/$pid/deploy', body: {'build_id': buildId, 'track': track, if (fraction != null) 'fraction': fraction, 'notes': notes});
    return r['pending'] == true ? null : r['job_id'] as int;
  }
  Future<Map<String, dynamic>> log(int jobId, int offset) async => Map<String, dynamic>.from(await req('GET', '/api/jobs/$jobId/log?offset=$offset'));
  Future<void> cancel(int jobId) => req('POST', '/api/jobs/$jobId/cancel');
  Future<void> testNotify() => req('POST', '/api/notify/test');

  /// Unduh AAB hasil server ke folder artefak di PC → jadi "Build siap deploy" lokal juga
  /// (tetap bisa dideploy dari PC walaupun server mati).
  Future<String> downloadBuild(Project pr, Map<String, dynamic> b, {void Function(int got, int total)? progress}) async {
    final token = await Storage.secret(kToken);
    final req = http.Request('GET', Uri.parse('$_base/api/builds/${b['id']}/download'))..headers['Authorization'] = 'Bearer $token';
    final res = await http.Client().send(req);
    if (res.statusCode != 200) throw Exception('Unduh gagal: HTTP ${res.statusCode}');
    final ver = '${b['version']}'.replaceAll('+', '-');
    final dir = Directory(p.join(Storage.dir.path, 'artifacts', pr.packageName.isEmpty ? pr.id : pr.packageName, ver));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'app-release.aab'));
    final tmp = File('${file.path}.part');
    final sink = tmp.openWrite();
    var got = 0;
    final total = res.contentLength ?? 0;
    await for (final chunk in res.stream) {
      sink.add(chunk);
      got += chunk.length;
      progress?.call(got, total);
    }
    await sink.close();
    if (total > 0 && got != total) {
      await tmp.delete();
      throw Exception('Unduhan terputus ($got dari $total byte)');
    }
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
    await ReadyBuilds.instance.put(pr.id, ReadyBuild(platform: 'android', path: file.path, version: '${b['version']}', commit: '${b['commit_sha'] ?? ''}'));
    return file.path;
  }

  /// Kirim konfigurasi proyek + rahasianya ke server. Mengembalikan daftar yang terkirim / peringatan.
  Future<List<String>> syncProject(Project pr, AppSettings s, {bool secrets = true}) async {
    if (!pr.hasGithub) throw Exception('Isi GitHub (owner/repo) di Edit proyek dulu — server mengambil kode dari GitHub');
    final c = cfg(pr.id);
    final out = <String>[];
    await req('PUT', '/api/projects/${pr.id}', body: {
      'name': pr.name,
      'repo_url': 'https://github.com/${pr.githubOwner}/${pr.githubRepo}.git',
      'branch': pr.branch,
      'package': pr.packageName,
      'env': 'prod',
      'auto_build': c.autoBuild,
      'auto_deploy_track': c.autoDeployTrack,
      'extra_build_args': pr.extraBuildArgs,
      'min_coverage': pr.minCoverage,
      'pr_checks': c.prChecks,
      'vuln_block': c.vulnBlock,
      'health_urls': c.healthUrls,
      'rollout': {'enabled': true, 'auto': c.rolloutAuto, 'steps': c.steps, 'min_hours': c.minHours, 'max_crash': 1.09, 'max_anr': 0.47},
    });
    out.add('✔ konfigurasi ${pr.name}');
    if (secrets) {
      Future<void> put(String name, String value, String label) async {
        if (value.isEmpty) return;
        await req('PUT', '/api/projects/${pr.id}/secrets/$name', body: {'value': value});
        out.add('🔐 $label');
      }

      // Service account Google Play (login Google OAuth tidak bisa dipakai server)
      final sa = pr.serviceAccountPath.isNotEmpty ? pr.serviceAccountPath : s.playServiceAccountPath;
      if (sa.isNotEmpty && PlayAuth.isServiceAccountFile(sa)) {
        await put('service_account_json', await File(sa).readAsString(), 'service account Google Play');
      } else {
        out.add('⚠ Service account belum ada — server tidak bisa upload ke Play (login Google hanya untuk aplikasi desktop). Buat di Google Cloud → IAM → Service accounts.');
      }
      // keystore + key.properties
      final kp = File(p.join(pr.localPath, 'android', 'key.properties'));
      if (await kp.exists()) {
        final text = await kp.readAsString();
        final store = RegExp(r'^storeFile\s*=\s*(.+)$', multiLine: true).firstMatch(text)?.group(1)?.trim() ?? '';
        final ks = [store, p.join(pr.localPath, 'android', 'app', store), p.join(pr.localPath, 'android', store)]
            .map(File.new)
            .where((f) => store.isNotEmpty && f.existsSync())
            .firstOrNull;
        if (ks != null) {
          await put('keystore_b64', base64Encode(await ks.readAsBytes()), 'keystore upload');
          await put('key_properties', text, 'key.properties');
        } else {
          out.add('⚠ keystore "$store" tidak ditemukan');
        }
      } else {
        out.add('⚠ android/key.properties tidak ada — AAB di server tidak bisa ditandatangani');
      }
      final gs = File(pr.googleServicesJsonPath.isNotEmpty ? pr.googleServicesJsonPath : p.join(pr.localPath, 'android', 'app', 'google-services.json'));
      if (await gs.exists()) await put('google_services_json', await gs.readAsString(), 'google-services.json');
      await put('github_token', await Storage.secret(Secrets.github), 'token GitHub (clone repo private)');
      for (final e in ['dev', 'staging', 'prod']) {
        final f = File(p.join(pr.localPath, 'env', '$e.json'));
        if (await f.exists()) await put('env_$e', await f.readAsString(), 'env/$e.json');
      }
    }
    c.syncedAt = DateTime.now().toIso8601String();
    await save();
    return out;
  }

  /// Notifikasi Telegram / Discord / Slack dari DeployHub desktop → server.
  Future<List<String>> syncNotify(AppSettings s) async {
    final out = <String>[];
    Future<void> put(String name, String v) async {
      if (v.isEmpty) return;
      await req('PUT', '/api/secrets/$name', body: {'value': v});
      out.add(name);
    }

    await put('telegram_token', await Storage.secret(Secrets.telegram));
    await put('telegram_chat', s.telegramChatId);
    final it = Integrations.instance;
    if (it.discordOn) await put('discord_webhook', await Storage.secret(Integrations.kDiscord));
    if (it.slackOn) await put('slack_webhook', await Storage.secret(Integrations.kSlack));
    return out;
  }

  /// Pasang webhook GitHub → build langsung saat push (butuh URL server yang bisa diakses GitHub).
  Future<String> installWebhook(Project pr, String githubToken) async {
    final i = await info();
    final pub = '${(i['settings'] as Map?)?['public_url'] ?? ''}'.trim();
    final base = pub.isNotEmpty ? pub : _base;
    if (base.contains('localhost') || base.contains('127.0.0.1') || RegExp(r'//(10|192\.168|172\.(1[6-9]|2\d|3[01]))\.').hasMatch(base)) {
      throw Exception('URL server ($base) tidak bisa diakses GitHub dari internet. Pakai server di VPS dengan domain HTTPS, '
          'atau biarkan polling (server mengecek commit baru tiap beberapa menit).');
    }
    final hook = '${base.replaceAll(RegExp(r'/+$'), '')}${i['webhook_path']}';
    if ('${i['webhook_secret'] ?? ''}'.isEmpty) throw Exception('Hanya admin server yang bisa memasang webhook');
    await GitHubService(githubToken).upsertWebhook(pr.githubOwner, pr.githubRepo, hook, '${i['webhook_secret']}');
    return hook;
  }
}
