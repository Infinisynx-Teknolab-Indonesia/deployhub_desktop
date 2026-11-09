import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/play_auth.dart';
import '../services/storage.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../utils.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';
import 'history_screen.dart';
import 'quick_upload_dialog.dart';

/// Dasbor: ringkasan deploy, status koneksi, deploy terakhir.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final week = DateTime.now().subtract(const Duration(days: 7));
        final recent = app.history.where((r) => r.startedAt.isAfter(week)).toList();
        final ok = recent.where((r) => r.status == 'success').length;
        final fail = recent.where((r) => r.status == 'failed').length;
        final avg = recent.isEmpty
            ? Duration.zero
            : Duration(
                seconds: recent.map((r) => r.finishedAt.difference(r.startedAt).inSeconds).reduce((a, b) => a + b) ~/
                    recent.length);
        final rate = recent.isEmpty ? 0 : (ok * 100 / recent.length).round();

        return PageBody(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PageHeader(
              crumbs: [appName, tr('Dasbor')],
              title: tr('Dasbor'),
              subtitle: tr('Ringkasan build & deploy semua proyek dalam 7 hari terakhir.'),
              actions: [
                OutlinedButton.icon(
                  style: outlineButtonStyle(),
                  onPressed: app.isRunning ? null : () => openQuickUpload(context),
                  icon: const Icon(Icons.upload_file_rounded),
                  label: Text(tr('Upload file AAB / IPA')),
                ),
                ElevatedButton.icon(
                  style: primaryButtonStyle(),
                  onPressed: () => nav.value = 'projects',
                  icon: const Icon(Icons.rocket_launch_rounded),
                  label: Text(tr('Deploy sekarang')),
                ),
              ],
            ),
            const SizedBox(height: 24),
            PlayConnectBanner(ready: PlayAuth.globalReady()),
            LayoutBuilder(builder: (context, c) {
              final w = (c.maxWidth - 16 * 3) / 4;
              return Wrap(spacing: 16, runSpacing: 16, children: [
                SizedBox(
                  width: w,
                  child: Reveal(
                    child: StatCard(
                      label: tr('Proyek'),
                      value: '${app.projects.length}',
                      number: app.projects.length,
                      icon: Icons.folder_copy_outlined,
                      color: YmColors.primary,
                      sub: tr('Aplikasi yang dikelola'),
                      onTap: () => nav.value = 'projects',
                    ),
                  ),
                ),
                SizedBox(
                  width: w,
                  child: Reveal(
                    index: 1,
                    child: StatCard(
                      label: tr('Deploy sukses'),
                      value: '$ok',
                      number: ok,
                      unit: '$rate%',
                      unitColor: YmColors.success,
                      icon: Icons.check_circle_outline_rounded,
                      color: YmColors.success,
                      tileBg: YmColors.successSoft,
                      sub: tr('7 hari terakhir'),
                    ),
                  ),
                ),
                SizedBox(
                  width: w,
                  child: Reveal(
                    index: 2,
                    child: StatCard(
                      label: tr('Deploy gagal'),
                      value: '$fail',
                      number: fail,
                      icon: Icons.error_outline_rounded,
                      color: YmColors.danger,
                      tileBg: YmColors.dangerSoft,
                      numberColor: fail > 0 ? YmColors.danger : null,
                      sub: tr('7 hari terakhir'),
                    ),
                  ),
                ),
                SizedBox(
                  width: w,
                  child: Reveal(
                    index: 3,
                    child: StatCard(
                      label: tr('Rata-rata durasi'),
                      value: recent.isEmpty ? '-' : fmtDuration(avg),
                      icon: Icons.timer_outlined,
                      color: YmColors.warning,
                      tileBg: YmColors.warningSoft,
                      sub: tr('Per pipeline'),
                    ),
                  ),
                ),
              ]);
            }),
            const SizedBox(height: 18),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                flex: 3,
                child: Reveal(
                  index: 4,
                  child: Panel(
                    title: tr('Deploy terakhir'),
                    icon: Icons.history_rounded,
                    trailing: TextButton(onPressed: () => nav.value = 'history', child: Text(tr('Lihat semua'))),
                    child: app.history.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Text(tr('Belum ada deploy.'), style: YmTextStyles.bodySm, textAlign: TextAlign.center),
                          )
                        : Column(children: [for (final r in app.history.take(6)) HistoryTile(record: r, dense: true)]),
                  ),
                ),
              ),
              const SizedBox(width: 18),
              const Expanded(flex: 2, child: Reveal(index: 5, child: _ConnectionPanel())),
            ]),
          ]),
        );
      },
    );
  }
}

class _ConnectionPanel extends StatefulWidget {
  const _ConnectionPanel();

  @override
  State<_ConnectionPanel> createState() => _ConnectionPanelState();
}

class _ConnectionPanelState extends State<_ConnectionPanel> {
  bool play = false, github = false, telegram = false;

  @override
  void initState() {
    super.initState();
    app.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    app.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final p = await PlayAuth.globalReady();
    final g = (await Storage.secret(Secrets.github)).isNotEmpty;
    final t = (await Storage.secret(Secrets.telegram)).isNotEmpty && app.settings.telegramChatId.isNotEmpty;
    if (!mounted) return;
    setState(() {
      play = p;
      github = g;
      telegram = t;
    });
  }

  Widget _row(IconData icon, String name, bool ok, String detail) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: ok ? YmColors.successSoft : YmColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 19, color: ok ? YmColors.success : YmColors.outline),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: YmTextStyles.username),
              Text(detail, style: YmTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          ok ? SoftChip.success(tr('Terhubung')) : SoftChip.neutral(tr('Belum')),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = app.settings;
    return Panel(
      title: tr('Koneksi'),
      icon: Icons.link_rounded,
      trailing: TextButton(onPressed: () => nav.value = 'settings', child: Text(tr('Atur'))),
      child: Column(children: [
        _row(Icons.shop_outlined, 'Google Play', play,
            s.playAuthMode == 'oauth' ? (s.playOAuthEmail.isEmpty ? tr('Login Google') : s.playOAuthEmail) : 'Service Account'),
        _row(Icons.hub_outlined, 'GitHub', github, s.githubUser.isEmpty ? 'Personal Access Token' : '@${s.githubUser}'),
        _row(Icons.apple, 'App Store Connect', s.ascVerifiedTeam.isNotEmpty,
            s.ascVerifiedTeam.isEmpty ? tr('Belum dihubungkan (API key .p8)') : 'Key ${s.ascKeyId} • ${s.ascVerifiedTeam}'),
        _row(Icons.laptop_mac_rounded, 'MacBook (SSH)', s.macHost.isNotEmpty,
            s.macHost.isEmpty ? tr('Untuk build iOS') : '${s.macUser}@${s.macHost}'),
        _row(Icons.send_outlined, 'Telegram', telegram, tr('Notifikasi hasil deploy')),
      ]),
    );
  }
}
