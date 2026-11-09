import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/release_checks.dart';
import '../services/storage.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

/// Jalankan semua pemeriksaan rilis tanpa build, tampilkan sebagai checklist.
class ReleaseCheckDialog extends StatefulWidget {
  const ReleaseCheckDialog({super.key, required this.project});
  final Project project;

  @override
  State<ReleaseCheckDialog> createState() => _ReleaseCheckDialogState();
}

class _ReleaseCheckDialogState extends State<ReleaseCheckDialog> {
  bool loading = true;
  bool android = true;
  bool ios = false;
  bool production = false;
  List<CheckResult> results = [];
  String demoPw = '';

  @override
  void initState() {
    super.initState();
    ios = widget.project.hasIos;
    _run();
  }

  Future<void> _run() async {
    setState(() => loading = true);
    demoPw = await Storage.secret(Secrets.demoPassword(widget.project.id));
    final checker = ReleaseChecker(widget.project, app.settings, demoPassword: demoPw);
    final r = await checker.runAll(android: android, ios: ios, track: production ? 'production' : '');
    if (mounted) {
      setState(() {
        results = List.of(r);
        loading = false;
      });
    }
  }

  (IconData, Color, Color) _style(CheckLevel l) => switch (l) {
        CheckLevel.pass => (Icons.check_circle_rounded, YmColors.success, YmColors.successSoft),
        CheckLevel.warn => (Icons.warning_amber_rounded, YmColors.warning, YmColors.warningSoft),
        CheckLevel.fail => (Icons.cancel_rounded, YmColors.danger, YmColors.dangerSoft),
        CheckLevel.info => (Icons.info_outline_rounded, YmColors.primary, YmColors.primarySoft),
      };

  @override
  Widget build(BuildContext context) {
    final fails = results.where((r) => r.level == CheckLevel.fail).length;
    final warns = results.where((r) => r.level == CheckLevel.warn).length;
    final passes = results.where((r) => r.level == CheckLevel.pass).length;
    final cats = <String>[];
    for (final r in results) {
      if (!cats.contains(r.category)) cats.add(r.category);
    }
    final (bannerFg, bannerBg, bannerIcon, bannerText) = fails > 0
        ? (YmColors.onDangerSoft, YmColors.dangerSoft, Icons.cancel_rounded,
            tr('{0} masalah wajib diperbaiki sebelum rilis, {1} peringatan', [fails, warns]))
        : warns > 0
            ? (YmColors.onWarningSoft, YmColors.warningSoft, Icons.warning_amber_rounded,
                tr('Siap rilis, tapi ada {0} peringatan yang sebaiknya diperbaiki', [warns]))
            : (YmColors.onSuccessSoft, YmColors.successSoft, Icons.verified_rounded, tr('Semua pemeriksaan lolos — siap rilis'));

    return DhDialog(
      title: tr('Cek kelayakan rilis'),
      subtitle: widget.project.name,
      icon: Icons.fact_check_outlined,
      width: 900,
      height: 680,
      actions: [
        OutlinedButton.icon(
          style: outlineButtonStyle(),
          onPressed: loading
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: storeInfoText(widget.project, demoPw)));
                  showSnack(context, tr('Info akun demo & link disalin — tempel di Play Console / App Store Connect'));
                },
          icon: const Icon(Icons.copy_rounded),
          label: Text(tr('Salin info untuk Play Console')),
        ),
        OutlinedButton.icon(
            style: outlineButtonStyle(), onPressed: loading ? null : _run, icon: const Icon(Icons.refresh_rounded), label: Text(tr('Cek ulang'))),
        ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(context), child: Text(tr('Tutup'))),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          QuickChip(label: 'Android', icon: Icons.android_rounded, selected: android, onTap: () {
            if (loading) return;
            android = !android;
            _run();
          }),
          QuickChip(label: 'iOS', icon: Icons.apple, selected: ios, onTap: () {
            if (loading) return;
            ios = !ios;
            _run();
          }),
          QuickChip(label: tr('Mode production'), icon: Icons.public_rounded, selected: production, tone: ChipTone.warning, onTap: () {
            if (loading) return;
            production = !production;
            _run();
          }),
        ]),
        const SizedBox(height: 12),
        if (loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: bannerBg, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(bannerIcon, color: bannerFg),
              const SizedBox(width: 10),
              Expanded(child: Text(bannerText, style: YmTextStyles.labelLg.copyWith(color: bannerFg, fontWeight: FontWeight.w600))),
              SoftChip.success('$passes ✔'),
              const SizedBox(width: 6),
              SoftChip.warning('$warns ⚠'),
              const SizedBox(width: 6),
              SoftChip.danger('$fails ✖'),
            ]),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(children: [
              for (final cat in cats) ...[
                GroupLabel(cat),
                for (final r in results.where((e) => e.category == cat))
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(color: _style(r.level).$3, borderRadius: BorderRadius.circular(8)),
                        child: Icon(_style(r.level).$1, color: _style(r.level).$2, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(r.title, style: YmTextStyles.username),
                          const SizedBox(height: 2),
                          Text(r.detail, style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark)),
                          if (r.fix.isNotEmpty && r.level != CheckLevel.pass)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text('→ ${r.fix}', style: YmTextStyles.bodySm),
                            ),
                        ]),
                      ),
                    ]),
                  ),
              ],
            ]),
          ),
        ],
      ]),
    );
  }
}
