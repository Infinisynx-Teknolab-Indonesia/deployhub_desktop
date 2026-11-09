import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'storage.dart';
import 'tool_env.dart';

/// Integrasi DevOps opsional — diaktifkan satu per satu di Pengaturan → DevOps & integrasi.
/// Disimpan di integrations.json; token/password di Credential Manager (Storage.secret).
class Integrations {
  Integrations._();
  static final Integrations instance = Integrations._();

  // Notifikasi
  bool discordOn = false;
  bool slackOn = false;

  // CI server lain
  bool jenkinsOn = false;
  String jenkinsUrl = 'http://localhost:8080';
  String jenkinsUser = '';
  String jenkinsJob = '';

  bool gitlabOn = false;
  String gitlabUrl = 'https://gitlab.com';
  String gitlabProject = ''; // mis. prakash/aplikasichat

  bool bitbucketOn = false; // hanya file bitbucket-pipelines.yml

  // Container & artefak
  bool dockerOn = false;
  bool dockerBuild = false; // build Android di dalam container (environment selalu sama)
  bool artifactsOn = true; // arsip AAB + mapping + laporan di PC (artifact repository lokal)
  bool nexusOn = false; // upload artefak ke Nexus / Artifactory (raw repository)
  String nexusUrl = ''; // mis. https://nexus.domain.com/repository/mobile-raw
  String nexusUser = '';

  // Test
  bool securityScanOn = true;
  bool vulnScanOn = true; // scan kerentanan library (OSV)

  // Source trigger: jalankan pipeline otomatis saat ada commit baru di branch
  bool autoTriggerOn = false;
  int autoTriggerMinutes = 5;
  /// ready = build AAB + IPA siap deploy (deploy tetap manual 1 klik) • ci = cek + build saja • cd = build + upload ke Pengujian internal
  String autoTriggerMode = 'ready';
  List<String> autoTriggerProjects = [];

  static const kDiscord = 'int_discord_webhook';
  static const kSlack = 'int_slack_webhook';
  static const kJenkins = 'int_jenkins_token';
  static const kGitlab = 'int_gitlab_token';
  static const kNexus = 'int_nexus_password';

  Future<void> load() async {
    final j = await Storage.readJson('integrations.json');
    if (j is! Map) return;
    discordOn = j['discordOn'] == true;
    slackOn = j['slackOn'] == true;
    jenkinsOn = j['jenkinsOn'] == true;
    jenkinsUrl = j['jenkinsUrl'] ?? jenkinsUrl;
    jenkinsUser = j['jenkinsUser'] ?? '';
    jenkinsJob = j['jenkinsJob'] ?? '';
    gitlabOn = j['gitlabOn'] == true;
    gitlabUrl = j['gitlabUrl'] ?? gitlabUrl;
    gitlabProject = j['gitlabProject'] ?? '';
    bitbucketOn = j['bitbucketOn'] == true;
    dockerOn = j['dockerOn'] == true;
    dockerBuild = j['dockerBuild'] == true;
    artifactsOn = j['artifactsOn'] != false;
    nexusOn = j['nexusOn'] == true;
    nexusUrl = j['nexusUrl'] ?? '';
    nexusUser = j['nexusUser'] ?? '';
    securityScanOn = j['securityScanOn'] != false;
    vulnScanOn = j['vulnScanOn'] != false;
    autoTriggerOn = j['autoTriggerOn'] == true;
    autoTriggerMinutes = (j['autoTriggerMinutes'] as num?)?.toInt() ?? 5;
    autoTriggerMode = j['autoTriggerMode'] ?? 'ready';
    autoTriggerProjects = List<String>.from(j['autoTriggerProjects'] ?? const []);
  }

  Future<void> save() => Storage.writeJson('integrations.json', {
        'discordOn': discordOn,
        'slackOn': slackOn,
        'jenkinsOn': jenkinsOn,
        'jenkinsUrl': jenkinsUrl,
        'jenkinsUser': jenkinsUser,
        'jenkinsJob': jenkinsJob,
        'gitlabOn': gitlabOn,
        'gitlabUrl': gitlabUrl,
        'gitlabProject': gitlabProject,
        'bitbucketOn': bitbucketOn,
        'dockerOn': dockerOn,
        'dockerBuild': dockerBuild,
        'artifactsOn': artifactsOn,
        'nexusOn': nexusOn,
        'nexusUrl': nexusUrl,
        'nexusUser': nexusUser,
        'securityScanOn': securityScanOn,
        'vulnScanOn': vulnScanOn,
        'autoTriggerOn': autoTriggerOn,
        'autoTriggerMinutes': autoTriggerMinutes,
        'autoTriggerMode': autoTriggerMode,
        'autoTriggerProjects': autoTriggerProjects,
      });

  // ───────────────────────── Notifikasi
  /// Kirim ke semua kanal yang aktif (Discord, Slack). Telegram diurus terpisah.
  Future<void> notify(String text) async {
    if (discordOn) {
      final url = await Storage.secret(kDiscord);
      if (url.isNotEmpty) await sendDiscord(url, text).catchError((_) {});
    }
    if (slackOn) {
      final url = await Storage.secret(kSlack);
      if (url.isNotEmpty) await sendSlack(url, text).catchError((_) {});
    }
  }

  static Future<void> sendDiscord(String webhook, String text) async {
    final r = await http.post(Uri.parse(webhook),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'content': text.length > 1900 ? '${text.substring(0, 1900)}…' : text, 'username': 'DeployHub'}));
    if (r.statusCode >= 300) throw Exception('Discord HTTP ${r.statusCode}: ${r.body}');
  }

  static Future<void> sendSlack(String webhook, String text) async {
    final r = await http.post(Uri.parse(webhook), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'text': text}));
    if (r.statusCode >= 300) throw Exception('Slack HTTP ${r.statusCode}: ${r.body}');
  }

  // ───────────────────────── Jenkins
  Future<Map<String, String>> _jenkinsHeaders() async {
    final token = await Storage.secret(kJenkins);
    return {
      if (jenkinsUser.isNotEmpty) 'Authorization': 'Basic ${base64Encode(utf8.encode('$jenkinsUser:$token'))}',
    };
  }

  String get _jUrl => jenkinsUrl.replaceAll(RegExp(r'/+$'), '');
  String _jobPath(String job) => job.split('/').map((x) => 'job/${Uri.encodeComponent(x)}').join('/');

  /// Tes koneksi → versi Jenkins + jumlah job.
  Future<String> jenkinsTest() async {
    final r = await http.get(Uri.parse('$_jUrl/api/json?tree=jobs[name]'), headers: await _jenkinsHeaders());
    if (r.statusCode >= 300) throw Exception('Jenkins HTTP ${r.statusCode}');
    final jobs = (jsonDecode(r.body)['jobs'] as List? ?? const []).map((e) => '${e['name']}').toList();
    return 'Jenkins ${r.headers['x-jenkins'] ?? ''} • ${jobs.length} job${jobs.isEmpty ? '' : ': ${jobs.take(5).join(', ')}'}';
  }

  /// Picu build job (opsional parameter). Mengembalikan URL antrian.
  Future<String> jenkinsBuild({String job = '', Map<String, String> params = const {}}) async {
    final j = job.isEmpty ? jenkinsJob : job;
    if (j.isEmpty) throw Exception('Nama job Jenkins belum diisi');
    final path = params.isEmpty ? 'build' : 'buildWithParameters';
    final uri = Uri.parse('$_jUrl/${_jobPath(j)}/$path').replace(queryParameters: params.isEmpty ? null : params);
    final r = await http.post(uri, headers: await _jenkinsHeaders());
    if (r.statusCode >= 300) throw Exception('Jenkins HTTP ${r.statusCode}: ${r.body.length > 200 ? r.body.substring(0, 200) : r.body}');
    return r.headers['location'] ?? '$_jUrl/${_jobPath(j)}';
  }

  /// Status build terakhir: (nomor, hasil, url).
  Future<(int, String, String)?> jenkinsLast({String job = ''}) async {
    final j = job.isEmpty ? jenkinsJob : job;
    if (j.isEmpty) return null;
    final r = await http.get(Uri.parse('$_jUrl/${_jobPath(j)}/lastBuild/api/json?tree=number,result,building,url'),
        headers: await _jenkinsHeaders());
    if (r.statusCode >= 300) return null;
    final m = jsonDecode(r.body);
    return ((m['number'] as num).toInt(), m['building'] == true ? 'RUNNING' : '${m['result'] ?? '-'}', '${m['url']}');
  }

  // ───────────────────────── GitLab
  String get _gUrl => gitlabUrl.replaceAll(RegExp(r'/+$'), '');
  Future<Map<String, String>> _gitlabHeaders() async => {'PRIVATE-TOKEN': await Storage.secret(kGitlab)};

  Future<String> gitlabTest() async {
    final r = await http.get(Uri.parse('$_gUrl/api/v4/user'), headers: await _gitlabHeaders());
    if (r.statusCode >= 300) throw Exception('GitLab HTTP ${r.statusCode}');
    return 'GitLab: @${jsonDecode(r.body)['username']}';
  }

  Future<String> gitlabRunPipeline(String ref) async {
    if (gitlabProject.isEmpty) throw Exception('Project GitLab belum diisi');
    final id = Uri.encodeComponent(gitlabProject);
    final r = await http.post(Uri.parse('$_gUrl/api/v4/projects/$id/pipeline?ref=${Uri.encodeQueryComponent(ref)}'),
        headers: await _gitlabHeaders());
    if (r.statusCode >= 300) throw Exception('GitLab HTTP ${r.statusCode}: ${r.body}');
    return '${jsonDecode(r.body)['web_url']}';
  }

  /// Pipeline terbaru: (id, status, ref, url).
  Future<List<(int, String, String, String)>> gitlabPipelines() async {
    if (gitlabProject.isEmpty) return [];
    final id = Uri.encodeComponent(gitlabProject);
    final r = await http.get(Uri.parse('$_gUrl/api/v4/projects/$id/pipelines?per_page=10'), headers: await _gitlabHeaders());
    if (r.statusCode >= 300) return [];
    return [
      for (final m in jsonDecode(r.body) as List)
        ((m['id'] as num).toInt(), '${m['status']}', '${m['ref']}', '${m['web_url']}'),
    ];
  }

  // ───────────────────────── Nexus / Artifactory (raw repository)
  Future<String> nexusUpload(File f, String path) async {
    final pass = await Storage.secret(kNexus);
    final url = '${nexusUrl.replaceAll(RegExp(r'/+$'), '')}/$path';
    final r = await http.put(Uri.parse(url),
        headers: {
          if (nexusUser.isNotEmpty) 'Authorization': 'Basic ${base64Encode(utf8.encode('$nexusUser:$pass'))}',
          'Content-Type': 'application/octet-stream',
        },
        body: await f.readAsBytes());
    if (r.statusCode >= 300) throw Exception('Nexus HTTP ${r.statusCode}');
    return url;
  }
}

// ───────────────────────── Alat di PC: cek & pasang otomatis
class ToolStatus {
  ToolStatus(this.installed, this.version);
  final bool installed;
  final String version;
}

Future<ToolStatus> toolVersion(String exe, List<String> args) async {
  try {
    final r = await Process.run(exe, args, runInShell: true, environment: ToolEnv.env()).timeout(const Duration(seconds: 15));
    final out = '${r.stdout}${r.stderr}'.trim().split('\n').first;
    return ToolStatus(r.exitCode == 0, out);
  } catch (_) {
    return ToolStatus(false, '');
  }
}

/// Perintah pasang otomatis per alat (Windows: winget • macOS: Homebrew).
List<String>? installCommand(String tool) {
  if (Platform.isWindows) {
    return switch (tool) {
      'docker' => ['winget', 'install', '-e', '--id', 'Docker.DockerDesktop', '--accept-package-agreements', '--accept-source-agreements'],
      'git' => ['winget', 'install', '-e', '--id', 'Git.Git', '--accept-package-agreements', '--accept-source-agreements'],
      'gh' => ['winget', 'install', '-e', '--id', 'GitHub.cli', '--accept-package-agreements', '--accept-source-agreements'],
      'glab' => ['winget', 'install', '-e', '--id', 'GLab.GLab', '--accept-package-agreements', '--accept-source-agreements'],
      'java' => ['winget', 'install', '-e', '--id', 'EclipseAdoptium.Temurin.17.JDK', '--accept-package-agreements', '--accept-source-agreements'],
      'terraform' => ['winget', 'install', '-e', '--id', 'Hashicorp.Terraform', '--accept-package-agreements', '--accept-source-agreements'],
      _ => null,
    };
  }
  if (Platform.isMacOS) {
    return switch (tool) {
      'docker' => ['brew', 'install', '--cask', 'docker'],
      'git' => ['brew', 'install', 'git'],
      'gh' => ['brew', 'install', 'gh'],
      'glab' => ['brew', 'install', 'glab'],
      'java' => ['brew', 'install', 'openjdk@17'],
      'terraform' => ['bash', '-lc', 'brew tap hashicorp/tap && brew install hashicorp/tap/terraform'],
      _ => null,
    };
  }
  return null;
}


// ───────────────────────── Pasang otomatis saat dibutuhkan
const _probeArgs = <String, (String, List<String>)>{
  'docker': ('docker', ['--version']),
  'git': ('git', ['--version']),
  'gh': ('gh', ['--version']),
  'glab': ('glab', ['--version']),
  'java': ('java', ['-version']),
  'terraform': ('terraform', ['version']),
};

const toolLabels = <String, String>{
  'docker': 'Docker Desktop',
  'git': 'Git',
  'gh': 'GitHub CLI',
  'glab': 'GitLab CLI',
  'java': 'Java JDK 17',
  'terraform': 'Terraform',
};

Future<ToolStatus> checkTool(String tool) {
  final pr = _probeArgs[tool]!;
  return toolVersion(pr.$1, pr.$2);
}

final _installing = <String, Future<bool>>{};

/// Pastikan alat ada di PC. Belum ada → dipasang otomatis (winget / Homebrew), PATH dibaca
/// ulang, lalu dicek lagi. Docker juga dinyalakan dan ditunggu sampai siap.
/// Dipanggil otomatis oleh setiap fitur yang butuh alat tersebut.
Future<bool> ensureTool(String tool, void Function(String) log) {
  // dua tombol menekan bersamaan → tetap satu proses pemasangan
  return _installing[tool] ??= _ensureTool(tool, log).whenComplete(() => _installing.remove(tool));
}

Future<bool> _ensureTool(String tool, void Function(String) log) async {
  final label = toolLabels[tool] ?? tool;
  var st = await checkTool(tool);
  if (!st.installed) {
    final cmd = installCommand(tool);
    if (cmd == null) {
      log('✖ $label belum terpasang dan tidak bisa dipasang otomatis di sistem ini.');
      return false;
    }
    log('📦 $label belum terpasang — memasang otomatis…');
    if (Platform.isWindows) log('   (Windows mungkin menampilkan jendela izin administrator — klik "Yes")');
    if (tool == 'docker' && Platform.isWindows) {
      // Docker Desktop butuh WSL2 — pasang dulu (diabaikan kalau sudah ada)
      log('\$ wsl --install --no-distribution');
      final w = await Process.run('wsl', ['--install', '--no-distribution'], runInShell: true);
      final wo = '${w.stdout}${w.stderr}'.replaceAll('\x00', '').trim();
      if (wo.isNotEmpty) log('   ${wo.split('\n').last.trim()}');
      if (RegExp(r'restart|reboot|mulai ulang', caseSensitive: false).hasMatch(wo)) {
        log('⚠ WSL baru dipasang — restart PC setelah Docker selesai dipasang.');
      }
    }
    log('\$ ${cmd.join(' ')}');
    final proc = await Process.start(cmd.first, cmd.sublist(1), runInShell: true, environment: ToolEnv.env());
    const dec = Utf8Decoder(allowMalformed: true);
    void show(String l) {
      final t = l.trim();
      // buang animasi progress bar winget (█▒ / - \ |)
      if (t.isEmpty || RegExp(r'^[\-\\|/█▒\s\d.%KMGB/]+$').hasMatch(t)) return;
      log('   $t');
    }

    final a = proc.stdout.transform(dec).transform(const LineSplitter()).forEach(show);
    final b = proc.stderr.transform(dec).transform(const LineSplitter()).forEach(show);
    final code = await proc.exitCode;
    await Future.wait([a, b]);
    await ToolEnv.init(); // PATH baru (tanpa menutup DeployHub)
    st = await checkTool(tool);
    if (!st.installed) {
      // winget kode -1978335189 = sudah terpasang / tidak ada update; tetap gagal kalau exe tidak terbaca
      log(code == 0
          ? '⚠ $label sudah dipasang tapi belum terbaca. Tutup & buka lagi DeployHub (atau restart PC kalau diminta installer).'
          : '✖ Gagal memasang $label (kode $code).');
      return false;
    }
    log('✔ $label terpasang: ${st.version}');
  }
  if (tool == 'docker') return ensureDockerRunning(log);
  return true;
}

/// Docker sudah terpasang tapi engine-nya mati → nyalakan Docker Desktop dan tunggu siap (maks. ±4 menit).
Future<bool> ensureDockerRunning(void Function(String) log) async {
  Future<bool> up() async {
    try {
      final r = await Process.run('docker', ['info', '--format', '{{.ServerVersion}}'], runInShell: true, environment: ToolEnv.env())
          .timeout(const Duration(seconds: 20));
      return r.exitCode == 0 && '${r.stdout}'.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  if (await up()) return true;
  log('🐳 Docker belum berjalan — menyalakan Docker Desktop…');
  try {
    if (Platform.isWindows) {
      final e = Platform.environment;
      final cands = [
        for (final pf in {e['ProgramFiles'], e['ProgramW6432'], r'C:\Program Files'}.whereType<String>()) '$pf\\Docker\\Docker\\Docker Desktop.exe',
      ];
      final exe = cands.firstWhere((f) => File(f).existsSync(), orElse: () => '');
      if (exe.isEmpty) {
        log('✖ Docker Desktop.exe tidak ditemukan');
        return false;
      }
      await Process.start(exe, [], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-a', 'Docker']);
    } else {
      await Process.run('systemctl', ['--user', 'start', 'docker-desktop']);
    }
  } catch (e) {
    log('✖ Tidak bisa menyalakan Docker: $e');
    return false;
  }
  for (var i = 0; i < 48; i++) {
    await Future.delayed(const Duration(seconds: 5));
    if (await up()) {
      log('✔ Docker siap');
      return true;
    }
    if (i % 6 == 5) log('   …menunggu Docker Desktop (${(i + 1) * 5} detik). Kalau muncul jendela persetujuan / WSL, selesaikan dulu.');
  }
  log('✖ Docker belum siap setelah 4 menit. Buka Docker Desktop, terima syaratnya. Kalau diminta "WSL update" / restart PC, lakukan lalu coba lagi.');
  return false;
}

/// Jenkins lokal dalam Docker (port 8080). Mengembalikan password admin awal.
Future<String> installJenkinsDocker(void Function(String) log) async {
  if (!await ensureTool('docker', log)) throw Exception('Docker belum siap');
  Future<ProcessResult> d(List<String> a) => Process.run('docker', a, runInShell: true, environment: ToolEnv.env());
  final exists = await d(['ps', '-a', '--filter', 'name=^/jenkins\$', '--format', '{{.Names}}']);
  if ('${exists.stdout}'.trim() == 'jenkins') {
    log('ℹ Container jenkins sudah ada — dinyalakan');
    await d(['start', 'jenkins']);
  } else {
    log('\$ docker run -d --name jenkins -p 8080:8080 -p 50000:50000 -v jenkins_home:/var/jenkins_home jenkins/jenkins:lts-jdk17');
    final r = await d(['run', '-d', '--name', 'jenkins', '--restart', 'unless-stopped', '-p', '8080:8080', '-p', '50000:50000',
      '-v', 'jenkins_home:/var/jenkins_home', 'jenkins/jenkins:lts-jdk17']);
    if (r.exitCode != 0) throw Exception('${r.stderr}${r.stdout}');
  }
  for (var i = 0; i < 40; i++) {
    final r = await d(['exec', 'jenkins', 'cat', '/var/jenkins_home/secrets/initialAdminPassword']);
    final pw = '${r.stdout}'.trim();
    if (r.exitCode == 0 && pw.isNotEmpty) return pw;
    await Future.delayed(const Duration(seconds: 3));
  }
  return '';
}

// ───────────────────────── File CI untuk repo (trigger otomatis di server saat push / Pull Request)
/// Skrip bersama: jalankan test MILIK aplikasi (test bawaan template Flutter "Counter increments" dilewati,
/// karena hampir selalu sudah tidak cocok dengan aplikasinya).
const _ciTest = r'''if [ -d test ]; then
  files=$(grep -rL "Counter increments smoke test" test --include='*_test.dart' || true)
  # shellcheck disable=SC2086 # sengaja tanpa kutip: daftar beberapa file test
  if [ -n "$files" ]; then flutter test $files; else echo "Tidak ada test milik aplikasi — dilewati"; fi
else echo "Folder test/ tidak ada — dilewati"; fi''';

/// Skrip bersama: keystore dari secret CI (ANDROID_KEYSTORE_BASE64 + ANDROID_KEY_PROPERTIES).
/// Ada → AAB release bertanda tangan. Tidak ada → cukup cek kode bisa di-build (APK debug).
const _ciBuild = r'''if [ -n "$ANDROID_KEYSTORE_BASE64" ] && [ -n "$ANDROID_KEY_PROPERTIES" ]; then
  echo "$ANDROID_KEYSTORE_BASE64" | base64 -d > android/app/upload-keystore.jks
  printf '%s\n' "$ANDROID_KEY_PROPERTIES" > android/key.properties
  flutter build appbundle --release
else
  echo "Secret keystore belum diisi → hanya cek build (APK debug). Isi lewat DeployHub: Pengaturan → File CI → Pasang secret signing."
  flutter build apk --debug
fi''';

String _indent(String s, int n) => s.split('\n').map((l) => '${' ' * n}$l').join('\n');

String githubWorkflow(String flutterVersion) => '''
# Dibuat oleh DeployHub — jalan otomatis setiap push & Pull Request
name: Flutter CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - run: flutter pub get
      - name: Analyze (lint / static analysis)
        run: flutter analyze lib --no-fatal-infos --no-fatal-warnings
      - name: Unit test
        run: |
${_indent(_ciTest, 10)}
      - name: Build
        env:
          ANDROID_KEYSTORE_BASE64: \${{ secrets.ANDROID_KEYSTORE_BASE64 }}
          ANDROID_KEY_PROPERTIES: \${{ secrets.ANDROID_KEY_PROPERTIES }}
        run: |
${_indent(_ciBuild, 10)}
      - uses: actions/upload-artifact@v4
        with:
          name: app-build
          path: |
            build/app/outputs/bundle/release/*.aab
            build/app/outputs/flutter-apk/*.apk
          if-no-files-found: warn
''';

String gitlabCi() => '''
# Dibuat oleh DeployHub — jalan otomatis setiap push & Merge Request
# Secret signing (opsional): Settings → CI/CD → Variables → ANDROID_KEYSTORE_BASE64, ANDROID_KEY_PROPERTIES
image: ghcr.io/cirruslabs/flutter:stable

stages: [test, build]

cache:
  paths: [.pub-cache/]

variables:
  PUB_CACHE: "\$CI_PROJECT_DIR/.pub-cache"

analyze_test:
  stage: test
  script:
    - flutter pub get
    - flutter analyze lib --no-fatal-infos --no-fatal-warnings
    - |
${_indent(_ciTest, 6)}

build:
  stage: build
  script:
    - flutter pub get
    - |
${_indent(_ciBuild, 6)}
  artifacts:
    paths: [build/app/outputs/bundle/release/, build/app/outputs/flutter-apk/]
    expire_in: 7 days
''';

String jenkinsfile() => '''
// Dibuat oleh DeployHub — Jenkins Pipeline (Multibranch: jalan saat push / Pull Request)
// Secret signing (opsional): Manage Jenkins → Credentials → "Secret text" dengan ID
// android-keystore-base64 dan android-key-properties.
pipeline {
  agent {
    docker { image 'ghcr.io/cirruslabs/flutter:stable' }
  }
  options { timestamps() }
  stages {
    stage('Source')  { steps { checkout scm } }
    stage('Build deps') { steps { sh 'flutter pub get' } }
    stage('Test') {
      parallel {
        stage('Analyze') { steps { sh 'flutter analyze lib --no-fatal-infos --no-fatal-warnings' } }
        stage('Unit test') {
          steps {
            sh \'\'\'
${_indent(_ciTest, 12)}
            \'\'\'
          }
        }
      }
    }
    stage('Build') {
      steps {
        script {
          def creds = []
          try {
            withCredentials([string(credentialsId: 'android-keystore-base64', variable: 'ANDROID_KEYSTORE_BASE64'),
                             string(credentialsId: 'android-key-properties', variable: 'ANDROID_KEY_PROPERTIES')]) {
              sh \'\'\'
${_indent(_ciBuild, 14)}
              \'\'\'
            }
          } catch (org.jenkinsci.plugins.credentialsbinding.impl.CredentialNotFoundException e) {
            sh 'flutter build apk --debug'
          }
        }
      }
    }
    stage('Release') {
      steps { archiveArtifacts artifacts: 'build/app/outputs/**/*.aab, build/app/outputs/**/*.apk', allowEmptyArchive: true, fingerprint: true }
    }
  }
}
''';

String bitbucketPipelines() => '''
# Dibuat oleh DeployHub — Bitbucket Pipelines (push & Pull Request)
# Secret signing (opsional): Repository settings → Repository variables → ANDROID_KEYSTORE_BASE64, ANDROID_KEY_PROPERTIES
image: ghcr.io/cirruslabs/flutter:stable

definitions:
  steps:
    - step: &check
        name: Analyze, test, build
        script:
          - flutter pub get
          - flutter analyze lib --no-fatal-infos --no-fatal-warnings
          - |
${_indent(_ciTest, 12)}
          - |
${_indent(_ciBuild, 12)}
        artifacts:
          - build/app/outputs/**

pipelines:
  default:
    - step: *check
  pull-requests:
    '**':
      - step: *check
''';

String dockerfileAndroid() => r'''
# Dibuat oleh DeployHub — environment build Android yang selalu sama (Flutter + Android SDK + JDK 17)
FROM ghcr.io/cirruslabs/flutter:stable
WORKDIR /app
# Kode di-mount saat docker run (-v <folder project>:/app), jadi image ini bisa dipakai semua project.
CMD ["bash", "-lc", "flutter pub get && flutter build appbundle --release"]
''';

/// CD backend ke VPS lewat GitHub Actions: setiap push ke main → SSH ke server → git pull →
/// docker compose build → health check → rollback otomatis kalau gagal.
/// Secret: SSH_HOST, SSH_PORT, SSH_USER, SSH_KEY, DEPLOY_DIR, HEALTH_URL (diisi DeployHub lewat gh).
String githubDeployServer(String deployCmd) => '''
# Dibuat oleh DeployHub — Continuous Deployment ke VPS (setiap push ke main)
name: Deploy ke server
on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: deploy-server
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Siapkan SSH
        env:
          SSH_KEY: \${{ secrets.SSH_KEY }}
          SSH_HOST: \${{ secrets.SSH_HOST }}
          SSH_PORT: \${{ secrets.SSH_PORT }}
        run: |
          mkdir -p ~/.ssh
          printf '%s\\n' "\$SSH_KEY" > ~/.ssh/id_deploy
          chmod 600 ~/.ssh/id_deploy
          ssh-keyscan -p "\${SSH_PORT:-22}" "\$SSH_HOST" >> ~/.ssh/known_hosts
      - name: Deploy + health check + rollback otomatis
        env:
          SSH_HOST: \${{ secrets.SSH_HOST }}
          SSH_PORT: \${{ secrets.SSH_PORT }}
          SSH_USER: \${{ secrets.SSH_USER }}
          DEPLOY_DIR: \${{ secrets.DEPLOY_DIR }}
          HEALTH_URL: \${{ secrets.HEALTH_URL }}
        run: |
          ssh -i ~/.ssh/id_deploy -p "\${SSH_PORT:-22}" "\$SSH_USER@\$SSH_HOST" \\
            "DEPLOY_DIR='\$DEPLOY_DIR' HEALTH_URL='\$HEALTH_URL' COMMIT='\$GITHUB_SHA' bash -s" <<'EOF'
${_indent(deployServerScript(deployCmd), 10)}
          EOF
''';

/// Skrip yang dijalankan DI SERVER oleh workflow di atas (juga dites langsung lewat SSH).
String deployServerScript(String deployCmd) {
  final cmd = deployCmd.replaceAll(RegExp(r'git pull[^&;]*(&&|;)\s*'), '');
  return '''set -e
cd "\$DEPLOY_DIR"
PREV=\$(git rev-parse HEAD)
echo "📌 versi sekarang: \$PREV"
healthy() {
  [ -z "\$HEALTH_URL" ] && return 0
  for i in 1 2 3 4 5 6 7; do
    sleep 8
    code=\$(curl -s -o /dev/null -w '%{http_code}' -m 10 "\$HEALTH_URL" || true)
    echo "health \$i/7: HTTP \${code:-000}"
    if [ "\${code:-0}" -ge 200 ] && [ "\${code:-0}" -lt 500 ]; then return 0; fi
  done
  return 1
}
rollback() {
  trap - ERR
  echo "❌ \$1 → rollback ke \$PREV"
  git reset --hard "\$PREV"
  if ( $cmd ) && healthy; then echo "⏪ versi lama berjalan lagi"; else echo "🔴 rollback juga gagal — cek server!"; fi
  exit 1
}
trap 'rollback "perintah gagal"' ERR
git fetch -q origin main
git reset --hard "\${COMMIT:-origin/main}"
echo "🚀 deploy \$(git log --oneline -1)"
# ( … ) supaya kegagalan di tengah "a && b" juga terdeteksi (set -e tidak menangkapnya)
if ! ( $cmd ); then rollback "build / deploy gagal"; fi
if healthy; then echo "✅ deploy sukses"; else rollback "health check gagal"; fi''';
}

/// Tulis file CI ke repo. [kind] = github | gitlab | jenkins | bitbucket | docker. Mengembalikan path.
Future<String> writeCiFile(String root, String kind) async {
  final (rel, content) = switch (kind) {
    'github' => ('.github/workflows/deployhub-ci.yml', githubWorkflow('stable')),
    'gitlab' => ('.gitlab-ci.yml', gitlabCi()),
    'jenkins' => ('Jenkinsfile', jenkinsfile()),
    'bitbucket' => ('bitbucket-pipelines.yml', bitbucketPipelines()),
    'server' => ('.github/workflows/deploy-server.yml', githubDeployServer('docker compose up -d --build && docker image prune -f')),
    _ => ('Dockerfile.deployhub', dockerfileAndroid()),
  };
  final f = File(p.join(root, rel));
  await f.parent.create(recursive: true);
  if (await f.exists()) await f.copy('${f.path}.deployhub.bak');
  await f.writeAsString(content);
  return f.path;
}
