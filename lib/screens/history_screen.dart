import 'dart:io';

import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/hub_client.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../utils.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';
import 'aab_report_dialog.dart';

/// Satu baris riwayat deploy (dipakai di Dasbor & Riwayat).
class HistoryTile extends StatelessWidget {
  const HistoryTile({super.key, required this.record, this.dense = false});
  final RunRecord record;
  final bool dense;

  Future<void> _showLog(BuildContext context) async {
    String text;
    if (record.logPath.isEmpty && record.id.startsWith('srv-')) {
      // deploy yang dijalankan server → ambil lognya dari server
      try {
        final r = await Hub.instance.log(int.parse(record.id.substring(4)), 0);
        text = '${r['text'] ?? ''}'.isEmpty ? trL('Log kosong di server.') : '${r['text']}';
      } catch (e) {
        text = trL('Log server tidak bisa diambil: {0}', ['$e']);
      }
    } else {
      final f = File(record.logPath);
      text = await f.exists() ? await f.readAsString() : trL('File log tidak ditemukan.');
    }
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (_) => DhDialog(
        title: '${record.projectName} • ${record.platform == 'ios' ? 'iOS' : 'Android'} • ${record.version}',
        subtitle: '${fmtTime(record.startedAt)} • ${fmtDuration(record.finishedAt.difference(record.startedAt))}',
        icon: Icons.article_outlined,
        width: 980,
        height: 640,
        child: Container(
          decoration: BoxDecoration(color: const Color(0xFF0A0F1A), borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.all(14),
          child: SingleChildScrollView(
            child: SelectableText(text,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 12.5, height: 1.4, color: Color(0xFFD7DCE3))),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = record;
    return HoverCard(
      onTap: () => _showLog(context),
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: dense ? 10 : 14),
      color: Colors.transparent,
      hoverColor: YmColors.surfaceContainer,
      baseShadowOverride: const [],
      hoverShadowOverride: const [],
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
          child: Icon(r.platform == 'ios' ? Icons.apple : Icons.android_rounded,
              size: 20, color: r.platform == 'ios' ? YmColors.textDark : YmColors.success),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${r.projectName}  ${r.version}', style: YmTextStyles.username, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              [timeAgo(r.finishedAt), fmtDuration(r.finishedAt.difference(r.startedAt)), if (r.summary.isNotEmpty) r.summary]
                  .join(' • '),
              style: YmTextStyles.bodySm,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
        const SizedBox(width: 8),
        if (r.platform == 'android') AabReportButton(runId: r.id, compact: true),
        statusChip(r.status),
        if (!dense)
          IconButton(
            tooltip: tr('Hapus riwayat ini'),
            onPressed: () async {
              final ok = await confirmDialog(context,
                  title: tr('Hapus riwayat ini?'),
                  message: tr('"{0} {1}" beserta log dan laporan AAB-nya dihapus dari PC ini. Tidak ada yang berubah di Google Play / App Store.', [r.projectName, r.version]),
                  ok: tr('Hapus'),
                  danger: true);
              if (ok) await app.deleteHistory([r.id]);
            },
            icon: Icon(Icons.delete_outline_rounded, color: YmColors.danger, size: 20),
          ),
      ]),
    );
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String filter = 'all';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final list = app.history.where((r) => switch (filter) {
              'android' => r.platform == 'android',
              'ios' => r.platform == 'ios',
              'failed' => r.status == 'failed',
              _ => true,
            }).toList();
        return PageBody(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PageHeader(
              crumbs: [appName, tr('Deploy'), tr('Riwayat deploy')],
              title: tr('Riwayat deploy'),
              subtitle: tr('Semua pipeline yang pernah dijalankan. Klik untuk melihat log lengkap.'),
              actions: [
                if (list.isNotEmpty)
                  OutlinedButton.icon(
                    style: outlineButtonStyle(),
                    onPressed: () async {
                      final label = switch (filter) {
                        'android' => 'Android',
                        'ios' => 'iOS',
                        'failed' => tr('Gagal'),
                        _ => tr('Semua'),
                      };
                      final ok = await confirmDialog(context,
                          title: tr('Hapus {0} riwayat ({1})?', [list.length, label]),
                          message: tr('Riwayat beserta log dan laporan AAB-nya dihapus dari PC ini. Tidak ada yang berubah di Google Play / App Store.'),
                          ok: tr('Hapus'),
                          danger: true);
                      if (ok) await app.deleteHistory(list.map((r) => r.id));
                    },
                    icon: Icon(Icons.delete_sweep_outlined, color: YmColors.danger),
                    label: Text(filter == 'all' ? tr('Hapus semua') : tr('Hapus yang tampil')),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(spacing: 8, children: [
              for (final (id, label) in [
                ('all', tr('Semua')),
                ('android', 'Android'),
                ('ios', 'iOS'),
                ('failed', tr('Gagal')),
              ])
                QuickChip(label: label, selected: filter == id, onTap: () => setState(() => filter = id)),
            ]),
            const SizedBox(height: 16),
            if (list.isEmpty)
              Panel(
                child: EmptyState(
                  icon: Icons.history_rounded,
                  title: tr('Belum ada riwayat'),
                  message: tr('Riwayat muncul setelah kamu menjalankan deploy dari halaman Proyek.'),
                ),
              )
            else
              Panel(
                padding: const EdgeInsets.all(8),
                child: Column(children: [for (final r in list) HistoryTile(record: r)]),
              ),
          ]),
        );
      },
    );
  }
}
