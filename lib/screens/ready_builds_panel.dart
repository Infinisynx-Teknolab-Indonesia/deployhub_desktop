import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/integrations.dart';
import '../services/hub_client.dart';
import '../services/ready_builds.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

/// Kartu proyek → "Build siap deploy": AAB/IPA otomatis di-build setiap GitHub di-update,
/// deploy tetap manual (1 klik).
class ReadyBuildsPanel extends StatefulWidget {
  const ReadyBuildsPanel({super.key, required this.project});
  final Project project;

  @override
  State<ReadyBuildsPanel> createState() => _ReadyBuildsPanelState();
}

class _ReadyBuildsPanelState extends State<ReadyBuildsPanel> {
  Project get p => widget.project;
  final it = Integrations.instance;

  bool get _auto => it.autoTriggerOn && it.autoTriggerMode == 'ready' && it.autoTriggerProjects.contains(p.id);

  Future<void> _setAuto(bool v) async {
    final hub = Hub.instance;
    if (v && hub.ready && hub.cfg(p.id).autoBuild && hub.cfg(p.id).syncedAt.isNotEmpty) {
      final ok = await confirmDialog(context,
          title: tr('Server sudah build otomatis'),
          message: tr('DeployHub Server sudah mem-build {0} setiap push. Kalau PC juga aktif, satu commit di-build 2 kali. Aktifkan di PC dan matikan di server?', [p.name]),
          ok: tr('Pakai PC saja'));
      if (!ok) return;
      hub.cfg(p.id).autoBuild = false;
      await hub.save();
      try {
        await hub.syncProject(p, app.settings, secrets: false);
      } catch (_) {}
    }
    if (v) {
      it.autoTriggerOn = true;
      it.autoTriggerMode = 'ready';
      if (!it.autoTriggerProjects.contains(p.id)) it.autoTriggerProjects.add(p.id);
    } else {
      it.autoTriggerProjects.remove(p.id);
    }
    await it.save();
    app.restartAutoTrigger();
    if (!mounted) return;
    setState(() {});
    if (v) {
      showSnack(context, tr('Aktif: setiap ada commit baru di {0} ({1}), AAB{2} di-build otomatis. Dicek tiap {3} menit selama DeployHub terbuka / di tray.',
          [p.githubRepo.isEmpty ? p.name : p.githubRepo, p.branch, p.useIos && p.hasIos ? ' + IPA' : '', it.autoTriggerMinutes]));
    }
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return trL('baru saja');
    if (d.inHours < 1) return trL('{0} menit lalu', [d.inMinutes]);
    if (d.inDays < 1) return trL('{0} jam lalu', [d.inHours]);
    return trL('{0} hari lalu', [d.inDays]);
  }

  Future<void> _deploy(String platform) async {
    final b = ReadyBuilds.instance.get(p.id, platform)!;
    var track = p.defaultTrack.isEmpty ? 'internal' : p.defaultTrack;
    var submit = false;
    final notes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(platform == 'ios' ? tr('Deploy ke App Store Connect') : tr('Deploy ke Google Play')),
          content: SizedBox(
            width: 480,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(tr('Build {0} • commit {1} • {2}', [b.version, b.shortCommit.isEmpty ? '-' : b.shortCommit, _ago(b.builtAt)]), style: YmTextStyles.bodySm),
              const SizedBox(height: 12),
              if (platform == 'android')
                DropdownButtonFormField<String>(
                  value: track,
                  decoration: InputDecoration(labelText: tr('Track Google Play'), isDense: true),
                  items: [
                    DropdownMenuItem(value: 'internal', child: Text(tr('Pengujian internal'))),
                    DropdownMenuItem(value: 'alpha', child: Text(tr('Pengujian tertutup (alpha)'))),
                    DropdownMenuItem(value: 'beta', child: Text(tr('Pengujian terbuka (beta)'))),
                    DropdownMenuItem(value: 'production', child: Text(tr('Produksi (publik)'))),
                  ],
                  onChanged: (v) => set(() => track = v ?? 'internal'),
                )
              else
                CheckRow(
                  label: tr('Kirim juga untuk review App Store'),
                  sub: tr('Mati = hanya TestFlight'),
                  value: submit,
                  onChanged: (v) => set(() => submit = v),
                ),
              const SizedBox(height: 10),
              DhField(notes, tr('Catatan rilis'), maxLines: 3, hint: tr('Perbaikan bug dan peningkatan performa')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Batal'))),
            ElevatedButton.icon(
              style: primaryButtonStyle(),
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.rocket_launch_rounded),
              label: Text(tr('Deploy sekarang')),
            ),
          ],
        ),
      ),
    );
    final n = notes.text;
    notes.dispose();
    if (ok != true || !mounted) return;
    try {
      await app.deployReady(p, platform, track: track, releaseNotes: n, submitReview: submit);
      nav.value = 'pipeline';
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  Widget _row(String platform, IconData icon) {
    final b = ReadyBuilds.instance.get(p.id, platform);
    final busy = app.isRunning;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Icon(icon, size: 18, color: YmColors.outline),
        const SizedBox(width: 8),
        Expanded(
          child: b == null
              ? Text(tr('Belum ada build siap'), style: YmTextStyles.bodySm)
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${b.version}${b.shortCommit.isEmpty ? '' : ' • ${b.shortCommit}'} • ${_ago(b.builtAt)}',
                      style: YmTextStyles.labelMd, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (!b.exists)
                    Text(tr('File hilang — build ulang'), style: YmTextStyles.bodySm.copyWith(color: YmColors.danger))
                  else if (b.deployed)
                    Text(tr('✔ sudah dideploy ke {0} • {1}', [b.deployedTrack, _ago(b.deployedAt!)]), style: YmTextStyles.bodySm.copyWith(color: YmColors.success))
                  else
                    Text(tr('Siap — belum dideploy'), style: YmTextStyles.bodySm.copyWith(color: YmColors.warning)),
                ]),
        ),
        if (b != null && b.exists)
          ElevatedButton.icon(
            style: primaryButtonStyle(color: platform == 'ios' ? null : const Color(0xFF0F9D58)),
            onPressed: busy ? null : () => _deploy(platform),
            icon: const Icon(Icons.rocket_launch_rounded, size: 16),
            label: Text(tr('Deploy')),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ios = p.useIos && p.hasIos;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.inventory_2_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('Build siap deploy'), style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700))),
          Tooltip(
            message: p.hasGithub ? tr('Build otomatis setiap ada commit baru di GitHub') : tr('Atur GitHub di Edit proyek dulu'),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(tr('Auto-build saat GitHub update'), style: YmTextStyles.bodySm),
              Switch(value: _auto, onChanged: p.hasGithub ? _setAuto : null),
            ]),
          ),
        ]),
        _row('android', Icons.android_rounded),
        if (ios) _row('ios', Icons.apple),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: app.isRunning
                ? null
                : () {
                    app.buildReady(p);
                    nav.value = 'pipeline';
                  },
            icon: const Icon(Icons.build_rounded, size: 18),
            label: Text(ios ? tr('Build AAB + IPA sekarang') : tr('Build AAB sekarang')),
          ),
        ),
      ]),
    );
  }
}
