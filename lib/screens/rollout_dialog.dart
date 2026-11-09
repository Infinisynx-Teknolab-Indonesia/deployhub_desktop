import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/play_service.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

/// Rollout bertahap (staged rollout) + crash rate & ANR dari Google Play.
/// Ambang "perilaku buruk" Google: crash 1.09%, ANR 0.47% (user-perceived) — di atas itu aplikasi
/// diturunkan peringkatnya di Play Store.
class RolloutDialog extends StatefulWidget {
  const RolloutDialog({super.key, required this.project});
  final Project project;

  @override
  State<RolloutDialog> createState() => _RolloutDialogState();
}

class _RolloutDialogState extends State<RolloutDialog> {
  Project get pr => widget.project;
  static const tracks = ['production', 'beta', 'alpha', 'internal'];
  static const maxCrash = 1.09, maxAnr = 0.47;
  final rel = <String, List<({int code, String status, double fraction, String name})>>{};
  Map<String, List<({String date, double rate, double perceived, int users})>>? vit;
  String vitErr = '';
  String err = '';
  bool loading = true;
  String? busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      err = '';
    });
    try {
      for (final t in tracks) {
        rel[t] = await PlayService.trackReleases(pr.serviceAccountPath, pr.packageName, t);
      }
    } catch (e) {
      err = '$e';
    }
    try {
      vit = await PlayService.vitals(pr.serviceAccountPath, pr.packageName);
      vitErr = '';
    } catch (e) {
      vitErr = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _act(String track, int code, String status, {double? fraction}) async {
    if (status == 'halted') {
      final ok = await confirmDialog(context,
          title: tr('Hentikan rollout versi {0}?', [code]),
          message: tr('Pengguna baru berhenti menerima versi ini. Pengguna yang sudah update tetap di versi ini (Google Play tidak bisa menurunkan versi) — rilis versi perbaikan dengan versionCode lebih tinggi.'),
          danger: true,
          ok: tr('Hentikan'));
      if (!ok) return;
    }
    setState(() => busy = '$track$code');
    try {
      await PlayService.updateRelease(pr.serviceAccountPath, pr.packageName, track, code, status: status, fraction: fraction);
      if (mounted) showSnack(context, tr('Rilis {0} diperbarui: {1}', [code, status == 'completed' ? '100%' : status == 'halted' ? tr('dihentikan') : '${((fraction ?? 0) * 100).round()}%']));
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Widget _vitCard(String title, List<({String date, double rate, double perceived, int users})>? s, double limit) {
    final last = (s == null || s.isEmpty) ? null : s.last;
    final v = last?.perceived ?? last?.rate;
    final bad = v != null && v > limit;
    final color = v == null ? YmColors.outline : (bad ? YmColors.danger : (v > limit * 0.7 ? YmColors.warning : YmColors.success));
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: YmTextStyles.labelMd),
          Text(v == null ? '—' : '${v.toStringAsFixed(2)}%', style: YmTextStyles.headlineMd.copyWith(color: color)),
          Text(v == null ? tr('Belum ada data (Play butuh pengguna cukup banyak, data tertunda ±1–2 hari)') : tr('{0} • {1} pengguna • batas Google {2}%', [last!.date, last.users, limit]),
              style: YmTextStyles.bodySm),
          if (s != null && s.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                height: 36,
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  for (final d in s)
                    Expanded(
                      child: Tooltip(
                        message: '${d.date}: ${d.perceived.toStringAsFixed(2)}%',
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          height: (36 * (d.perceived / (limit * 2)).clamp(0.05, 1.0)).toDouble(),
                          color: d.perceived > limit ? YmColors.danger : YmColors.primary.withOpacity(0.6),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _release(String track, ({int code, String status, double fraction, String name}) r) {
    final pct = (r.fraction * 100).round();
    final active = r.status == 'inProgress' || r.status == 'halted';
    final chip = switch (r.status) {
      'completed' => SoftChip.success(tr('100% pengguna')),
      'inProgress' => SoftChip.warning(tr('{0}% pengguna', [pct])),
      'halted' => SoftChip.danger(tr('dihentikan di {0}%', [pct])),
      'draft' => SoftChip.neutral('draft'),
      _ => SoftChip.neutral(r.status),
    };
    final b = busy == '$track${r.code}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(width: 150, child: Text('${r.name.isEmpty ? '' : '${r.name} '}(${r.code})', style: YmTextStyles.labelLg)),
        chip,
        if (b) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        if (active && !b) ...[
          for (final next in [5, 10, 20, 50].where((x) => x > pct))
            OutlinedButton(style: outlineButtonStyle(), onPressed: () => _act(track, r.code, 'inProgress', fraction: next / 100), child: Text('$next%')),
          ElevatedButton(style: primaryButtonStyle(color: YmColors.success), onPressed: () => _act(track, r.code, 'completed'), child: const Text('100%')),
          if (r.status == 'inProgress')
            ElevatedButton.icon(
              style: primaryButtonStyle(color: YmColors.danger),
              onPressed: () => _act(track, r.code, 'halted'),
              icon: const Icon(Icons.pan_tool_outlined, size: 16),
              label: Text(tr('Hentikan')),
            )
          else
            OutlinedButton.icon(
              style: outlineButtonStyle(),
              onPressed: () => _act(track, r.code, 'inProgress', fraction: r.fraction),
              icon: const Icon(Icons.play_arrow_rounded, size: 16),
              label: Text(tr('Lanjutkan')),
            ),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DhDialog(
      title: tr('Rollout & crash'),
      subtitle: '${pr.name} • ${pr.packageName}',
      icon: Icons.stacked_line_chart_rounded,
      width: 860,
      height: 720,
      actions: [
        TextButton.icon(
          onPressed: () => launchUrl(Uri.parse('https://play.google.com/console')),
          icon: const Icon(Icons.open_in_new_rounded, size: 16),
          label: Text(tr('Android vitals di Play Console')),
        ),
        TextButton.icon(onPressed: loading ? null : _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr('Muat ulang'))),
        ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(context), child: Text(tr('Tutup'))),
      ],
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              GroupLabel(tr('Kesehatan aplikasi (semua versi, 14 hari)')),
              if (vitErr.isNotEmpty)
                Text(
                  tr('Crash rate tidak bisa dibaca: {0}\n→ Aktifkan "Google Play Developer Reporting API" di Google Cloud project service account, dan beri izin "Lihat informasi aplikasi" di Play Console → Pengguna & izin. Kalau login dengan Google: login ulang sekali.', [vitErr.length > 200 ? '${vitErr.substring(0, 200)}…' : vitErr]),
                  style: YmTextStyles.bodySm.copyWith(color: YmColors.warning),
                )
              else
                Row(children: [
                  _vitCard(tr('Crash rate (user-perceived)'), vit?['crash'], maxCrash),
                  const SizedBox(width: 10),
                  _vitCard(tr('ANR rate (user-perceived)'), vit?['anr'], maxAnr),
                ]),
              const SizedBox(height: 14),
              if (err.isNotEmpty) Text(err, style: YmTextStyles.bodySm.copyWith(color: YmColors.danger)),
              for (final t in tracks)
                if ((rel[t] ?? const []).isNotEmpty) ...[
                  GroupLabel(switch (t) {
                    'production' => tr('Produksi'),
                    'beta' => tr('Pengujian terbuka'),
                    'alpha' => tr('Pengujian tertutup'),
                    _ => tr('Pengujian internal'),
                  }),
                  for (final r in rel[t]!.take(3)) _release(t, r),
                ],
              const SizedBox(height: 8),
              Text(
                tr('Cara aman merilis: deploy production dengan 10% → pantau crash 1–2 hari → 20% → 50% → 100%. Crash naik? klik Hentikan, perbaiki, rilis versi baru. DeployHub Server bisa melakukan ini otomatis 24 jam (Pengaturan → DeployHub Server).'),
                style: YmTextStyles.bodySm,
              ),
            ]),
    );
  }
}
