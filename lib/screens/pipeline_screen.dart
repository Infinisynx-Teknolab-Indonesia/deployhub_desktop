import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/ai_fixer.dart';
import 'listing_dialog.dart';
import '../services/gradle_fixer.dart';
import '../services/pipeline.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../utils.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';
import 'aab_report_dialog.dart';
import 'project_editor.dart';

class PipelineScreen extends StatelessWidget {
  const PipelineScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final run = app.currentRun;
        if (run == null) {
          return PageBody(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              PageHeader(crumbs: [appName, tr('Deploy'), tr('Pipeline berjalan')], title: tr('Pipeline berjalan')),
              const SizedBox(height: 24),
              Panel(
                child: EmptyState(
                  icon: Icons.play_circle_outline_rounded,
                  title: tr('Belum ada pipeline berjalan'),
                  message: tr('Klik "Deploy Android" atau "Deploy iOS" di halaman Proyek. Langkah dan log tampil di sini secara langsung.'),
                  action: ElevatedButton.icon(
                    style: primaryButtonStyle(),
                    onPressed: () => nav.value = 'projects',
                    icon: const Icon(Icons.folder_copy_outlined),
                    label: Text(tr('Buka Proyek')),
                  ),
                ),
              ),
            ]),
          );
        }
        return _RunView(key: ValueKey(run.id), run: run);
      },
    );
  }
}

class _RunView extends StatefulWidget {
  const _RunView({super.key, required this.run});
  final PipelineRun run;

  @override
  State<_RunView> createState() => _RunViewState();
}

class _RunViewState extends State<_RunView> {
  final scroll = ScrollController();
  bool follow = true;
  Timer? ticker;

  @override
  void initState() {
    super.initState();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.run.isRunning && mounted) setState(() {});
    });
    scroll.addListener(() {
      if (!scroll.hasClients) return;
      follow = scroll.position.pixels >= scroll.position.maxScrollExtent - 40;
    });
  }

  @override
  void dispose() {
    ticker?.cancel();
    scroll.dispose();
    super.dispose();
  }

  void _autoScroll() {
    if (!follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  Color _lineColor(String l) {
    final s = l.toLowerCase();
    if (l.startsWith('━━━')) return const Color(0xFF9DB2FF);
    if (l.startsWith('✔')) return const Color(0xFF4ADE9F);
    if (l.startsWith('✖') || s.contains('error') || s.contains('failure')) return const Color(0xFFFF8A80);
    if (l.startsWith('⚠') || s.contains('warning')) return const Color(0xFFFBBF6A);
    if (l.startsWith('\$ ') || l.startsWith('mac\$ ')) return const Color(0xFF8B95A7);
    return const Color(0xFFD7DCE3);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.run,
      builder: (context, _) {
        final run = widget.run;
        _autoScroll();
        final done = run.steps.where((s) => s.status == StepStatus.success || s.status == StepStatus.skipped).length;
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PageHeader(
              crumbs: [appName, tr('Deploy'), tr('Pipeline berjalan')],
              title: '${run.project.name} — ${run.platform == 'ios' ? 'iOS' : 'Android'}',
              subtitle: tr('Versi {0} • mulai {1} • {2}',
                  [run.version.isEmpty ? '-' : run.version, fmtTime(run.startedAt), fmtDuration(run.elapsed)]),
              badge: statusChip(run.status.name),
              actions: [
                OutlinedButton.icon(
                  style: outlineButtonStyle(),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: run.logs.join('\n')));
                    showSnack(context, tr('Log disalin'));
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: Text(tr('Salin log')),
                ),
                if (!run.isRunning && run.platform == 'android') AabReportButton(key: ValueKey('rep-${run.id}'), runId: run.id),
                if (!run.isRunning && run.rerun != null)
                  ElevatedButton.icon(
                    style: primaryButtonStyle(),
                    onPressed: app.isRunning ? null : () => run.rerun!(),
                    icon: const Icon(Icons.replay_rounded),
                    label: Text(tr('Jalankan ulang')),
                  ),
                if (run.isRunning)
                  ElevatedButton.icon(
                    style: primaryButtonStyle(color: YmColors.danger),
                    onPressed: run.cancel,
                    icon: const Icon(Icons.stop_rounded),
                    label: Text(tr('Batalkan')),
                  ),
              ],
            ),
            if (!run.isRunning && run.vars['playDraft'] == '1') ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: YmColors.warningSoft, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Icon(Icons.info_outline_rounded, color: YmColors.onWarningSoft),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tr('AAB sudah terupload sebagai DRAFT — belum dipublikasikan. Aplikasi ini masih berstatus Draf di Play Console, dan aturan Google mengharuskan publikasi pertama diklik manual. Buka Play Console → Pengujian internal → Simpan dan publikasikan (sekali saja). Upload berikutnya akan langsung terpublikasi.'),
                      style: YmTextStyles.bodySm.copyWith(color: YmColors.onWarningSoft, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    style: primaryButtonStyle(),
                    onPressed: () => launchUrl(Uri.parse('https://play.google.com/console')),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: Text(tr('Buka Play Console')),
                  ),
                ]),
              ),
            ],
            if (run.awaitingApproval) ...[
              const SizedBox(height: 14),
              _ApprovalPanel(run: run),
            ],
            if (run.status == RunStatus.failed && run.rerun != null) ...[
              const SizedBox(height: 14),
              _FailedHelp(run: run),
            ],
            const SizedBox(height: 18),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: 330,
                  child: Panel(
                    title: tr('Langkah'),
                    icon: Icons.account_tree_outlined,
                    expand: true,
                    padding: const EdgeInsets.all(16),
                    titleBadge: SoftChip.neutral('$done/${run.steps.length}'),
                    child: Column(children: [
                      ProgressBar(value: run.steps.isEmpty ? 0 : done / run.steps.length),
                      const SizedBox(height: 10),
                      Expanded(
                        child: ListView(children: [
                          for (final s in run.steps)
                            Container(
                              margin: const EdgeInsets.only(bottom: 2),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: s.status == StepStatus.running ? YmColors.primarySoft : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(children: [
                                stepIcon(s.status),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    s.title,
                                    style: YmTextStyles.labelMd.copyWith(
                                      color: s.status == StepStatus.skipped ? YmColors.outline : YmColors.textDark,
                                      decoration: s.status == StepStatus.skipped ? TextDecoration.lineThrough : null,
                                      fontWeight: s.status == StepStatus.running ? FontWeight.w600 : FontWeight.w500,
                                    ),
                                  ),
                                ),
                                if (s.duration != null) Text(fmtDuration(s.duration!), style: YmTextStyles.labelSm),
                              ]),
                            ),
                        ]),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0F1A),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: shadowSm,
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF1E2638)))),
                        child: Row(children: [
                          for (final c in const [Color(0xFFFF5F57), Color(0xFFFEBC2E), Color(0xFF28C840)])
                            Container(
                                margin: const EdgeInsets.only(right: 6),
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                          const SizedBox(width: 8),
                          Text('${tr('Log')} • ${run.logs.length}',
                              style: const TextStyle(fontFamily: kFont, color: Color(0xFF8B95A7), fontSize: 12)),
                        ]),
                      ),
                      Expanded(
                        child: SelectionArea(
                          child: ListView.builder(
                            controller: scroll,
                            padding: const EdgeInsets.all(16),
                            itemCount: run.logs.length,
                            itemBuilder: (_, i) {
                              final l = run.logs[i];
                              return Text(
                                l,
                                style: TextStyle(
                                  fontFamily: 'Consolas',
                                  fontFamilyFallback: const ['Menlo', 'monospace'],
                                  fontSize: 12.5,
                                  height: 1.4,
                                  color: _lineColor(l),
                                  fontWeight: l.startsWith('━━━') ? FontWeight.w700 : null,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
          ]),
        );
      },
    );
  }
}


/// Panel bantuan saat pipeline gagal: apa yang kurang + tombol perbaiki / jalankan ulang.
class _FailedHelp extends StatelessWidget {
  const _FailedHelp({required this.run});
  final PipelineRun run;

  @override
  Widget build(BuildContext context) {
    final failed = run.steps.where((s) => s.status == StepStatus.failed).firstOrNull;
    final checks = failed?.title == tr('Cek kelayakan rilis');
    // baris "✖ [Grup] Judul — detail" dari hasil cek
    final fails = run.logs.where((l) => l.startsWith('✖ [')).map((l) => l.substring(2)).toList();
    final pr = app.projects.where((x) => x.id == run.project.id).firstOrNull;
    final fixes = autoFixesFromLog(run.logs, root: run.project.localPath, packageName: run.project.packageName, flutterCmd: app.settings.flutterCmd);

    Future<void> editProject() async {
      if (pr == null) return;
      final np = await showDialog<Project>(context: context, builder: (_) => ProjectEditor(project: Project.fromJson(pr.toJson())));
      if (np != null) await app.upsertProject(np);
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: YmColors.dangerSoft, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.error_outline_rounded, color: YmColors.onDangerSoft),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              checks
                  ? tr('Berhenti di "Cek kelayakan rilis": {0} isian belum lengkap. Belum ada yang di-build atau diupload.', [fails.length])
                  : tr('Gagal di langkah "{0}". Lihat baris ✖ di log untuk penyebabnya.', [failed?.title ?? '-']),
              style: YmTextStyles.labelLg.copyWith(color: YmColors.onDangerSoft, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
        if (checks && fails.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final f in fails.take(8))
            Padding(
              padding: const EdgeInsets.only(left: 32, bottom: 2),
              child: Text('• $f', style: YmTextStyles.bodySm.copyWith(color: YmColors.onDangerSoft)),
            ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: Text(
              tr('Untuk aplikasi yang sudah live, data ini biasanya sudah diisi di Play Console — DeployHub hanya belum tahu. Isi sekali di Edit proyek supaya cek berikutnya hijau, atau lanjutkan tanpa cek.'),
              style: YmTextStyles.bodySm.copyWith(color: YmColors.onDangerSoft),
            ),
          ),
        ],
        if (fixes.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: YmColors.surface, borderRadius: BorderRadius.circular(10)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(Icons.auto_fix_high_rounded, color: YmColors.primary, size: 20),
                const SizedBox(width: 8),
                Text(tr('Bisa diperbaiki otomatis'), style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 6),
              for (final f in fixes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• ${f.problem}\n   → ${f.action}', style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark)),
                ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: ElevatedButton.icon(
                  style: primaryButtonStyle(color: YmColors.success),
                  onPressed: app.isRunning
                      ? null
                      : () async {
                          final done = <String>[];
                          for (final f in fixes) {
                            try {
                              done.addAll(await f.run());
                            } catch (e) {
                              done.add('✖ $e');
                            }
                          }
                          if (!context.mounted) return;
                          showSnack(context, done.isEmpty ? tr('Tidak ada yang diubah') : done.join(' • '));
                          await run.rerun!();
                        },
                  icon: const Icon(Icons.build_circle_outlined),
                  label: Text(tr('Perbaiki otomatis & jalankan ulang')),
                ),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (checks && pr != null)
            ElevatedButton.icon(
              style: primaryButtonStyle(),
              onPressed: () async {
                await editProject();
              },
              icon: const Icon(Icons.edit_note_rounded),
              label: Text(tr('Isi data proyek')),
            ),
          if (!checks && AiFixer.instance.ready && run.project.localPath.isNotEmpty)
            ElevatedButton.icon(
              style: primaryButtonStyle(),
              onPressed: app.isRunning ? null : () => _aiFix(context, run),
              icon: const Icon(Icons.psychology_alt_outlined),
              label: Text(tr('Perbaiki dengan AI & jalankan ulang')),
            ),
          OutlinedButton.icon(
            style: outlineButtonStyle(),
            onPressed: app.isRunning ? null : () => run.rerun!(),
            icon: const Icon(Icons.replay_rounded),
            label: Text(tr('Jalankan ulang')),
          ),
          if (checks)
            OutlinedButton.icon(
              style: outlineButtonStyle(),
              onPressed: app.isRunning
                  ? null
                  : () async {
                      final ok = await confirmDialog(context,
                          title: tr('Lanjutkan tanpa cek kelayakan?'),
                          message: tr('Build & upload tetap jalan. Pastikan isian yang kurang (kebijakan privasi, akun demo, link hapus akun, CSAE) memang sudah diisi di Play Console — kalau belum, review Google bisa menolak.'),
                          ok: tr('Lanjutkan'));
                      if (ok) await run.rerun!(skipChecks: true);
                    },
              icon: const Icon(Icons.skip_next_rounded),
              label: Text(tr('Lanjutkan tanpa cek (aplikasi sudah live)')),
            ),
        ]),
      ]),
    );
  }

  /// Kirim log langkah yang gagal ke AI → terapkan perbaikan → jalankan ulang.
  Future<void> _aiFix(BuildContext context, PipelineRun run) async {
    final failed = run.steps.where((s) => s.status == StepStatus.failed).firstOrNull;
    final lines = <String>[];
    final progress = ValueNotifier<List<String>>([]);
    void log(String l) => progress.value = [...progress.value, l];
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(tr('AI sedang memperbaiki…')),
        content: SizedBox(
          width: 560,
          child: ValueListenableBuilder<List<String>>(
            valueListenable: progress,
            builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const LinearProgressIndicator(),
              const SizedBox(height: 10),
              for (final l in v.reversed.take(8).toList().reversed) Text(l, style: YmTextStyles.bodySm),
            ]),
          ),
        ),
      ),
    );
    AiFixResult? fx;
    Object? err;
    try {
      final tail = run.logs.length > 600 ? run.logs.sublist(run.logs.length - 600) : run.logs;
      lines.addAll(tail);
      fx = await AiFixer.instance.fix(
        root: run.project.localPath,
        task: 'Langkah "${failed?.title ?? '-'}" gagal',
        logs: lines,
        log: log,
      );
      await AiFixer.instance.runCommands(run.project.localPath, fx.commands, app.settings.flutterCmd, log);
    } catch (e) {
      err = e;
    }
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (err != null || fx == null || !fx.ok) {
      showSnack(context, err != null ? 'AI: $err' : tr('AI tidak menemukan perbaikan: {0}', [fx?.explanation ?? '-']), error: true);
      return;
    }
    final go = await confirmDialog(context,
        title: tr('AI mengubah {0} file', [fx.changed.length]),
        message: '${fx.explanation}\n\n${fx.changed.map((f) => '• $f').join('\n')}\n\n${tr('File lama dibackup ke *.deployhub.bak. Jalankan ulang pipeline sekarang?')}',
        ok: tr('Jalankan ulang'));
    if (go) await run.rerun!();
  }
}

/// Panel "Upload sekarang?" — muncul setelah cek kelayakan, build, dan laporan AAB selesai.
class _ApprovalPanel extends StatelessWidget {
  const _ApprovalPanel({required this.run});
  final PipelineRun run;

  @override
  Widget build(BuildContext context) {
    final b = run.approvalBlockers;
    final ok = b.isEmpty;
    final bg = ok ? YmColors.successSoft : YmColors.warningSoft;
    final fg = ok ? YmColors.onSuccessSoft : YmColors.onWarningSoft;
    final pr = app.projects.where((x) => x.id == run.project.id).firstOrNull;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(ok ? Icons.verified_rounded : Icons.warning_amber_rounded, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ok
                  ? tr('Semua cek beres — AAB siap diupload ke Google Play.')
                  : tr('AAB sudah jadi, tapi ada {0} hal yang harus dibereskan sebelum upload.', [b.length]),
              style: YmTextStyles.labelLg.copyWith(color: fg, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        for (final x in b)
          Padding(
            padding: const EdgeInsets.only(left: 32, bottom: 2),
            child: Row(children: [
              Expanded(child: Text('✖ $x', style: YmTextStyles.bodySm.copyWith(color: YmColors.danger, fontWeight: FontWeight.w600))),
              if (pr != null && fixKindFor(x) != null)
                TextButton.icon(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () => openFixFor(context, pr, x, run),
                  icon: const Icon(Icons.build_circle_outlined, size: 16),
                  label: Text(tr('Perbaiki')),
                ),
            ]),
          ),
        for (final x in run.approvalInfo)
          Padding(
            padding: const EdgeInsets.only(left: 32, bottom: 2),
            child: Text('• $x', style: YmTextStyles.bodySm.copyWith(color: fg)),
          ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ElevatedButton.icon(
            style: primaryButtonStyle(color: ok ? YmColors.success : null),
            onPressed: () async {
              if (!ok) {
                final yes = await confirmDialog(context,
                    title: tr('Tetap upload?'),
                    message: tr('Masih ada {0} masalah. Google Play bisa menolak AAB atau review bisa gagal. Yakin tetap upload?', [b.length]),
                    ok: tr('Tetap upload'),
                    danger: true);
                if (!yes) return;
              }
              run.approve(true);
            },
            icon: const Icon(Icons.cloud_upload_rounded),
            label: Text(ok ? tr('Upload sekarang') : tr('Tetap upload')),
          ),
          OutlinedButton.icon(
            style: outlineButtonStyle(),
            onPressed: () => run.approve(false),
            icon: const Icon(Icons.inventory_2_outlined),
            label: Text(tr('Jangan upload (simpan AAB saja)')),
          ),
          AabReportButton(key: ValueKey('rep-a-${run.id}'), runId: run.id),
          if (!ok && pr != null)
            TextButton.icon(
              onPressed: () => recheckBlockers(context, pr, run),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr('Cek ulang')),
            ),
          if (!ok && pr != null)
            TextButton.icon(
              onPressed: () async {
                final np = await showDialog<Project>(context: context, builder: (_) => ProjectEditor(project: Project.fromJson(pr.toJson())));
                if (np != null) await app.upsertProject(np);
              },
              icon: const Icon(Icons.edit_note_rounded),
              label: Text(tr('Isi data proyek')),
            ),
        ]),
        if (!ok)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              tr('Setelah membereskan: klik "Jangan upload", lalu "Jalankan ulang" — semua dicek lagi dan versi dinaikkan otomatis.'),
              style: YmTextStyles.bodySm.copyWith(color: fg),
            ),
          ),
      ]),
    );
  }
}
