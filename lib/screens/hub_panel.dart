import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/hub_client.dart';
import '../services/integrations.dart';
import '../services/ready_builds.dart';
import '../services/storage.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

// ═════════════════════════════════════════════ Pengaturan → DeployHub Server
class HubPanel extends StatefulWidget {
  const HubPanel({super.key});

  @override
  State<HubPanel> createState() => _HubPanelState();
}

class _HubPanelState extends State<HubPanel> {
  final hub = Hub.instance;
  late final url = TextEditingController(text: hub.url);
  final token = TextEditingController();
  final user = TextEditingController(text: Hub.instance.username.isEmpty ? 'admin' : Hub.instance.username);
  final pass = TextEditingController();
  bool useToken = false;
  Map<String, dynamic>? info;
  String? busy;
  final logs = <String>[];

  @override
  void initState() {
    super.initState();
    useToken = hub.username.isEmpty && hub.url.isNotEmpty;
    Storage.secret(Hub.kToken).then((v) {
      if (hub.username.isEmpty) token.text = v;
    });
    if (hub.ready) _test(quiet: true);
  }

  @override
  void dispose() {
    url.dispose();
    token.dispose();
    user.dispose();
    pass.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    hub.url = url.text.trim();
    if (useToken) {
      hub.username = '';
      await Storage.setSecret(Hub.kToken, token.text.trim());
    }
    await hub.save();
  }

  Future<void> _test({bool quiet = false}) async {
    try {
      await _save();
      final i = await hub.info();
      if (!mounted) return;
      setState(() => info = i);
      if (!quiet) showSnack(context, tr('Terhubung ke DeployHub Server {0}', [i['version']]));
    } catch (e) {
      if (mounted && !quiet) showSnack(context, '$e', error: true);
    }
  }

  Future<void> _login() async {
    hub.url = url.text.trim();
    await hub.save();
    final d = await hub.login(user.text.trim(), pass.text);
    pass.clear();
    useToken = false;
    await _test(quiet: true);
    if (!mounted) return;
    showSnack(context, tr('Masuk sebagai {0} ({1})', [d['username'], d['role']]));
    if (d['must_change'] == true) await _changePw();
  }

  Future<void> _changePw() async {
    final o = TextEditingController(), n = TextEditingController(), n2 = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Ganti password server')),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr('Password bawaan mudah ditebak — ganti sekarang. Minimal 8 karakter, ada huruf besar, huruf kecil, dan angka.'), style: YmTextStyles.bodySm),
            const SizedBox(height: 10),
            DhField(o, tr('Password lama'), obscure: true),
            const SizedBox(height: 8),
            DhField(n, tr('Password baru'), obscure: true),
            const SizedBox(height: 8),
            DhField(n2, tr('Ulangi password baru'), obscure: true),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Nanti'))),
          ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Simpan'))),
        ],
      ),
    );
    final old = o.text, nw = n.text, nw2 = n2.text;
    o.dispose();
    n.dispose();
    n2.dispose();
    if (ok != true || !mounted) return;
    if (nw != nw2) return showSnack(context, tr('Password baru tidak sama'), error: true);
    try {
      await hub.changePassword(old, nw);
      final u = hub.username;
      await hub.login(u, nw); // sesi lama dihapus server → masuk lagi otomatis
      await _test(quiet: true);
      if (mounted) showSnack(context, tr('Password diganti'));
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  Future<void> _audit() async {
    final rows = await hub.audit(limit: 300);
    if (!mounted) return;
    String fmt(num t) => DateTime.fromMillisecondsSinceEpoch((t * 1000).round()).toString().substring(0, 19);
    await showDialog(
      context: context,
      builder: (ctx) => DhDialog(
        title: tr('Audit log server'),
        subtitle: tr('Siapa melakukan apa, kapan — {0} catatan terakhir', [rows.length]),
        icon: Icons.history_rounded,
        width: 900,
        height: 640,
        actions: [ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(ctx), child: Text(tr('Tutup')))],
        child: ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final a = rows[i];
            final act = '${a['action']}';
            final color = RegExp(r'fail|locked|halt|delete').hasMatch(act)
                ? YmColors.danger
                : RegExp(r'deploy|rollout').hasMatch(act)
                    ? YmColors.warning
                    : YmColors.outline;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 150, child: Text(fmt(a['t'] as num), style: YmTextStyles.bodySm)),
                SizedBox(width: 90, child: Text('${a['username']}', style: YmTextStyles.labelMd)),
                SizedBox(width: 130, child: Text(act, style: YmTextStyles.labelMd.copyWith(color: color))),
                Expanded(child: SelectableText('${a['target'] ?? ''}  ${a['detail'] ?? ''}', style: YmTextStyles.bodySm)),
              ]),
            );
          },
        ),
      ),
    );
  }

  Future<void> _do(String name, Future<void> Function() fn) async {
    setState(() {
      busy = name;
      logs.clear();
    });
    try {
      await _save();
      await fn();
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Widget _btn(String label, IconData icon, Future<void> Function() fn, {bool primary = false}) {
    final child = busy == label ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon, size: 18);
    final on = busy != null ? null : () => _do(label, fn);
    return primary
        ? ElevatedButton.icon(style: primaryButtonStyle(), onPressed: on, icon: child, label: Text(label))
        : OutlinedButton.icon(style: outlineButtonStyle(), onPressed: on, icon: child, label: Text(label));
  }

  Widget _project(Project pr) {
    final c = hub.cfg(pr.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(pr.name, style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700))),
          Text(c.syncedAt.isEmpty ? tr('belum dikirim') : tr('dikirim {0}', [c.syncedAt.substring(0, 16).replaceFirst('T', ' ')]), style: YmTextStyles.bodySm),
        ]),
        Wrap(spacing: 16, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Switch(
              value: c.autoBuild,
              onChanged: (v) async {
                final local = Integrations.instance;
                if (v && local.autoTriggerOn && local.autoTriggerProjects.contains(pr.id)) {
                  final off = await confirmDialog(context,
                      title: tr('Auto-build sudah aktif di PC'),
                      message: tr('{0} sudah di-build otomatis oleh DeployHub di PC. Kalau server juga aktif, satu commit di-build 2 kali. Matikan auto-build di PC dan pakai server saja (tetap jalan walau PC mati)?', [pr.name]),
                      ok: tr('Pakai server saja'));
                  if (!off) return;
                  local.autoTriggerProjects.remove(pr.id);
                  await local.save();
                  app.restartAutoTrigger();
                }
                setState(() => c.autoBuild = v);
                await hub.save();
                if (c.syncedAt.isNotEmpty) {
                  try {
                    await hub.syncProject(pr, app.settings, secrets: false);
                  } catch (_) {}
                }
              },
            ),
            Text(tr('Build otomatis setiap push'), style: YmTextStyles.bodySm),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(tr('Setelah build:'), style: YmTextStyles.bodySm),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: c.autoDeployTrack,
              items: [
                DropdownMenuItem(value: '', child: Text(tr('simpan saja (deploy manual)'))),
                DropdownMenuItem(value: 'internal', child: Text(tr('langsung ke Pengujian internal'))),
                DropdownMenuItem(value: 'alpha', child: Text(tr('langsung ke Pengujian tertutup'))),
                DropdownMenuItem(value: 'production', child: Text(tr('langsung ke Production (rollout bertahap)'))),
              ],
              onChanged: (v) => setState(() => c.autoDeployTrack = v ?? ''),
            ),
          ]),
          if (c.autoDeployTrack == 'production')
            Text(tr('Setiap build sukses langsung dirilis ke Production. Pakai rollout bertahap di bawah supaya aman.'),
                style: YmTextStyles.bodySm.copyWith(color: YmColors.onWarningSoft)),
          Tooltip(
            message: tr('Setiap Pull Request ke {0}: analyze + test + scan kerentanan. Hasil ✔/✖ "DeployHub CI" muncul di GitHub sebelum merge. Butuh webhook (tombol di bawah) dan token GitHub dengan izin Commit statuses: Read and write.', [pr.branch]),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(value: c.prChecks, onChanged: (v) => setState(() => c.prChecks = v)),
              Text(tr('Cek Pull Request (✔/✖ di GitHub)'), style: YmTextStyles.bodySm),
            ]),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(tr('Gagalkan build kalau ada kerentanan:'), style: YmTextStyles.bodySm),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: c.vulnBlock,
              items: [
                DropdownMenuItem(value: 'critical', child: Text(tr('CRITICAL'))),
                DropdownMenuItem(value: 'high', child: Text(tr('HIGH ke atas'))),
                DropdownMenuItem(value: 'medium', child: Text(tr('MEDIUM ke atas'))),
                DropdownMenuItem(value: 'off', child: Text(tr('jangan gagalkan (laporan saja)'))),
              ],
              onChanged: (v) => setState(() => c.vulnBlock = v ?? 'critical'),
            ),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Switch(value: c.rolloutAuto, onChanged: (v) => setState(() => c.rolloutAuto = v)),
            Text(tr('Production: naikkan rollout otomatis {0} (berhenti sendiri kalau crash/ANR tinggi)', [c.steps.map((s) => '$s%').join(' → ')]), style: YmTextStyles.bodySm),
          ]),
        ]),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _btn(tr('Kirim proyek + rahasia'), Icons.cloud_upload_outlined, () async {
            final ok = await confirmDialog(context,
                title: tr('Kirim {0} ke server?', [pr.name]),
                message: tr('Dikirim: konfigurasi, service account Google Play, keystore + key.properties, google-services.json, token GitHub, env/*.json. Disimpan TERENKRIPSI di server dan tidak pernah dikirim balik. Pakai HTTPS kalau server di internet.'));
            if (!ok) return;
            logs.addAll(await hub.syncProject(pr, app.settings));
            setState(() {});
          }, primary: true),
          _btn(tr('Pasang webhook GitHub'), Icons.webhook_rounded, () async {
            final hook = await hub.installWebhook(pr, await Storage.secret(Secrets.github));
            logs.add('✔ webhook: $hook');
            setState(() {});
          }),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: tr('DeployHub Server'),
      subtitle: tr('CI/CD 24 jam di PC atau VPS: build setiap push, deploy, rollout bertahap otomatis, crash monitoring — tetap jalan walau aplikasi ini ditutup.'),
      icon: Icons.dns_rounded,
      trailing: Switch(
        value: hub.on,
        onChanged: (v) async {
          setState(() => hub.on = v);
          await _save();
          if (v) _test(quiet: true);
        },
      ),
      child: !hub.on
          ? Text(tr('Nonaktif — semua pipeline berjalan di PC ini. Server: folder deployhub-server (Python) — jalankan run.py di PC atau docker compose di VPS.'), style: YmTextStyles.bodySm)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DhField(url, tr('URL server'), icon: Icons.link_rounded, hint: 'http://localhost:8787  /  https://deployhub.domainmu.com'),
              const SizedBox(height: 10),
              if (hub.username.isNotEmpty && !useToken)
                Row(children: [
                  Icon(Icons.verified_user_outlined, size: 18, color: YmColors.success),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(tr('Masuk sebagai {0}{1} — setiap build / deploy tercatat atas nama ini di audit log server', [
                      hub.username,
                      info?['me'] is Map ? ' (${(info!['me'] as Map)['role']})' : '',
                    ]), style: YmTextStyles.bodySm),
                  ),
                  TextButton(onPressed: _changePw, child: Text(tr('Ganti password'))),
                  TextButton(
                    onPressed: () async {
                      await hub.logout();
                      setState(() => info = null);
                    },
                    child: Text(tr('Keluar')),
                  ),
                ])
              else if (!useToken) ...[
                fieldRow([
                  DhField(user, 'Username', icon: Icons.person_outline_rounded),
                  DhField(pass, 'Password', icon: Icons.lock_outline_rounded, obscure: true, hint: tr('akun bawaan: admin / user — ganti setelah masuk')),
                ]),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: () => setState(() => useToken = true), child: Text(tr('Pakai token server (tanpa akun)'))),
                ),
              ] else ...[
                DhField(token, 'Token', icon: Icons.key_outlined, obscure: true, hint: tr('lihat di layar run.py / log container')),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: () => setState(() => useToken = false), child: Text(tr('Masuk dengan username & password (disarankan: tercatat di audit log)'))),
                ),
              ],
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (!useToken && hub.username.isEmpty) _btn(tr('Masuk'), Icons.login_rounded, _login, primary: true),
                _btn(tr('Tes koneksi'), Icons.wifi_tethering_rounded, () => _test()),
                _btn(tr('Kirim notifikasi ke server'), Icons.notifications_active_outlined, () async {
                  final n = await hub.syncNotify(app.settings);
                  await hub.testNotify();
                  logs.add(n.isEmpty ? tr('⚠ Belum ada Telegram/Discord/Slack yang diatur') : '✔ ${n.join(', ')} — ${tr('pesan tes terkirim')}');
                  setState(() {});
                }),
                if (info != null && (info!['me'] as Map?)?['role'] == 'admin') _btn(tr('Audit log'), Icons.history_rounded, _audit),
                TextButton.icon(
                  onPressed: hub.url.isEmpty ? null : () => launchUrl(Uri.parse(hub.url)),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: Text(tr('Buka dashboard web')),
                ),
              ]),
              if (info != null) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 18, runSpacing: 6, children: [
                  Text('✔ v${info!['version']}', style: YmTextStyles.labelMd.copyWith(color: YmColors.success)),
                  Text('Flutter: ${info!['flutter']}', style: YmTextStyles.bodySm),
                  Text(tr('Disk kosong {0} GB', [info!['disk_free_gb']]), style: YmTextStyles.bodySm),
                  Text(tr('Antrean {0}', [info!['queued']]), style: YmTextStyles.bodySm),
                ]),
                if ((info!['me'] as Map?)?['must_change'] == true || (info!['default_passwords'] as List? ?? const []).isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: YmColors.warning.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                    child: Row(children: [
                      Icon(Icons.warning_amber_rounded, color: YmColors.warning),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            tr('Akun dengan password bawaan: {0}. Siapa pun yang tahu URL server bisa masuk — ganti passwordnya (dashboard web → Pengguna).',
                                [(((info!['default_passwords'] as List?) ?? const []).isEmpty ? [hub.username] : info!['default_passwords'] as List).join(', ')]),
                            style: YmTextStyles.bodySm),
                      ),
                      if ((info!['me'] as Map?)?['must_change'] == true) TextButton(onPressed: _changePw, child: Text(tr('Ganti password'))),
                    ]),
                  ),
                if ('${info!['webhook_secret'] ?? ''}'.length >= 8)
                Row(children: [
                  Expanded(child: Text(tr('Webhook secret: {0}', ['${info!['webhook_secret']}'.substring(0, 8)]) + '…', style: YmTextStyles.bodySm)),
                  IconButton(
                    tooltip: tr('Salin webhook secret'),
                    onPressed: () => Clipboard.setData(ClipboardData(text: '${info!['webhook_secret']}')),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                  ),
                ]),
              ],
              const SizedBox(height: 10),
              GroupLabel(tr('Proyek di server')),
              for (final pr in app.projects) _project(pr),
              if (logs.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFF0A0F1A), borderRadius: BorderRadius.circular(10)),
                  child: SelectableText(logs.join('\n'), style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: Color(0xFFD7DCE3))),
                ),
            ]),
    );
  }
}

// ═════════════════════════════════════════════ Kartu proyek → bagian Server
class HubProjectSection extends StatefulWidget {
  const HubProjectSection({super.key, required this.project});
  final Project project;

  @override
  State<HubProjectSection> createState() => _HubProjectSectionState();
}

class _HubProjectSectionState extends State<HubProjectSection> {
  final hub = Hub.instance;
  List<Map<String, dynamic>> builds = [], jobs = [];
  String err = '';
  int? dl; // build yang sedang diunduh
  double? dlPct;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _load();
    _t = Timer.periodic(const Duration(seconds: 20), (_) => _load());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final b = await hub.builds(widget.project.id);
      final j = await hub.jobs(widget.project.id);
      if (mounted) {
        setState(() {
          builds = b;
          jobs = j;
          err = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => err = '$e');
    }
  }

  static String _ago(num t) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch((t * 1000).round()));
    if (d.inMinutes < 1) return trL('baru saja');
    if (d.inHours < 1) return trL('{0} menit lalu', [d.inMinutes]);
    if (d.inDays < 1) return trL('{0} jam lalu', [d.inHours]);
    return trL('{0} hari lalu', [d.inDays]);
  }

  Future<void> _deploy(Map<String, dynamic> b) async {
    var track = 'internal';
    var pct = 10;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(tr('Deploy {0} dari server', [b['version']])),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
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
              ),
              if (track == 'production')
                DropdownButtonFormField<int>(
                  value: pct,
                  decoration: InputDecoration(labelText: tr('Rollout awal'), isDense: true),
                  items: [for (final v in [5, 10, 20, 50, 100]) DropdownMenuItem(value: v, child: Text('$v%'))],
                  onChanged: (v) => set(() => pct = v ?? 10),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Batal'))),
            ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Deploy sekarang'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      final jid = await hub.deploy(widget.project.id, b['id'] as int, track: track, fraction: track == 'production' && pct < 100 ? pct / 100 : null);
      if (!mounted) return;
      if (jid == null) {
        showSnack(context, tr('Permintaan deploy dikirim — menunggu persetujuan admin di dashboard server (menu Persetujuan)'));
      } else {
        showDialog(context: context, builder: (_) => HubLogDialog(jobId: jid));
      }
      _load();
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = jobs.where((j) => j['status'] == 'running' || j['status'] == 'queued').firstOrNull;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.dns_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('DeployHub Server'), style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700))),
          if (running != null)
            TextButton.icon(
              onPressed: () => showDialog(context: context, builder: (_) => HubLogDialog(jobId: running['id'] as int)),
              icon: const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              label: Text('#${running['id']} ${running['kind']} • ${running['summary'] ?? running['status']}', overflow: TextOverflow.ellipsis),
            )
          else
            TextButton.icon(
              onPressed: () async {
                try {
                  final jid = await hub.build(widget.project.id);
                  if (context.mounted) showDialog(context: context, builder: (_) => HubLogDialog(jobId: jid));
                  _load();
                } catch (e) {
                  if (context.mounted) showSnack(context, '$e', error: true);
                }
              },
              icon: const Icon(Icons.build_rounded, size: 16),
              label: Text(tr('Build di server')),
            ),
        ]),
        if (err.isNotEmpty) Text(err.length > 160 ? '${err.substring(0, 160)}…' : err, style: YmTextStyles.bodySm.copyWith(color: YmColors.danger)),
        for (final b in builds.take(3))
          Row(children: [
            Expanded(
              child: Text(
                '${b['version']} • ${'${b['commit_sha'] ?? ''}'.padRight(7).substring(0, 7)} • ${_ago(b['created'] as num)}${b['coverage'] != null ? ' • cov ${b['coverage']}%' : ''}',
                style: YmTextStyles.bodySm,
              ),
            ),
            if (ReadyBuilds.instance.get(widget.project.id, 'android')?.version == b['version'] &&
                ReadyBuilds.instance.get(widget.project.id, 'android')!.exists)
              Tooltip(message: tr('Sudah ada di PC'), child: Icon(Icons.download_done_rounded, size: 18, color: YmColors.success))
            else if (dl == b['id'])
              SizedBox(width: 60, child: LinearProgressIndicator(value: dlPct))
            else
              IconButton(
                tooltip: tr('Unduh ke PC (tersimpan lokal & bisa dideploy walau server mati)'),
                icon: const Icon(Icons.download_rounded, size: 18),
                onPressed: dl != null
                    ? null
                    : () async {
                        setState(() {
                          dl = b['id'] as int;
                          dlPct = null;
                        });
                        try {
                          final path = await hub.downloadBuild(widget.project, b, progress: (g, t) {
                            if (mounted && t > 0) setState(() => dlPct = g / t);
                          });
                          if (mounted) showSnack(context, tr('Tersimpan di PC: {0}', [path]));
                          app.notifyListeners();
                        } catch (e) {
                          if (mounted) showSnack(context, '$e', error: true);
                        } finally {
                          if (mounted) setState(() => dl = null);
                        }
                      },
              ),
            if ((b['deployed_track'] ?? '').toString().isNotEmpty)
              Text('✔ ${b['deployed_track']}', style: YmTextStyles.bodySm.copyWith(color: YmColors.success))
            else
              TextButton(onPressed: () => _deploy(b), child: Text(tr('Deploy'))),
          ]),
        if (builds.isEmpty && err.isEmpty) Text(tr('Belum ada build di server'), style: YmTextStyles.bodySm),
        for (final j in jobs.where((j) => j['status'] == 'failed').take(1))
          TextButton.icon(
            onPressed: () => showDialog(context: context, builder: (_) => HubLogDialog(jobId: j['id'] as int)),
            icon: Icon(Icons.error_outline_rounded, size: 16, color: YmColors.danger),
            label: Text('#${j['id']} ${j['kind']} ${tr('gagal')}: ${j['summary'] ?? ''}', overflow: TextOverflow.ellipsis, style: TextStyle(color: YmColors.danger)),
          ),
      ]),
    );
  }
}

/// Log job server (bertahap, otomatis diperbarui).
class HubLogDialog extends StatefulWidget {
  const HubLogDialog({super.key, required this.jobId});
  final int jobId;

  @override
  State<HubLogDialog> createState() => _HubLogDialogState();
}

class _HubLogDialogState extends State<HubLogDialog> {
  final buf = StringBuffer();
  int offset = 0;
  bool done = false;
  Timer? t;
  final scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _tick();
    t = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  @override
  void dispose() {
    t?.cancel();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _tick() async {
    if (done) return;
    try {
      final r = await Hub.instance.log(widget.jobId, offset);
      offset = r['offset'] as int;
      buf.write(r['text']);
      done = r['done'] == true;
      if (done) t?.cancel();
      if (!mounted) return;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
      });
    } catch (e) {
      buf.writeln('\n✖ $e');
      done = true;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(children: [
        Text(tr('Job server #{0}', [widget.jobId])),
        const SizedBox(width: 10),
        if (!done) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      ]),
      content: SizedBox(
        width: 900,
        height: 520,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFF0A0F1A), borderRadius: BorderRadius.circular(10)),
          child: SingleChildScrollView(
            controller: scroll,
            child: SelectableText(buf.toString(), style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: Color(0xFFD7DCE3))),
          ),
        ),
      ),
      actions: [
        if (!done) TextButton(onPressed: () => Hub.instance.cancel(widget.jobId), child: Text(tr('Batalkan job'))),
        ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(context), child: Text(tr('Tutup'))),
      ],
    );
  }
}
