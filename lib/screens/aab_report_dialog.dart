import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/i18n.dart';
import '../services/aab_optimizer.dart';
import '../services/aab_report.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

/// Tampilan Laporan AAB — mirip ringkasan Play Console setelah upload.
class AabReportDialog extends StatefulWidget {
  const AabReportDialog({super.key, required this.report});
  final AabReport report;

  static Future<void> show(BuildContext context, AabReport r) =>
      showDialog(context: context, builder: (_) => AabReportDialog(report: r));

  @override
  State<AabReportDialog> createState() => _AabReportDialogState();
}

class _AabReportDialogState extends State<AabReportDialog> {
  AabReport get report => widget.report;
  final done = <AabAction, OptimizeResult>{};
  AabAction? busy;

  /// Folder project: dari laporan R8, atau proyek dengan package yang sama.
  String get _root {
    if (report.r8.projectRoot.isNotEmpty) return report.r8.projectRoot;
    return app.projects.where((x) => x.packageName == report.packageName).firstOrNull?.localPath ?? '';
  }

  Future<void> _optimize(AabAction a) async {
    setState(() => busy = a);
    final res = await runAabAction(a, report, _root, flutterCmd: app.settings.flutterCmd);
    if (!mounted) return;
    setState(() {
      busy = null;
      done[a] = res;
    });
    showSnack(context, res.ok ? tr('Dioptimalkan — build ulang (Jalankan ulang) supaya hasilnya masuk ke AAB') : res.error, error: !res.ok);
  }

  Future<void> _optimizeAll() async {
    final acts = report.findings.map(actionFor).whereType<AabAction>().toSet();
    for (final a in acts) {
      if (!done.containsKey(a)) await _optimize(a);
    }
  }

  Widget _optButton(AabAction a) {
    final r = done[a];
    if (r != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!r.ok) Text('✖ ${r.error}', style: YmTextStyles.bodySm.copyWith(color: YmColors.danger)),
          for (final c in r.changes) Text('✔ $c', style: YmTextStyles.bodySm.copyWith(color: YmColors.success)),
          for (final n in r.notes) Text('ℹ $n', style: YmTextStyles.bodySm),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ElevatedButton.icon(
        style: primaryButtonStyle(color: YmColors.success),
        onPressed: busy != null ? null : () => _optimize(a),
        icon: busy == a
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.auto_fix_high_rounded, size: 18),
        label: Text(tr('Optimalkan')),
      ),
    );
  }

  (IconData, Color, Color) _style(String l) => switch (l) {
        'pass' => (Icons.check_circle_rounded, YmColors.success, YmColors.successSoft),
        'warn' => (Icons.warning_amber_rounded, YmColors.warning, YmColors.warningSoft),
        'fail' => (Icons.cancel_rounded, YmColors.danger, YmColors.dangerSoft),
        _ => (Icons.info_outline_rounded, YmColors.primary, YmColors.primarySoft),
      };

  @override
  Widget build(BuildContext context) {
    final r = report;
    final groups = <String>[];
    for (final f in r.findings) {
      if (!groups.contains(f.group)) groups.add(f.group);
    }
    final (bannerBg, bannerFg, bannerIcon, bannerText) = r.failCount > 0
        ? (YmColors.dangerSoft, YmColors.onDangerSoft, Icons.cancel_rounded,
            tr('{0} masalah akan membuat Google Play menolak AAB ini', [r.failCount]))
        : r.warnCount > 0
            ? (YmColors.warningSoft, YmColors.onWarningSoft, Icons.warning_amber_rounded,
                tr('Bisa diupload, tapi ada {0} peringatan seperti yang akan muncul di Play Console', [r.warnCount]))
            : (YmColors.successSoft, YmColors.onSuccessSoft, Icons.verified_rounded, tr('Tidak ada masalah — AAB siap diterima Google Play'));

    Widget stat(String label, String value) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: YmTextStyles.labelSm),
              const SizedBox(height: 2),
              Text(value, style: YmTextStyles.headlineSm.copyWith(fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        );

    return DhDialog(
      title: tr('Laporan AAB'),
      subtitle: '${p.basename(r.file)} • ${r.packageName}',
      icon: Icons.assessment_outlined,
      width: 900,
      height: 700,
      actions: [
        if (report.findings.map(actionFor).whereType<AabAction>().any((a) => !done.containsKey(a)))
          OutlinedButton.icon(
            style: outlineButtonStyle(),
            onPressed: busy != null ? null : _optimizeAll,
            icon: const Icon(Icons.auto_fix_high_rounded),
            label: Text(tr('Optimalkan semua')),
          ),
        ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(context), child: Text(tr('Tutup'))),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: bannerBg, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Icon(bannerIcon, color: bannerFg),
            const SizedBox(width: 10),
            Expanded(child: Text(bannerText, style: YmTextStyles.labelLg.copyWith(color: bannerFg, fontWeight: FontWeight.w600))),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          stat(tr('Versi'), '${r.versionName} (${r.versionCode})'),
          const SizedBox(width: 8),
          stat(tr('Android minimal'), r.minSdk == 0 ? '-' : androidName(r.minSdk)),
          const SizedBox(width: 8),
          stat('targetSdk', r.targetSdk == 0 ? '-' : androidName(r.targetSdk)),
          const SizedBox(width: 8),
          stat(tr('Download (arm64)'), r.downloadByAbi['arm64-v8a'] == null ? '-' : '~${(r.downloadByAbi['arm64-v8a']! / 1048576).toStringAsFixed(1)} MB'),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: ListView(children: [
            GroupLabel(tr('App bundle explorer (seperti Play Console)')),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
              child: AabExplorerCard(report: r, onOptimizeR8: done.containsKey(AabAction.r8) || busy != null ? null : () => _optimize(AabAction.r8)),
            ),
            for (final g in groups) ...[
              GroupLabel(g),
              for (final f in r.findings.where((x) => x.group == g))
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(color: _style(f.level).$3, borderRadius: BorderRadius.circular(8)),
                      child: Icon(_style(f.level).$1, size: 18, color: _style(f.level).$2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(f.title, style: YmTextStyles.username),
                        const SizedBox(height: 2),
                        SelectableText(f.detail, style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark)),
                        if (f.fix.isNotEmpty && f.level != 'pass')
                          Padding(padding: const EdgeInsets.only(top: 4), child: Text('→ ${f.fix}', style: YmTextStyles.bodySm)),
                        if (actionFor(f) case final a?) _optButton(a),
                      ]),
                    ),
                  ]),
                ),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Tombol "Laporan AAB" — tampil kalau run punya laporan.
class AabReportButton extends StatelessWidget {
  const AabReportButton({super.key, required this.runId, this.compact = false});
  final String runId;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AabReport?>(
      future: loadReport(runId),
      builder: (context, snap) {
        final r = snap.data;
        if (r == null) return const SizedBox.shrink();
        final color = r.failCount > 0 ? YmColors.danger : (r.warnCount > 0 ? YmColors.warning : YmColors.success);
        if (compact) {
          return IconButton(
            tooltip: tr('Laporan AAB'),
            onPressed: () => AabReportDialog.show(context, r),
            icon: Icon(Icons.assessment_outlined, color: color),
          );
        }
        return OutlinedButton.icon(
          style: outlineButtonStyle(),
          onPressed: () => AabReportDialog.show(context, r),
          icon: Icon(Icons.assessment_outlined, color: color),
          label: Text(tr('Laporan AAB')),
        );
      },
    );
  }
}

/// Ringkasan seperti "App bundle explorer" Play Console — tampil SEBELUM upload.
class AabExplorerCard extends StatelessWidget {
  const AabExplorerCard({super.key, required this.report, this.onOptimizeR8});
  final AabReport report;
  /// Tombol "Optimalkan" di Konfigurasi R8 (null = tidak ditampilkan).
  final VoidCallback? onOptimizeR8;

  Widget _row(String k, Widget v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 210, child: Text(k, style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark))),
          Expanded(child: v),
        ]),
      );

  Widget _txt(String s, {Color? color}) => Text(s, style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w600, color: color));

  Widget _pct(double? v, {bool estimate = false, String unknown = ''}) {
    if (v == null) return Text(unknown.isEmpty ? '?' : unknown, style: YmTextStyles.bodySm);
    final low = v < 50;
    final c = low ? YmColors.danger : (v < 65 ? YmColors.warning : YmColors.success);
    return Row(children: [
      SizedBox(width: 64, child: _txt('${estimate ? '≈' : ''}${v.round()}%', color: c)),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: (v / 100).clamp(0, 1),
            minHeight: 7,
            backgroundColor: YmColors.surfaceContainer,
            valueColor: AlwaysStoppedAnimation(c),
          ),
        ),
      ),
      const SizedBox(width: 8),
      if (low) Text(tr('< 50%'), style: YmTextStyles.labelSm.copyWith(color: YmColors.danger, fontWeight: FontWeight.w700)),
    ]);
  }

  Widget _check(String label, bool? on) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(children: [
          Icon(on == null ? Icons.help_outline_rounded : (on ? Icons.check_circle_outline_rounded : Icons.cancel_outlined),
              size: 18, color: on == null ? YmColors.outline : (on ? YmColors.success : YmColors.danger)),
          const SizedBox(width: 6),
          Text(label, style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final r = report;
    final m = r.r8;
    final dexLevel = (m.optimization ?? 0) >= 50 ? tr('Tinggi') : ((m.optimization ?? 0) >= 25 ? tr('Sedang') : tr('Rendah'));
    final r8Known = m.fullMode != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _row(tr('Platform asal'), _txt(r.abis.isEmpty ? tr('Semua (tanpa kode native)') : r.abis.join(', '))),
      _row('API level', _txt(r.minSdk == 0 ? '-' : '${r.minSdk}+')),
      _row(tr('SDK Target'), _txt(r.targetSdk == 0 ? '-' : '${r.targetSdk}')),
      _row(tr('Versi OpenGL ES'), _txt(r.glEsDeclared ? tr('Dideklarasikan di manifest') : '0.0+')),
      _row(tr('Tata letak layar'), _txt(r.screenLayouts.join(', '))),
      _row(tr('Fitur'), _txt(tr('{0} fitur', [r.features.length]))),
      _row(
        tr('Ukuran halaman memori'),
        r.nativeLibs == 0 || r.misaligned16k.isEmpty
            ? _txt(tr('Mendukung 16 KB'), color: YmColors.success)
            : _txt(tr('{0} library belum 16 KB', [r.misaligned16k.length]), color: YmColors.danger),
      ),
      const Divider(height: 18),
      _row(tr('Pengoptimalan kode DEX'), _txt(r.hasR8Mapping ? dexLevel : tr('Tidak ada (R8 mati)'), color: r.hasR8Mapping ? null : YmColors.danger)),
      _row(tr('Persentase pengoptimalan'), _pct(m.optimization, estimate: true)),
      _row(tr('Persentase obfuscation'), _pct(m.obfuscation)),
      _row(tr('Persentase penyusutan'), _pct(m.shrinking, unknown: tr('Butuh usage.txt dari build yang sama (build lewat DeployHub atau pilih AAB dari folder build project)'))),
      _row(
        tr('Konfigurasi R8'),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _check(tr('Mode Penuh'), r8Known ? m.fullMode : (r.hasR8Mapping ? null : false)),
          _check(tr('Penyingkatan Resource'), r8Known ? m.shrinkResources : null),
          _check(tr('Penyingkatan Resource yang Dioptimalkan'), r8Known ? m.optimizedResourceShrinking : null),
          _check(tr('Kemas Ulang Kelas'), r8Known ? m.repackageClasses : null),
          if (!r8Known)
            Text(tr('? = folder project tidak ditemukan, konfigurasi tidak bisa dibaca'), style: YmTextStyles.bodySm),
          if (onOptimizeR8 != null && (m.fullMode != true || m.shrinkResources != true || m.optimizedResourceShrinking != true || m.repackageClasses != true || (m.lowest ?? 100) < 50))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ElevatedButton.icon(
                style: primaryButtonStyle(color: YmColors.success),
                onPressed: onOptimizeR8,
                icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                label: Text(tr('Optimalkan R8 (mode penuh, penyingkatan resource, kemas ulang kelas)')),
              ),
            ),
          if (m.agpVersion.isNotEmpty && (int.tryParse(m.agpVersion.split('.').first) ?? 9) < 9)
            Text(tr('AGP {0} — upgrade ke AGP versi 9.0 untuk performa terbaik', [m.agpVersion]), style: YmTextStyles.bodySm),
        ]),
      ),
      _row(tr('Total ukuran DEX tanpa kompresi'), _txt(r.dexUncompressed == 0 ? '-' : '${(r.dexUncompressed / 1048576).toStringAsFixed(2)} MB')),
      if (m.compiler.isNotEmpty) _row('Compiler', Text(m.compiler, style: YmTextStyles.bodySm)),
      const SizedBox(height: 4),
      Text(
        tr('Obfuscation dihitung dari mapping R8 di dalam AAB; penyusutan dari usage.txt. Angka pengoptimalan adalah perkiraan — angka persis dihitung Google setelah upload.'),
        style: YmTextStyles.bodySm,
      ),
    ]);
  }
}
