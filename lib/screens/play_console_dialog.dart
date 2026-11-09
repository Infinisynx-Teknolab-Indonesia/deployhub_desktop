import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import 'legal_dialog.dart';
import '../models.dart';
import '../services/play_console_tasks.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../utils.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

/// Checklist Play Console (bagian tanpa API) + pelacak pengujian tertutup.
class PlayConsoleDialog extends StatefulWidget {
  const PlayConsoleDialog({super.key, required this.project});
  final Project project;

  @override
  State<PlayConsoleDialog> createState() => _PlayConsoleDialogState();
}

class _PlayConsoleDialogState extends State<PlayConsoleDialog> {
  late final Project pr = Project.fromJson(widget.project.toJson());
  late final tasks = consoleTasks(pr);
  late final answers = {
    for (final t in tasks) t.key: TextEditingController(text: pr.consoleAnswers[t.key] ?? t.suggestion),
  };
  late final groups = TextEditingController(text: pr.testerGroups);
  late final testerCount = TextEditingController(text: '${pr.testerCount}');
  String? open;

  @override
  void dispose() {
    for (final c in answers.values) {
      c.dispose();
    }
    groups.dispose();
    testerCount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    for (final t in tasks) {
      final v = answers[t.key]!.text;
      if (v == t.suggestion) {
        pr.consoleAnswers.remove(t.key); // tetap mengikuti data proyek terbaru
      } else {
        pr.consoleAnswers[t.key] = v;
      }
    }
    pr.testerGroups = groups.text.trim();
    pr.testerCount = int.tryParse(testerCount.text.trim()) ?? 0;
    await app.upsertProject(pr);
    if (mounted) {
      Navigator.pop(context);
      showSnack(context, tr('Checklist Play Console disimpan'));
    }
  }

  Future<void> _pickStart() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(pr.closedTestStart) ?? now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
    );
    if (d != null) setState(() => pr.closedTestStart = d.toIso8601String());
  }

  @override
  Widget build(BuildContext context) {
    pr.testerCount = int.tryParse(testerCount.text) ?? 0;
    final ct = ClosedTestStatus(pr);
    final done = tasks.where((x) => pr.consoleDone.contains(x.key)).length;

    return DhDialog(
      title: tr('Checklist Play Console'),
      subtitle: pr.name,
      icon: Icons.checklist_rounded,
      width: 900,
      headerTrailing: TextButton.icon(
        onPressed: () => launchUrl(Uri.parse('https://play.google.com/console')),
        icon: const Icon(Icons.open_in_new_rounded, size: 16),
        label: Text(tr('Buka Play Console')),
      ),
      actions: [
        OutlinedButton(style: outlineButtonStyle(), onPressed: () => Navigator.pop(context), child: Text(tr('Batal'))),
        OutlinedButton.icon(
          style: outlineButtonStyle(),
          onPressed: () => showDialog(context: context, builder: (_) => LegalPagesDialog(project: widget.project)),
          icon: const Icon(Icons.policy_outlined),
          label: Text(tr('Kebijakan privasi & Keamanan Data')),
        ),
        ElevatedButton.icon(style: primaryButtonStyle(), onPressed: _save, icon: const Icon(Icons.save_outlined), label: Text(tr('Simpan'))),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DialogSection(
          title: tr('Pengujian tertutup'),
          icon: Icons.groups_outlined,
          subtitle: tr('Tester disinkron otomatis lewat Google Group saat deploy.'),
          children: [
            SettingRow(
              title: tr('Akun developer pribadi'),
              subtitle: tr('Dibuat setelah 13 Nov 2023 → wajib 12 tester selama 14 hari sebelum production'),
              trailing: Switch(value: pr.isPersonalAccount, onChanged: (v) => setState(() => pr.isPersonalAccount = v)),
            ),
            const SizedBox(height: 10),
            fieldRow([
              DhField(groups, tr('Google Group tester (pisahkan koma)'),
                  icon: Icons.group_add_outlined, hint: 'tester-batamchitchat@googlegroups.com'),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DropdownButtonFormField<String>(
                  value: ['alpha', 'beta'].contains(pr.closedTestTrack) ? pr.closedTestTrack : 'alpha',
                  isExpanded: true,
                  decoration: fieldDecoration('Track'),
                  items: [
                    DropdownMenuItem(value: 'alpha', child: Text(tr('alpha (tertutup)'))),
                    DropdownMenuItem(value: 'beta', child: Text(tr('beta (terbuka)'))),
                  ],
                  onChanged: (v) => setState(() => pr.closedTestTrack = v!),
                ),
              ),
            ], flex: [3, 2]),
            fieldRow([
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: OutlinedButton.icon(
                  style: outlineButtonStyle(),
                  onPressed: _pickStart,
                  icon: const Icon(Icons.event_outlined),
                  label: Text(pr.closedTestStart.isEmpty
                      ? tr('Pilih tanggal mulai pengujian')
                      : tr('Mulai: {0}', [fmtTime(DateTime.parse(pr.closedTestStart)).split(' ').first])),
                ),
              ),
              DhField(testerCount, tr('Jumlah tester yang sudah ikut (opt-in)'),
                  icon: Icons.people_outline_rounded, keyboard: TextInputType.number, onChanged: (_) => setState(() {})),
            ]),
            if (pr.isPersonalAccount) ...[
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Hari: {0}/{1}', [ct.days.clamp(0, 999), ClosedTestStatus.minDays]), style: YmTextStyles.labelSm),
                    const SizedBox(height: 6),
                    ProgressBar(value: ct.days / ClosedTestStatus.minDays, color: ct.daysOk ? YmColors.success : YmColors.primary),
                  ]),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Tester: {0}/{1}', [pr.testerCount, ClosedTestStatus.minTesters]), style: YmTextStyles.labelSm),
                    const SizedBox(height: 6),
                    ProgressBar(
                        value: pr.testerCount / ClosedTestStatus.minTesters,
                        color: ct.testersOk ? YmColors.success : YmColors.primary),
                  ]),
                ),
              ]),
              const SizedBox(height: 12),
              ct.ready
                  ? SoftChip.success(ct.describe(), icon: Icons.verified_rounded)
                  : SoftChip.warning(ct.describe(), icon: Icons.hourglass_bottom_rounded),
              const SizedBox(height: 12),
            ],
          ],
        ),
        Row(children: [
          Expanded(child: GroupLabel(tr('Konten aplikasi — {0}/{1} selesai', [done, tasks.length]))),
          SizedBox(width: 160, child: ProgressBar(value: tasks.isEmpty ? 0 : done / tasks.length, color: YmColors.success)),
        ]),
        const SizedBox(height: 4),
        for (final task in tasks)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: YmColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: open == task.key ? YmColors.primary.withOpacity(0.5) : YmColors.line),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => open = open == task.key ? null : task.key),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
                  child: Row(children: [
                    Checkbox(
                      value: pr.consoleDone.contains(task.key),
                      onChanged: (v) => setState(() {
                        pr.consoleDone.remove(task.key);
                        if (v == true) pr.consoleDone.add(task.key);
                      }),
                    ),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(task.title, style: YmTextStyles.username),
                        Text(task.where, style: YmTextStyles.bodySm),
                      ]),
                    ),
                    if (task.auto.isNotEmpty) ...[SoftChip.primary(tr('Otomatis'), icon: Icons.bolt_rounded), const SizedBox(width: 8)],
                    Icon(open == task.key ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: YmColors.outline),
                  ]),
                ),
              ),
              if (open == task.key)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (task.auto.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text('⚡ ${task.auto}', style: YmTextStyles.bodySm.copyWith(color: YmColors.primary)),
                      ),
                    DhField(
                      answers[task.key]!,
                      tr('Jawaban siap tempel'),
                      maxLines: null,
                      suffix: IconButton(
                        tooltip: tr('Salin'),
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: answers[task.key]!.text));
                          showSnack(context, tr('"{0}" disalin', [task.title]));
                        },
                      ),
                    ),
                  ]),
                ),
            ]),
          ),
      ]),
    );
  }
}
