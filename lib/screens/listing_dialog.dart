import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/ai_fixer.dart';
import '../services/listing_fixer.dart';
import '../services/pipeline.dart';
import '../services/release_checks.dart';
import '../services/storage.dart';
import '../services/store_metadata.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';
import 'project_editor.dart';

/// Jenis perbaikan untuk satu baris merah di panel persetujuan.
String? fixKindFor(String blocker) {
  final b = blocker.toLowerCase();
  if (b.contains('sha-1')) return 'sha';
  if (b.contains(trL('Listing Play Store').toLowerCase()) || b.contains('listing play store') || b.contains('email kontak') || b.contains('store/')) return 'listing';
  if (b.contains(trL('Cek kelayakan: {0}', ['']).toLowerCase())) return 'project';
  return null;
}

Future<void> openFixFor(BuildContext context, Project pr, String blocker, PipelineRun run) async {
  switch (fixKindFor(blocker)) {
    case 'sha':
      await showDialog(context: context, builder: (_) => ShaFixDialog(project: pr));
    case 'listing':
      await showDialog(context: context, builder: (_) => StoreListingDialog(project: pr));
    default:
      final np = await showDialog<Project>(context: context, builder: (_) => ProjectEditor(project: Project.fromJson(pr.toJson())));
      if (np != null) await app.upsertProject(np);
  }
  if (context.mounted) await recheckBlockers(context, app.projects.firstWhere((x) => x.id == pr.id, orElse: () => pr), run);
}

/// Jalankan ulang cek kelayakan (tanpa build ulang) → perbarui daftar merah di panel persetujuan.
Future<void> recheckBlockers(BuildContext context, Project pr, PipelineRun run) async {
  final prefix = trL('Cek kelayakan: {0}', ['']);
  run.log('');
  run.log('── ${trL('Cek ulang kelayakan rilis')}');
  final checker = ReleaseChecker(pr, app.settings, demoPassword: await Storage.secret(Secrets.demoPassword(pr.id)), log: run.log);
  await checker.runAll(android: run.platform == 'android', ios: run.platform == 'ios', track: pr.defaultTrack.isEmpty ? 'internal' : pr.defaultTrack);
  final fails = checker.results.where((c) => c.level == CheckLevel.fail).map((c) => trL('Cek kelayakan: {0}', ['${c.category}: ${c.title}'])).toList();
  run.updateBlockers([...run.approvalBlockers.where((x) => !x.startsWith(prefix)), ...fails]);
  if (context.mounted) {
    showSnack(context, fails.isEmpty ? tr('Semua cek kelayakan sudah beres ✔') : tr('Masih {0} cek kelayakan yang merah', [fails.length]), error: fails.isNotEmpty);
  }
}

// ═════════════════════════════════════════════ Listing Play Store
class StoreListingDialog extends StatefulWidget {
  const StoreListingDialog({super.key, required this.project});
  final Project project;

  @override
  State<StoreListingDialog> createState() => _StoreListingDialogState();
}

class _StoreListingDialogState extends State<StoreListingDialog> {
  Project get pr => widget.project;
  String lang = 'id-ID';
  final c = {for (final k in ['title', 'short', 'full', 'email', 'website', 'phone', 'tagline', 'hint']) k: TextEditingController()};
  final notes = <String>[];
  String? busy;
  int _v = 0; // paksa reload gambar

  File _img(String rel) => File('${listingDir(pr, lang).path}${Platform.pathSeparator}images${Platform.pathSeparator}$rel');
  List<File> get _shots {
    final d = Directory('${listingDir(pr, lang).path}${Platform.pathSeparator}images${Platform.pathSeparator}phoneScreenshots');
    if (!d.existsSync()) return [];
    return d.listSync().whereType<File>().where((f) => RegExp(r'\.(png|jpe?g)$', caseSensitive: false).hasMatch(f.path)).toList()..sort((a, b) => a.path.compareTo(b.path));
  }

  @override
  void initState() {
    super.initState();
    for (final x in c.values) {
      x.addListener(() => setState(() {}));
    }
    _load();
  }

  Future<void> _load() async {
    final meta = await loadStoreMeta(pr);
    if (meta != null && meta.listings.isNotEmpty) lang = meta.listings.first.language;
    final v = await readListing(pr, lang);
    if (!mounted) return;
    setState(() {
      for (final e in v.entries) {
        c[e.key]!.text = e.value;
      }
      if (c['title']!.text.isEmpty) c['title']!.text = pr.name;
    });
  }

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  Future<void> _do(String name, Future<void> Function() fn) async {
    setState(() => busy = name);
    try {
      await fn();
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          busy = null;
          _v++;
        });
      }
    }
  }

  Future<void> _save() async {
    final t = c['title']!.text.trim(), s = c['short']!.text.trim(), f = c['full']!.text.trim(), e = c['email']!.text.trim();
    final err = <String>[
      if (t.isEmpty || t.length > 30) tr('Judul 1–30 karakter'),
      if (s.isEmpty || s.length > 80) tr('Deskripsi singkat 1–80 karakter'),
      if (f.isEmpty || f.length > 4000) tr('Deskripsi lengkap 1–4000 karakter'),
      if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) tr('Email kontak tidak valid'),
    ];
    if (err.isNotEmpty) {
      showSnack(context, err.join(' • '), error: true);
      return;
    }
    await writeListing(pr, lang, {for (final k in ['title', 'short', 'full', 'email', 'website', 'phone']) k: c[k]!.text});
    if (mounted) Navigator.pop(context, true);
  }

  Widget _counter(String k, int max) {
    final n = c[k]!.text.trim().length;
    return Text('$n/$max', style: YmTextStyles.bodySm.copyWith(color: n == 0 || n > max ? YmColors.danger : YmColors.success));
  }

  Widget _status(bool ok, String text) => Row(children: [
        Icon(ok ? Icons.check_circle_rounded : Icons.cancel_rounded, size: 18, color: ok ? YmColors.success : YmColors.danger),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: YmTextStyles.labelMd)),
      ]);

  Widget _btn(String label, IconData icon, Future<void> Function() fn) => OutlinedButton.icon(
        style: outlineButtonStyle(),
        onPressed: busy != null ? null : () => _do(label, fn),
        icon: busy == label ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon, size: 18),
        label: Text(label),
      );

  Future<File?> _pick({bool multi = false}) async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg'], allowMultiple: multi);
    final path = r?.files.firstOrNull?.path;
    return path == null ? null : File(path);
  }

  @override
  Widget build(BuildContext context) {
    final icon = _img('icon.png'), fg = _img('featureGraphic.png');
    final shots = _shots;
    return DhDialog(
      title: tr('Listing Play Store'),
      subtitle: tr('Tersimpan di store/android/{0}/ — disinkron ke Play Store otomatis setiap deploy', [lang]),
      icon: Icons.storefront_outlined,
      width: 860,
      height: 760,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Batal'))),
        ElevatedButton.icon(style: primaryButtonStyle(), onPressed: busy != null ? null : _save, icon: const Icon(Icons.save_outlined), label: Text(tr('Simpan'))),
      ],
      child: ListView(children: [
        GroupLabel(tr('Teks')),
        Row(children: [
          Expanded(child: DhField(c['title']!, tr('Judul aplikasi (maks 30)'), icon: Icons.title_rounded)),
          const SizedBox(width: 8),
          _counter('title', 30),
        ]),
        Row(children: [
          Expanded(child: DhField(c['short']!, tr('Deskripsi singkat (maks 80)'), icon: Icons.short_text_rounded, hint: tr('Chat, telepon & video call gratis untuk warga Batam'))),
          const SizedBox(width: 8),
          _counter('short', 80),
        ]),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: DhField(c['full']!, tr('Deskripsi lengkap (maks 4000)'), icon: Icons.notes_rounded, maxLines: 8)),
          const SizedBox(width: 8),
          Padding(padding: const EdgeInsets.only(top: 14), child: _counter('full', 4000)),
        ]),
        Row(children: [
          Expanded(child: DhField(c['hint']!, tr('Ceritakan aplikasimu singkat (untuk AI)'), icon: Icons.lightbulb_outline_rounded, hint: tr('Aplikasi chat untuk warga Batam, ada grup, telepon, video call, kirim foto'))),
          const SizedBox(width: 8),
          _btn(tr('Tulis dengan AI'), Icons.auto_awesome_rounded, () async {
            if (!AiFixer.instance.ready) throw Exception(tr('Aktifkan AI di Pengaturan → AI perbaikan otomatis'));
            final v = await aiListing(pr, c['hint']!.text);
            c['title']!.text = v['title']!;
            c['short']!.text = v['short']!;
            c['full']!.text = v['full']!;
          }),
        ]),
        GroupLabel(tr('Kontak (tampil di Play Store)')),
        fieldRow([
          DhField(c['email']!, tr('Email kontak (wajib)'), icon: Icons.email_outlined, hint: 'support@batamchitchat.com'),
          DhField(c['website']!, tr('Website (opsional)'), icon: Icons.language_rounded),
          DhField(c['phone']!, tr('Telepon (opsional)'), icon: Icons.phone_outlined, hint: '+62812...'),
        ]),
        GroupLabel(tr('Gambar')),
        _status(icon.existsSync(), tr('Ikon 512 x 512')),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _btn(tr('Pakai ikon aplikasi'), Icons.auto_fix_high_rounded, () async {
            final f = await findAppIcon(pr);
            if (f == null) throw Exception(tr('Ikon aplikasi tidak ditemukan di project — pilih file'));
            notes.add(await setIcon(pr, lang, f));
          }),
          _btn(tr('Pilih file…'), Icons.folder_open_rounded, () async {
            final f = await _pick();
            if (f != null) notes.add(await setIcon(pr, lang, f));
          }),
          if (icon.existsSync()) Image.file(icon, key: ValueKey('i$_v'), width: 48, height: 48),
        ]),
        const SizedBox(height: 10),
        _status(fg.existsSync(), tr('Feature graphic 1024 x 500')),
        Row(children: [
          Expanded(child: DhField(c['tagline']!, tr('Tagline di gambar (opsional)'), icon: Icons.text_fields_rounded, hint: c['short']!.text)),
        ]),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _btn(tr('Buat otomatis dari ikon'), Icons.auto_fix_high_rounded, () async {
            final ic = icon.existsSync() ? icon : await findAppIcon(pr);
            if (ic == null) throw Exception(tr('Buat ikon dulu'));
            notes.add(await generateFeatureGraphic(pr, lang, ic, c['title']!.text, c['tagline']!.text.isEmpty ? c['short']!.text : c['tagline']!.text));
          }),
          _btn(tr('Pilih file…'), Icons.folder_open_rounded, () async {
            final f = await _pick();
            if (f != null) notes.add(await setFeatureGraphic(pr, lang, f));
          }),
          TextButton.icon(
            onPressed: () => launchUrl(Uri.parse('https://www.canva.com/create/google-play-feature-graphics/')),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text(tr('Desain sendiri di Canva')),
          ),
        ]),
        if (fg.existsSync()) Padding(padding: const EdgeInsets.only(top: 6), child: Image.file(fg, key: ValueKey('f$_v'), height: 120, alignment: Alignment.centerLeft)),
        const SizedBox(height: 10),
        _status(shots.length >= 2 && shots.length <= 8, tr('Screenshot HP: {0} gambar (wajib 2–8)', [shots.length])),
        Text(tr('Ambil screenshot di HP (tombol power + volume bawah), kirim ke PC, lalu pilih di sini. Ukuran & rasio disesuaikan otomatis.'), style: YmTextStyles.bodySm),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _btn(tr('Pilih screenshot (2–8)…'), Icons.add_photo_alternate_outlined, () async {
            final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg'], allowMultiple: true);
            final files = [for (final f in r?.files ?? const <PlatformFile>[]) if (f.path != null) File(f.path!)];
            if (files.isNotEmpty) notes.addAll(await addScreenshots(pr, lang, files));
          }),
        ]),
        if (shots.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, children: [for (final f in shots) Image.file(f, key: ValueKey('${f.path}$_v'), height: 120)]),
          ),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final n in notes.reversed.take(6)) Text('• $n', style: YmTextStyles.bodySm),
        ],
      ]),
    );
  }
}

// ═════════════════════════════════════════════ SHA-1 Firebase
class ShaFixDialog extends StatefulWidget {
  const ShaFixDialog({super.key, required this.project});
  final Project project;

  @override
  State<ShaFixDialog> createState() => _ShaFixDialogState();
}

class _ShaFixDialogState extends State<ShaFixDialog> {
  late final play = TextEditingController(text: widget.project.playSigningSha1);
  final logs = <String>[];
  bool busy = false;

  @override
  void dispose() {
    play.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final pr = widget.project;
    final sha = play.text.trim();
    if (sha.isNotEmpty && !RegExp(r'^([0-9A-Fa-f]{2}:){19}[0-9A-Fa-f]{2}$').hasMatch(sha)) {
      showSnack(context, tr('Format SHA-1: 20 pasang heksadesimal dipisah titik dua (AA:BB:…)'), error: true);
      return;
    }
    setState(() {
      busy = true;
      logs.clear();
    });
    try {
      if (sha.isNotEmpty && sha != pr.playSigningSha1) {
        pr.playSigningSha1 = sha.toUpperCase();
        await app.upsertProject(pr);
      }
      final ok = await fixFirebaseSha(pr, app.settings, playSha: sha, log: (l) => setState(() => logs.add(l)));
      if (mounted) {
        showSnack(context, ok ? tr('SHA-1 terdaftar & google-services.json diperbarui. Login Google aktif setelah build berikutnya.') : tr('Sebagian gagal — lihat log'), error: !ok);
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Daftarkan SHA-1 ke Firebase')),
      content: SizedBox(
        width: 600,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            tr('Login Google butuh 2 SHA-1 terdaftar di Firebase:\n1) upload key (keystore di PC) — dibaca otomatis\n2) App signing key dari Google Play — salin dari Play Console → Uji dan rilis → Penyiapan → Integritas aplikasi → Penandatanganan aplikasi → SHA-1 sertifikat.'),
            style: YmTextStyles.bodySm,
          ),
          const SizedBox(height: 10),
          DhField(play, tr('SHA-1 App signing key (Play Console)'), icon: Icons.fingerprint_rounded, hint: 'AB:CD:EF:…'),
          TextButton.icon(
            onPressed: () => launchUrl(Uri.parse('https://play.google.com/console')),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text(tr('Buka Play Console')),
          ),
          if (logs.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0xFF0A0F1A), borderRadius: BorderRadius.circular(10)),
              child: SelectableText(logs.join('\n'), style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: Color(0xFFD7DCE3))),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Tutup'))),
        ElevatedButton.icon(
          style: primaryButtonStyle(),
          onPressed: busy ? null : _go,
          icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_sync_rounded),
          label: Text(tr('Daftarkan otomatis')),
        ),
      ],
    );
  }
}
