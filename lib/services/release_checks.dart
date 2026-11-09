import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/i18n.dart';
import '../models.dart';
import '../utils.dart';
import 'keystore_tool.dart';
import 'play_console_tasks.dart';
import 'store_metadata.dart';
import 'version.dart';
import 'tool_env.dart';

enum CheckLevel { pass, warn, fail, info }

class CheckResult {
  final String category;
  final String title;
  final CheckLevel level;
  final String detail;
  final String fix;
  CheckResult(this.category, this.title, this.level, this.detail, [this.fix = '']);
}

String get catVersi => tr('Versi & SDK');
String get catLogin => tr('Login & Akun Demo');
String get catKebijakan => tr('Kebijakan & Perlindungan Anak');
String get catFirebase => tr('Firebase & Login Google');
String get catHemat => tr('Ukuran & Hemat');
String get catStore => tr('Listing Play Store');
String get catConsole => tr('Play Console & Pengujian Tertutup');

/// Pemeriksaan kelayakan rilis sebelum build/upload ke Google Play & App Store.
class ReleaseChecker {
  ReleaseChecker(this.pr, this.s, {required this.demoPassword, void Function(String)? log})
      : _log = log ?? ((_) {});

  final Project pr;
  final AppSettings s;
  final String demoPassword;
  final void Function(String) _log;
  final List<CheckResult> results = [];

  String pubspec = '';
  Set<String> deps = {};
  String code = '';
  bool hasLogin = false;
  bool hasGoogleLogin = false;
  bool hasFirebase = false;

  String get root => pr.localPath;
  int get failCount => results.where((r) => r.level == CheckLevel.fail).length;
  int get warnCount => results.where((r) => r.level == CheckLevel.warn).length;

  File get googleServicesJson => pr.googleServicesJsonPath.isNotEmpty
      ? File(pr.googleServicesJsonPath)
      : File(p.join(root, 'android', 'app', 'google-services.json'));

  File get googleServiceInfoPlist => pr.googleServiceInfoPlistPath.isNotEmpty
      ? File(pr.googleServiceInfoPlistPath)
      : File(p.join(root, 'ios', 'Runner', 'GoogleService-Info.plist'));

  void _add(String cat, String title, CheckLevel level, String detail, [String fix = '']) {
    results.add(CheckResult(cat, title, level, detail, fix));
    final icon = switch (level) {
      CheckLevel.pass => '✔',
      CheckLevel.warn => '⚠',
      CheckLevel.fail => '✖',
      CheckLevel.info => 'ℹ',
    };
    _log('$icon [$cat] $title — $detail');
    if (fix.isNotEmpty && level != CheckLevel.pass) _log('   ↳ ${trL('Solusi')}: $fix');
  }

  /// [track] = track tujuan upload ('' kalau tidak upload). Production lebih ketat.
  Future<List<CheckResult>> runAll({bool android = true, bool ios = false, String track = ''}) async {
    results.clear();
    final pub = File(p.join(root, 'pubspec.yaml'));
    if (!await pub.exists()) {
      _add(catVersi, 'pubspec.yaml', CheckLevel.fail, trL('Tidak ditemukan di {0}', [root]));
      return results;
    }
    pubspec = await pub.readAsString();
    deps = RegExp(r'^\s{2}([a-z0-9_]+):', multiLine: true).allMatches(pubspec).map((m) => m.group(1)!).toSet();
    code = await _readDartCode();

    hasFirebase = deps.any((d) => d.startsWith('firebase_'));
    hasGoogleLogin = deps.contains('google_sign_in') || RegExp(r'GoogleAuthProvider|GoogleSignIn\(').hasMatch(code);
    hasLogin = hasGoogleLogin ||
        deps.contains('firebase_auth') ||
        deps.contains('sign_in_with_apple') ||
        RegExp(r'''signInWith\w+|class\s+\w*(Login|SignIn|Masuk)\w*|['"/]login['"/]|auth/login|obscureText:\s*true''')
            .hasMatch(code);

    await _checkVersion();
    if (android) await _checkTargetSdk();
    if (android) await _checkSigning(track);
    // Aplikasi sudah live di Play Store (Android): kebijakan, CSAE, akun demo & listing
    // sudah beres di Play Console → tidak diperiksa lagi, cukup cek AAB-nya.
    final live = pr.alreadyLive && !ios;
    if (live) {
      _add(catKebijakan, tr('Kebijakan, CSAE, akun demo & listing'), CheckLevel.info,
          trL('Dilewati — aplikasi sudah live di Play Store'));
    } else {
      await _checkLogin();
      await _checkPolicies(ios: ios);
    }
    if (android) await _checkFirebaseAndroid();
    if (ios) await _checkFirebaseIos();
    await _checkEfficiency();
    if (android) {
      if (!live) await _checkStoreListing();
      _checkPlayConsole(track);
    }
    return results;
  }

  Future<String> _readDartCode() async {
    final dir = Directory(p.join(root, 'lib'));
    if (!await dir.exists()) return '';
    final buf = StringBuffer();
    await for (final e in dir.list(recursive: true)) {
      if (e is File && e.path.endsWith('.dart')) {
        try {
          buf.writeln(await e.readAsString());
        } catch (_) {}
      }
    }
    return buf.toString();
  }

  /// Nama-nama aplikasi yang wajar muncul di halaman (nama proyek, judul listing, package, repo).
  Future<List<String>> _appNames() async {
    final names = <String>{pr.name};
    try {
      final meta = await loadStoreMeta(pr);
      for (final l in meta?.listings ?? const <StoreListing>[]) {
        if (l.title.isNotEmpty && !l.title.contains('(maksimal')) names.add(l.title);
      }
    } catch (_) {}
    if (pr.githubRepo.isNotEmpty) names.add(pr.githubRepo);
    if (pr.packageName.isNotEmpty) {
      names.add(pr.packageName);
      final parts = pr.packageName.split('.');
      if (parts.length >= 2 && parts[1].length > 3) names.add(parts[1]); // com.batamchitchat.app → batamchitchat
    }
    return names.where((n) => n.trim().length >= 3).toList();
  }

  /// Cari nama aplikasi di halaman: abaikan tag HTML, huruf besar/kecil, spasi & tanda baca
  /// ("Batam ChitChat" = "batamchitchat" = "Batam-Chit-Chat").
  Future<({String? found, bool jsOnly, int textLength, String title, List<String> tried})> matchAppName(String html) async {
    final title = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(html)?.group(1)?.trim() ?? '';
    var text = html
        .replaceAll(RegExp(r'<(script|style|noscript)[^>]*>[\s\S]*?</\1>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'&nbsp;|&#160;'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // meta description / og:title juga dihitung (sering berisi nama aplikasi di halaman SPA)
    final metas = RegExp(r'<meta[^>]+content="([^"]*)"', caseSensitive: false).allMatches(html).map((m) => m.group(1)!).join(' ');
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final hay = norm('$title $text $metas');
    final names = await _appNames();
    String? found;
    for (final n in names) {
      if (norm(n).length >= 3 && hay.contains(norm(n))) {
        found = n;
        break;
      }
    }
    final scripts = RegExp(r'<script', caseSensitive: false).allMatches(html).length;
    final jsOnly = found == null && text.length < 400 && scripts > 0;
    return (found: found, jsOnly: jsOnly, textLength: text.length, title: title, tried: names);
  }

  Future<(int, String)> _get(String url) async {
    try {
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      return (r.statusCode, r.body);
    } catch (e) {
      return (0, '$e');
    }
  }

  Future<void> _url(String cat, String title, String url, {String emptyFix = ''}) async {
    if (url.isEmpty) {
      if (pr.alreadyLive) {
        _add(cat, title, CheckLevel.info, trL('Dilewati — aplikasi sudah live di Play Store'));
        return;
      }
      _add(cat, title, CheckLevel.fail, trL('Belum diisi'), emptyFix);
      return;
    }
    final (st, _) = await _get(url);
    _add(cat, title, st == 200 ? CheckLevel.pass : CheckLevel.fail,
        st == 200 ? url : trL('Tidak bisa dibuka (HTTP {0})', [st]),
        st == 200 ? '' : trL('Halaman harus publik dan bisa dibuka tanpa login'));
  }

  // ───────────────────────── Versi & SDK
  Future<void> _checkVersion() async {
    final v = readVersion(pubspec);
    if (v == null) {
      _add(catVersi, tr('Versi aplikasi'), CheckLevel.fail, trL('Baris version: tidak ada'),
          trL('Tambahkan mis. "version: 1.0.0+1" di pubspec.yaml'));
    } else {
      _add(catVersi, tr('Versi aplikasi'), CheckLevel.pass, v.toString());
    }
  }

  Future<File?> _appGradle() async {
    for (final g in ['build.gradle.kts', 'build.gradle']) {
      final f = File(p.join(root, 'android', 'app', g));
      if (await f.exists()) return f;
    }
    return null;
  }

  Future<int?> _flutterDefaultTargetSdk() async {
    try {
      final r = await Process.run(s.flutterCmd, ['--version', '--machine'], runInShell: true, environment: ToolEnv.env());
      final out = '${r.stdout}';
      final start = out.indexOf('{');
      if (start < 0) return null;
      final json = jsonDecode(out.substring(start)) as Map<String, dynamic>;
      final flutterRoot = json['flutterRoot'] as String?;
      if (flutterRoot == null) return null;
      final dir = Directory(p.join(flutterRoot, 'packages', 'flutter_tools', 'gradle'));
      if (!await dir.exists()) return null;
      final re = RegExp(r'targetSdkVersion\s*(?::\s*Int)?\s*=\s*(\d+)');
      await for (final e in dir.list(recursive: true)) {
        if (e is File && (e.path.endsWith('.kt') || e.path.endsWith('.groovy'))) {
          final m = re.firstMatch(await e.readAsString());
          if (m != null) return int.parse(m.group(1)!);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _checkTargetSdk() async {
    final g = await _appGradle();
    if (g == null) {
      _add(catVersi, 'targetSdk', CheckLevel.fail, trL('android/app/build.gradle tidak ditemukan'));
      return;
    }
    final name = p.basename(g.path);
    final m = RegExp(r'targetSdk(?:Version)?\s*=?\s*([\w.]+)').firstMatch(await g.readAsString());
    int? target;
    String source;
    if (m != null && int.tryParse(m.group(1)!) != null) {
      target = int.parse(m.group(1)!);
      source = name;
    } else {
      target = await _flutterDefaultTargetSdk();
      source = trL('bawaan Flutter SDK');
    }
    if (target == null) {
      _add(catVersi, 'targetSdk', CheckLevel.warn, trL('Tidak bisa dibaca otomatis'),
          trL('Pastikan targetSdk minimal {0} di {1}', [s.minTargetSdk, name]));
    } else if (target < s.minTargetSdk) {
      _add(catVersi, 'targetSdk', CheckLevel.fail,
          trL('targetSdk {0} ({1}), Google Play mewajibkan minimal {2}', [target, source, s.minTargetSdk]),
          trL('Ubah menjadi targetSdk = {0} di android/app/{1} atau upgrade Flutter', [s.minTargetSdk, name]));
    } else {
      _add(catVersi, 'targetSdk', CheckLevel.pass, '$target ($source)');
    }
  }

  Future<void> _checkSigning(String track) async {
    final ok = await hasReleaseSigning(root);
    _add(catVersi, tr('Keystore (signing release)'), ok ? CheckLevel.pass : (track.isNotEmpty ? CheckLevel.fail : CheckLevel.warn),
        ok ? trL('key.properties + signingConfigs release aktif') : trL('Belum diatur — AAB akan ditandatangani debug key dan ditolak Google Play'),
        trL('Edit Proyek → langkah 1 → klik "Keystore (signing release)" → Buat keystore otomatis'));
  }

  // ───────────────────────── Login & akun demo
  Future<void> _checkLogin() async {
    if (!pr.hasLogin) {
      if (hasLogin) {
        _add(catLogin, tr('Deteksi login'), CheckLevel.warn,
            trL('Proyek diisi "tidak ada login", tapi kode terdeteksi punya login'),
            trL('Edit Proyek → Fitur aplikasi → ubah "Aplikasi punya login" menjadi Ya kalau memang ada login'));
      } else {
        _add(catLogin, tr('Deteksi login'), CheckLevel.info, trL('Tidak ada login — akun demo tidak wajib'));
      }
      return;
    }
    _add(catLogin, tr('Deteksi login'), CheckLevel.info,
        hasGoogleLogin
            ? trL('Aplikasi punya login (termasuk Login Google) — reviewer butuh akun demo')
            : trL('Aplikasi punya login — reviewer butuh akun demo'));

    if (pr.demoUser.isEmpty || demoPassword.isEmpty) {
      _add(catLogin, tr('Akun demo untuk reviewer'), pr.alreadyLive ? CheckLevel.warn : CheckLevel.fail, trL('Username/password akun demo belum diisi'),
          trL('Edit Proyek → isi akun demo. Akun yang sama dimasukkan ke Play Console (Detail login) dan App Store Connect (Sign-in required)'));
    } else {
      _add(catLogin, tr('Akun demo untuk reviewer'), CheckLevel.pass, 'User: ${pr.demoUser}');
    }

    if (pr.loginTestUrl.isNotEmpty && pr.demoUser.isNotEmpty && demoPassword.isNotEmpty) {
      try {
        final r = await http
            .post(Uri.parse(pr.loginTestUrl),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({pr.loginUserField: pr.demoUser, 'password': demoPassword}))
            .timeout(const Duration(seconds: 20));
        if (r.statusCode >= 200 && r.statusCode < 300) {
          _add(catLogin, tr('Tes login akun demo'), CheckLevel.pass, 'HTTP ${r.statusCode} • ${pr.loginTestUrl}');
        } else {
          final body = r.body.length > 160 ? '${r.body.substring(0, 160)}…' : r.body;
          _add(catLogin, tr('Tes login akun demo'), CheckLevel.fail, 'HTTP ${r.statusCode}: $body',
              trL('Akun demo tidak bisa login — reviewer pasti menolak. Cek user/password atau server.'));
        }
      } catch (e) {
        _add(catLogin, tr('Tes login akun demo'), CheckLevel.fail, trL('Server tidak bisa dihubungi: {0}', [e]),
            trL('Pastikan server API online saat review'));
      }
    } else if (pr.demoUser.isNotEmpty) {
      // Tes login opsional: reviewer Google/Apple sendiri yang mencoba login.
      // Yang wajib hanya memasukkan akun ini di Play Console → Konten aplikasi → Akses aplikasi.
      _add(catLogin, tr('Akun demo di Play Console'), CheckLevel.info,
          trL('Masukkan {0} + password di Play Console → Kebijakan → Konten aplikasi → Akses aplikasi ("Semua atau sebagian fungsi dibatasi"). Reviewer Google yang mencoba login sendiri.', [pr.demoUser]));
    }

    await _url(catLogin, tr('Link hapus akun'), pr.deleteAccountUrl,
        emptyFix: trL('Google Play mewajibkan link web untuk hapus akun bila aplikasi bisa membuat akun'));

    final inApp = RegExp(r'(hapus akun|delete account|deleteAccount|delete_account)', caseSensitive: false).hasMatch(code);
    _add(catLogin, tr('Hapus akun di dalam aplikasi'), inApp ? CheckLevel.pass : CheckLevel.warn,
        inApp ? trL('Terdeteksi di kode') : trL('Tidak terdeteksi di kode'),
        trL('Apple & Google mewajibkan user bisa menghapus akun dari dalam aplikasi'));
  }

  // ───────────────────────── Kebijakan & perlindungan anak
  Future<void> _checkPolicies({required bool ios}) async {
    await _url(catKebijakan, tr('Kebijakan privasi'), pr.privacyPolicyUrl,
        emptyFix: trL('Wajib di Google Play & App Store. Isi di Edit Proyek'));

    if (!pr.isSocialApp) {
      final chat = RegExp(r'class\s+\w*(Chat|Message|Pesan|Room)\w*').hasMatch(code) ||
          deps.any((d) => const ['web_socket_channel', 'socket_io_client', 'livekit_client', 'stream_chat_flutter'].contains(d));
      _add(catKebijakan, tr('Standar perlindungan anak'), chat ? CheckLevel.warn : CheckLevel.info,
          chat ? trL('Proyek diisi "tidak ada chat", tapi kode terdeteksi punya fitur chat') : trL('Tidak ada fitur chat/sosial — CSAE tidak wajib'),
          trL('Edit Proyek → Fitur aplikasi → ubah "Ada fitur chat / sosial / komunitas" menjadi Ya kalau memang ada chat'));
      return;
    }

    final csae = tr('Link standar perlindungan anak (CSAE)');
    if (pr.childSafetyUrl.isEmpty) {
      _add(catKebijakan, csae, CheckLevel.fail, trL('Belum diisi'),
          trL('Aplikasi chat/sosial wajib punya halaman standar anti eksploitasi anak (CSAE) dan link-nya diisi di Play Console'));
    } else {
      final (st, body) = await _get(pr.childSafetyUrl);
      if (st != 200) {
        _add(catKebijakan, csae, CheckLevel.fail, trL('Tidak bisa dibuka (HTTP {0})', [st]),
            trL('Halaman harus publik dan bisa dibuka tanpa login'));
      } else {
        final m = await matchAppName(body);
        if (m.found != null) {
          _add(catKebijakan, csae, CheckLevel.pass, trL('{0} — menyebut "{1}"', [pr.childSafetyUrl, m.found]));
        } else if (m.jsOnly) {
          _add(catKebijakan, csae, CheckLevel.info,
              trL('Halaman terbuka, tapi isinya dibuat JavaScript ({0} karakter teks) — nama aplikasi tidak bisa dicek otomatis', [m.textLength]),
              trL('Buka {0} di browser dan pastikan nama aplikasi tampil. Lebih aman pakai halaman statis: menu proyek → "Buat kebijakan privasi & halaman wajib".', [pr.childSafetyUrl]));
        } else {
          _add(catKebijakan, csae, CheckLevel.warn,
              trL('Halaman terbuka{0}, tapi tidak menyebut nama aplikasi (dicari: {1})', [m.title.isEmpty ? '' : ' ("${m.title}")', m.tried.join(', ')]),
              trL('Google mewajibkan halaman CSAE menyebut nama aplikasi persis seperti di listing Play Store. Tambahkan nama aplikasi di halaman itu, atau buat halaman khusus lewat menu proyek → "Buat kebijakan privasi & halaman wajib".'));
        }
      }
    }

    final hasReport = RegExp(r'(laporkan|report|lapor)', caseSensitive: false).hasMatch(code);
    final hasBlock = RegExp(r'(blokir|block\s*user|blockUser|block_user)', caseSensitive: false).hasMatch(code);
    _add(catKebijakan, tr('Fitur lapor di dalam aplikasi'), hasReport ? CheckLevel.pass : CheckLevel.fail,
        hasReport ? trL('Terdeteksi di kode') : trL('Tidak terdeteksi di kode'),
        trL('Wajib ada cara melapor dari dalam aplikasi (form, email support, atau chat ke admin)'));
    if (ios) {
      _add(catKebijakan, tr('Fitur blokir user (App Store)'), hasBlock ? CheckLevel.pass : CheckLevel.warn,
          hasBlock ? trL('Terdeteksi di kode') : trL('Tidak terdeteksi di kode'),
          trL('Apple mewajibkan aplikasi konten buatan user punya fitur lapor dan blokir user'));
    }
    _add(catKebijakan, tr('Kontak penanggung jawab CSAM'), CheckLevel.info, trL('Tidak bisa dicek otomatis'),
        trL('Pastikan nama + kontak penanggung jawab sudah diisi di Play Console → Standar keselamatan anak'));
  }

  // ───────────────────────── Firebase & Login Google (Android)
  Future<String?> _uploadKeySha1() async {
    final kp = File(p.join(root, 'android', 'key.properties'));
    if (!await kp.exists()) return null;
    final props = <String, String>{};
    for (final line in await kp.readAsLines()) {
      final i = line.indexOf('=');
      if (i > 0) props[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
    final storeFile = props['storeFile'];
    if (storeFile == null) return null;
    var ks = p.isAbsolute(storeFile) ? storeFile : p.join(root, 'android', 'app', storeFile);
    if (!await File(ks).exists()) ks = p.join(root, 'android', storeFile);
    final r = await Process.run(s.keytoolCmd, [
      '-list', '-v',
      '-keystore', ks,
      '-alias', props['keyAlias'] ?? '',
      '-storepass', props['storePassword'] ?? '',
    ], runInShell: true, environment: ToolEnv.env());
    return RegExp(r'SHA1:\s*([0-9A-Fa-f:]+)').firstMatch('${r.stdout}')?.group(1);
  }

  String _norm(String sha) => sha.replaceAll(':', '').trim().toLowerCase();

  Future<void> _checkFirebaseAndroid() async {
    if (!pr.usesFirebase && !hasFirebase && !hasGoogleLogin) {
      _add(catFirebase, 'Firebase Android', CheckLevel.info, trL('Tidak memakai Firebase / Login Google'));
      return;
    }
    if (!pr.usesFirebase) {
      _add(catFirebase, 'Firebase', CheckLevel.warn, trL('Proyek diisi "tidak pakai Firebase", tapi kode memakai Firebase / Login Google'),
          trL('Edit Proyek → Fitur aplikasi → ubah "Pakai Firebase atau Login Google" menjadi Ya'));
    }
    final f = googleServicesJson;
    if (!await f.exists()) {
      _add(catFirebase, 'google-services.json', CheckLevel.fail, trL('File tidak ditemukan'),
          trL('Edit Proyek → langkah Firebase → "Siapkan Firebase" untuk membuatnya otomatis (atau ikuti langkah manual di sana)'));
      return;
    }
    Map<String, dynamic> json;
    try {
      json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      _add(catFirebase, 'google-services.json', CheckLevel.fail, trL('File rusak: {0}', [e]));
      return;
    }
    final clients = (json['client'] as List? ?? []).cast<Map<String, dynamic>>();
    Map<String, dynamic>? client;
    for (final c in clients) {
      final pkg = (c['client_info']?['android_client_info']?['package_name'] ?? '').toString();
      if (pkg == pr.packageName) client = c;
    }
    if (client == null) {
      _add(catFirebase, tr('Package di Firebase'), CheckLevel.fail,
          trL('{0} tidak terdaftar di google-services.json', [pr.packageName]),
          trL('Tambahkan aplikasi Android dengan package yang sama di Firebase, lalu download ulang file-nya'));
      return;
    }
    _add(catFirebase, tr('Package di Firebase'), CheckLevel.pass,
        '${pr.packageName} (project ${json['project_info']?['project_id']})');

    if (!hasGoogleLogin) return;

    final oauth = (client['oauth_client'] as List? ?? []).cast<Map<String, dynamic>>();
    final hashes = oauth
        .where((o) => o['client_type'] == 1)
        .map((o) => _norm('${o['android_info']?['certificate_hash'] ?? ''}'))
        .where((h) => h.isNotEmpty)
        .toSet();
    final hasWebClient = oauth.any((o) => o['client_type'] == 3);

    if (hashes.isEmpty) {
      _add(catFirebase, tr('SHA-1 di Firebase'), CheckLevel.fail, trL('Belum ada SHA-1 terdaftar'),
          trL('Firebase → Project settings → Android app → Add fingerprint (SHA-1 upload key + App signing key), lalu download ulang google-services.json'));
    }
    _add(catFirebase, tr('Web client ID (OAuth)'), hasWebClient ? CheckLevel.pass : CheckLevel.warn,
        hasWebClient ? trL('Ada') : trL('Tidak ada client_type 3'),
        trL('Aktifkan Google di Firebase → Authentication → Sign-in method, lalu download ulang google-services.json'));

    String? upload;
    try {
      upload = await _uploadKeySha1();
    } catch (_) {
      upload = null;
    }
    final upTitle = tr('SHA-1 upload key');
    if (upload == null) {
      _add(catFirebase, upTitle, CheckLevel.warn, trL('Tidak bisa dibaca dari android/key.properties'),
          trL('Pastikan key.properties benar dan keytool tersedia (atur path keytool di Pengaturan)'));
    } else if (hashes.contains(_norm(upload))) {
      _add(catFirebase, upTitle, CheckLevel.pass, trL('{0} terdaftar di Firebase', [upload]));
    } else if (hashes.isNotEmpty) {
      _add(catFirebase, upTitle, CheckLevel.fail, trL('{0} BELUM terdaftar di Firebase', [upload]),
          trL('Tambahkan SHA-1 ini di Firebase lalu download ulang google-services.json'));
    }

    final signTitle = tr('SHA-1 App signing (Google Play)');
    if (pr.playSigningSha1.isEmpty) {
      _add(catFirebase, signTitle, CheckLevel.warn, trL('Belum diisi di proyek'),
          trL('Ambil dari Play Console → Integritas aplikasi → Penandatanganan aplikasi. Tanpa SHA-1 ini, Login Google gagal di aplikasi yang diinstall dari Play Store'));
    } else if (hashes.contains(_norm(pr.playSigningSha1))) {
      _add(catFirebase, signTitle, CheckLevel.pass, trL('Terdaftar di Firebase'));
    } else {
      _add(catFirebase, signTitle, CheckLevel.fail, trL('{0} BELUM terdaftar di Firebase', [pr.playSigningSha1]),
          trL('Tambahkan di Firebase lalu download ulang google-services.json — ini penyebab paling umum "Login Google gagal (error 10)" di versi Play Store'));
    }
  }

  // ───────────────────────── Firebase & Login Google (iOS)
  String? _plistValue(String plist, String key) =>
      RegExp('<key>$key</key>\\s*<string>([^<]+)</string>').firstMatch(plist)?.group(1);

  Future<void> _checkFirebaseIos() async {
    final pbx = File(p.join(root, 'ios', 'Runner.xcodeproj', 'project.pbxproj'));
    String? bundleId;
    if (await pbx.exists()) {
      for (final m in RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = "?([^;"]+)"?;').allMatches(await pbx.readAsString())) {
        final id = m.group(1)!;
        if (!id.contains('RunnerTests')) {
          bundleId = id;
          break;
        }
      }
    }

    if (hasFirebase || hasGoogleLogin) {
      final f = googleServiceInfoPlist;
      if (!await f.exists()) {
        _add(catFirebase, 'GoogleService-Info.plist', CheckLevel.fail, trL('File tidak ditemukan'),
            trL('Edit Proyek → langkah Firebase → "Siapkan Firebase" (centang rilis iPhone supaya plist iOS ikut dibuat)'));
      } else {
        final plist = await f.readAsString();
        final fbBundle = _plistValue(plist, 'BUNDLE_ID');
        if (bundleId != null && fbBundle != null && fbBundle != bundleId) {
          _add(catFirebase, tr('Bundle ID iOS di Firebase'), CheckLevel.fail, 'Firebase: $fbBundle, Xcode: $bundleId',
              trL('Daftarkan bundle ID yang sama di Firebase lalu download ulang plist'));
        } else {
          _add(catFirebase, tr('Bundle ID iOS di Firebase'), CheckLevel.pass, fbBundle ?? '-');
        }

        if (hasGoogleLogin) {
          final reversed = _plistValue(plist, 'REVERSED_CLIENT_ID');
          final info = File(p.join(root, 'ios', 'Runner', 'Info.plist'));
          final infoText = await info.exists() ? await info.readAsString() : '';
          if (reversed == null) {
            _add(catFirebase, 'REVERSED_CLIENT_ID', CheckLevel.fail, trL('Tidak ada di GoogleService-Info.plist'),
                trL('Aktifkan Google Sign-In di Firebase lalu download ulang plist'));
          } else if (!infoText.contains(reversed)) {
            _add(catFirebase, tr('URL scheme Login Google (iOS)'), CheckLevel.fail,
                trL('REVERSED_CLIENT_ID belum ada di ios/Runner/Info.plist'),
                trL('Tambahkan "{0}" ke CFBundleURLTypes → CFBundleURLSchemes di Info.plist', [reversed]));
          } else {
            _add(catFirebase, tr('URL scheme Login Google (iOS)'), CheckLevel.pass, reversed);
          }
        }
      }
    }

    if (hasGoogleLogin && !deps.contains('sign_in_with_apple')) {
      _add(catFirebase, 'Sign in with Apple', CheckLevel.warn, trL('Ada Login Google tapi tidak ada Sign in with Apple'),
          trL('App Store (Guideline 4.8) mewajibkan opsi login setara seperti Sign in with Apple bila memakai login pihak ketiga'));
    }
  }

  // ───────────────────────── Ukuran & hemat
  Future<void> _checkEfficiency() async {
    final big = <(String, int)>[];
    final assets = Directory(p.join(root, 'assets'));
    if (await assets.exists()) {
      await for (final e in assets.list(recursive: true)) {
        if (e is File) {
          final len = await e.length();
          if (len > 1024 * 1024) big.add((p.relative(e.path, from: root), len));
        }
      }
    }
    final bigTitle = tr('Aset besar (>1 MB)');
    if (big.isEmpty) {
      _add(catHemat, bigTitle, CheckLevel.pass, trL('Tidak ada'));
    } else {
      big.sort((a, b) => b.$2.compareTo(a.$2));
      final list = big.take(5).map((e) => '${e.$1} (${fmtMb(e.$2)})').join(', ');
      _add(catHemat, bigTitle, CheckLevel.warn, trL('{0} file: {1}', [big.length, list]),
          trL('Kompres gambar ke WebP, video/audio diturunkan bitrate-nya, atau download dari server saat dibutuhkan'));
    }

    final args = pr.extraBuildArgs;
    final obf = args.contains('--obfuscate') && args.contains('--split-debug-info');
    _add(catHemat, tr('Obfuscate + split debug info'), CheckLevel.pass,
        obf ? trL('Aktif') : trL('Otomatis aktif saat deploy mode Produksi'));
    final g = await _appGradle();
    if (g != null) {
      final gs = await g.readAsString();
      final r8 = RegExp(r'isMinifyEnabled\s*=\s*true|minifyEnabled\s+true').hasMatch(gs);
      _add(catHemat, 'R8 + shrinkResources', r8 ? CheckLevel.pass : CheckLevel.info,
          r8 ? trL('Aktif') : trL('Diaktifkan otomatis saat deploy mode Produksi (backup build.gradle dibuat)'));
    }

    final prints = RegExp(r'(^|[^\w.])print\(').allMatches(code).length;
    _add(catHemat, tr('print() di kode'), prints > 20 ? CheckLevel.warn : CheckLevel.pass,
        trL('{0} panggilan', [prints]),
        trL('Ganti dengan debugPrint/log atau hapus — print berlebihan memperlambat aplikasi release'));
  }

  /// Dipanggil setelah build: cek ukuran AAB dan bandingkan dengan build sebelumnya.
  void checkAabSize(int bytes, int? previousBytes) {
    final mb = bytes / 1024 / 1024;
    if (mb > pr.maxAabMb) {
      _add(catHemat, tr('Ukuran AAB'), CheckLevel.warn, trL('{0} (batas {1} MB)', [fmtMb(bytes), pr.maxAabMb]),
          trL('Kurangi aset besar / library yang tidak dipakai'));
    } else {
      _add(catHemat, tr('Ukuran AAB'), CheckLevel.pass, fmtMb(bytes));
    }
    if (previousBytes != null && previousBytes > 0) {
      final growth = (bytes - previousBytes) / previousBytes * 100;
      final txt = trL('{0}% dari build sebelumnya ({1})',
          ['${growth >= 0 ? '+' : ''}${growth.toStringAsFixed(1)}', fmtMb(previousBytes)]);
      _add(catHemat, tr('Perubahan ukuran'), growth > 10 ? CheckLevel.warn : CheckLevel.pass, txt,
          trL('Ukuran naik lebih dari 10% — cek aset/library yang baru ditambahkan'));
    }
  }

  /// Laporan optimasi ukuran setelah build.
  void reportOptimization({required String mode, required int aabBytes, int? downloadBytes, int? internalAabBytes}) {
    final cat = tr('Ukuran & Hemat');
    if (downloadBytes != null && downloadBytes > 0) {
      final cut = (1 - downloadBytes / aabBytes) * 100;
      _add(cat, tr('Perkiraan download di HP (arm64)'), CheckLevel.pass,
          trL('{0} — {1}% lebih kecil dari file AAB {2}', [fmtMb(downloadBytes), cut.toStringAsFixed(0), fmtMb(aabBytes)]),
          '');
    }
    if (mode != 'production') return;
    if (internalAabBytes == null || internalAabBytes <= 0) {
      _add(cat, tr('Pengurangan dibanding build internal'), CheckLevel.info,
          trL('Belum ada build internal untuk dibandingkan. Deploy mode Internal sekali supaya perbandingan muncul.'));
      return;
    }
    final base = internalAabBytes;
    final aabCut = (1 - aabBytes / base) * 100;
    _add(cat, tr('AAB produksi vs AAB internal'), aabCut > 0 ? CheckLevel.pass : CheckLevel.warn,
        trL('{0} → {1} ({2}%)', [fmtMb(base), fmtMb(aabBytes), '${aabCut >= 0 ? '−' : '+'}${aabCut.abs().toStringAsFixed(0)}']));
    if (downloadBytes != null) {
      final dlCut = (1 - downloadBytes / base) * 100;
      _add(cat, tr('Download HP vs AAB internal (target ≥50%)'), dlCut >= 50 ? CheckLevel.pass : CheckLevel.warn,
          trL('{0} → ~{1} ({2}%)', [fmtMb(base), fmtMb(downloadBytes), '−${dlCut.toStringAsFixed(0)}']),
          trL('Belum 50%: kompres aset besar ke WebP, hapus library yang tidak dipakai, atau pindahkan aset besar ke server.'));
    }
  }

  // ───────────────────────── Listing Play Store (folder store/)
  Future<void> _checkStoreListing() async {
    final meta = await loadStoreMeta(pr);
    if (meta == null || meta.listings.isEmpty) {
      _add(catStore, tr('Folder store/'), CheckLevel.warn, trL('Belum ada — listing tidak disinkron otomatis'),
          trL('Menu kartu proyek → "Buat template store/", lalu isi teks dan gambar'));
      return;
    }
    final d = meta.details;
    if (d.containsKey('_error')) {
      _add(catStore, 'details.json', CheckLevel.fail, trL('details.json bukan JSON yang valid'));
    } else if ((d['contactEmail'] ?? '').toString().isEmpty || '${d['contactEmail']}'.contains('contoh.com')) {
      _add(catStore, tr('Email kontak'), CheckLevel.fail, trL('Belum diisi di store/details.json'),
          trL('Email kontak wajib ditampilkan di Play Store'));
    } else {
      _add(catStore, tr('Email kontak'), CheckLevel.pass, '${d['contactEmail']}');
    }

    for (final l in meta.listings) {
      final lang = l.language;
      void len(String name, String v, int max) {
        if (v.isEmpty || v.contains('(maksimal') || v.endsWith('...')) {
          _add(catStore, '$lang: $name', CheckLevel.fail, trL('Belum diisi / masih template'));
        } else if (v.length > max) {
          _add(catStore, '$lang: $name', CheckLevel.fail, trL('{0} karakter (maks {1})', [v.length, max]),
              trL('Persingkat teksnya'));
        } else {
          _add(catStore, '$lang: $name', CheckLevel.pass, '${v.length}/$max');
        }
      }

      len(tr('Judul'), l.title, 30);
      len(tr('Deskripsi singkat'), l.shortDescription, 80);
      len(tr('Deskripsi lengkap'), l.fullDescription, 4000);

      Future<void> img(String name, File? f, int w, int h) async {
        if (f == null) {
          _add(catStore, '$lang: $name', CheckLevel.fail, trL('Tidak ada'), trL('Tambahkan {0} x {1} px', [w, h]));
          return;
        }
        final size = await imageSize(f);
        if (size == null) {
          _add(catStore, '$lang: $name', CheckLevel.warn, trL('Ukuran tidak terbaca'));
        } else if (size.$1 != w || size.$2 != h) {
          _add(catStore, '$lang: $name', CheckLevel.fail,
              trL('{0} x {1} px (harus {2} x {3})', [size.$1, size.$2, w, h]));
        } else {
          _add(catStore, '$lang: $name', CheckLevel.pass, '$w x $h px');
        }
      }

      await img(tr('Ikon'), l.icon, 512, 512);
      await img('Feature graphic', l.featureGraphic, 1024, 500);

      final shotTitle = '$lang: ${tr('Screenshot HP')}';
      final phone = l.screenshots['phoneScreenshots'] ?? const <File>[];
      if (phone.length < 2 || phone.length > 8) {
        _add(catStore, shotTitle, CheckLevel.fail, trL('{0} gambar (harus 2–8)', [phone.length]));
      } else {
        final bad = <String>[];
        for (final f in phone) {
          final sz = await imageSize(f);
          if (sz == null) continue;
          final lo = sz.$1 < sz.$2 ? sz.$1 : sz.$2;
          final hi = sz.$1 < sz.$2 ? sz.$2 : sz.$1;
          if (lo < 320 || hi > 3840 || hi > lo * 2) bad.add('${p.basename(f.path)} (${sz.$1}x${sz.$2})');
        }
        _add(catStore, shotTitle, bad.isEmpty ? CheckLevel.pass : CheckLevel.fail,
            bad.isEmpty ? trL('{0} gambar', [phone.length]) : trL('Ukuran tidak valid: {0}', [bad.join(', ')]),
            trL('Sisi 320–3840 px, sisi panjang maksimal 2x sisi pendek'));
      }
    }

    _add(catStore, tr('Keamanan Data (CSV)'), meta.dataSafety == null ? CheckLevel.warn : CheckLevel.pass,
        meta.dataSafety == null ? trL('store/data_safety.csv belum ada') : trL('Akan diupload otomatis'),
        trL('Isi Keamanan Data sekali di Play Console → Export to CSV → simpan sebagai store/data_safety.csv'));
  }

  // ───────────────────────── Checklist Play Console & pengujian tertutup
  void _checkPlayConsole(String track) {
    final production = track == 'production';
    if (pr.alreadyLive) {
      _add(catConsole, tr('Konten aplikasi di Play Console'), CheckLevel.info,
          trL('Dilewati — aplikasi sudah live di Play Store'));
      return;
    }
    final tasks = consoleTasks(pr);
    final undone = tasks.where((t) => !pr.consoleDone.contains(t.key)).map((t) => t.title).toList();
    final title = tr('Konten aplikasi di Play Console');
    if (undone.isEmpty) {
      _add(catConsole, title, CheckLevel.pass, trL('Semua {0} tugas sudah ditandai', [tasks.length]));
    } else {
      _add(catConsole, title, production ? CheckLevel.fail : CheckLevel.warn,
          trL('Belum ditandai: {0}', [undone.join(', ')]),
          trL('Menu kartu proyek → "Checklist Play Console" (jawaban siap tempel)'));
    }

    final ct = ClosedTestStatus(pr);
    if (pr.isPersonalAccount) {
      final level = ct.ready ? CheckLevel.pass : (production ? CheckLevel.fail : CheckLevel.info);
      _add(catConsole, tr('Pengujian tertutup (12 tester, 14 hari)'), level, ct.describe(),
          trL('Akun developer pribadi wajib menjalankan pengujian tertutup sebelum bisa rilis production'));
    } else {
      _add(catConsole, tr('Pengujian tertutup'), CheckLevel.info, ct.describe());
    }
    if (pr.testerGroupList.isEmpty) {
      _add(catConsole, tr('Google Group tester'), CheckLevel.warn, trL('Belum diisi — tester tidak disinkron otomatis'),
          trL('Buat Google Group, masukkan email tester, lalu isi di Checklist Play Console'));
    } else {
      _add(catConsole, tr('Google Group tester'), CheckLevel.pass,
          '${pr.testerGroupList.join(', ')} → track ${pr.closedTestTrack}');
    }
  }
}

/// Teks siap tempel untuk Play Console / App Store Connect.
String storeInfoText(Project pr, String demoPassword) => [
      '${trL('Aplikasi')}: ${pr.name}',
      if (pr.demoUser.isNotEmpty) '--- ${trL('Akun demo untuk reviewer')} ---',
      if (pr.demoUser.isNotEmpty) 'Username: ${pr.demoUser}',
      if (pr.demoUser.isNotEmpty) 'Password: $demoPassword',
      '--- Link ---',
      '${trL('Kebijakan privasi')}: ${pr.privacyPolicyUrl.isEmpty ? '-' : pr.privacyPolicyUrl}',
      '${trL('Hapus akun')}: ${pr.deleteAccountUrl.isEmpty ? '-' : pr.deleteAccountUrl}',
      if (pr.isSocialApp) 'CSAE: ${pr.childSafetyUrl.isEmpty ? '-' : pr.childSafetyUrl}',
    ].join('\n');
