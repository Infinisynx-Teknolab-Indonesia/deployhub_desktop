import 'dart:convert';
import 'dart:io';

import 'tool_env.dart';

/// Menjalankan Firebase CLI & FlutterFire CLI (alat resmi Google) dari DeployHub.
class FirebaseTool {
  FirebaseTool({required this.flutterCmd, required this.log});
  final String flutterCmd;
  final void Function(String) log;

  /// Jalankan perintah, kirim output ke [log]. Mengembalikan (exit code, stdout).
  Future<(int, String)> run(String exe, List<String> args, {String? cwd, bool quiet = false}) async {
    if (!quiet) log('\$ $exe ${args.join(' ')}');
    try {
      final p = await Process.start(exe, args, workingDirectory: cwd, runInShell: true, environment: env());
      final out = StringBuffer();
      const dec = Utf8Decoder(allowMalformed: true);
      final a = p.stdout.transform(dec).forEach((s) {
        out.write(s);
        if (!quiet) {
          for (final l in const LineSplitter().convert(s)) {
            if (l.trim().isNotEmpty) log(l);
          }
        }
      });
      final b = p.stderr.transform(dec).transform(const LineSplitter()).forEach((l) {
        if (!quiet && l.trim().isNotEmpty) log(l);
      });
      final code = await p.exitCode;
      await Future.wait([a, b]);
      return (code, out.toString());
    } catch (e) {
      if (!quiet) log('✖ $e');
      return (-1, '');
    }
  }

  static Map<String, String> env() => ToolEnv.env();
  static String? get nodeDir => ToolEnv.nodeDir;
  static Future<String?> detectNode() => ToolEnv.detectNode();
  static Future<bool> setNodeDir(String dir) => ToolEnv.setNodeDir(dir);

  /// winget (Windows Package Manager) tersedia di Windows 10/11 modern.
  Future<bool> hasWinget() async => Platform.isWindows && (await version('winget', ['--version'])) != null;

  /// Pasang Node.js LTS. Windows: winget (minta izin administrator).
  /// macOS: Homebrew (`brew install node`).
  Future<bool> installNode() async {
    final (code, _) = Platform.isMacOS
        ? await run('brew', ['install', 'node'])
        : await run('winget', [
            'install', '-e', '--id', 'OpenJS.NodeJS.LTS',
            '--accept-package-agreements', '--accept-source-agreements',
          ]);
    await ToolEnv.detectNode();
    return code == 0;
  }

  /// Homebrew tersedia? (macOS)
  Future<bool> hasBrew() async => Platform.isMacOS && (await version('brew', ['--version'])) != null;

  /// macOS tanpa Node.js: installer resmi Firebase (binary mandiri ke /usr/local/bin).
  /// Dibuka di Terminal karena butuh password administrator (sudo).
  Future<void> installFirebaseStandaloneMac() async {
    await Process.run('osascript', [
      '-e',
      'tell application "Terminal" to do script "curl -sL https://firebase.tools | bash"',
      '-e',
      'tell application "Terminal" to activate',
    ]);
  }

  Future<bool> installFirebaseCli() async {
    var (code, _) = await run('npm', ['install', '-g', 'firebase-tools']);
    // macOS: npm global ke /usr/local butuh sudo → pasang ke ~/.npm-global saja
    if (code != 0 && Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '';
      (code, _) = await run('npm', ['install', '-g', '--prefix', '$home/.npm-global', 'firebase-tools']);
    }
    return code == 0;
  }

  Future<bool> installFlutterFire() async {
    final ok = (await run(flutterCmd, ['pub', 'global', 'activate', 'flutterfire_cli'])).$1 == 0;
    await ToolEnv.init(); // ~/.pub-cache/bin ikut masuk PATH
    return ok;
  }

  Future<String?> version(String exe, List<String> args) async {
    final (code, out) = await run(exe, args, quiet: true);
    if (code != 0) return null;
    final v = out.trim().split('\n').last.trim();
    return v.isEmpty ? 'ok' : v;
  }

  Future<String?> nodeVersion() async {
    await detectNode();
    final v = await version('npm', ['--version']);
    if (v == null) return null;
    return nodeDir == null ? v : 'npm $v  ($nodeDir)';
  }
  Future<String?> firebaseVersion() => version('firebase', ['--version']);

  Future<bool> hasFlutterFire() async {
    final (code, out) = await run(flutterCmd, ['pub', 'global', 'list'], quiet: true);
    return code == 0 && out.contains('flutterfire_cli');
  }

  Future<bool> installTools() async {
    final (c1, _) = await run('npm', ['install', '-g', 'firebase-tools']);
    final (c2, _) = await run(flutterCmd, ['pub', 'global', 'activate', 'flutterfire_cli']);
    return c1 == 0 && c2 == 0;
  }

  /// Hasil `--json` Firebase CLI → bagian "result".
  dynamic _json(String out) {
    final i = out.indexOf('{');
    if (i < 0) return null;
    try {
      final j = jsonDecode(out.substring(i));
      return j is Map ? j['result'] : null;
    } catch (_) {
      return null;
    }
  }

  /// Email akun yang sedang login (null = belum login).
  Future<String?> loginEmail() async {
    final (_, out) = await run('firebase', ['login:list', '--json'], quiet: true);
    final r = _json(out);
    if (r is List && r.isNotEmpty) {
      final u = r.first is Map ? (r.first['user'] ?? r.first) : null;
      return u is Map ? '${u['email'] ?? 'ok'}' : 'ok';
    }
    // Cadangan: baca langsung file login Firebase CLI
    // (Windows: %USERPROFILE%\.config\configstore\firebase-tools.json, Mac: ~/.config/configstore/…)
    final fromFile = configEmail();
    if (fromFile != null) return fromFile;
    lastLoginOutput = out.trim();
    return null;
  }

  /// Output terakhir `firebase login:list` (untuk diagnosa kalau tetap dianggap belum login).
  String lastLoginOutput = '';

  static String get configFile {
    final e = Platform.environment;
    final home = e['USERPROFILE'] ?? e['HOME'] ?? '';
    final base = e['XDG_CONFIG_HOME'] ?? '$home${Platform.pathSeparator}.config';
    return '$base${Platform.pathSeparator}configstore${Platform.pathSeparator}firebase-tools.json';
  }

  static String? configEmail() {
    try {
      final f = File(configFile);
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map || j['tokens'] is! Map || (j['tokens']['refresh_token'] ?? '') == '') return null;
      final u = j['user'];
      return u is Map ? '${u['email'] ?? 'ok'}' : 'ok';
    } catch (_) {
      return null;
    }
  }

  /// Buka jendela terminal terpisah untuk `firebase login` (perlu browser & interaksi).
  /// Lewati pertanyaan "Allow Firebase to collect CLI usage…? (Y/n)" yang membuat login
  /// menunggu ketikan di terminal: simpan jawabannya (usage = false) di file konfigurasi CLI.
  static void presetNoUsagePrompt() {
    try {
      final f = File(configFile);
      Map<String, dynamic> j = {};
      if (f.existsSync()) {
        final d = jsonDecode(f.readAsStringSync());
        if (d is Map) j = Map<String, dynamic>.from(d);
      }
      if (j.containsKey('usage')) return;
      j['usage'] = false;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(j));
    } catch (_) {}
  }

  /// Login Firebase CLI. Yang perlu dilakukan pengguna hanya klik "Izinkan" di browser:
  /// pertanyaan usage sudah dijawab otomatis, jendela terminal diperkecil (Windows) dan
  /// menutup sendiri setelah selesai.
  Future<void> openLoginWindow({bool reauth = false}) async {
    presetNoUsagePrompt();
    final cmd = reauth ? 'firebase login --reauth' : 'firebase login';
    log('\$ $cmd');
    if (Platform.isWindows) {
      await Process.start('cmd', ['/c', 'start', 'Firebase Login', '/min', 'cmd', '/c', cmd],
          runInShell: false, environment: env());
    } else if (Platform.isMacOS) {
      final path = ToolEnv.env()['PATH'] ?? '';
      await Process.run('osascript', [
        '-e', 'tell app "Terminal" to do script "export PATH=\\"$path\\"; $cmd; exit"',
      ]);
    } else {
      await Process.start('x-terminal-emulator', ['-e', cmd]);
    }
  }

  /// Windows: PowerShell memblokir skrip npm (firebase.ps1). Izinkan untuk akun ini saja
  /// (RemoteSigned, tanpa admin) supaya perintah firebase juga jalan kalau diketik manual.
  Future<void> fixPowerShellPolicy() async {
    if (!Platform.isWindows) return;
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-Command', 'Get-ExecutionPolicy -Scope CurrentUser']);
      final cur = '${r.stdout}'.trim();
      if (cur == 'Undefined' || cur == 'Restricted' || cur == 'AllSigned') {
        await Process.run('powershell',
            ['-NoProfile', '-Command', 'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force']);
        log('✔ PowerShell: ExecutionPolicy CurrentUser = RemoteSigned');
      }
    } catch (_) {}
  }



  /// Daftar project Firebase: (projectId, nama).
  Future<List<(String, String)>> projects() async {
    final (_, out) = await run('firebase', ['projects:list', '--json'], quiet: true);
    final r = _json(out);
    if (r is! List) return [];
    return [for (final p in r) ('${p['projectId']}', '${p['displayName'] ?? p['projectId']}')];
  }

  Future<bool> createProject(String id, String name) async {
    final (code, _) = await run('firebase', ['projects:create', id, '--display-name', name, '--non-interactive']);
    return code == 0;
  }

  /// flutterfire configure: buat aplikasi Android/iOS di Firebase + unduh konfigurasi + firebase_options.dart.
  Future<bool> configure({
    required String root,
    required String projectId,
    required String androidPackage,
    String iosBundleId = '',
  }) async {
    final platforms = ['android', if (iosBundleId.isNotEmpty) 'ios'];
    final (code, _) = await run(
      flutterCmd,
      [
        'pub', 'global', 'run', 'flutterfire_cli:flutterfire', 'configure',
        '--project=$projectId',
        '--platforms=${platforms.join(',')}',
        '--android-package-name=$androidPackage',
        if (iosBundleId.isNotEmpty) '--ios-bundle-id=$iosBundleId',
        '--yes',
        '--overwrite-firebase-options',
      ],
      cwd: root,
    );
    return code == 0;
  }

  /// appId aplikasi Android di project Firebase untuk package tertentu.
  Future<String?> androidAppId(String projectId, String packageName) async {
    final (_, out) = await run('firebase', ['apps:list', 'ANDROID', '--project', projectId, '--json'], quiet: true);
    final r = _json(out);
    if (r is! List) return null;
    for (final a in r) {
      if ('${a['packageName']}' == packageName) return '${a['appId']}';
    }
    return null;
  }

  Future<bool> addSha(String projectId, String appId, String sha) async {
    final (code, _) = await run('firebase', ['apps:android:sha:create', appId, sha, '--project', projectId]);
    return code == 0;
  }

  /// Unduh ulang google-services.json (setelah SHA-1 ditambah).
  Future<bool> downloadAndroidConfig(String projectId, String appId, String outPath) async {
    final f = File(outPath);
    if (await f.exists()) await f.copy('$outPath.bak').then((_) => f.delete());
    final (code, _) = await run('firebase', ['apps:sdkconfig', 'ANDROID', appId, '--project', projectId, '--out', outPath]);
    return code == 0;
  }
}
