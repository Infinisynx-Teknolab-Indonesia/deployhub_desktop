import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/legal_pages.dart';
import '../services/store_metadata.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

/// Buat kebijakan privasi + hapus akun + standar keselamatan anak → host di GitHub Pages → isi link proyek.
class LegalPagesDialog extends StatefulWidget {
  const LegalPagesDialog({super.key, required this.project});
  final Project project;

  @override
  State<LegalPagesDialog> createState() => _LegalPagesDialogState();
}

class _LegalPagesDialogState extends State<LegalPagesDialog> {
  Project get pr => widget.project;
  late final appName = TextEditingController(text: pr.name);
  final developer = TextEditingController();
  final email = TextEditingController();
  final steps = TextEditingController();
  final childContact = TextEditingController();
  List<DataUse> uses = [];
  final logs = <String>[];
  bool busy = false;
  String url = '';

  @override
  void initState() {
    super.initState();
    () async {
      final u = await detectDataUse(pr);
      final meta = await loadStoreMeta(pr);
      if (!mounted) return;
      setState(() {
        uses = u;
        email.text = '${meta?.details['contactEmail'] ?? ''}';
        developer.text = pr.githubOwner.replaceAll('-', ' ');
      });
    }();
  }

  @override
  void dispose() {
    for (final c in [appName, developer, email, steps, childContact]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _go() async {
    if (email.text.trim().isEmpty || developer.text.trim().isEmpty) {
      showSnack(context, tr('Isi nama developer dan email kontak'), error: true);
      return;
    }
    setState(() {
      busy = true;
      logs.clear();
    });
    try {
      final pages = buildLegalPages(
          pr,
          LegalInfo(appName: appName.text.trim(), developer: developer.text.trim(), email: email.text.trim(), deleteSteps: steps.text, childContact: childContact.text.trim()),
          uses);
      final base = await publishLegalPages(pr, pages, (l) => setState(() => logs.add(l)));
      pr.privacyPolicyUrl = base;
      if (pages.containsKey('delete-account.html')) pr.deleteAccountUrl = '${base}delete-account.html';
      if (pages.containsKey('child-safety.html')) pr.childSafetyUrl = '${base}child-safety.html';
      await app.upsertProject(pr);
      setState(() => url = base);
      if (mounted) showSnack(context, tr('Link kebijakan privasi, hapus akun & keselamatan anak sudah diisi di proyek'));
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _link(String label, String u) => u.isEmpty
      ? const SizedBox.shrink()
      : Row(children: [
          Expanded(child: Text('$label: $u', style: YmTextStyles.bodySm)),
          IconButton(tooltip: tr('Salin'), onPressed: () => Clipboard.setData(ClipboardData(text: u)), icon: const Icon(Icons.copy_rounded, size: 18)),
          IconButton(tooltip: tr('Buka'), onPressed: () => launchUrl(Uri.parse(u)), icon: const Icon(Icons.open_in_new_rounded, size: 18)),
        ]);

  @override
  Widget build(BuildContext context) {
    return DhDialog(
      title: tr('Halaman wajib Google Play'),
      subtitle: tr('Kebijakan privasi{0}{1} — dibuat dari SDK & izin aplikasimu, di-host gratis di GitHub Pages',
          [pr.hasLogin ? tr(', hapus akun') : '', pr.isSocialApp ? tr(', keselamatan anak') : '']),
      icon: Icons.policy_outlined,
      width: 760,
      height: 720,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Tutup'))),
        ElevatedButton.icon(
          style: primaryButtonStyle(),
          onPressed: busy ? null : _go,
          icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.publish_rounded),
          label: Text(tr('Buat & publikasikan')),
        ),
      ],
      child: ListView(children: [
        GroupLabel(tr('Data yang terdeteksi di aplikasi')),
        if (uses.isEmpty) Text(tr('Tidak ada SDK pengumpul data yang terdeteksi'), style: YmTextStyles.bodySm),
        for (final u in uses)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('• ${u.source}: ${u.data.join(', ')}${u.shared ? ' (${tr('dibagikan')})' : ''}', style: YmTextStyles.bodySm),
          ),
        const SizedBox(height: 10),
        fieldRow([
          DhField(appName, tr('Nama aplikasi'), icon: Icons.apps_rounded),
          DhField(developer, tr('Nama developer / perusahaan'), icon: Icons.business_outlined, hint: 'Infinisynx Teknolab Indonesia'),
        ]),
        DhField(email, tr('Email kontak (tampil di halaman)'), icon: Icons.email_outlined, hint: 'support@batamchitchat.com'),
        if (pr.hasLogin)
          DhField(steps, tr('Langkah hapus akun di aplikasi'), icon: Icons.person_remove_outlined, maxLines: 2, hint: tr('Buka aplikasi → Profil → Pengaturan → Hapus akun → konfirmasi')),
        if (pr.isSocialApp) DhField(childContact, tr('Penanggung jawab keselamatan anak (nama)'), icon: Icons.child_care_outlined),
        Text(
          tr('Halaman juga disimpan di store/legal/ di project. Di-host di repo publik terpisah "<repo>-legal" — kode aplikasimu tetap private. Periksa isinya sekali sebelum dipakai; ini bukan nasihat hukum.'),
          style: YmTextStyles.bodySm,
        ),
        const SizedBox(height: 10),
        _link(tr('Kebijakan privasi'), pr.privacyPolicyUrl),
        _link(tr('Hapus akun'), pr.deleteAccountUrl),
        _link(tr('Keselamatan anak'), pr.childSafetyUrl),
        if (logs.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF0A0F1A), borderRadius: BorderRadius.circular(10)),
            child: SelectableText(logs.join('\n'), style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: Color(0xFFD7DCE3))),
          ),
        const SizedBox(height: 14),
        GroupLabel(tr('Panduan jawaban Keamanan Data')),
        Row(children: [
          Expanded(child: SelectableText(dataSafetyGuide(pr, uses), style: YmTextStyles.bodySm)),
          IconButton(tooltip: tr('Salin'), onPressed: () => Clipboard.setData(ClipboardData(text: dataSafetyGuide(pr, uses))), icon: const Icon(Icons.copy_rounded)),
        ]),
      ]),
    );
  }
}
