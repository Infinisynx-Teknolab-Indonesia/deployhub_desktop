import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/asc_api.dart';
import '../services/github_service.dart';
import '../services/mac_service.dart';
import '../services/play_auth.dart';
import '../services/storage.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';
import 'automation_panels.dart';
import 'hub_panel.dart';
import 'integrations_panel.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings s = app.settings.copy();
  late final c = <String, TextEditingController>{
    'playSa': TextEditingController(text: s.playServiceAccountPath),
    'playClientId': TextEditingController(text: s.playOAuthClientId),
    'playClientSecret': TextEditingController(),
    'playTestPackage': TextEditingController(text: s.playTestPackage),
    'github': TextEditingController(),
    'ascKeyId': TextEditingController(text: s.ascKeyId),
    'ascIssuerId': TextEditingController(text: s.ascIssuerId),
    'ascP8': TextEditingController(text: s.ascP8Path),
    'macHost': TextEditingController(text: s.macHost),
    'macPort': TextEditingController(text: '${s.macPort}'),
    'macUser': TextEditingController(text: s.macUser),
    'macKey': TextEditingController(text: s.macKeyPath),
    'macPassword': TextEditingController(),
    'tgToken': TextEditingController(),
    'tgChat': TextEditingController(text: s.telegramChatId),
    'flutter': TextEditingController(text: s.flutterCmd),
    'git': TextEditingController(text: s.gitCmd),
    'keytool': TextEditingController(text: s.keytoolCmd),
    'minSdk': TextEditingController(text: '${s.minTargetSdk}'),
    'appName': TextEditingController(text: ThemeCtl.instance.appName),
    'tagline': TextEditingController(text: ThemeCtl.instance.tagline),
  };
  bool playLoggedIn = false;
  String? busy;

  @override
  void initState() {
    super.initState();
    () async {
      c['playClientSecret']!.text = await Storage.secret(Secrets.playOAuthSecret);
      c['github']!.text = await Storage.secret(Secrets.github);
      c['macPassword']!.text = await Storage.secret(Secrets.macPassword);
      c['tgToken']!.text = await Storage.secret(Secrets.telegram);
      final creds = await Storage.secret(Secrets.playOAuthCreds);
      if (mounted) setState(() => playLoggedIn = creds.isNotEmpty);
    }();
  }

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  String v(String k) => c[k]!.text.trim();

  AppSettings _collect() => s
    ..playServiceAccountPath = v('playSa')
    ..playOAuthClientId = v('playClientId')
    ..playTestPackage = v('playTestPackage')
    ..ascKeyId = v('ascKeyId')
    ..ascIssuerId = v('ascIssuerId')
    ..ascP8Path = v('ascP8')
    ..macHost = v('macHost')
    ..macPort = int.tryParse(v('macPort')) ?? 22
    ..macUser = v('macUser')
    ..macKeyPath = v('macKey')
    ..telegramChatId = v('tgChat')
    ..flutterCmd = v('flutter').isEmpty ? 'flutter' : v('flutter')
    ..gitCmd = v('git').isEmpty ? 'git' : v('git')
    ..keytoolCmd = v('keytool').isEmpty ? 'keytool' : v('keytool')
    ..minTargetSdk = int.tryParse(v('minSdk')) ?? 36;

  Future<void> _save({bool quiet = false}) async {
    await app.saveSettings(_collect().copy());
    await Storage.setSecret(Secrets.github, v('github'));
    await Storage.setSecret(Secrets.macPassword, c['macPassword']!.text);
    await Storage.setSecret(Secrets.telegram, v('tgToken'));
    await Storage.setSecret(Secrets.playOAuthSecret, v('playClientSecret'));
    if (!quiet && mounted) showSnack(context, tr('Pengaturan disimpan'));
  }

  Future<void> _run(String name, Future<String> Function() fn) async {
    setState(() => busy = name);
    try {
      await _save(quiet: true);
      final out = await fn();
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => DhDialog(
          title: tr('{0} berhasil', [name]),
          icon: Icons.check_circle_outline_rounded,
          width: 560,
          actions: [ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
          child: SelectableText(out, style: YmTextStyles.chatText.copyWith(fontFamily: 'Consolas')),
        ),
      );
    } catch (e) {
      if (mounted) showSnack(context, '${tr('{0} gagal', [name])}: $e', error: true);
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Widget _btn(String name, IconData icon, Future<String> Function() fn, {bool primary = false}) {
    final child = busy == name
        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(icon);
    return primary
        ? ElevatedButton.icon(
            style: primaryButtonStyle(), onPressed: busy != null ? null : () => _run(name, fn), icon: child, label: Text(name))
        : OutlinedButton.icon(
            style: outlineButtonStyle(), onPressed: busy != null ? null : () => _run(name, fn), icon: child, label: Text(name));
  }

  Widget _pick(String key, String title, {List<String>? ext}) => IconButton(
        tooltip: tr('Pilih file'),
        icon: const Icon(Icons.file_open_outlined),
        onPressed: () async {
          final r = await FilePicker.platform.pickFiles(
              dialogTitle: title, type: ext == null ? FileType.any : FileType.custom, allowedExtensions: ext);
          final path = r?.files.single.path;
          if (path != null) setState(() => c[key]!.text = path);
        },
      );

  Widget _help(String text) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lightbulb_outline_rounded, size: 18, color: YmColors.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: YmTextStyles.bodySm.copyWith(height: 1.55))),
        ]),
      );

  // ───────────────────────── Google Play
  bool showPlaySetup = false;

  Widget _setupStep(int n, String text, {String? url, String? button}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: YmColors.primary, shape: BoxShape.circle),
            child: Text('$n', style: YmTextStyles.labelSm.copyWith(color: YmColors.onPrimary)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Padding(padding: const EdgeInsets.only(top: 3), child: Text(text, style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark, height: 1.5)))),
          if (url != null) ...[
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () => launchUrl(Uri.parse(url)),
              icon: const Icon(Icons.open_in_new_rounded, size: 15),
              label: Text(button ?? tr('Buka')),
            ),
          ],
        ]),
      );

  Widget _playPanel() {
    final oauth = s.playAuthMode == 'oauth';
    final hasClient = v('playClientId').isNotEmpty;
    final setupOpen = showPlaySetup || !hasClient;

    final loginCard = Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: playLoggedIn ? YmColors.successSoft : YmColors.primarySoft,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: YmColors.surface, borderRadius: BorderRadius.circular(14), boxShadow: shadowSm),
          child: Icon(playLoggedIn ? Icons.verified_user_rounded : Icons.shop_rounded,
              size: 28, color: playLoggedIn ? YmColors.success : YmColors.primary),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(playLoggedIn ? tr('Terhubung ke Google Play') : tr('Login ke Google Play'),
                style: YmTextStyles.headlineSm.copyWith(color: playLoggedIn ? YmColors.onSuccessSoft : YmColors.onPrimaryFixed)),
            const SizedBox(height: 2),
            Text(
              playLoggedIn
                  ? (s.playOAuthEmail.isEmpty ? tr('Sudah login') : tr('Login sebagai: {0}', [s.playOAuthEmail]))
                  : tr('Browser akan terbuka → pilih akun Google pemilik Play Console → Izinkan → kembali ke DeployHub.'),
              style: YmTextStyles.bodySm.copyWith(color: playLoggedIn ? YmColors.onSuccessSoft : YmColors.onPrimaryFixed),
            ),
          ]),
        ),
        const SizedBox(width: 12),
        if (playLoggedIn)
          OutlinedButton.icon(
            style: outlineButtonStyle(),
            onPressed: () async {
              await PlayAuth.logout();
              s.playOAuthEmail = '';
              await _save(quiet: true);
              setState(() => playLoggedIn = false);
            },
            icon: const Icon(Icons.logout_rounded),
            label: Text(tr('Logout')),
          )
        else
          ElevatedButton.icon(
            style: primaryButtonStyle(),
            onPressed: busy != null
                ? null
                : () {
                    if (!hasClient) {
                      setState(() => showPlaySetup = true);
                      showSnack(context, tr('Isi OAuth Client ID dulu (langkah persiapan di bawah, cukup sekali).'), error: true);
                      return;
                    }
                    _run(tr('Login dengan Google'), () async {
                      final email = await PlayAuth.login(v('playClientId'), v('playClientSecret'));
                      s.playOAuthEmail = email;
                      await _save(quiet: true);
                      if (mounted) setState(() => playLoggedIn = true);
                      return tr('Login sebagai: {0}', [email.isEmpty ? '-' : email]);
                    });
                  },
            icon: busy == tr('Login dengan Google')
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.login_rounded),
            label: Text(tr('Login dengan Google')),
          ),
      ]),
    );

    return Panel(
      title: 'Google Play',
      subtitle: tr('Akses resmi Google Play Developer API untuk upload AAB, listing, tester, dan Keamanan Data.'),
      icon: Icons.shop_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (oauth) ...[
          loginCard,
          const SizedBox(height: 14),
          // ---- persiapan sekali saja (OAuth Client ID)
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: hasClient ? () => setState(() => showPlaySetup = !showPlaySetup) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Icon(hasClient ? Icons.check_circle_rounded : Icons.build_circle_outlined,
                    size: 18, color: hasClient ? YmColors.success : YmColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hasClient ? tr('Persiapan sekali saja: OAuth Client ID sudah diisi') : tr('Persiapan sekali saja (±5 menit): buat OAuth Client ID'),
                    style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (hasClient) Icon(setupOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: YmColors.outline),
              ]),
            ),
          ),
          if (setupOpen) ...[
            const SizedBox(height: 8),
            Text(
              tr('Google mewajibkan setiap aplikasi desktop punya OAuth Client ID sendiri untuk login. Ini dibuat di akun Google Cloud kamu, gratis, cukup sekali.'),
              style: YmTextStyles.bodySm,
            ),
            const SizedBox(height: 12),
            _setupStep(1, tr('Aktifkan "Google Play Android Developer API" di Google Cloud (buat project baru kalau belum ada).'),
                url: 'https://console.cloud.google.com/apis/library/androidpublisher.googleapis.com', button: tr('Buka')),
            _setupStep(2, tr('Buka OAuth consent screen → User type: External → isi nama aplikasi & email → tambahkan email kamu di Test users. Lalu klik "Publish app" supaya login tidak kedaluwarsa tiap 7 hari.'),
                url: 'https://console.cloud.google.com/apis/credentials/consent', button: tr('Buka')),
            _setupStep(3, tr('Credentials → Create credentials → OAuth client ID → Application type: Desktop app → Create.'),
                url: 'https://console.cloud.google.com/apis/credentials', button: tr('Buka')),
            _setupStep(4, tr('Salin Client ID dan Client Secret ke kolom di bawah, lalu klik "Login dengan Google" di atas.')),
            const SizedBox(height: 4),
            fieldRow([
              DhField(c['playClientId']!, 'OAuth Client ID',
                  icon: Icons.badge_outlined, hint: '1234-abc.apps.googleusercontent.com', onChanged: (_) => setState(() {})),
              DhField(c['playClientSecret']!, 'Client Secret', icon: Icons.password_rounded, obscure: true),
            ], flex: [3, 2]),
            Text(
              tr('Saat login muncul "Google belum memverifikasi aplikasi ini"? Itu normal untuk aplikasi milik sendiri — klik Lanjutan → Buka (tidak aman) → Izinkan.'),
              style: YmTextStyles.bodySm,
            ),
          ],
        ] else ...[
          _help(tr(
              'Cara standar CI/CD tanpa browser. Google Cloud → IAM → Service Accounts → buat key JSON. Lalu Play Console → Pengguna dan izin → undang email service account dengan izin rilis.')),
          DhField(c['playSa']!, tr('File Service Account JSON (bawaan semua proyek)'),
              icon: Icons.description_outlined, suffix: _pick('playSa', 'Service Account JSON', ext: ['json'])),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: c['playSa']!,
            builder: (_, v, __) => _jsonKindHint(v.text.trim()),
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => s.playAuthMode = oauth ? 'service' : 'oauth'),
            icon: Icon(oauth ? Icons.key_outlined : Icons.account_circle_outlined, size: 18),
            label: Text(oauth ? tr('Cara lain: pakai Service Account JSON (tanpa browser)') : tr('Kembali ke Login dengan Google')),
          ),
        ),
        Divider(color: YmColors.line),
        const SizedBox(height: 12),
        fieldRow([
          DhField(c['playTestPackage']!, tr('Package untuk tes koneksi'), icon: Icons.android_rounded, hint: 'com.batamchitchat.app'),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _btn(tr('Tes Google Play'), Icons.wifi_tethering_rounded, () async {
                if (v('playTestPackage').isEmpty) throw Exception(tr('Isi package untuk tes'));
                return PlayAuth.test(v('playTestPackage'));
              }),
            ),
          ),
        ], flex: [3, 2]),
      ]),
    );
  }

  // ───────────────────────── App Store Connect
  bool showAscSetup = false;

  Widget _ascPanel() {
    final connected = s.ascVerifiedTeam.isNotEmpty;
    final complete = v('ascKeyId').isNotEmpty && v('ascIssuerId').isNotEmpty && v('ascP8').isNotEmpty;
    final setupOpen = showAscSetup || !connected;

    Future<String> connect() async {
      final api = AscApi(v('ascKeyId'), v('ascIssuerId'), await File(v('ascP8')).readAsString());
      final apps = await api.apps();
      s.ascVerifiedTeam = tr('{0} aplikasi', [apps.length]);
      await _save(quiet: true);
      if (mounted) setState(() {});
      final lines = <String>[
        tr('Terhubung ke App Store Connect — {0} aplikasi:', [apps.length]),
        for (final (_, name, bundle) in apps.take(15)) '• $name  ($bundle)',
      ];
      if (apps.isNotEmpty) {
        final (id, name, _) = apps.first;
        final vs = await api.versions(id, limit: 1);
        final bs = await api.latestBuilds(id, limit: 1);
        lines.add('');
        lines.add('$name:');
        if (vs.isNotEmpty) lines.add('  App Store ${vs.first.$1}: ${ascStateText(vs.first.$2)}');
        if (bs.isNotEmpty) lines.add('  ${tr('Build terakhir')} ${bs.first.$1}: ${ascStateText(bs.first.$2)}');
      }
      return lines.join('\n');
    }

    final card = Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: connected ? YmColors.successSoft : YmColors.primarySoft, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: YmColors.surface, borderRadius: BorderRadius.circular(14), boxShadow: shadowSm),
          child: Icon(connected ? Icons.verified_user_rounded : Icons.apple, size: 28, color: connected ? YmColors.success : YmColors.textDark),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(connected ? tr('Terhubung ke App Store Connect') : tr('Hubungkan App Store Connect'),
                style: YmTextStyles.headlineSm.copyWith(color: connected ? YmColors.onSuccessSoft : YmColors.onPrimaryFixed)),
            const SizedBox(height: 2),
            Text(
              connected
                  ? tr('Key {0} • {1}', [s.ascKeyId, s.ascVerifiedTeam])
                  : tr('Apple tidak memakai login Apple ID untuk alat otomatis. Yang resmi adalah API key (.p8) — sekali buat, dipakai terus, tanpa 2FA.'),
              style: YmTextStyles.bodySm.copyWith(color: connected ? YmColors.onSuccessSoft : YmColors.onPrimaryFixed),
            ),
          ]),
        ),
        const SizedBox(width: 12),
        if (connected)
          OutlinedButton.icon(
            style: outlineButtonStyle(),
            onPressed: () async {
              s.ascVerifiedTeam = '';
              await _save(quiet: true);
              setState(() => showAscSetup = true);
            },
            icon: const Icon(Icons.link_off_rounded),
            label: Text(tr('Putuskan')),
          )
        else
          ElevatedButton.icon(
            style: primaryButtonStyle(),
            onPressed: busy != null
                ? null
                : () {
                    if (!complete) {
                      showSnack(context, tr('Isi Key ID, Issuer ID, dan pilih file .p8 dulu (langkah di bawah).'), error: true);
                      return;
                    }
                    _run(tr('Hubungkan App Store Connect'), connect);
                  },
            icon: busy == tr('Hubungkan App Store Connect')
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.login_rounded),
            label: Text(tr('Hubungkan')),
          ),
      ]),
    );

    return Panel(
      title: 'App Store Connect',
      subtitle: tr('Untuk TestFlight, review, dan rilis App Store. Bisa dicek langsung dari PC; build & upload IPA tetap lewat MacBook.'),
      icon: Icons.apple,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        card,
        const SizedBox(height: 14),
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: connected ? () => setState(() => showAscSetup = !showAscSetup) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Icon(complete ? Icons.check_circle_rounded : Icons.build_circle_outlined, size: 18, color: complete ? YmColors.success : YmColors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(complete ? tr('API key sudah diisi') : tr('Persiapan sekali saja (±3 menit): buat API key App Store Connect'),
                    style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w600)),
              ),
              if (connected) Icon(setupOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: YmColors.outline),
            ]),
          ),
        ),
        if (setupOpen) ...[
          const SizedBox(height: 8),
          Text(tr('Butuh akun Apple Developer Program (berbayar per tahun) dengan peran Admin / Account Holder untuk membuat key.'), style: YmTextStyles.bodySm),
          const SizedBox(height: 12),
          _setupStep(1, tr('Buka App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys.'),
              url: 'https://appstoreconnect.apple.com/access/integrations/api', button: tr('Buka')),
          _setupStep(2, tr('Klik "+" (Generate API Key) → beri nama, mis. DeployHub → Access: App Manager → Generate.')),
          _setupStep(3, tr('Klik "Download API Key" → file AuthKey_XXXXXXXXXX.p8. PENTING: file ini hanya bisa didownload SEKALI, simpan baik-baik.')),
          _setupStep(4, tr('Salin Key ID (kolom di tabel) dan Issuer ID (di atas tabel) ke bawah, pilih file .p8, lalu klik "Hubungkan".')),
          const SizedBox(height: 4),
          fieldRow([
            DhField(c['ascKeyId']!, 'Key ID', icon: Icons.badge_outlined, hint: 'ABC123DEFG', onChanged: (_) => setState(() {})),
            DhField(c['ascIssuerId']!, 'Issuer ID',
                icon: Icons.fingerprint_rounded, hint: '69a6de7f-xxxx-xxxx-xxxx-xxxxxxxxxxxx', onChanged: (_) => setState(() {})),
          ], flex: [2, 3]),
          DhField(c['ascP8']!, tr('File AuthKey_XXXX.p8'), icon: Icons.description_outlined, suffix: _pick('ascP8', 'AuthKey .p8', ext: ['p8'])),
          Text(tr('File .p8 juga dipasang otomatis ke MacBook saat deploy iOS.'), style: YmTextStyles.bodySm),
        ],
        if (connected) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: _btn(tr('Cek aplikasi & status review'), Icons.wifi_tethering_rounded, connect),
          ),
        ],
      ]),
    );
  }

  /// Cek isi file JSON: Service Account atau malah file OAuth client (client_secret_….json)?
  Widget _jsonKindHint(String path) {
    if (path.isEmpty) return const SizedBox.shrink();
    Map? j;
    try {
      final d = jsonDecode(File(path).readAsStringSync());
      if (d is Map) j = d;
    } catch (_) {}
    Widget box(Color bg, Color fg, IconData icon, String text, [Widget? action]) => Container(
          margin: const EdgeInsets.only(top: 4, bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Icon(icon, color: fg, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: YmTextStyles.bodySm.copyWith(color: fg, fontWeight: FontWeight.w600))),
            if (action != null) ...[const SizedBox(width: 8), action],
          ]),
        );
    if (j == null) {
      return box(YmColors.dangerSoft, YmColors.onDangerSoft, Icons.error_outline_rounded, tr('File tidak ditemukan atau bukan JSON yang valid.'));
    }
    final client = (j['installed'] ?? j['web']) as Map?;
    if (client != null) {
      return box(
        YmColors.warningSoft,
        YmColors.onWarningSoft,
        Icons.warning_amber_rounded,
        tr('Ini file OAuth client (client_secret_….json), BUKAN Service Account. File ini dipakai untuk "Login dengan Google". Klik tombol di kanan supaya Client ID & Secret terisi otomatis.'),
        ElevatedButton(
          style: primaryButtonStyle(),
          onPressed: () async {
            c['playClientId']!.text = '${client['client_id'] ?? ''}';
            c['playClientSecret']!.text = '${client['client_secret'] ?? ''}';
            c['playSa']!.text = '';
            setState(() => s.playAuthMode = 'oauth');
            await _save(quiet: true);
            if (mounted) showSnack(context, tr('Client ID & Secret terisi. Sekarang klik "Login dengan Google".'));
          },
          child: Text(tr('Pakai untuk Login Google')),
        ),
      );
    }
    if (j['type'] == 'service_account') {
      return box(YmColors.successSoft, YmColors.onSuccessSoft, Icons.check_circle_rounded,
          tr('Service Account: {0}. Pastikan email ini sudah diundang di Play Console → Pengguna dan izin.', [j['client_email'] ?? '-']));
    }
    return box(YmColors.warningSoft, YmColors.onWarningSoft, Icons.help_outline_rounded, tr('JSON ini bukan file Service Account (tidak ada "type": "service_account").'));
  }

  // ───────────────────────── Tampilan & bahasa
  Widget _appearancePanel() {
    final t = ThemeCtl.instance;
    Future<void> apply(Future<void> Function() fn) async {
      await _save(quiet: true); // isian tidak hilang saat layar digambar ulang
      nav.value = 'settings';
      await fn();
    }

    return Panel(
      title: tr('Tampilan & bahasa'),
      subtitle: tr('Berlaku untuk PC ini saja. Pilihan tersimpan otomatis.'),
      icon: Icons.palette_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GroupLabel(tr('Nama aplikasi')),
        fieldRow([
          DhField(c['appName']!, tr('Nama aplikasi'), icon: Icons.badge_outlined, hint: 'DeployHub'),
          DhField(c['tagline']!, tr('Teks di bawah nama'), icon: Icons.short_text_rounded, hint: tr('CI/CD aplikasi Flutter')),
        ], flex: [2, 3]),
        Text(tr('Tampil di top bar, title bar, jendela, sidebar, dan ikon system tray. Kosongkan teks di bawah nama untuk memakai bawaan (ikut bahasa).'),
            style: YmTextStyles.bodySm),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          ElevatedButton.icon(
            style: primaryButtonStyle(),
            onPressed: () => apply(() => t.setBranding(c['appName']!.text, c['tagline']!.text)),
            icon: const Icon(Icons.check_rounded),
            label: Text(tr('Terapkan nama')),
          ),
          OutlinedButton.icon(
            style: outlineButtonStyle(),
            onPressed: () {
              c['appName']!.text = 'DeployHub';
              c['tagline']!.text = '';
              apply(() => t.setBranding('DeployHub', ''));
            },
            icon: const Icon(Icons.restart_alt_rounded),
            label: Text(tr('Kembalikan bawaan')),
          ),
        ]),
        const SizedBox(height: 16),
        GroupLabel(tr('Bahasa')),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (code, label) in [
            ('id', 'Bahasa Indonesia'),
            ('en', 'English'),
            ('both', 'Bilingual (English / Indonesia)'),
          ])
            QuickChip(
              label: label,
              icon: Icons.translate_rounded,
              selected: t.lang == code,
              onTap: () => apply(() => t.setLang(code)),
            ),
        ]),
        const SizedBox(height: 16),
        GroupLabel(tr('Tema warna')),
        LayoutBuilder(builder: (context, cs) {
          final w = (cs.maxWidth - 12 * 2) / 3;
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (final p in appPalettes)
              SizedBox(width: w, child: _ThemeTile(p: p, selected: p.id == t.palette.id, onTap: () => apply(() => t.set(p.id)))),
          ]);
        }),
        const SizedBox(height: 12),
        SettingRow(
          title: tr('Kurangi animasi'),
          subtitle: tr('Matikan efek geser, pudar, dan angka berjalan. Cocok untuk PC yang lambat.'),
          trailing: Switch(value: t.lessMotion, onChanged: (v) => t.setLessMotion(v)),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageBody(
      maxWidth: 1100,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          crumbs: [appName, tr('Pengaturan')],
          title: tr('Pengaturan'),
          subtitle: tr('Akun & koneksi (Google Play, GitHub, App Store Connect, MacBook), tampilan, bahasa, dan tools di PC. Token & password disimpan aman di Windows Credential Manager.'),
          actions: [
            ElevatedButton.icon(
                style: primaryButtonStyle(), onPressed: _save, icon: const Icon(Icons.save_outlined), label: Text(tr('Simpan'))),
          ],
        ),
        const SizedBox(height: 24),
        GroupLabel(tr('Akun & koneksi')),
        Reveal(child: _playPanel()),
        const SizedBox(height: 18),
        Reveal(child: _ascPanel()),
        const SizedBox(height: 18),
        Reveal(
          index: 1,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Panel(
                title: 'GitHub',
                subtitle: tr('Tag, release, dan menjalankan GitHub Actions.'),
                icon: Icons.hub_outlined,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  DhField(c['github']!, 'Personal Access Token',
                      icon: Icons.key_outlined, obscure: true, hint: 'github_pat_...'),
                  Text(tr('Izin fine-grained: Contents & Actions = Read and write.'), style: YmTextStyles.bodySm),
                  const SizedBox(height: 12),
                  Row(children: [
                    if (s.githubUser.isNotEmpty) SoftChip.success('@${s.githubUser}', icon: Icons.verified_user_outlined),
                    const Spacer(),
                    _btn(tr('Tes GitHub'), Icons.wifi_tethering_rounded, () async {
                      final user = await GitHubService(v('github')).currentUser();
                      s.githubUser = user;
                      await _save(quiet: true);
                      if (mounted) setState(() {});
                      return tr('Login sebagai: {0}', [user]);
                    }),
                  ]),
                ]),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Panel(
                title: tr('Tools di PC'),
                icon: Icons.terminal_rounded,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  DhField(c['flutter']!, tr('Perintah Flutter'), icon: Icons.flutter_dash, hint: r'C:\flutter\bin\flutter.bat'),
                  DhField(c['git']!, tr('Perintah Git'), icon: Icons.merge_type_rounded, hint: 'git'),
                  DhField(c['keytool']!, tr('Perintah keytool (cek SHA-1)'),
                      icon: Icons.key_outlined, hint: r'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe'),
                  DhField(c['minSdk']!, tr('targetSdk minimal Google Play'), icon: Icons.android_rounded, keyboard: TextInputType.number),
                ]),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 18),
        Reveal(
          index: 2,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Panel(
                title: 'MacBook (SSH)',
                subtitle: tr('Build iOS dijalankan di MacBook lewat SSH.'),
                icon: Icons.laptop_mac_rounded,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  fieldRow([
                    DhField(c['macHost']!, tr('Host / IP'), icon: Icons.lan_outlined, hint: '192.168.1.20'),
                    DhField(c['macPort']!, 'Port', keyboard: TextInputType.number),
                  ], flex: [3, 1]),
                  DhField(c['macUser']!, tr('Username Mac'), icon: Icons.person_outline_rounded),
                  DhField(c['macKey']!, tr('Private key SSH (opsional)'),
                      icon: Icons.vpn_key_outlined, suffix: _pick('macKey', 'SSH private key')),
                  DhField(c['macPassword']!, tr('Password Mac (login & unlock keychain)'), icon: Icons.password_rounded, obscure: true),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _btn(tr('Tes SSH MacBook'), Icons.wifi_tethering_rounded,
                        () => MacService.check(_collect().copy(), c['macPassword']!.text)),
                  ),
                ]),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Panel(
                title: 'Telegram',
                subtitle: tr('Notifikasi hasil deploy ke HP (opsional).'),
                icon: Icons.send_outlined,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  DhField(c['tgToken']!, 'Bot token', icon: Icons.smart_toy_outlined, obscure: true, hint: '123456:ABC...'),
                  DhField(c['tgChat']!, 'Chat ID', icon: Icons.chat_outlined, hint: '123456789'),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _btn(tr('Tes Telegram'), Icons.wifi_tethering_rounded, () async {
                      await Telegram.send(v('tgToken'), v('tgChat'), '🔔 DeployHub ✔');
                      return tr('Pesan tes terkirim ke Telegram');
                    }),
                  ),
                ]),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 24),
        GroupLabel(tr('DeployHub Server (CI/CD 24 jam)')),
        const Reveal(index: 2, child: HubPanel()),
        const SizedBox(height: 18),
        GroupLabel(tr('DevOps & integrasi')),
        const Reveal(index: 2, child: IntegrationsPanel()),
        const SizedBox(height: 18),
        GroupLabel(tr('AI perbaikan otomatis')),
        const Reveal(index: 2, child: AiPanel()),
        const SizedBox(height: 18),
        GroupLabel(tr('Server & infrastruktur')),
        const Reveal(index: 2, child: ServerOpsPanel()),
        const SizedBox(height: 18),
        GroupLabel(tr('Infrastructure as Code')),
        const Reveal(index: 2, child: InfraPanel()),
        const SizedBox(height: 24),
        GroupLabel(tr('Aplikasi')),
        Reveal(index: 3, child: _appearancePanel()),
        const SizedBox(height: 18),
        Reveal(
          index: 5,
          child: Panel(
            title: tr('Tentang'),
            icon: Icons.info_outline_rounded,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const DhLogo(size: 52),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(appName, style: YmTextStyles.headline),
                  Text(tr('Versi {0}', ['1.25.0']), style: YmTextStyles.label.copyWith(fontSize: 12.5)),
                  const SizedBox(height: 6),
                  Text(
                    tr('CI/CD desktop untuk aplikasi Flutter: build, cek kelayakan rilis, upload ke Google Play & TestFlight, sinkron listing, dan GitHub dalam satu aplikasi.'),
                    style: YmTextStyles.chatText.copyWith(fontSize: 12.5),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _ThemeTile extends StatefulWidget {
  const _ThemeTile({required this.p, required this.selected, required this.onTap});
  final AppPalette p;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ThemeTile> createState() => _ThemeTileState();
}

class _ThemeTileState extends State<_ThemeTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: motion(context, const Duration(milliseconds: 150)),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: YmColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: widget.selected ? YmColors.primary : (_hover ? YmColors.outlineVariant : YmColors.line),
                width: widget.selected ? 2 : 1),
          ),
          child: Row(children: [
            Container(
              width: 56,
              height: 40,
              decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
              padding: const EdgeInsets.all(5),
              child: Row(children: [
                Container(width: 12, decoration: BoxDecoration(color: p.sidebar, borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(children: [
                    Container(height: 8, decoration: BoxDecoration(color: p.primary, borderRadius: BorderRadius.circular(3))),
                    const SizedBox(height: 4),
                    Expanded(child: Container(decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(3)))),
                  ]),
                ),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: YmTextStyles.username),
                Text(tr(p.note), style: YmTextStyles.bodySm, maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (widget.selected) Icon(Icons.check_circle_rounded, color: YmColors.primary, size: 20),
          ]),
        ),
      ),
    );
  }
}
