import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'github_service.dart';
import 'infra.dart';
import 'integrations.dart';
import 'server_ops.dart';
import 'storage.dart';
import 'tool_env.dart';

/// Langkah "pertama kali" supaya aplikasi backend benar-benar bisa di-upload & jalan di VPS:
///  1. Siapkan project di server: deploy key GitHub + git clone (repo private aman tanpa token di server)
///  2. Docker untuk backend: Dockerfile + docker-compose.yml + .env.example (FastAPI + MySQL)
///  3. Domain & HTTPS: Caddy (sertifikat Let's Encrypt otomatis & diperpanjang sendiri)
///  4. CD lewat GitHub Actions: workflow + GitHub Secrets diisi otomatis (gh CLI)
///  5. Secret signing Android di GitHub (keystore → ANDROID_KEYSTORE_BASE64)

/// (owner, repo) dari URL GitHub https / ssh. null = bukan GitHub.
(String, String)? parseGithub(String url) {
  final m = RegExp(r'github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$').firstMatch(url.trim());
  return m == null ? null : (m.group(1)!, m.group(2)!);
}

String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

// ───────────────────────── 1. project di server
Future<bool> setupProjectOnServer(ServerTarget s, String repoUrl, void Function(String) log) async {
  final ops = ServerOps.instance;
  if (s.workdir.isEmpty) throw Exception('Folder project di server belum diisi');
  var cloneUrl = repoUrl.trim();
  final gh = parseGithub(cloneUrl);
  if (gh != null) {
    // Deploy key: kunci SSH khusus server ini, hanya bisa BACA repo ini
    final lines = <String>[];
    final code = await ops.exec(
        s,
        'mkdir -p ~/.ssh && chmod 700 ~/.ssh; '
        '[ -f ~/.ssh/deployhub_repo ] || ssh-keygen -q -t ed25519 -N "" -C "deployhub-${s.name.replaceAll(RegExp(r'[^\w-]'), '')}" -f ~/.ssh/deployhub_repo; '
        'grep -q "deployhub_repo" ~/.ssh/config 2>/dev/null || printf "Host github.com\\n  IdentityFile ~/.ssh/deployhub_repo\\n  StrictHostKeyChecking accept-new\\n" >> ~/.ssh/config; '
        'chmod 600 ~/.ssh/config; cat ~/.ssh/deployhub_repo.pub',
        lines.add,
        inWorkdir: false);
    final pub = lines.lastWhere((l) => l.startsWith('ssh-ed25519 '), orElse: () => '');
    if (code != 0 || pub.isEmpty) throw Exception('Gagal membuat deploy key di server');
    final token = await Storage.secret(Secrets.github);
    if (token.isEmpty) throw Exception('Hubungkan GitHub dulu (Pengaturan → GitHub) supaya deploy key bisa dipasang otomatis');
    await GitHubService(token).addDeployKey(gh.$1, gh.$2, 'DeployHub • ${s.name} (${s.host})', pub);
    log('🔑 Deploy key (read-only) dipasang di GitHub ${gh.$1}/${gh.$2}');
    cloneUrl = 'git@github.com:${gh.$1}/${gh.$2}.git';
  }
  final wd = _q(s.workdir);
  final code = await ops.exec(
      s,
      'set -e; '
      'if [ -d $wd/.git ]; then echo "ℹ project sudah ada — git pull"; cd $wd && git pull --ff-only origin ${_q(s.branch)}; '
      'else '
      '  parent=\$(dirname $wd); mkdir -p "\$parent" 2>/dev/null || sudo -n mkdir -p "\$parent"; '
      '  [ -w "\$parent" ] || sudo -n chown "\$(id -un)" "\$parent"; '
      '  git clone -b ${_q(s.branch)} ${_q(cloneUrl)} $wd; cd $wd; '
      'fi; '
      'if [ -f .env.example ] && [ ! -f .env ]; then cp .env.example .env; chmod 600 .env; echo "⚠ .env dibuat dari .env.example — ISI password/secret-nya di server: nano ${s.workdir}/.env"; fi; '
      'git log --oneline -1; ls',
      log,
      inWorkdir: false);
  return code == 0;
}

// ───────────────────────── 2. Docker untuk backend
/// Tulis Dockerfile + docker-compose.yml + .dockerignore + .env.example (FastAPI + MySQL) di folder backend.
/// File yang sudah ada TIDAK ditimpa. Mengembalikan daftar file yang dibuat.
Future<List<String>> writeBackendDocker(String root, {int port = 8000}) async {
  // cari "app = FastAPI(" → modul uvicorn (mis. app.main:app)
  var module = 'main:app';
  var hasReq = await File(p.join(root, 'requirements.txt')).exists();
  await for (final e in Directory(root).list(recursive: true)) {
    if (e is! File || !e.path.endsWith('.py') || e.path.contains('${p.separator}.') || e.path.contains('venv')) continue;
    final txt = await e.readAsString().catchError((_) => '');
    final m = RegExp(r'^(\w+)\s*=\s*FastAPI\(', multiLine: true).firstMatch(txt);
    if (m != null) {
      final rel = p.relative(e.path, from: root).replaceAll('\\', '/').replaceAll(RegExp(r'\.py$'), '').replaceAll('/', '.');
      module = '$rel:${m.group(1)}';
      break;
    }
  }
  final files = <String, String>{
    'Dockerfile': '''# Dibuat oleh DeployHub — image backend FastAPI
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
${hasReq ? 'COPY requirements.txt .\nRUN pip install --no-cache-dir -r requirements.txt' : 'RUN pip install --no-cache-dir fastapi "uvicorn[standard]" sqlalchemy pymysql'}
COPY . .
RUN useradd -m app && chown -R app /app
USER app
EXPOSE $port
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:$port/health', timeout=4).status < 500 else 1)"
CMD ["uvicorn", "$module", "--host", "0.0.0.0", "--port", "$port", "--proxy-headers"]
''',
    'docker-compose.yml': '''# Dibuat oleh DeployHub — backend + MySQL
# Port API hanya dibuka di 127.0.0.1 → diakses lewat Caddy (HTTPS). Port Docker yang dibuka
# ke publik MELEWATI firewall ufw, jadi jangan buka port database ke internet.
services:
  api:
    build: .
    restart: unless-stopped
    env_file:
      - path: .env
        required: false
    ports: ["127.0.0.1:$port:$port"]
    depends_on:
      mysql:
        condition: service_healthy
  mysql:
    image: mysql:8.4
    container_name: mysql
    restart: unless-stopped
    env_file:
      - path: .env
        required: false
    volumes: [mysql_data:/var/lib/mysql]
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\$\$MYSQL_ROOT_PASSWORD --silent"]
      interval: 10s
      retries: 10
volumes:
  mysql_data: {}
''',
    '.dockerignore': '.git\n.venv\nvenv\n__pycache__\n*.pyc\n.env\nbackups\n',
    '.env.example': '''# Salin ke .env di server lalu isi. JANGAN commit file .env
MYSQL_ROOT_PASSWORD=ganti-password-root
MYSQL_DATABASE=app
MYSQL_USER=app
MYSQL_PASSWORD=ganti-password-app
DATABASE_URL=mysql+pymysql://app:ganti-password-app@mysql:3306/app
''',
  };
  final made = <String>[];
  for (final e in files.entries) {
    final f = File(p.join(root, e.key));
    if (await f.exists()) continue;
    await f.writeAsString(e.value);
    made.add(e.key);
  }
  // .env tidak boleh masuk git
  final gi = File(p.join(root, '.gitignore'));
  final g = await gi.exists() ? await gi.readAsString() : '';
  if (!RegExp(r'^\.env$', multiLine: true).hasMatch(g)) {
    await gi.writeAsString('${g.trimRight()}\n.env\n'.trimLeft());
    made.add('.gitignore (+ .env)');
  }
  return made;
}

/// Isi Caddyfile (reverse proxy + HTTPS otomatis).
String caddyfile(String domain, int port, String email) => '''{
\temail $email
}

$domain {
\tencode zstd gzip
\treverse_proxy 127.0.0.1:$port
\theader {
\t\tStrict-Transport-Security "max-age=31536000"
\t\tX-Content-Type-Options nosniff
\t\t-Server
\t}
}
''';

// ───────────────────────── 3. Domain & HTTPS
Future<bool> installHttps(ServerTarget s, String domain, int port, String email, void Function(String) log) async {
  final d = domain.trim().toLowerCase();
  if (!RegExp(r'^[a-z0-9.-]+\.[a-z]{2,}$').hasMatch(d)) throw Exception('Domain tidak valid: $domain');
  log('ℹ Pastikan DNS: record A $d → ${s.host} sudah dibuat (di panel domain / Cloudflare).');
  final compose = '''services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
volumes:
  caddy_data: {}
  caddy_config: {}''';
  final script = [
    'set -e',
    'mkdir -p ~/caddy',
    "cat > ~/caddy/Caddyfile <<'DHEOF'\n${caddyfile(d, port, email)}DHEOF",
    "cat > ~/caddy/docker-compose.yml <<'DHEOF'\n$compose\nDHEOF",
    'cd ~/caddy && docker compose pull -q && docker compose up -d',
    'docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile',
    'docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile',
  ].join('\n');
  final code = await ServerOps.instance.exec(s, script, log, inWorkdir: false);
  if (code == 0) {
    s.healthUrl = s.healthUrl.isEmpty ? 'https://$d/health' : s.healthUrl;
    await ServerOps.instance.save();
    log('🔒 https://$d → 127.0.0.1:$port (sertifikat dibuat otomatis dalam ±1 menit)');
  }
  return code == 0;
}

// ───────────────────────── 4/5. GitHub Secrets (gh CLI)
Future<String> _repoOf(String localRepo) async {
  final r = await Process.run('git', ['remote', 'get-url', 'origin'], workingDirectory: localRepo, runInShell: true, environment: ToolEnv.env());
  final gh = parseGithub('${r.stdout}');
  if (gh == null) throw Exception('Remote origin di $localRepo bukan repo GitHub');
  return '${gh.$1}/${gh.$2}';
}

/// Simpan secret ke repo GitHub. Nilai dikirim lewat stdin (tidak terlihat di daftar proses).
Future<void> setGithubSecrets(String localRepo, Map<String, String> secrets, void Function(String) log) async {
  if (!await ensureTool('gh', log)) throw Exception('GitHub CLI belum siap');
  final repo = await _repoOf(localRepo);
  final token = await Storage.secret(Secrets.github);
  if (token.isEmpty) throw Exception('Hubungkan GitHub dulu (Pengaturan → GitHub)');
  for (final e in secrets.entries) {
    final proc = await Process.start('gh', ['secret', 'set', e.key, '--repo', repo],
        runInShell: true, environment: {...ToolEnv.env(), 'GH_TOKEN': token});
    proc.stdin.write(e.value);
    await proc.stdin.close();
    final err = await proc.stderr.transform(utf8.decoder).join();
    final code = await proc.exitCode;
    if (code != 0) throw Exception('gh secret set ${e.key}: ${err.trim()}');
    log('🔐 secret ${e.key} → $repo');
  }
}

/// Workflow CD ke VPS + secret SSH-nya. Key SSH KHUSUS GitHub Actions dibuat & dipasang di server
/// (bisa dicabut kapan saja tanpa mengganggu akses DeployHub).
Future<String> installServerCd(ServerTarget s, String localRepo, void Function(String) log) async {
  final keyFile = p.join(Storage.dir.path, 'infra', 'gha_${s.id}');
  if (!await File(keyFile).exists()) {
    await Directory(p.dirname(keyFile)).create(recursive: true);
    final r = await Process.run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-C', 'github-actions-${s.name}', '-f', keyFile], environment: ToolEnv.env());
    if (r.exitCode != 0) throw Exception('ssh-keygen: ${r.stderr}');
  }
  final pub = (await File('$keyFile.pub').readAsString()).trim();
  await ServerOps.instance.exec(
      s,
      'mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && '
      'grep -qF ${_q(pub)} ~/.ssh/authorized_keys || echo ${_q(pub)} >> ~/.ssh/authorized_keys',
      log,
      inWorkdir: false);
  log('🔑 Key SSH khusus GitHub Actions dipasang di server');
  final wf = File(p.join(localRepo, '.github', 'workflows', 'deploy-server.yml'));
  await wf.parent.create(recursive: true);
  if (await wf.exists()) await wf.copy('${wf.path}.deployhub.bak');
  await wf.writeAsString(githubDeployServer(s.deployCmd.replaceAll('{branch}', s.branch)));
  log('📝 ${p.relative(wf.path, from: localRepo)}');
  await setGithubSecrets(localRepo, {
    'SSH_HOST': s.host,
    'SSH_PORT': '${s.port}',
    'SSH_USER': s.user,
    'SSH_KEY': await File(keyFile).readAsString(),
    'DEPLOY_DIR': s.workdir,
    'HEALTH_URL': s.healthUrl,
  }, log);
  return wf.path;
}

/// Keystore + key.properties → GitHub Secrets (ANDROID_KEYSTORE_BASE64, ANDROID_KEY_PROPERTIES)
/// supaya workflow CI bisa membuat AAB release bertanda tangan. File-nya sendiri tetap TIDAK masuk git.
Future<void> installAndroidSigningSecrets(String projectRoot, void Function(String) log) async {
  final kp = File(p.join(projectRoot, 'android', 'key.properties'));
  if (!await kp.exists()) throw Exception('android/key.properties tidak ada — jalankan "Periksa & perbaiki file project" dulu');
  final props = <String, String>{};
  for (final l in await kp.readAsLines()) {
    final i = l.indexOf('=');
    if (i > 0 && !l.trimLeft().startsWith('#')) props[l.substring(0, i).trim()] = l.substring(i + 1).trim();
  }
  final store = props['storeFile'] ?? '';
  // storeFile relatif terhadap android/app (cara Gradle membaca file())
  final candidates = [store, p.join(projectRoot, 'android', 'app', store), p.join(projectRoot, 'android', store)];
  final ks = candidates.map(File.new).firstWhere((f) => store.isNotEmpty && f.existsSync(), orElse: () => File(''));
  if (ks.path.isEmpty) throw Exception('Keystore "$store" tidak ditemukan');
  props['storeFile'] = 'upload-keystore.jks'; // lokasi tujuan di runner CI (android/app/)
  await setGithubSecrets(projectRoot, {
    'ANDROID_KEYSTORE_BASE64': base64Encode(await ks.readAsBytes()),
    'ANDROID_KEY_PROPERTIES': props.entries.map((e) => '${e.key}=${e.value}').join('\n'),
  }, log);
}

/// Dipakai panel: key SSH DeployHub default untuk server dari Terraform.
String defaultKey() => Infra.instance.keyPath;
