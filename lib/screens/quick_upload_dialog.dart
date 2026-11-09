import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/i18n.dart';
import '../models.dart';
import '../services/aab_inspect.dart';
import '../services/aab_report.dart';
import '../services/android_pipeline.dart';
import '../services/build_optimizer.dart';
import '../services/play_auth.dart';
import '../services/play_service.dart';
import '../services/quick_upload.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../utils.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';
import 'aab_report_dialog.dart';
import 'deploy_dialogs.dart' show tracks, trackLabel;

/// Upload file yang sudah jadi — .aab ke Google Play, .ipa ke App Store (TestFlight / review).
class QuickUploadDialog extends StatefulWidget {
  const QuickUploadDialog({super.key, this.project, this.initialDest});
  final Project? project;
  final String? initialDest; // play | appstore

  @override
  State<QuickUploadDialog> createState() => _QuickUploadDialogState();
}

class _QuickUploadDialogState extends State<QuickUploadDialog> {
  late String dest = widget.initialDest ?? 'play'; // play | appstore
  File? file;
  BinaryInfo? info;
  AabReport? report;
  bool reading = false;
  String? projectId;
  final pkg = TextEditingController(); // package (AAB) atau bundle ID (IPA)
  final notes = TextEditingController();
  String track = 'internal';
  String status = 'completed';
  bool submitReview = false;
  bool playReady = true;
  bool acceptLowOpt = false; // optimasi R8 < 50% tapi tetap mau upload
  PlayVersions? playVersions; // versi yang sudah ada di Google Play
  bool fixing = false;

  /// Folder project untuk perbaikan R8: proyek terpilih → folder yang terdeteksi dari AAB.
  String get _fixRoot {
    final pr = project;
    if (pr != null && pr.localPath.isNotEmpty) return pr.localPath;
    return report?.r8.projectRoot ?? '';
  }

  /// "Perbaiki otomatis": ubah build.gradle / gradle.properties / proguard-rules.pro,
  /// lalu tawarkan build ulang mode Produksi + upload (versi juga dinaikkan otomatis).
  Future<void> _autoFix() async {
    final root = _fixRoot;
    if (root.isEmpty) {
      showSnack(context, tr('Pilih proyek dulu di bagian "Tujuan & opsi" (folder project dibutuhkan untuk perbaikan).'), error: true);
      return;
    }
    setState(() => fixing = true);
    final res = await fixR8(root, packageName: pkg.text.trim());
    if (!mounted) return;
    setState(() => fixing = false);
    if (res.error.isNotEmpty) {
      showSnack(context, res.error, error: true);
      return;
    }
    final pr = project ??
        app.projects.where((x) => x.localPath == root).firstOrNull ??
        Project(id: 'p${DateTime.now().millisecondsSinceEpoch}', name: p.basename(root), localPath: root, packageName: pkg.text.trim());
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => DhDialog(
        title: tr('R8 sudah diperbaiki'),
        subtitle: root,
        icon: Icons.auto_fix_high_rounded,
        width: 680,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Nanti saja'))),
          ElevatedButton.icon(
            style: primaryButtonStyle(),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.rocket_launch_rounded),
            label: Text(tr('Build ulang & cek ({0})', [trackLabel(track)])),
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          if (res.changes.isEmpty && res.disabledRules.isEmpty)
            Text(tr('Konfigurasi R8 sudah benar — tidak ada file yang perlu diubah. Persentase rendah biasanya karena AAB dibuat sebelum perbaikan; build ulang dengan mode Produksi.'),
                style: YmTextStyles.bodySm)
          else ...[
            Text(tr('Yang diubah:'), style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final c in res.changes) Text('✔ $c', style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark)),
            if (res.disabledRules.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(tr('Aturan yang dinonaktifkan (diberi tanda # di proguard-rules.pro):'), style: YmTextStyles.labelMd),
              const SizedBox(height: 4),
              CodeBox(res.disabledRules.join('\n'), label: 'proguard-rules.pro'),
            ],
            if (res.backup.isNotEmpty) Text(tr('Backup: {0}', [res.backup]), style: YmTextStyles.bodySm),
          ],
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: YmColors.primarySoft, borderRadius: BorderRadius.circular(10)),
            child: Text(
              tr('Langkah berikutnya: "Build ulang & cek" menjalankan Deploy ke Play Store mode Produksi — versionCode dinaikkan otomatis (tidak bentrok dengan Google Play), R8 + obfuscate aktif, semua cek & laporan AAB dibuat. Upload ke {0} baru terjadi setelah kamu klik "Upload sekarang" di akhir. Uji dulu di Pengujian internal: kalau ada fitur yang error setelah R8 (biasanya model JSON/Gson), tambahkan -keep khusus untuk class itu saja.', [trackLabel(track)]),
              style: YmTextStyles.bodySm.copyWith(color: YmColors.onPrimaryFixed),
            ),
          ),
        ]),
      ),
    );
    if (go != true || !mounted) return;
    if (!app.projects.any((x) => x.id == pr.id)) await app.upsertProject(pr);
    if (!mounted) return;
    Navigator.pop(context); // tutup dialog upload
    await app.startAndroid(
      pr,
      AndroidOptions(mode: 'production', applyR8: true, track: track, releaseStatus: status, releaseNotes: notes.text),
    );
    nav.value = 'pipeline';
  }
  bool loadingVersions = false;

  /// Ambil versi yang sudah ada di Google Play untuk package ini.
  Future<void> _loadPlayVersions() async {
    final id = pkg.text.trim();
    if (isIpa || id.isEmpty || !playReady) return;
    setState(() {
      loadingVersions = true;
      playVersions = null;
    });
    final v = await PlayService.versions(project?.serviceAccountPath ?? '', id);
    if (!mounted || pkg.text.trim() != id) return;
    setState(() {
      playVersions = v;
      loadingVersions = false;
    });
  }

  int get _fileCode => int.tryParse(info?.versionCode ?? '') ?? 0;

  /// Saran versi untuk pubspec.yaml: nama versi sama, build number = tertinggi + 1.
  String get _suggestVersion {
    final name = (info?.versionName ?? '1.0.0').isEmpty ? '1.0.0' : info!.versionName;
    return '$name+${(playVersions?.maxCode ?? 0) + 1}';
  }

  bool get isIpa => dest == 'appstore';

  @override
  void initState() {
    super.initState();
    final pr = widget.project;
    projectId = pr?.id;
    if (pr != null) {
      pkg.text = isIpa ? pr.iosBundleId : pr.packageName;
      track = tracks.contains(pr.defaultTrack) ? pr.defaultTrack : 'internal';
    }
    PlayAuth.globalReady().then((v) {
      if (mounted) setState(() => playReady = v || (widget.project?.serviceAccountPath.isNotEmpty ?? false));
    });
  }

  @override
  void dispose() {
    pkg.dispose();
    notes.dispose();
    super.dispose();
  }

  Project? get project {
    for (final x in app.projects) {
      if (x.id == projectId) return x;
    }
    return null;
  }

  void _setDest(String d) {
    if (d == dest) return;
    setState(() {
      dest = d;
      file = null;
      info = null;
      report = null;
      pkg.text = project == null ? '' : (isIpa ? project!.iosBundleId : project!.packageName);
    });
  }

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: isIpa ? tr('Pilih file IPA') : tr('Pilih file AAB'),
      type: FileType.custom,
      allowedExtensions: [isIpa ? 'ipa' : 'aab'],
    );
    final path = r?.files.single.path;
    if (path == null) return;
    setState(() {
      file = File(path);
      info = null;
      reading = true;
    });
    final i = await inspectBinary(File(path));
    final rep = isIpa ? null : await analyzeAab(File(path), track: track, minTargetSdk: app.settings.minTargetSdk, projectRoot: project?.localPath ?? '');
    if (!mounted) return;
    report = rep;
    setState(() {
      info = i;
      reading = false;
      final id = isIpa ? i.bundleId : i.packageName;
      if (id.isNotEmpty) {
        pkg.text = id;
        final match = app.projects.where((x) => (isIpa ? x.iosBundleId : x.packageName) == id).firstOrNull;
        if (match != null) projectId = match.id;
      }
      acceptLowOpt = false;
    });
    _loadPlayVersions();
    // Proyek baru dikenali dari package → baca ulang dengan folder project (konfigurasi R8 + usage.txt)
    final root = project?.localPath ?? '';
    if (!isIpa && rep != null && root.isNotEmpty && rep.r8.fullMode == null) {
      final again = await analyzeAab(File(path), track: track, minTargetSdk: app.settings.minTargetSdk, projectRoot: root);
      if (mounted && file?.path == path) setState(() => report = again);
    }
  }

  String? get _blocker {
    final i = info;
    if (file == null) return isIpa ? tr('Pilih file .ipa dulu') : tr('Pilih file .aab dulu');
    if (reading || i == null) return tr('Membaca file...');
    if (i.error.isNotEmpty) return i.error;
    final id = pkg.text.trim();
    if (isIpa) {
      final s = app.settings;
      if (s.macHost.isEmpty || s.macUser.isEmpty) {
        return tr('Upload ke App Store butuh MacBook — alat upload Apple hanya jalan di macOS (Pengaturan → MacBook)');
      }
      if ((project?.ascKeyId ?? '').isEmpty && s.ascKeyId.isEmpty) return tr('API key App Store Connect belum diisi (Pengaturan)');
      if (submitReview) {
        if (id.isEmpty) return tr('Bundle ID belum diketahui');
        if (s.ascP8Path.isEmpty) return tr('Kirim review butuh file .p8 (Pengaturan → App Store Connect)');
        if (i.versionName.isEmpty || i.versionCode.isEmpty) return tr('Versi di Info.plist tidak terbaca');
      }
      final pr = project;
      if (pr != null && pr.iosBundleId.isNotEmpty && id.isNotEmpty && pr.iosBundleId != id) {
        return tr('Bundle ID di file ({0}) berbeda dengan proyek "{1}" ({2})', [id, pr.name, pr.iosBundleId]);
      }
      return null;
    }
    if (i.sign == SignState.debug) return tr('File ditandatangani dengan DEBUG key — Google Play pasti menolak');
    if ((report?.failCount ?? 0) > 0) return tr('Laporan AAB menemukan {0} masalah yang pasti ditolak Google Play — klik "Lihat laporan lengkap"', [report!.failCount]);
    if (report != null && report!.lowOptimization && !acceptLowOpt) {
      return tr('Optimasi R8 di bawah 50% — perbaiki dulu, atau centang "Tetap upload" di bagian Optimasi R8');
    }
    if (i.sign == SignState.unsigned) return tr('File belum ditandatangani — Google Play pasti menolak');
    if (id.isEmpty) return tr('Package name belum diketahui');
    final pr = project;
    if (pr != null && pr.packageName.isNotEmpty && pr.packageName != id) {
      return tr('Package di file ({0}) berbeda dengan proyek "{1}" ({2})', [id, pr.name, pr.packageName]);
    }
    if (!playReady) return tr('Google Play belum terhubung. Buka Pengaturan → Akun & Koneksi.');
    if (loadingVersions) return tr('Mengecek versi di Google Play...');
    final pv = playVersions;
    if (pv != null && pv.error.isEmpty && _fileCode > 0 && _fileCode <= pv.maxCode) {
      return tr('versionCode {0} sudah dipakai / lebih kecil dari yang ada di Google Play (tertinggi {1}). Naikkan versi lalu build ulang.', [_fileCode, pv.maxCode]);
    }
    return null;
  }

  /// Laporan dengan waktu tunggu sesuai track yang dipilih sekarang.
  void _showReport() {
    final r = report;
    if (r == null) return;
    r.track = track;
    r.findings.removeWhere((f) => f.title == tr('Waktu tunggu'));
    r.findings.add(AabFinding('info', tr('Rilis & waktu tunggu'), tr('Waktu tunggu'), releaseWaitText(track)));
    AabReportDialog.show(context, r);
  }

  void _start() {
    final id = pkg.text.trim();
    final pr = project ??
        Project(
          id: 'upload-${id.isEmpty ? p.basenameWithoutExtension(file!.path) : id}',
          name: id.isEmpty ? p.basenameWithoutExtension(file!.path) : id,
          packageName: isIpa ? '' : id,
          iosBundleId: isIpa ? id : '',
        );
    final o = QuickUploadOptions(file: file!, project: pr)
      ..track = track
      ..releaseStatus = status
      ..releaseNotes = notes.text
      ..submitReview = isIpa && submitReview
      ..bundleId = id
      ..appVersion = info?.versionName ?? ''
      ..buildNumber = info?.versionCode ?? '';
    Navigator.pop(context, o);
  }

  Widget _destCard(String id, IconData icon, String title, String sub, Color color) {
    final sel = dest == id;
    return Expanded(
      child: Material(
        color: sel ? YmColors.primarySoft : YmColors.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _setDest(id),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sel ? YmColors.primary : YmColors.line, width: sel ? 2 : 1),
            ),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: YmTextStyles.headlineSm.copyWith(fontSize: 15)),
                  Text(sub, style: YmTextStyles.bodySm),
                ]),
              ),
              Icon(sel ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: sel ? YmColors.primary : YmColors.outline, size: 20),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _row(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 140, child: Text(k, style: YmTextStyles.bodySm)),
          Expanded(child: Text(v, style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w600, color: color))),
        ]),
      );

  Widget _versionSection() {
    final pv = playVersions;
    final code = _fileCode;
    Widget body;
    if (loadingVersions || pv == null) {
      body = Row(children: [
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Text(tr('Mengecek versi yang sudah ada di Google Play...'), style: YmTextStyles.bodySm),
      ]);
    } else if (pv.error.isNotEmpty) {
      body = Text(
        pv.appMissing
            ? tr('Aplikasi {0} belum ada di Play Console (atau akun ini tidak punya akses). Buat aplikasinya dulu di Play Console → Buat aplikasi.', [pkg.text.trim()])
            : tr('Versi di Google Play tidak bisa dicek: {0}', [pv.error]),
        style: YmTextStyles.bodySm.copyWith(color: YmColors.warning),
      );
    } else {
      final dup = code > 0 && code <= pv.maxCode;
      final rows = <Widget>[];
      for (final t in ['production', 'beta', 'alpha', 'internal']) {
        final l = pv.latest(t);
        if (l == null) continue;
        rows.add(_row(trackLabel(t), '${l.$2.isEmpty ? '-' : l.$2} (versionCode ${l.$1})${l.$3.isEmpty ? '' : ' • ${l.$3}'}'));
      }
      for (final t in pv.tracks.keys.where((k) => !['production', 'beta', 'alpha', 'internal'].contains(k))) {
        final l = pv.latest(t)!;
        rows.add(_row(t, '${l.$2.isEmpty ? '-' : l.$2} (versionCode ${l.$1})'));
      }
      final prodName = pv.latest('production')?.$2 ?? '';
      final sameName = prodName.isNotEmpty && (info?.versionName ?? '').isNotEmpty && prodName.startsWith(info!.versionName);
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (rows.isEmpty) Text(tr('Belum ada rilis di Google Play — ini upload pertama.'), style: YmTextStyles.bodySm) else ...rows,
        _row(tr('versionCode tertinggi'), pv.maxCode == 0 ? '-' : '${pv.maxCode}'),
        _row(tr('File ini'), '${info?.versionName ?? '-'} (versionCode $code)', color: dup ? YmColors.danger : YmColors.success),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: dup ? YmColors.dangerSoft : YmColors.successSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              dup
                  ? tr('✖ versionCode {0} sudah dipakai atau lebih kecil dari {1}. Google Play pasti menolak ("Version code {0} has already been used").', [code, pv.maxCode])
                  : tr('✔ versionCode {0} lebih besar dari {1} — aman, tidak mengulang versi yang ada.', [code, pv.maxCode]),
              style: YmTextStyles.labelLg.copyWith(
                  fontWeight: FontWeight.w600, color: dup ? YmColors.onDangerSoft : YmColors.onSuccessSoft),
            ),
            if (dup) ...[
              const SizedBox(height: 6),
              Text(tr('Cara memperbaiki: ubah baris version di pubspec.yaml menjadi'), style: YmTextStyles.bodySm.copyWith(color: YmColors.onDangerSoft)),
              const SizedBox(height: 6),
              CodeBox('version: $_suggestVersion', label: 'pubspec.yaml'),
              Text(
                tr('Angka setelah + adalah versionCode (harus naik setiap upload). Angka sebelum + adalah nama versi yang dilihat pengguna — naikkan juga kalau ada perubahan, mis. 1.1.3. Lalu build ulang (atau pakai "Deploy ke Play Store" — DeployHub menaikkan versi otomatis).'),
                style: YmTextStyles.bodySm.copyWith(color: YmColors.onDangerSoft),
              ),
            ] else if (sameName)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  tr('Catatan: nama versi {0} sama dengan Production sekarang ({1}). Pengguna melihat nomor versi yang sama — sebaiknya naikkan nama versi juga.', [info!.versionName, prodName]),
                  style: YmTextStyles.bodySm.copyWith(color: YmColors.onSuccessSoft),
                ),
              ),
          ]),
        ),
      ]);
    }
    return DialogSection(
      title: tr('Versi di Google Play'),
      icon: Icons.history_rounded,
      children: [
        body,
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: loadingVersions ? null : _loadPlayVersions,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(tr('Cek ulang')),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final i = info;
    final blocker = _blocker;
    final (signText, signColor) = switch (i?.sign) {
      SignState.upload => (tr('Upload key ✔'), YmColors.success),
      SignState.debug => (tr('DEBUG key ✖ — akan ditolak'), YmColors.danger),
      SignState.unsigned => (tr('Belum ditandatangani ✖'), YmColors.danger),
      _ => ('-', null),
    };
    final warn = (!isIpa && track == 'production') || (isIpa && submitReview);
    final outcome = isIpa
        ? (submitReview
            ? tr('IPA dikirim ke MacBook, diupload ke App Store Connect, lalu versi ini otomatis dikirim untuk review App Store. Apple mereview 1–2 hari; setelah disetujui kamu klik "Release" di App Store Connect dan aplikasi tampil untuk SEMUA orang.')
            : tr('IPA dikirim ke MacBook lalu diupload ke App Store Connect. Setelah diproses Apple (5–30 menit) muncul di TestFlight. TIDAK tampil di App Store.'))
        : switch (track) {
            'internal' => tr('AAB diupload ke Pengujian internal. Dalam beberapa menit bisa diinstall tester internal lewat Play Store. TIDAK tampil untuk publik.'),
            'alpha' => tr('AAB diupload ke Pengujian tertutup (alpha). Hanya tester di Google Group yang bisa install. Biasanya direview Google dulu.'),
            'beta' => tr('AAB diupload ke Pengujian terbuka (beta). Siapa pun bisa ikut jadi tester dari halaman Play Store. Direview Google dulu.'),
            _ => tr('AAB diupload ke Production. Google mereview beberapa jam sampai beberapa hari, setelah lolos tampil di Play Store untuk SEMUA orang.'),
          };

    return DhDialog(
      title: tr('Upload file langsung'),
      subtitle: tr('Tanpa build, tanpa folder project — pilih tujuan lalu pilih file'),
      icon: Icons.upload_file_rounded,
      width: 700,
      actions: [
        OutlinedButton(style: outlineButtonStyle(), onPressed: () => Navigator.pop(context), child: Text(tr('Batal'))),
        ElevatedButton.icon(
          style: primaryButtonStyle(),
          onPressed: blocker == null && !app.isRunning ? _start : null,
          icon: Icon(isIpa ? Icons.apple : Icons.shop_rounded),
          label: Text(isIpa ? (submitReview ? tr('Upload & kirim review App Store') : tr('Upload ke TestFlight')) : tr('Upload ke Google Play')),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GroupLabel(tr('1. Pilih tujuan')),
        Row(children: [
          _destCard('play', Icons.shop_rounded, 'Google Play', tr('File .aab • Android'), const Color(0xFF0F9D58)),
          const SizedBox(width: 12),
          _destCard('appstore', Icons.apple, 'App Store', tr('File .ipa • iPhone (lewat MacBook)'),
              YmColors.isDark ? const Color(0xFF3A3F4B) : const Color(0xFF111318)),
        ]),
        const SizedBox(height: 16),
        GroupLabel(isIpa ? tr('2. Pilih file .ipa') : tr('2. Pilih file .aab')),
        Material(
          color: YmColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _pick,
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: file == null ? YmColors.primary.withOpacity(0.5) : YmColors.line, width: 1.5),
              ),
              child: Row(children: [
                Icon(file == null ? Icons.file_open_outlined : (isIpa ? Icons.apple : Icons.android_rounded), size: 32, color: YmColors.primary),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(file == null ? (isIpa ? tr('Klik untuk memilih file .ipa') : tr('Klik untuk memilih file .aab')) : p.basename(file!.path),
                        style: YmTextStyles.headlineSm.copyWith(fontSize: 15)),
                    Text(
                      file != null
                          ? file!.parent.path
                          : (isIpa
                              ? tr('Misalnya build\\ios_from_mac\\aplikasi.ipa (hasil build di MacBook)')
                              : tr('Misalnya build\\app\\outputs\\bundle\\release\\app-release.aab')),
                      style: YmTextStyles.bodySm,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ]),
                ),
                if (file != null) Text(tr('Ganti'), style: YmTextStyles.labelMd.copyWith(color: YmColors.primary, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (reading) const LinearProgressIndicator(),

        if (i != null) ...[
          DialogSection(title: tr('Isi file'), icon: Icons.fact_check_outlined, children: [
            _row(tr('Ukuran'), fmtMb(i.size)),
            if (isIpa) ...[
              _row('Bundle ID', i.bundleId.isEmpty ? tr('Tidak terbaca — isi manual di bawah') : i.bundleId),
              _row(tr('Versi'), i.versionName.isEmpty ? '-' : '${i.versionName} (build ${i.versionCode})'),
            ] else ...[
              _row('Package', i.packageName.isEmpty ? tr('Tidak terbaca — isi manual di bawah') : i.packageName),
              _row(tr('Versi'), i.versionName.isEmpty ? '-' : '${i.versionName} (versionCode ${i.versionCode})'),
              _row(tr('Tanda tangan'), signText, color: signColor),
              if (report != null) ...[
                const SizedBox(height: 6),
                Row(children: [
                  SoftChip.danger('${report!.failCount} ✖'),
                  const SizedBox(width: 6),
                  SoftChip.warning('${report!.warnCount} ⚠'),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      report!.failCount > 0
                          ? tr('Ada masalah yang pasti ditolak Google Play')
                          : tr('Cek perangkat, R8, 16 KB, izin, dan waktu tunggu'),
                      style: YmTextStyles.bodySm,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _showReport,
                    icon: const Icon(Icons.assessment_outlined, size: 18),
                    label: Text(tr('Lihat laporan lengkap')),
                  ),
                ]),
              ],
            ],
            const SizedBox(height: 6),
          ]),
        ],

        if (!isIpa && file != null && !reading && (loadingVersions || playVersions != null)) _versionSection(),

        if (!isIpa && report != null && !reading)
          DialogSection(
            title: tr('Optimasi & perangkat (seperti App bundle explorer)'),
            icon: Icons.speed_rounded,
            children: [
              if (report!.lowOptimization)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: YmColors.warningSoft, borderRadius: BorderRadius.circular(10)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Icon(Icons.warning_amber_rounded, color: YmColors.onWarningSoft),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tr('Optimasi R8 kurang dari 50% (terendah {0}%). Aplikasi lebih besar, lebih boros memori, dan kodenya lebih mudah dibaca orang.', [(report!.r8.lowest ?? 0).round()]),
                          style: YmTextStyles.labelLg.copyWith(color: YmColors.onWarningSoft, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text(
                      tr('Cara menaikkan: build ulang lewat DeployHub dengan mode Produksi (R8 mode penuh, shrinkResources, optimizedResourceShrinking otomatis), tambahkan -repackageclasses di proguard-rules.pro, dan hapus aturan -keep yang terlalu luas.'),
                      style: YmTextStyles.bodySm.copyWith(color: YmColors.onWarningSoft),
                    ),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      ElevatedButton.icon(
                        style: primaryButtonStyle(),
                        onPressed: fixing ? null : _autoFix,
                        icon: fixing
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.auto_fix_high_rounded),
                        label: Text(tr('Perbaiki otomatis')),
                      ),
                    ]),
                    if (_fixRoot.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(tr('Perlu folder project: pilih proyek di bagian "Tujuan & opsi", atau pilih AAB dari folder build project.'),
                            style: YmTextStyles.bodySm.copyWith(color: YmColors.onWarningSoft)),
                      ),
                    // Material transparan: ListTile butuh Material di atas Container berwarna,
                    // kalau tidak Flutter melempar "ListTile background color or ink splashes may be invisible".
                    Material(
                      type: MaterialType.transparency,
                      child: CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: acceptLowOpt,
                        onChanged: (v) => setState(() => acceptLowOpt = v ?? false),
                        title: Text(tr('Tetap upload walau di bawah 50%'), style: YmTextStyles.labelMd.copyWith(color: YmColors.onWarningSoft)),
                      ),
                    ),
                  ]),
                ),
              AabExplorerCard(report: report!),
              const SizedBox(height: 8),
            ],
          ),

        if (file != null) ...[
          DialogSection(title: tr('3. Tujuan & opsi'), icon: Icons.flag_outlined, children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DropdownButtonFormField<String?>(
                value: app.projects.any((x) => x.id == projectId) ? projectId : null,
                isExpanded: true,
                decoration: fieldDecoration(tr('Proyek (opsional — supaya masuk riwayat proyek)')),
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text(tr('Tanpa proyek'))),
                  for (final x in app.projects)
                    DropdownMenuItem<String?>(value: x.id, child: Text('${x.name} • ${isIpa ? x.iosBundleId : x.packageName}')),
                ],
                onChanged: (v) => setState(() {
                  projectId = v;
                  if (project != null && pkg.text.isEmpty) pkg.text = isIpa ? project!.iosBundleId : project!.packageName;
                }),
              ),
            ),
            DhField(pkg, isIpa ? 'Bundle ID' : 'Package name',
                icon: Icons.inventory_2_outlined, hint: 'com.batamchitchat.app', onChanged: (_) => setState(() {})),
            if (isIpa)
              CheckRow(
                label: tr('Kirim untuk review App Store setelah upload'),
                sub: tr('Mati = hanya TestFlight. Nyala = otomatis dikirim ke review Apple (butuh fastlane di MacBook dan info App Store sudah diisi di App Store Connect).'),
                value: submitReview,
                onChanged: (v) => setState(() => submitReview = v),
              )
            else ...[
              fieldRow([
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DropdownButtonFormField<String>(
                    value: track,
                    isExpanded: true,
                    decoration: fieldDecoration(tr('Track Google Play')),
                    items: [for (final t in tracks) DropdownMenuItem(value: t, child: Text(trackLabel(t)))],
                    onChanged: (v) => setState(() => track = v!),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DropdownButtonFormField<String>(
                    value: status,
                    isExpanded: true,
                    decoration: fieldDecoration(tr('Status rilis')),
                    items: [
                      DropdownMenuItem(value: 'completed', child: Text(tr('completed (langsung rilis)'))),
                      DropdownMenuItem(value: 'draft', child: Text(tr('draft (review dulu)'))),
                    ],
                    onChanged: (v) => setState(() => status = v!),
                  ),
                ),
              ]),
              DhField(notes, tr('Catatan rilis'), maxLines: 3, hint: tr('Perbaikan bug dan peningkatan performa')),
            ],
          ]),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: warn ? YmColors.warningSoft : YmColors.primarySoft, borderRadius: BorderRadius.circular(12)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline_rounded, color: warn ? YmColors.onWarningSoft : YmColors.onPrimaryFixed),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Yang akan terjadi'), style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(outcome, style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark)),
                ]),
              ),
            ]),
          ),
        ],
        if (isIpa && app.settings.macHost.isEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: YmColors.warningSoft, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              Icon(Icons.laptop_mac_rounded, color: YmColors.onWarningSoft, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('Upload ke App Store butuh MacBook — alat upload Apple hanya jalan di macOS (Pengaturan → MacBook)'),
                  style: YmTextStyles.bodySm.copyWith(color: YmColors.onWarningSoft),
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  nav.value = 'settings';
                },
                child: Text(tr('Atur MacBook')),
              ),
            ]),
          ),
        ],
        if (blocker != null && file != null && !reading) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: YmColors.dangerSoft, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              Icon(Icons.block_rounded, color: YmColors.onDangerSoft, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(blocker, style: YmTextStyles.bodySm.copyWith(color: YmColors.onDangerSoft))),
            ]),
          ),
        ],
        const SizedBox(height: 8),
      ]),
    );
  }
}

/// Buka dialog upload file lalu jalankan pipeline-nya.
Future<void> openQuickUpload(BuildContext context, {Project? project, String? dest}) async {
  final o = await showDialog<QuickUploadOptions>(
      context: context, builder: (_) => QuickUploadDialog(project: project, initialDest: dest));
  if (o == null) return;
  await app.startQuickUpload(o);
  nav.value = 'pipeline';
}
