import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../services/firebase_tool.dart';
import '../services/keystore_tool.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

/// Siapkan Firebase untuk project: otomatis (Firebase CLI + FlutterFire CLI) atau manual langkah demi langkah.
/// Mengembalikan 'rescan' kalau ada file yang dibuat/diubah.
class FirebaseSetupDialog extends StatefulWidget {
  const FirebaseSetupDialog({
    super.key,
    required this.root,
    required this.packageName,
    this.iosBundleId = '',
    this.useIos = false,
    this.playSigningSha1 = '',
    this.googleLogin = false,
  });
  final String root;
  final String packageName;
  final String iosBundleId;
  final bool useIos;
  final String playSigningSha1;
  final bool googleLogin;

  @override
  State<FirebaseSetupDialog> createState() => _FirebaseSetupDialogState();
}

class _FirebaseSetupDialogState extends State<FirebaseSetupDialog> {
  late final tool = FirebaseTool(flutterCmd: app.settings.flutterCmd, log: _log);
  final logs = <String>[];
  final scroll = ScrollController();
  String mode = 'auto'; // auto | manual
  bool changed = false;
  String? busy;

  String? npm, firebase, loginEmail;
  bool flutterfire = false;
  bool winget = false;
  bool brew = false; // Homebrew (macOS)
  bool userPicked = false; // project dipilih sendiri di dropdown
  bool creatingNew = false; // pilih "Buat project baru…" di dropdown
  bool get isMac => Platform.isMacOS;
  bool checked = false;
  List<(String, String)> projects = [];
  String? projectId;
  final newId = TextEditingController();
  final newName = TextEditingController();
  late final signSha = TextEditingController(text: widget.playSigningSha1);
  String? uploadSha;

  bool get hasAndroidConfig => File(p.join(widget.root, 'android', 'app', 'google-services.json')).existsSync();
  bool get hasIosConfig => File(p.join(widget.root, 'ios', 'Runner', 'GoogleService-Info.plist')).existsSync();

  @override
  void initState() {
    super.initState();
    // Isi otomatis ID & nama project baru dari package (com.batamchitchat.app → batamchitchat-app)
    final parts = widget.packageName.split('.').where((x) => x.isNotEmpty && x != 'com' && x != 'id' && x != 'co').toList();
    var sug = parts.join('-').toLowerCase().replaceAll(RegExp('[^a-z0-9-]'), '');
    if (sug.length > 30) sug = sug.substring(0, 30);
    if (sug.length >= 6 && RegExp('^[a-z]').hasMatch(sug)) newId.text = sug;
    if (parts.isNotEmpty) {
      final n = parts.first;
      newName.text = n[0].toUpperCase() + n.substring(1);
    }
    _check();
    uploadKeySha1(widget.root, app.settings.keytoolCmd).then((v) {
      if (mounted) setState(() => uploadSha = v);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    scroll.dispose();
    newId.dispose();
    newName.dispose();
    signSha.dispose();
    super.dispose();
  }

  void _log(String l) {
    if (!mounted) return;
    setState(() => logs.add(l));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  Future<void> _do(String name, Future<void> Function() fn) async {
    setState(() => busy = name);
    try {
      await fn();
    } catch (e) {
      _log('✖ $e');
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Future<void> _check() async {
    final n = await tool.nodeVersion();
    final f = await tool.firebaseVersion();
    final ff = await tool.hasFlutterFire();
    final w = n == null ? await tool.hasWinget() : winget;
    final br = n == null ? await tool.hasBrew() : brew;
    final e = f == null ? null : await tool.loginEmail();
    if (!mounted) return;
    setState(() {
      npm = n;
      firebase = f;
      flutterfire = ff;
      winget = w;
      brew = br;
      loginEmail = e;
      checked = true;
    });
    if (e != null && projects.isEmpty) await _loadProjects();
  }

  Future<void> _loadProjects() async {
    final list = await tool.projects();
    if (!mounted) return;
    setState(() {
      projects = list;
      if (projectId == null || !list.any((x) => x.$1 == projectId)) projectId = list.isEmpty ? null : list.first.$1;
    });
    _log(trL('{0} project Firebase ditemukan', [list.length]));
  }

  // ───────────────────────── UI kecil
  Widget _step(int n, String title, bool done, {required List<Widget> children, bool locked = false}) => Opacity(
        opacity: locked ? 0.5 : 1,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: YmColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: done ? YmColors.success.withOpacity(0.5) : YmColors.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: done ? YmColors.success : YmColors.primary, shape: BoxShape.circle),
                child: done
                    ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                    : Text('$n', style: YmTextStyles.labelSm.copyWith(color: Colors.white)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700))),
              if (done) SoftChip.success(tr('Selesai')),
            ]),
            const SizedBox(height: 10),
            ...children,
          ]),
        ),
      );

  Widget _btn(String name, IconData icon, Future<void> Function()? fn, {bool primary = true}) {
    final child = busy == name ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon);
    final onPressed = fn == null || busy != null ? null : () => _do(name, fn);
    return primary
        ? ElevatedButton.icon(style: primaryButtonStyle(), onPressed: onPressed, icon: child, label: Text(name))
        : OutlinedButton.icon(style: outlineButtonStyle(), onPressed: onPressed, icon: child, label: Text(name));
  }

  Widget _status(String label, String? value, {String help = '', List<Widget> actions = const []}) {
    final ok = value != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ok ? YmColors.successSoft.withOpacity(0.5) : YmColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.cancel_rounded, size: 18, color: ok ? YmColors.success : YmColors.danger),
          const SizedBox(width: 8),
          Text('$label: ', style: YmTextStyles.bodySm),
          Expanded(child: Text(value ?? tr('belum terpasang'), style: YmTextStyles.labelMd)),
        ]),
        if (!ok && help.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 26, top: 4), child: Text(help, style: YmTextStyles.bodySm)),
        if (!ok && actions.isNotEmpty)
          Padding(padding: const EdgeInsets.only(left: 26, top: 8), child: Wrap(spacing: 8, runSpacing: 8, children: actions)),
      ]),
    );
  }

  Widget _link(String label, String url) => OutlinedButton.icon(
        style: outlineButtonStyle(),
        onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        icon: const Icon(Icons.open_in_new_rounded, size: 18),
        label: Text(label),
      );

  /// Node.js dipasang di lokasi lain (mis. D:\Program Files\nodejs) → pilih manual.
  Future<void> _pickNode() async {
    final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: trL('Pilih folder Node.js (yang berisi node.exe)'));
    if (dir == null) return;
    if (await FirebaseTool.setNodeDir(dir)) {
      _log('✔ Node.js: $dir');
    } else {
      _log('✖ ${trL('node.exe tidak ditemukan di {0}', [dir])}');
    }
    await _check();
  }

  Future<bool> _configure() async {
    final pid = projectId;
    if (pid == null || widget.packageName.isEmpty) return false;
    final ok = await tool.configure(
      root: widget.root,
      projectId: pid,
      androidPackage: widget.packageName,
      iosBundleId: widget.useIos ? widget.iosBundleId : '',
    );
    _log(ok ? '✔ ${trL('Konfigurasi Firebase dibuat')}' : '✖ ${trL('flutterfire configure gagal — lihat log di atas')}');
    if (ok) {
      changed = true;
      if (mounted) setState(() {});
    }
    return ok;
  }

  Future<bool> _registerSha() async {
    final pid = projectId;
    if (pid == null) return false;
    final appId = await tool.androidAppId(pid, widget.packageName);
    if (appId == null) {
      _log('✖ ${trL('Aplikasi Android {0} belum ada di project — jalankan langkah 4 dulu', [widget.packageName])}');
      return false;
    }
    var any = false;
    for (final sha in [uploadSha, signSha.text.trim()]) {
      if (sha != null && sha.isNotEmpty) {
        await tool.addSha(pid, appId, sha);
        any = true;
      }
    }
    if (!any) {
      _log('ℹ ${trL('Belum ada SHA-1 untuk didaftarkan (keystore / App signing belum ada) — dilewati.')}');
      return true;
    }
    final ok = await tool.downloadAndroidConfig(pid, appId, p.join(widget.root, 'android', 'app', 'google-services.json'));
    _log(ok ? '✔ ${trL('google-services.json diperbarui dengan SHA-1')}' : '✖ ${trL('Gagal mengunduh google-services.json')}');
    if (ok) changed = true;
    return ok;
  }

  /// Tunggu login selesai (maks. 5 menit).
  Future<bool> _waitLogin() async {
    for (var i = 0; i < 100 && mounted; i++) {
      final e = await tool.loginEmail();
      if (e != null) {
        setState(() => loginEmail = e);
        return true;
      }
      await Future.delayed(const Duration(seconds: 3));
    }
    return false;
  }

  /// Pilih project yang paling cocok dengan nama aplikasi; kalau belum ada project sama sekali, buat baru.
  Future<bool> _ensureProject() async {
    if (projects.isEmpty) await _loadProjects();
    if (userPicked && projectId != null) {
      _log('✔ ${trL('Project Firebase: {0}', [projectId])}');
      return true;
    }
    // Cocokkan dengan nama aplikasi (mis. com.batamchitchat.app → "batamchitchat").
    // Project lain (mis. milik aplikasi lain) TIDAK dipakai — lebih aman buat baru.
    final key = widget.packageName.split('.').where((x) => x.length > 3 && x != 'com' && x != 'app').join().toLowerCase();
    for (final (id, name) in projects) {
      if (key.isNotEmpty && ('$id$name').toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '').contains(key)) {
        setState(() => projectId = id);
        _log('✔ ${trL('Project Firebase: {0}', [id])}');
        return true;
      }
    }
    var base = widget.packageName.split('.').where((x) => x != 'com' && x != 'app' && x.isNotEmpty).join('-').toLowerCase();
    base = base.replaceAll(RegExp('[^a-z0-9-]'), '');
    if (base.length < 4) base = 'deployhub-app';
    if (base.length > 22) base = base.substring(0, 22);
    final name = newName.text.trim().isEmpty ? base : newName.text.trim();
    var id = newId.text.trim();
    if (!RegExp(r'^[a-z][a-z0-9-]{5,29}$').hasMatch(id)) id = '$base-${DateTime.now().millisecondsSinceEpoch % 100000}';
    _log(trL('Belum ada project Firebase untuk aplikasi ini — membuat {0}…', [id]));
    if (!await tool.createProject(id, name)) {
      // ID sudah dipakai orang lain → tambah angka acak
      id = '${id.length > 24 ? id.substring(0, 24) : id}-${DateTime.now().millisecondsSinceEpoch % 100000}';
      _log(trL('ID sudah dipakai — mencoba {0}…', [id]));
      if (!await tool.createProject(id, name)) return false;
    }
    await _loadProjects();
    setState(() => projectId = id);
    return true;
  }

  /// SATU TOMBOL: pasang alat → login (cukup klik Izinkan di browser) → project → konfigurasi → SHA-1.
  Future<void> _autoAll() async {
    if (widget.packageName.isEmpty) {
      _log('✖ ${trL('Package name belum diisi di langkah Folder & nama')}');
      return;
    }
    await tool.fixPowerShellPolicy();
    if (firebase == null || !flutterfire) {
      _log('— ${trL('1/5 Memasang alat')}');
      await _installAll();
      if (firebase == null || !flutterfire) {
        _log('✖ ${trL('Alat belum lengkap. Lihat baris yang ✖ di langkah 1.')}');
        return;
      }
    }
    if (loginEmail == null) {
      _log('— ${trL('2/5 Login: browser terbuka, pilih akun Google lalu klik Izinkan / Allow')}');
      await tool.openLoginWindow();
      setState(() => polling = true);
      final ok = await _waitLogin();
      if (mounted) setState(() => polling = false);
      if (!ok) {
        _log('✖ ${trL('Login belum selesai. Klik "Jalankan semua otomatis" lagi setelah mengizinkan di browser.')}');
        return;
      }
    }
    _log('✔ ${trL('Login Firebase sebagai {0}', [loginEmail])}');
    _log('— ${trL('3/5 Project Firebase')}');
    if (!await _ensureProject()) return;
    _log('— ${trL('4/5 Membuat konfigurasi (flutterfire configure)')}');
    if (!await _configure()) return;
    _log('— ${trL('5/5 Mendaftarkan SHA-1')}');
    await _registerSha();
    _log('✔ ${trL('Selesai. Tinggal aktifkan Login Google di Firebase Console (langkah 6) kalau aplikasi memakai Login Google.')}');
  }

  bool get googleEnabled {
    // Login Google aktif → google-services.json punya oauth_client dengan client_type 3 (Web client)
    try {
      final f = File(p.join(widget.root, 'android', 'app', 'google-services.json'));
      if (!f.existsSync()) return false;
      return RegExp(r'"client_type"\s*:\s*3').hasMatch(f.readAsStringSync());
    } catch (_) {
      return false;
    }
  }

  Future<void> _checkGoogleEnabled() async {
    await _registerSha(); // unduh ulang google-services.json (sekalian SHA-1)
    if (!mounted) return;
    setState(() {});
    _log(googleEnabled
        ? '✔ ${trL('Login Google aktif — Web client ID ada di google-services.json')}'
        : '✖ ${trL('Login Google belum aktif. Pastikan saklar Google di Sign-in method sudah "Enabled" dan sudah klik Save, lalu coba lagi.')}');
  }

  Timer? _poll;
  bool polling = false;

  Future<void> _checkLogin() async {
    final e = await tool.loginEmail();
    if (!mounted) return;
    setState(() => loginEmail = e);
    if (e != null) {
      _log('✔ ${trL('Login Firebase sebagai {0}', [e])}');
      if (projects.isEmpty) await _loadProjects();
    } else if (!polling) {
      _log('✖ ${trL('Firebase CLI belum login. File login: {0}', [FirebaseTool.configFile])}');
    }
  }

  /// Buka terminal login lalu cek otomatis tiap 3 detik (maks. 5 menit).
  Future<void> _startLogin({bool reauth = false}) async {
    await tool.openLoginWindow(reauth: reauth);
    _poll?.cancel();
    setState(() => polling = true);
    final before = reauth ? loginEmail : null;
    var n = 0;
    _poll = Timer.periodic(const Duration(seconds: 3), (t) async {
      n++;
      final e = await tool.loginEmail();
      if (!mounted) return t.cancel();
      final done = e != null && (!reauth || e != before || n > 5);
      if (done || n >= 100) {
        t.cancel();
        setState(() => polling = false);
        await _checkLogin();
      }
    });
  }

  Future<void> _installAll() async {
    if (npm == null) {
      if (winget || brew) {
        _log(isMac
            ? trL('Memasang Node.js lewat Homebrew… (brew install node)')
            : trL('Memasang Node.js LTS… (setujui jendela izin Windows kalau muncul)'));
        await tool.installNode();
        await _check();
      }
      if (npm == null && isMac && firebase == null) {
        _log(trL('Node.js belum ada — memakai installer resmi Firebase untuk macOS. Ketik password Mac di jendela Terminal, lalu klik "Cek lagi".'));
        await tool.installFirebaseStandaloneMac();
      } else if (npm == null) {
        _log('✖ ${trL('Node.js belum terpasang. Pakai tombol "Download installer", pasang, lalu klik "Cek lagi".')}');
      }
    }
    if (npm != null && firebase == null) await tool.installFirebaseCli();
    if (!flutterfire) await tool.installFlutterFire();
    await _check();
  }

  Widget _text(String t) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(t, style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark, height: 1.5)));

  // ───────────────────────── otomatis
  List<Widget> _auto() {
    final toolsOk = firebase != null && flutterfire;
    final loggedIn = loginEmail != null;
    final configDone = hasAndroidConfig && (!widget.useIos || hasIosConfig);
    final pid = projectId;
    final consoleUrl = pid == null ? 'https://console.firebase.google.com' : 'https://console.firebase.google.com/project/$pid';
    return [
      Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: YmColors.primarySoft, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Icon(Icons.bolt_rounded, color: YmColors.onPrimaryFixed),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Satu klik untuk semuanya'),
                  style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700, color: YmColors.onPrimaryFixed)),
              Text(
                tr('DeployHub memasang alat, login, memilih/membuat project, membuat konfigurasi, dan mendaftarkan SHA-1 sendiri. Kamu cukup klik "Izinkan" di browser saat login. Tidak perlu buka terminal / PowerShell.'),
                style: YmTextStyles.bodySm.copyWith(color: YmColors.onPrimaryFixed),
              ),
            ]),
          ),
          const SizedBox(width: 10),
          _btn(tr('Jalankan semua otomatis'), Icons.play_arrow_rounded, _autoAll),
        ]),
      ),
      _step(1, tr('Pasang alat resmi Google (sekali saja)'), toolsOk, children: [
        if (!checked) const LinearProgressIndicator(),
        if (checked) ...[
          _status('Node.js / npm', npm,
              help: isMac
                  ? tr('Dibutuhkan untuk memasang Firebase CLI lewat npm. Cara termudah di Mac: Homebrew (brew install node). Tanpa Node.js pun bisa — Firebase CLI punya installer resmi khusus macOS (baris berikutnya).')
                  : tr('Dibutuhkan untuk memasang Firebase CLI. Pilih versi LTS. Pasang otomatis memakai winget (bawaan Windows 10/11); Windows akan minta izin administrator — klik Ya. Sudah terpasang di drive lain (mis. D:)? Klik "Pilih folder Node.js".'),
              actions: [
                if (winget || brew)
                  _btn(isMac ? tr('Pasang Node.js (Homebrew)') : tr('Pasang Node.js otomatis'), Icons.download_rounded, () async {
                    _log(isMac
                        ? trL('Memasang Node.js lewat Homebrew… (brew install node)')
                        : trL('Memasang Node.js LTS… (setujui jendela izin Windows kalau muncul)'));
                    await tool.installNode();
                    await _check();
                  }),
                if (isMac && !brew) _link(tr('Pasang Homebrew (brew.sh)'), 'https://brew.sh'),
                _link(isMac ? tr('Download installer (.pkg)') : tr('Download installer (.msi)'), 'https://nodejs.org/en/download'),
                _btn(tr('Sudah terpasang? Pilih folder Node.js'), Icons.folder_open_rounded, _pickNode, primary: false),
              ]),
          _status('Firebase CLI', firebase,
              help: npm != null
                  ? tr('Perintah: npm install -g firebase-tools (1–3 menit).')
                  : isMac
                      ? tr('Tanpa Node.js: installer resmi Firebase untuk macOS (curl -sL https://firebase.tools | bash). Terminal terbuka dan meminta password Mac.')
                      : tr('Pasang Node.js dulu (baris di atas), lalu tombol Pasang aktif.'),
              actions: [
                _btn(tr('Pasang Firebase CLI'), Icons.download_rounded, npm == null
                    ? null
                    : () async {
                        await tool.installFirebaseCli();
                        await _check();
                      }),
                if (isMac && npm == null)
                  _btn(tr('Pasang tanpa Node.js (installer resmi)'), Icons.terminal_rounded, () async {
                    _log(trL('Ketik password Mac di jendela Terminal. Setelah selesai klik "Cek lagi".'));
                    await tool.installFirebaseStandaloneMac();
                  }),
                _link(tr('Panduan resmi'),
                    isMac ? 'https://firebase.google.com/docs/cli#install-cli-mac-linux' : 'https://firebase.google.com/docs/cli#install-cli-windows'),
              ]),
          _status('FlutterFire CLI', flutterfire ? 'ok' : null,
              help: isMac
                  ? tr('Perintah: flutter pub global activate flutterfire_cli. Butuh Flutter terbaca — kalau gagal, isi lokasi flutter di Pengaturan → Tools di PC.')
                  : tr('Perintah: flutter pub global activate flutterfire_cli (tidak butuh Node.js).'),
              actions: [
                _btn(tr('Pasang FlutterFire CLI'), Icons.download_rounded, () async {
                  await tool.installFlutterFire();
                  await _check();
                }),
                _link(tr('Panduan resmi'), 'https://firebase.google.com/docs/flutter/setup'),
              ]),
          const SizedBox(height: 4),
          if (!toolsOk)
            Wrap(spacing: 8, runSpacing: 8, children: [
              _btn(tr('Pasang semua yang kurang'), Icons.auto_fix_high_rounded, _installAll),
              _btn(tr('Cek lagi'), Icons.refresh_rounded, _check, primary: false),
            ]),
          if (!toolsOk)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                isMac
                    ? tr('Kalau sudah dipasang tapi tetap ✖: tutup DeployHub (Cmd+Q) lalu buka lagi. DeployHub membaca PATH dari ~/.zshrc saat dibuka.')
                    : tr('Kalau sudah dipasang tapi tetap ✖: tutup VS Code / terminal sepenuhnya lalu jalankan DeployHub lagi, supaya PATH baru terbaca.'),
                style: YmTextStyles.bodySm,
              ),
            ),
        ],
      ]),
      _step(2, tr('Login ke Firebase'), loggedIn, locked: !toolsOk, children: [
        if (loggedIn) ...[
          _text(tr('Login sebagai: {0}', [loginEmail])),
          Wrap(spacing: 8, children: [
            _btn(tr('Ganti akun'), Icons.switch_account_rounded, () => _startLogin(reauth: true), primary: false),
          ]),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(color: YmColors.warningSoft, borderRadius: BorderRadius.circular(10)),
            child: Text(
              tr('Login di Firebase Console (browser) BERBEDA dengan login Firebase CLI. CLI harus login sendiri lewat jendela terminal — sekali saja, setelah itu tersimpan di PC.'),
              style: YmTextStyles.bodySm.copyWith(color: YmColors.onWarningSoft, fontWeight: FontWeight.w600),
            ),
          ),
          _text(tr('Yang terjadi setelah klik "Login Firebase":')),
          _text(tr('1. Jendela kecil Firebase Login terbuka di taskbar — biarkan saja, tidak perlu mengetik apa pun.')),
          _text(tr('2. Browser terbuka → pilih akun Google pemilik Firebase → klik "Allow / Izinkan".')),
          _text(tr('3. Browser menampilkan "Firebase CLI Login Successful".')),
          _text(tr('4. Jendela kecil itu menutup sendiri dan langkah ini jadi hijau otomatis.')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _btn(tr('Login Firebase'), Icons.login_rounded, toolsOk ? () => _startLogin() : null),
            _btn(tr('Login ulang (paksa)'), Icons.restart_alt_rounded, toolsOk ? () => _startLogin(reauth: true) : null, primary: false),
            _btn(tr('Cek lagi'), Icons.refresh_rounded, toolsOk ? _checkLogin : null, primary: false),
          ]),
          if (polling)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(child: Text(tr('Menunggu login selesai di terminal & browser…'), style: YmTextStyles.bodySm)),
              ]),
            ),
          if (tool.lastLoginOutput.isNotEmpty && !polling)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(tr('Hasil firebase login:list: {0}', [tool.lastLoginOutput.length > 300 ? '${tool.lastLoginOutput.substring(0, 300)}…' : tool.lastLoginOutput]),
                  style: YmTextStyles.bodySm.copyWith(fontFamily: 'monospace')),
            ),
        ],
      ]),
      _step(3, tr('Pilih atau buat project Firebase'), pid != null, locked: !loggedIn, children: [
        if (projects.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DropdownButtonFormField<String>(
              value: pid,
              isExpanded: true,
              decoration: fieldDecoration(tr('Project Firebase')),
              items: [
                for (final (id, name) in {for (final x in projects) x.$1: x}.values) DropdownMenuItem(value: id, child: Text('$name  ($id)')),
                // Project yang baru dibuat kadang belum muncul di daftar Firebase (perlu beberapa detik)
                if (pid != null && pid != '__new__' && !projects.any((x) => x.$1 == pid))
                  DropdownMenuItem(value: pid, child: Text('$pid  (${tr('baru dibuat')})')),
                DropdownMenuItem(
                  value: '__new__',
                  child: Row(children: [
                    Icon(Icons.add_circle_outline_rounded, size: 18, color: YmColors.primary),
                    const SizedBox(width: 8),
                    Text(tr('Buat project baru…'), style: TextStyle(color: YmColors.primary, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ],
              onChanged: (v) => setState(() {
                if (v == '__new__') {
                  creatingNew = true;
                  return;
                }
                creatingNew = false;
                projectId = v;
                userPicked = true;
              }),
            ),
          ),
        Wrap(spacing: 8, children: [
          _btn(tr('Muat daftar project'), Icons.refresh_rounded, loggedIn ? _loadProjects : null, primary: false),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: creatingNew || projects.isEmpty ? YmColors.primarySoft : YmColors.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: creatingNew ? YmColors.primary : Colors.transparent),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.add_circle_outline_rounded, size: 18, color: YmColors.primary),
              const SizedBox(width: 6),
              Text(tr('Buat project Firebase baru'), style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 4),
            _text(tr('ID sudah diisi otomatis dari package name — boleh diganti (huruf kecil, angka, tanda minus, 6–30 karakter, unik di seluruh dunia). Project dibuat di akun {0}, gratis (paket Spark).', [loginEmail ?? '-'])),
            fieldRow([
              DhField(newId, tr('ID project'), hint: 'batamchitchat-app'),
              DhField(newName, tr('Nama project'), hint: 'Batam ChitChat'),
            ]),
            Align(
              alignment: Alignment.centerLeft,
              child: _btn(tr('Buat project baru'), Icons.add_rounded, !loggedIn
                  ? null
                  : () async {
                      final id = newId.text.trim();
                      if (!RegExp(r'^[a-z][a-z0-9-]{5,29}$').hasMatch(id)) {
                        _log('✖ ${trL('ID project tidak valid')}');
                        return;
                      }
                      if (await tool.createProject(id, newName.text.trim().isEmpty ? id : newName.text.trim())) {
                        await _loadProjects();
                        setState(() {
                          projectId = id;
                          userPicked = true;
                          creatingNew = false;
                        });
                      } else {
                        _log('✖ ${trL('Gagal membuat project — ID mungkin sudah dipakai orang lain, coba ID lain.')}');
                      }
                    }),
            ),
          ]),
        ),
      ]),
      _step(4, tr('Buat konfigurasi otomatis'), configDone, locked: pid == null, children: [
        _text(tr('Menjalankan flutterfire configure: mendaftarkan aplikasi Android ({0}){1} di project Firebase, lalu membuat google-services.json, {2}dan lib/firebase_options.dart di folder project.', [
          widget.packageName,
          widget.useIos && widget.iosBundleId.isNotEmpty ? ' + iOS (${widget.iosBundleId})' : '',
          widget.useIos ? 'GoogleService-Info.plist, ' : '',
        ])),
        if (widget.packageName.isEmpty) _text('⚠ ${tr('Package name belum diisi di langkah Folder & nama')}'),
        _btn(tr('Buat konfigurasi'), Icons.auto_fix_high_rounded, pid == null || widget.packageName.isEmpty ? null : _configure),
      ]),
      _step(5, tr('Daftarkan SHA-1 (wajib untuk Login Google)'), false, locked: !hasAndroidConfig || pid == null, children: [
        _text(tr('Login Google di Android butuh SHA-1 upload key DAN SHA-1 App signing dari Play Console. Tanpa itu muncul error 10 di aplikasi dari Play Store.')),
        _text(tr('Belum pernah upload AAB? Kosongkan kolom App signing dan klik tombolnya sekarang (SHA-1 upload key saja). Setelah upload pertama, isi SHA-1 App signing lalu klik lagi.')),
        _text('${tr('SHA-1 upload key')}: ${uploadSha ?? tr('tidak terbaca (buat keystore dulu di langkah Folder & nama)')}'),
        DhField(signSha, tr('SHA-1 App signing (Play Console → Integritas aplikasi → Penandatanganan aplikasi)'), icon: Icons.fingerprint_rounded, hint: 'AB:CD:EF:...'),
        _btn(tr('Daftarkan SHA-1 & unduh ulang google-services.json'), Icons.fingerprint_rounded, pid == null ? null : _registerSha),
      ]),
      if (widget.googleLogin)
        _step(6, tr('Aktifkan Login Google di Firebase (1 menit, sekali saja)'), googleEnabled, locked: pid == null, children: [
          if (googleEnabled)
            _text(tr('✔ Login Google sudah aktif — google-services.json berisi Web client ID.'))
          else ...[
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(color: YmColors.primarySoft, borderRadius: BorderRadius.circular(10)),
              child: Text(
                tr('Kenapa tidak otomatis? Saat Login Google diaktifkan, Firebase membuat "Web client" OAuth beserta rahasianya. Google tidak menyediakan API untuk membuat itu dari luar Console, jadi langkah ini harus diklik sendiri — cukup sekali per aplikasi.'),
                style: YmTextStyles.bodySm.copyWith(color: YmColors.onPrimaryFixed),
              ),
            ),
            _text(tr('1. Klik "Buka Authentication" di bawah (browser terbuka di project {0}).', [pid ?? '-'])),
            _text(tr('2. Kalau muncul halaman perkenalan (video, "Learn more"), gulir ke ATAS lalu klik tombol "Get started" / "Mulai".')),
            _text(tr('3. Buka tab "Sign-in method" → di daftar penyedia klik "Google".')),
            _text(tr('4. Nyalakan saklar "Enable", pilih email dukungan project (email kamu), lalu klik "Save".')),
            _text(tr('5. Kembali ke sini dan klik "Cek & unduh ulang" — DeployHub mengunduh google-services.json terbaru dan memastikan Login Google sudah aktif.')),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                style: outlineButtonStyle(),
                onPressed: () => launchUrl(Uri.parse('$consoleUrl/authentication/providers')),
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(tr('Buka Authentication')),
              ),
              _btn(tr('Cek & unduh ulang'), Icons.refresh_rounded, pid == null ? null : _checkGoogleEnabled),
            ]),
          ],
        ]),
      GroupLabel(tr('Log')),
      Container(
        height: 180,
        decoration: BoxDecoration(color: const Color(0xFF0A0F1A), borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.all(10),
        child: ListView.builder(
          controller: scroll,
          itemCount: logs.length,
          itemBuilder: (_, i) => SelectableText(logs[i],
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.4, color: Color(0xFFD7DCE3))),
        ),
      ),
    ];
  }

  // ───────────────────────── manual
  List<Widget> _manual() {
    final pkg = widget.packageName.isEmpty ? 'com.contoh.aplikasi' : widget.packageName;
    Widget item(int n, String t, {String? url}) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: YmColors.primary, shape: BoxShape.circle),
              child: Text('$n', style: YmTextStyles.labelSm.copyWith(color: Colors.white)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Padding(padding: const EdgeInsets.only(top: 3), child: Text(t, style: YmTextStyles.bodyMd.copyWith(color: YmColors.textDark)))),
            if (url != null)
              TextButton.icon(onPressed: () => launchUrl(Uri.parse(url)), icon: const Icon(Icons.open_in_new_rounded, size: 15), label: Text(tr('Buka'))),
          ]),
        );
    return [
      item(1, tr('Buka Firebase Console → Add project / Tambahkan project → beri nama → (Google Analytics boleh dimatikan) → Create.'),
          url: 'https://console.firebase.google.com'),
      item(2, tr('Di halaman project klik ikon Android → Android package name: {0} → (opsional) isi SHA-1 → Register app.', [pkg])),
      item(3, tr('Download google-services.json, lalu taruh di folder:')),
      CodeBox('${widget.root.isEmpty ? r'D:\project' : widget.root}\\android\\app\\google-services.json', label: tr('Lokasi file')),
      item(4, tr('Project settings → Your apps → Android → Add fingerprint: tempel SHA-1 upload key dan SHA-1 App signing (Play Console → Integritas aplikasi). Lalu download ulang google-services.json.')),
      if (uploadSha != null) CodeBox(uploadSha!, label: tr('SHA-1 upload key kamu')),
      if (widget.useIos) ...[
        item(5, tr('Tambah aplikasi iOS → Bundle ID: {0} → download GoogleService-Info.plist → taruh di ios/Runner/ (di MacBook, tambahkan juga ke target Runner lewat Xcode).',
            [widget.iosBundleId.isEmpty ? 'com.contoh.aplikasi' : widget.iosBundleId])),
      ],
      if (widget.googleLogin)
        item(widget.useIos ? 6 : 5, tr('Authentication → Sign-in method → Google → Enable → Save. Lalu download ulang google-services.json.')),
      item(widget.useIos ? 7 : 6, tr('Pastikan plugin Google Services aktif di Android (biasanya sudah diatur otomatis oleh flutterfire). Kalau belum, tambahkan:')),
      const CodeBox('// android/settings.gradle(.kts) → plugins { }\nid("com.google.gms.google-services") version "4.4.2" apply false\n\n// android/app/build.gradle(.kts) → plugins { }\nid("com.google.gms.google-services")',
          label: 'Gradle'),
      item(widget.useIos ? 8 : 7, tr('Di main.dart panggil Firebase.initializeApp() sebelum runApp().')),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final configDone = hasAndroidConfig && (!widget.useIos || hasIosConfig);
    return DhDialog(
      title: tr('Siapkan Firebase'),
      subtitle: configDone ? tr('Konfigurasi sudah ada di project') : tr('Paket Firebase dipakai, tapi file konfigurasinya belum ada'),
      icon: Icons.local_fire_department_outlined,
      width: 860,
      height: 740,
      actions: [
        ElevatedButton(
          style: primaryButtonStyle(),
          onPressed: () => Navigator.pop(context, changed || hasAndroidConfig ? 'rescan' : null),
          child: Text(tr('Tutup')),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: configDone ? YmColors.successSoft : YmColors.warningSoft, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Icon(configDone ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                color: configDone ? YmColors.onSuccessSoft : YmColors.onWarningSoft),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                configDone
                    ? tr('google-services.json{0} sudah ada. Kamu bisa menambah SHA-1 atau mengaktifkan Login Google di bawah.', [widget.useIos ? ' + GoogleService-Info.plist' : ''])
                    : tr('Tanpa google-services.json, build Android gagal ("File google-services.json is missing") atau aplikasi crash saat Firebase.initializeApp().'),
                style: YmTextStyles.bodySm.copyWith(color: configDone ? YmColors.onSuccessSoft : YmColors.onWarningSoft),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          QuickChip(label: tr('Otomatis (disarankan)'), icon: Icons.auto_fix_high_rounded, selected: mode == 'auto', onTap: () => setState(() => mode = 'auto')),
          QuickChip(label: tr('Manual langkah demi langkah'), icon: Icons.list_alt_rounded, selected: mode == 'manual', onTap: () => setState(() => mode = 'manual')),
        ]),
        const SizedBox(height: 12),
        Expanded(child: ListView(children: mode == 'auto' ? _auto() : _manual())),
      ]),
    );
  }
}
