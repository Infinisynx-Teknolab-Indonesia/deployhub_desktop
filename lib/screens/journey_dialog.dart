import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/android_pipeline.dart';
import '../services/ios_pipeline.dart';
import '../services/release_checks.dart' show storeInfoText;
import '../services/storage.dart';
import '../services/journey.dart';
import '../services/play_auth.dart';
import '../services/store_metadata.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';
import 'deploy_dialogs.dart';
import 'play_console_dialog.dart';
import 'project_editor.dart';

/// Perjalanan rilis: tahap demi tahap sampai aplikasi tampil di Play Store.
class JourneyDialog extends StatefulWidget {
  const JourneyDialog({super.key, required this.projectId, this.platform = 'android'});
  final String projectId;
  final String platform; // android | ios

  @override
  State<JourneyDialog> createState() => _JourneyDialogState();
}

class _JourneyDialogState extends State<JourneyDialog> {
  List<JourneyStage>? stages;
  String? open;
  late String platform = widget.platform;

  Project? get pr {
    for (final p in app.projects) {
      if (p.id == widget.projectId) return p;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = pr;
    if (p == null) return;
    final s = platform == 'ios'
        ? buildIosJourney(p, app.history, app.settings)
        : await buildJourney(p, app.history, await PlayAuth.globalReady());
    if (!mounted) return;
    setState(() {
      stages = s;
      if (open == null || !s.any((x) => x.key == open)) {
        open = s.where((x) => x.state == StageState.current).map((x) => x.key).firstOrNull;
      }
    });
  }

  Future<void> _deploy(String track) async {
    final p = pr!;
    final o = await showDialog<AndroidOptions>(
        context: context, builder: (_) => AndroidDeployDialog(project: p, initialTrack: track));
    if (o == null || !mounted) return;
    await app.startAndroid(p, o);
    if (!mounted) return;
    Navigator.pop(context);
    nav.value = 'pipeline';
  }

  Future<void> _deployIos(String mode) async {
    final p = pr!;
    final o = await showDialog<IosOptions>(context: context, builder: (_) => IosDeployDialog(project: p, initialMode: mode));
    if (o == null || !mounted) return;
    await app.startIos(p, o);
    if (!mounted) return;
    Navigator.pop(context);
    nav.value = 'pipeline';
  }

  Future<void> _act(JourneyStage s) async {
    final p = pr!;
    switch (s.action) {
      case StageAction.editProject:
        final np = await showDialog<Project>(context: context, builder: (_) => ProjectEditor(project: Project.fromJson(p.toJson())));
        if (np != null) await app.upsertProject(np);
      case StageAction.settings:
        Navigator.pop(context);
        nav.value = 'settings';
        return;
      case StageAction.manual:
        final copy = Project.fromJson(p.toJson());
        copy.journeyDone.remove(s.key);
        if (!s.done) copy.journeyDone.add(s.key);
        await app.upsertProject(copy);
      case StageAction.console:
      case StageAction.testers:
        await showDialog(context: context, builder: (_) => PlayConsoleDialog(project: p));
      case StageAction.storeTemplate:
        final created = await createStoreTemplate(p);
        if (mounted) {
          showSnack(context, created.isEmpty ? tr('Folder store/ sudah lengkap') : tr('Dibuat {0} file di {1}', [created.length, storeDir(p)]));
        }
      case StageAction.deployInternal:
        await _deploy('internal');
        return;
      case StageAction.deployProduction:
        await _deploy('production');
        return;
      case StageAction.deployTestflight:
        await _deployIos('testflight');
        return;
      case StageAction.deployAppStore:
        await _deployIos('appstore');
        return;
      case StageAction.copyStoreInfo:
        final pw = await Storage.secret(Secrets.demoPassword(p.id));
        await Clipboard.setData(ClipboardData(text: storeInfoText(p, pw)));
        if (mounted) showSnack(context, tr('Info akun demo & link disalin — tempel di App Store Connect → App Review Information'));
        final copy = Project.fromJson(p.toJson());
        if (!copy.journeyDone.contains(s.key)) {
          final ok = await confirmDialog(context,
              title: tr('Informasi App Store sudah lengkap?'),
              message: tr('Tandai tahap ini selesai kalau screenshot, deskripsi, App Privacy, dan App Review Information sudah diisi di App Store Connect.'),
              ok: tr('Ya, sudah lengkap'));
          if (ok) {
            copy.journeyDone.add(s.key);
            await app.upsertProject(copy);
          }
        } else {
          copy.journeyDone.remove(s.key);
          await app.upsertProject(copy);
        }
      case StageAction.none:
        break;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = pr;
    final list = stages;
    final done = list?.where((s) => s.state == StageState.done).length ?? 0;
    return DhDialog(
      title: tr('Perjalanan rilis'),
      subtitle: p?.name ?? '',
      icon: Icons.route_outlined,
      width: 860,
      headerTrailing: TextButton.icon(
        onPressed: () => launchUrl(Uri.parse(platform == 'ios' ? 'https://appstoreconnect.apple.com' : 'https://play.google.com/console')),
        icon: const Icon(Icons.open_in_new_rounded, size: 16),
        label: Text(platform == 'ios' ? tr('Buka App Store Connect') : tr('Buka Play Console')),
      ),
      actions: [ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(context), child: Text(tr('Tutup')))],
      child: list == null || p == null
          ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 8, children: [
                QuickChip(
                  label: 'Google Play',
                  icon: Icons.shop_rounded,
                  selected: platform == 'android',
                  onTap: () {
                    platform = 'android';
                    open = null;
                    _load();
                  },
                ),
                QuickChip(
                  label: 'App Store',
                  icon: Icons.apple,
                  selected: platform == 'ios',
                  onTap: () {
                    platform = 'ios';
                    open = null;
                    _load();
                  },
                ),
              ]),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(
                      child: Text(
                        done == list.length
                            ? tr('Selesai — aplikasi sudah dirilis ke publik 🎉')
                            : tr('{0} dari {1} tahap selesai. Berikutnya: {2}',
                                [done, list.length, list.firstWhere((s) => s.state == StageState.current).title]),
                        style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text('${(done * 100 / list.length).round()}%', style: YmTextStyles.headlineSm.copyWith(color: YmColors.primary)),
                  ]),
                  const SizedBox(height: 10),
                  ProgressBar(value: done / list.length, height: 8),
                ]),
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < list.length; i++) _stage(i, list[i], i == list.length - 1, p),
            ]),
    );
  }

  Widget _stage(int i, JourneyStage s, bool last, Project p) {
    final locked = s.state == StageState.locked;
    final current = s.state == StageState.current;
    final expanded = open == s.key && !locked;
    final (Color dotBg, Color dotFg, Widget dotChild) = switch (s.state) {
      StageState.done => (YmColors.success, Colors.white, const Icon(Icons.check_rounded, size: 16, color: Colors.white)),
      StageState.current => (YmColors.primary, YmColors.onPrimary,
          Text('${i + 1}', style: YmTextStyles.labelMd.copyWith(color: YmColors.onPrimary, fontWeight: FontWeight.w700))),
      StageState.locked => (YmColors.surfaceContainer, YmColors.outline, Icon(Icons.lock_outline_rounded, size: 14, color: YmColors.outline)),
    };

    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 40,
          child: Column(children: [
            Container(width: 30, height: 30, alignment: Alignment.center, decoration: BoxDecoration(color: dotBg, shape: BoxShape.circle), child: dotChild),
            if (!last)
              Expanded(
                child: Container(width: 2, margin: const EdgeInsets.symmetric(vertical: 4), color: s.state == StageState.done ? YmColors.success : YmColors.line),
              ),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Opacity(
            opacity: locked ? 0.55 : 1,
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: current ? YmColors.surface : YmColors.surfaceAlt.withOpacity(0.6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: current ? YmColors.primary.withOpacity(0.5) : YmColors.line),
                boxShadow: current ? shadowSm : null,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: locked ? null : () => setState(() => open = expanded ? null : s.key),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(s.title, style: YmTextStyles.username.copyWith(fontSize: 14)),
                          if (locked)
                            Text(tr('Terbuka setelah tahap sebelumnya selesai'), style: YmTextStyles.bodySm)
                          else if (s.progressText.isNotEmpty)
                            Text(s.progressText, style: YmTextStyles.bodySm),
                        ]),
                      ),
                      switch (s.state) {
                        StageState.done => SoftChip.success(tr('Selesai')),
                        StageState.current => SoftChip.primary(tr('Sekarang'), dot: YmColors.primary),
                        StageState.locked => SoftChip.neutral(tr('Terkunci')),
                      },
                      if (!locked) ...[
                        const SizedBox(width: 6),
                        Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: YmColors.outline),
                      ],
                    ]),
                  ),
                ),
                if (expanded)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(s.description, style: YmTextStyles.bodyMd.copyWith(color: YmColors.textDark)),
                      if (s.progress != null) ...[
                        const SizedBox(height: 10),
                        ProgressBar(value: s.progress!, color: s.done ? YmColors.success : YmColors.primary),
                      ],
                      if (s.key == 'recruit') ...[const SizedBox(height: 12), _recruitBox(p)],
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        if (s.action != StageAction.none)
                          s.manual && s.action == StageAction.manual
                              ? (s.done
                                  ? OutlinedButton.icon(
                                      style: outlineButtonStyle(),
                                      onPressed: () => _act(s),
                                      icon: const Icon(Icons.undo_rounded),
                                      label: Text(tr('Tandai belum')),
                                    )
                                  : ElevatedButton.icon(
                                      style: primaryButtonStyle(),
                                      onPressed: () => _act(s),
                                      icon: const Icon(Icons.check_rounded),
                                      label: Text(s.actionLabel),
                                    ))
                              : ElevatedButton.icon(
                                  style: current ? primaryButtonStyle() : outlineButtonStyle(),
                                  onPressed: app.isRunning &&
                                          (s.action == StageAction.deployInternal ||
                                              s.action == StageAction.deployProduction ||
                                              s.action == StageAction.deployTestflight ||
                                              s.action == StageAction.deployAppStore)
                                      ? null
                                      : () => _act(s),
                                  icon: const Icon(Icons.arrow_forward_rounded),
                                  label: Text(s.actionLabel),
                                ),
                      ]),
                    ]),
                  ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _recruitBox(Project p) {
    final invite = testerInvite(p);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Cara rekrut tester'), style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        for (final line in [
          tr('1. Buat Google Group (groups.google.com), mis. tester-{0}@googlegroups.com', [p.name.toLowerCase().replaceAll(' ', '')]),
          tr('2. Isi alamat grup di "Atur tester & undangan" — DeployHub memasangnya ke track alpha saat deploy'),
          tr('3. Kirim pesan undangan di bawah ke teman/keluarga/komunitas (minimal 12 orang, sebaiknya 15+ untuk cadangan)'),
          tr('4. Cek jumlah tester di Play Console → Pengujian tertutup → Tester, lalu isi angkanya di DeployHub'),
        ])
          Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(line, style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark))),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: YmColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: YmColors.line)),
          child: SelectableText(invite, style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark, height: 1.5)),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            style: outlineButtonStyle(),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: invite));
              showSnack(context, tr('Pesan undangan disalin — tempel di WhatsApp / Telegram'));
            },
            icon: const Icon(Icons.copy_rounded),
            label: Text(tr('Salin pesan undangan')),
          ),
          OutlinedButton.icon(
            style: outlineButtonStyle(),
            onPressed: () => launchUrl(Uri.parse('https://groups.google.com/my-groups')),
            icon: const Icon(Icons.group_add_outlined),
            label: Text(tr('Buka Google Groups')),
          ),
        ]),
      ]),
    );
  }
}
