import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/android_pipeline.dart';
import '../services/ios_pipeline.dart';
import '../services/play_service.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

const tracks = ['internal', 'alpha', 'beta', 'production'];

String trackLabel(String t) => switch (t) {
      'internal' => tr('internal (pengujian internal)'),
      'alpha' => tr('alpha (pengujian tertutup)'),
      'beta' => tr('beta (pengujian terbuka)'),
      _ => tr('production (rilis publik)'),
    };

class AndroidDeployDialog extends StatefulWidget {
  const AndroidDeployDialog({super.key, required this.project, this.initialTrack, this.buildOnly = false});
  final Project project;
  final String? initialTrack;
  final bool buildOnly; // true = hanya buat file .aab, tanpa upload

  @override
  State<AndroidDeployDialog> createState() => _AndroidDeployDialogState();
}

class _AndroidDeployDialogState extends State<AndroidDeployDialog> {
  late final AndroidOptions o = AndroidOptions(
    track: tracks.contains(widget.initialTrack)
        ? widget.initialTrack!
        : (tracks.contains(widget.project.defaultTrack) ? widget.project.defaultTrack : 'internal'),
    upload: !widget.buildOnly,
    // Aplikasi sudah live: hanya update AAB → tanpa analyze/test, listing tidak disinkron.
    analyze: !widget.project.alreadyLive,
    test: !widget.project.alreadyLive,
    syncStore: !widget.buildOnly && !widget.project.alreadyLive,
    bumpVersion: !widget.buildOnly,
  );

  /// Penjelasan "apa yang terjadi" untuk pilihan saat ini.
  (IconData, String) get _outcome {
    if (!o.upload) return (Icons.inventory_2_outlined, tr('Hanya build file .aab di PC. Tidak ada yang dikirim ke Google Play.'));
    final draft = o.releaseStatus == 'draft';
    final base = switch (o.track) {
      'internal' => tr('AAB diupload ke Pengujian internal. Dalam beberapa menit bisa diinstall tester internal lewat Play Store. TIDAK tampil untuk publik.'),
      'alpha' => tr('AAB diupload ke Pengujian tertutup (alpha). Hanya tester di Google Group yang bisa install. Biasanya direview Google dulu.'),
      'beta' => tr('AAB diupload ke Pengujian terbuka (beta). Siapa pun bisa ikut jadi tester dari halaman Play Store. Direview Google dulu.'),
      _ => tr('AAB diupload ke Production. Google mereview beberapa jam sampai beberapa hari, setelah lolos tampil di Play Store untuk SEMUA orang.'),
    };
    return (o.track == 'production' ? Icons.public_rounded : Icons.science_outlined,
        draft ? '$base ${tr('Status draft: rilis disiapkan tapi belum dikirim — kamu klik "Kirim untuk ditinjau" sendiri di Play Console.')}' : base);
  }
  final notes = TextEditingController();

  @override
  void initState() {
    super.initState();
    o.mode = o.track == 'internal' ? 'internal' : 'production';
    _detectFirstRelease();
  }

  @override
  void dispose() {
    notes.dispose();
    super.dispose();
  }

  // Mode Produksi boleh ke semua track (termasuk internal: tes build final dulu sebelum publik)
  List<String> get _tracksForMode => o.mode == 'internal' ? const ['internal'] : const ['internal', 'alpha', 'beta', 'production'];

  void _setMode(String m) => setState(() {
        o.mode = m;
        if (!_tracksForMode.contains(o.track)) o.track = 'internal';
      });

  bool firstRelease = false; // aplikasi belum pernah punya rilis di Google Play

  Future<void> _detectFirstRelease() async {
    final pv = await PlayService.versions(widget.project.serviceAccountPath, widget.project.packageName);
    if (!mounted || pv.error.isNotEmpty || pv.tracks.isNotEmpty || pv.maxCode > 0) return;
    setState(() {
      firstRelease = true;
      o.track = 'internal'; // status tetap "completed": DeployHub coba publikasikan, Google menolak → otomatis draft
    });
  }

  Widget _modeCard(String id, IconData icon, String title, List<String> points) {
    final sel = o.mode == id;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _setMode(id),
        child: AnimatedContainer(
          duration: motion(context, const Duration(milliseconds: 150)),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: sel ? YmColors.primarySoft : YmColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sel ? YmColors.primary : YmColors.line, width: sel ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: sel ? YmColors.primary : YmColors.outline),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: YmTextStyles.headlineSm.copyWith(fontSize: 15))),
              Icon(sel ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: sel ? YmColors.primary : YmColors.outline, size: 20),
            ]),
            const SizedBox(height: 8),
            for (final pt in points)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(Icons.check_rounded, size: 14, color: sel ? YmColors.primary : YmColors.outline),
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: Text(pt, style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark))),
                ]),
              ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pr = widget.project;
    final gh = pr.hasGithub;
    return DhDialog(
      title: tr('Deploy Android — {0}', [pr.name]),
      subtitle: pr.packageName,
      icon: Icons.android_rounded,
      width: 620,
      actions: [
        OutlinedButton(style: outlineButtonStyle(), onPressed: () => Navigator.pop(context), child: Text(tr('Batal'))),
        ElevatedButton.icon(
          style: primaryButtonStyle(),
          onPressed: () {
            o.releaseNotes = notes.text;
            if (!gh) {
              o.gitTag = false;
              o.githubRelease = false;
            }
            Navigator.pop(context, o);
          },
          icon: const Icon(Icons.rocket_launch_rounded),
          label: Text(tr('Mulai deploy')),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GroupLabel(tr('Pilih mode build')),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _modeCard('internal', Icons.science_outlined, tr('Internal (uji cepat)'), [
            tr('Build cepat tanpa obfuscate'),
            tr('Track internal — tidak tampil publik'),
            tr('Untuk cek fitur & bug sebelum rilis'),
          ]),
          const SizedBox(width: 12),
          _modeCard('production', Icons.rocket_launch_outlined, tr('Produksi (optimal)'), [
            tr('R8 + shrink resources + obfuscate'),
            tr('Mapping R8 diupload ke Play'),
            tr('Semua track: internal s/d production'),
            tr('Laporan pengurangan ukuran'),
          ]),
        ]),
        const SizedBox(height: 14),
        Builder(builder: (_) {
          final (icon, text) = _outcome;
          return Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: o.track == 'production' && o.upload ? YmColors.warningSoft : YmColors.primarySoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: o.track == 'production' && o.upload ? YmColors.onWarningSoft : YmColors.onPrimaryFixed),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Yang akan terjadi'),
                      style: YmTextStyles.labelLg.copyWith(
                          fontWeight: FontWeight.w700,
                          color: o.track == 'production' && o.upload ? YmColors.onWarningSoft : YmColors.onPrimaryFixed)),
                  const SizedBox(height: 2),
                  Text(text,
                      style: YmTextStyles.bodySm.copyWith(
                          color: o.track == 'production' && o.upload ? YmColors.onWarningSoft : YmColors.onPrimaryFixed)),
                ]),
              ),
            ]),
          );
        }),
        DialogSection(title: tr('Rilis'), icon: Icons.publish_rounded, children: [
          if (firstRelease)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: YmColors.warningSoft, borderRadius: BorderRadius.circular(10)),
              child: Text(
                tr('Rilis pertama: aplikasi masih Draf di Play Console. Google hanya mengizinkan rilis draft lewat API untuk aplikasi Draf, jadi setelah upload klik "Simpan dan publikasikan" di Play Console SEKALI. Upload berikutnya langsung terpublikasi otomatis.'),
                style: YmTextStyles.bodySm.copyWith(color: YmColors.onWarningSoft, fontWeight: FontWeight.w600),
              ),
            ),
          fieldRow([
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DropdownButtonFormField<String>(
                value: o.track,
                isExpanded: true,
                decoration: fieldDecoration(tr('Track Google Play')),
                items: [for (final t in _tracksForMode) DropdownMenuItem(value: t, child: Text(trackLabel(t)))],
                onChanged: o.upload
                    ? (v) => setState(() {
                          o.track = v!;
                          // production: default rollout bertahap 10% (aman)
                          if (v == 'production' && o.rolloutPercent == 100) o.rolloutPercent = 10;
                          if (v != 'production') o.rolloutPercent = 100;
                        })
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DropdownButtonFormField<String>(
                value: o.releaseStatus,
                isExpanded: true,
                decoration: fieldDecoration(tr('Status rilis')),
                items: [
                  DropdownMenuItem(value: 'completed', child: Text(tr('completed (langsung rilis)'))),
                  DropdownMenuItem(value: 'draft', child: Text(tr('draft (review dulu)'))),
                ],
                onChanged: o.upload ? (v) => setState(() => o.releaseStatus = v!) : null,
              ),
            ),
          ]),
          DhField(notes, tr('Catatan rilis'), maxLines: 3, hint: tr('Perbaikan bug dan peningkatan performa')),
          fieldRow([
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DropdownButtonFormField<String>(
                value: o.env,
                isExpanded: true,
                decoration: fieldDecoration(tr('Lingkungan (env/*.json)')),
                items: [
                  DropdownMenuItem(value: 'prod', child: Text(tr('prod — server produksi'))),
                  DropdownMenuItem(value: 'staging', child: Text(tr('staging — server uji'))),
                  DropdownMenuItem(value: 'dev', child: Text(tr('dev — server lokal'))),
                ],
                onChanged: (v) => setState(() => o.env = v ?? 'prod'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DropdownButtonFormField<int>(
                value: o.rolloutPercent,
                isExpanded: true,
                decoration: fieldDecoration(tr('Rollout bertahap (production)')),
                items: [
                  for (final v in [5, 10, 20, 50, 100])
                    DropdownMenuItem(value: v, child: Text(v == 100 ? tr('100% — semua pengguna sekaligus') : tr('{0}% pengguna dulu', [v]))),
                ],
                onChanged: o.track == 'production' && o.upload ? (v) => setState(() => o.rolloutPercent = v ?? 100) : null,
              ),
            ),
          ]),
          if (o.track == 'production' && o.rolloutPercent < 100)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                tr('Hanya {0}% pengguna yang menerima versi ini. Pantau crash di Proyek → Rollout & crash, lalu naikkan bertahap atau hentikan kalau ada masalah.', [o.rolloutPercent]),
                style: YmTextStyles.bodySm,
              ),
            ),
          if (o.track == 'production')
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                tr('Production: checklist Play Console dan pengujian tertutup (akun pribadi) wajib lengkap, kalau tidak deploy dihentikan.'),
                style: YmTextStyles.bodySm.copyWith(color: YmColors.warning),
              ),
            ),
        ]),
        DialogSection(title: tr('Pemeriksaan'), icon: Icons.fact_check_outlined, children: [
          CheckRow(
            label: tr('Cek kelayakan rilis'),
            sub: tr('Akun demo, link kebijakan & perlindungan anak, Firebase/Login Google, targetSdk, listing, checklist'),
            value: o.releaseChecks,
            onChanged: (v) => setState(() => o.releaseChecks = v),
          ),
          CheckRow(
            label: tr('Integration test login pakai akun demo'),
            sub: tr('Jalankan integration_test/ di HP/emulator yang tersambung'),
            value: o.integrationTest,
            onChanged: (v) => setState(() => o.integrationTest = v),
          ),
          CheckRow(label: 'flutter analyze', value: o.analyze, onChanged: (v) => setState(() => o.analyze = v)),
          CheckRow(label: 'flutter test', value: o.test, onChanged: (v) => setState(() => o.test = v)),
        ]),
        DialogSection(title: tr('Build & upload'), icon: Icons.cloud_upload_outlined, children: [
          if (o.mode == 'production')
            CheckRow(
              label: tr('Aktifkan R8 + shrink resources di build.gradle'),
              sub: tr('Otomatis, file asli di-backup (.deployhub.bak) dan proguard-rules.pro aman untuk Flutter dibuat'),
              value: o.applyR8,
              onChanged: (v) => setState(() => o.applyR8 = v),
            ),
          CheckRow(label: tr('Git pull dulu'), value: o.gitPull, onChanged: (v) => setState(() => o.gitPull = v)),
          CheckRow(
            label: tr('Naikkan build number otomatis'),
            sub: tr('Dicocokkan dengan versionCode tertinggi di Play'),
            value: o.bumpVersion,
            onChanged: (v) => setState(() => o.bumpVersion = v),
          ),
          CheckRow(
            label: tr('Upload ke Google Play'),
            sub: tr('Matikan kalau hanya ingin build .aab'),
            value: o.upload,
            onChanged: (v) => setState(() => o.upload = v),
          ),
          CheckRow(
            label: tr('Cek & build dulu, upload setelah saya setujui'),
            sub: tr('Semua cek dan laporan AAB dijalankan dulu. Tombol "Upload sekarang" muncul di akhir — tidak ada yang terkirim sebelum kamu klik.'),
            value: o.askBeforeUpload,
            enabled: o.upload,
            onChanged: (v) => setState(() => o.askBeforeUpload = v),
          ),
          CheckRow(
            label: tr('Sinkron Play Store'),
            sub: tr('Listing, kontak, tester Google Group, Keamanan Data dari folder store/'),
            value: o.syncStore,
            onChanged: (v) => setState(() => o.syncStore = v),
          ),
          CheckRow(
            label: tr('Termasuk gambar (ikon, feature graphic, screenshot)'),
            value: o.syncImages,
            enabled: o.syncStore,
            onChanged: (v) => setState(() => o.syncImages = v),
          ),
        ]),
        DialogSection(title: 'GitHub', icon: Icons.hub_outlined, children: [
          CheckRow(
              label: tr('Git commit, tag & push'), value: o.gitTag, enabled: gh, onChanged: (v) => setState(() => o.gitTag = v)),
          CheckRow(
            label: tr('GitHub Release + lampirkan AAB'),
            value: o.githubRelease,
            enabled: gh,
            onChanged: (v) => setState(() => o.githubRelease = v),
          ),
          if (!gh) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(tr('Isi repo GitHub di Edit Proyek untuk mengaktifkan.'), style: YmTextStyles.bodySm)),
        ]),
      ]),
    );
  }
}

class IosDeployDialog extends StatefulWidget {
  const IosDeployDialog({super.key, required this.project, this.initialMode, this.buildOnly = false});
  final Project project;
  final String? initialMode; // testflight | appstore
  final bool buildOnly; // true = hanya buat file .ipa, tanpa upload

  @override
  State<IosDeployDialog> createState() => _IosDeployDialogState();
}

class _IosDeployDialogState extends State<IosDeployDialog> {
  late final o = IosOptions(
    mode: widget.initialMode == 'appstore' ? 'appstore' : 'testflight',
    upload: !widget.buildOnly,
    submitReview: !widget.buildOnly,
  );
  final buildCtrl = TextEditingController();

  @override
  void dispose() {
    buildCtrl.dispose();
    super.dispose();
  }

  String get _outcome {
    if (!o.upload) return tr('Hanya build file .ipa di MacBook (dan disalin ke PC). Tidak ada yang dikirim ke Apple.');
    if (o.mode == 'testflight') {
      return tr('IPA diupload ke App Store Connect. Setelah diproses Apple (5–30 menit) muncul di TestFlight: tester internal langsung bisa install lewat aplikasi TestFlight. TIDAK tampil di App Store.');
    }
    return o.submitReview
        ? tr('IPA diupload, lalu versi ini otomatis dikirim untuk review App Store. Apple mereview 1–2 hari; setelah disetujui kamu tinggal klik "Release" di App Store Connect dan aplikasi tampil untuk SEMUA orang.')
        : tr('IPA produksi diupload ke App Store Connect. Kamu kirim untuk review sendiri di App Store Connect.');
  }

  Widget _modeCard(String id, IconData icon, String title, List<String> points) {
    final sel = o.mode == id;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => o.mode = id),
        child: AnimatedContainer(
          duration: motion(context, const Duration(milliseconds: 150)),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: sel ? YmColors.primarySoft : YmColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sel ? YmColors.primary : YmColors.line, width: sel ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: sel ? YmColors.primary : YmColors.outline),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: YmTextStyles.headlineSm.copyWith(fontSize: 15))),
              Icon(sel ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: sel ? YmColors.primary : YmColors.outline, size: 20),
            ]),
            const SizedBox(height: 8),
            for (final pt in points)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(Icons.check_rounded, size: 14, color: sel ? YmColors.primary : YmColors.outline),
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: Text(pt, style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark))),
                ]),
              ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pr = widget.project;
    final prod = o.mode == 'appstore';
    final warn = prod && o.upload;
    return DhDialog(
      title: tr('Deploy ke App Store — {0}', [pr.name]),
      subtitle: tr('Build di MacBook lewat SSH: {0}', [pr.macProjectPath]),
      icon: Icons.apple,
      width: 640,
      actions: [
        OutlinedButton(style: outlineButtonStyle(), onPressed: () => Navigator.pop(context), child: Text(tr('Batal'))),
        ElevatedButton.icon(
          style: primaryButtonStyle(),
          onPressed: () {
            o.buildNumber = buildCtrl.text.trim();
            if (!o.autoBuildNumber && o.buildNumber.isEmpty) o.autoBuildNumber = true;
            Navigator.pop(context, o);
          },
          icon: const Icon(Icons.rocket_launch_rounded),
          label: Text(tr('Mulai deploy')),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GroupLabel(tr('Pilih mode build')),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _modeCard('testflight', Icons.science_outlined, tr('TestFlight (uji)'), [
            tr('Build cepat tanpa obfuscate'),
            tr('Tester internal langsung bisa install'),
            tr('Tidak tampil di App Store'),
          ]),
          const SizedBox(width: 12),
          _modeCard('appstore', Icons.rocket_launch_outlined, tr('App Store (produksi)'), [
            tr('Obfuscate + split debug info'),
            tr('Otomatis kirim untuk review Apple'),
            tr('Tampil publik setelah disetujui'),
          ]),
        ]),
        const SizedBox(height: 14),
        Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: warn ? YmColors.warningSoft : YmColors.primarySoft, borderRadius: BorderRadius.circular(12)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(prod ? Icons.public_rounded : Icons.science_outlined, color: warn ? YmColors.onWarningSoft : YmColors.onPrimaryFixed),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Yang akan terjadi'),
                    style: YmTextStyles.labelLg
                        .copyWith(fontWeight: FontWeight.w700, color: warn ? YmColors.onWarningSoft : YmColors.onPrimaryFixed)),
                const SizedBox(height: 2),
                Text(_outcome, style: YmTextStyles.bodySm.copyWith(color: warn ? YmColors.onWarningSoft : YmColors.onPrimaryFixed)),
              ]),
            ),
          ]),
        ),
        DialogSection(title: tr('Versi'), icon: Icons.tag_rounded, children: [
          CheckRow(
            label: tr('Build number otomatis (tanggal-jam)'),
            sub: tr('Selalu unik, jadi tidak ditolak Apple karena build number sama'),
            value: o.autoBuildNumber,
            onChanged: (v) => setState(() => o.autoBuildNumber = v),
          ),
          if (!o.autoBuildNumber)
            DhField(buildCtrl, tr('Build number manual'), keyboard: TextInputType.number, icon: Icons.tag_rounded),
        ]),
        DialogSection(title: tr('Pemeriksaan'), icon: Icons.fact_check_outlined, children: [
          CheckRow(
            label: tr('Cek kelayakan rilis (iOS)'),
            sub: tr('Akun demo, link kebijakan, Firebase plist, URL scheme Login Google, Sign in with Apple'),
            value: o.releaseChecks,
            onChanged: (v) => setState(() => o.releaseChecks = v),
          ),
        ]),
        DialogSection(title: 'MacBook', icon: Icons.laptop_mac_rounded, children: [
          CheckRow(
            label: tr('Push kode dari PC ke GitHub dulu'),
            sub: tr('Supaya MacBook menarik kode terbaru'),
            value: o.pushFromPc,
            onChanged: (v) => setState(() => o.pushFromPc = v),
          ),
          CheckRow(label: tr('Git pull di MacBook'), value: o.gitPull, onChanged: (v) => setState(() => o.gitPull = v)),
          CheckRow(label: 'flutter pub get + pod install', value: o.podInstall, onChanged: (v) => setState(() => o.podInstall = v)),
          CheckRow(
            label: tr('Unlock keychain'),
            sub: tr('Wajib agar codesign jalan lewat SSH (pakai password Mac di Pengaturan)'),
            value: o.unlockKeychain,
            onChanged: (v) => setState(() => o.unlockKeychain = v),
          ),
        ]),
        DialogSection(title: tr('Build & upload'), icon: Icons.cloud_upload_outlined, children: [
          CheckRow(
            label: tr('Salin IPA ke PC'),
            sub: tr('Disimpan di build/ios_from_mac/ di folder project PC'),
            value: o.downloadIpa,
            onChanged: (v) => setState(() => o.downloadIpa = v),
          ),
          CheckRow(
            label: tr('Upload ke App Store Connect / TestFlight'),
            sub: tr('Matikan kalau hanya ingin build .ipa'),
            value: o.upload,
            onChanged: (v) => setState(() => o.upload = v),
          ),
          if (prod)
            CheckRow(
              label: tr('Kirim untuk review App Store otomatis'),
              sub: tr('Butuh fastlane di MacBook (brew install fastlane). Info App Store (screenshot, deskripsi, akun demo) harus sudah diisi di App Store Connect.'),
              value: o.submitReview,
              enabled: o.upload,
              onChanged: (v) => setState(() => o.submitReview = v),
            ),
        ]),
      ]),
    );
  }
}
