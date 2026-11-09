import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../services/integrations.dart';
import '../services/server_setup.dart';
import '../services/storage.dart';
import '../services/tool_env.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

/// Pengaturan → DevOps & integrasi: setiap alat bisa diaktifkan / dimatikan sendiri,
/// dipasang otomatis, dan dites dari sini.
class IntegrationsPanel extends StatefulWidget {
  const IntegrationsPanel({super.key});

  @override
  State<IntegrationsPanel> createState() => _IntegrationsPanelState();
}

class _IntegrationsPanelState extends State<IntegrationsPanel> {
  final it = Integrations.instance;
  late final c = <String, TextEditingController>{
    'discord': TextEditingController(),
    'slack': TextEditingController(),
    'jenkinsUrl': TextEditingController(text: it.jenkinsUrl),
    'jenkinsUser': TextEditingController(text: it.jenkinsUser),
    'jenkinsToken': TextEditingController(),
    'jenkinsJob': TextEditingController(text: it.jenkinsJob),
    'gitlabUrl': TextEditingController(text: it.gitlabUrl),
    'gitlabProject': TextEditingController(text: it.gitlabProject),
    'gitlabToken': TextEditingController(),
    'nexusUrl': TextEditingController(text: it.nexusUrl),
    'nexusUser': TextEditingController(text: it.nexusUser),
    'nexusPass': TextEditingController(),
    'triggerMin': TextEditingController(text: '${it.autoTriggerMinutes}'),
  };
  final tools = <String, ToolStatus>{};
  String? busy;
  final logs = <String>[];
  final toolLogs = <String>[]; // log pemasangan alat (tampil di bawah daftar alat)

  void _log(String l) {
    if (!mounted) return;
    setState(() {
      toolLogs.add(l);
      if (toolLogs.length > 300) toolLogs.removeAt(0);
    });
  }

  @override
  void initState() {
    super.initState();
    () async {
      c['discord']!.text = await Storage.secret(Integrations.kDiscord);
      c['slack']!.text = await Storage.secret(Integrations.kSlack);
      c['jenkinsToken']!.text = await Storage.secret(Integrations.kJenkins);
      c['gitlabToken']!.text = await Storage.secret(Integrations.kGitlab);
      c['nexusPass']!.text = await Storage.secret(Integrations.kNexus);
      await _checkTools();
    }();
  }

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  Future<void> _checkTools() async {
    if (mounted) setState(tools.clear);
    await ToolEnv.init(); // baca ulang PATH (alat yang baru dipasang langsung terdeteksi)
    final r = await Future.wait([
      toolVersion('docker', ['--version']),
      toolVersion('git', ['--version']),
      toolVersion('gh', ['--version']),
      toolVersion('glab', ['--version']),
      toolVersion('java', ['-version']),
      toolVersion('terraform', ['version']),
    ]);
    if (!mounted) return;
    setState(() {
      tools['docker'] = r[0];
      tools['git'] = r[1];
      tools['gh'] = r[2];
      tools['glab'] = r[3];
      tools['java'] = r[4];
      tools['terraform'] = r[5];
    });
  }

  Future<void> _save({bool quiet = false}) async {
    it.jenkinsUrl = c['jenkinsUrl']!.text.trim();
    it.jenkinsUser = c['jenkinsUser']!.text.trim();
    it.jenkinsJob = c['jenkinsJob']!.text.trim();
    it.gitlabUrl = c['gitlabUrl']!.text.trim().isEmpty ? 'https://gitlab.com' : c['gitlabUrl']!.text.trim();
    it.gitlabProject = c['gitlabProject']!.text.trim();
    it.nexusUrl = c['nexusUrl']!.text.trim();
    it.nexusUser = c['nexusUser']!.text.trim();
    it.autoTriggerMinutes = int.tryParse(c['triggerMin']!.text) ?? 5;
    await Storage.setSecret(Integrations.kDiscord, c['discord']!.text.trim());
    await Storage.setSecret(Integrations.kSlack, c['slack']!.text.trim());
    await Storage.setSecret(Integrations.kJenkins, c['jenkinsToken']!.text.trim());
    await Storage.setSecret(Integrations.kGitlab, c['gitlabToken']!.text.trim());
    await Storage.setSecret(Integrations.kNexus, c['nexusPass']!.text);
    await it.save();
    app.restartAutoTrigger();
    if (!quiet && mounted) showSnack(context, tr('Integrasi disimpan'));
  }

  Future<void> _do(String name, Future<String> Function() fn) async {
    setState(() => busy = name);
    try {
      await _save(quiet: true);
      final msg = await fn();
      if (mounted) showSnack(context, msg);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Widget _btn(String label, IconData icon, Future<String> Function()? fn, {bool primary = false}) {
    final child = busy == label ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon, size: 18);
    final onPressed = fn == null || busy != null ? null : () => _do(label, fn);
    return primary
        ? ElevatedButton.icon(style: primaryButtonStyle(), onPressed: onPressed, icon: child, label: Text(label))
        : OutlinedButton.icon(style: outlineButtonStyle(), onPressed: onPressed, icon: child, label: Text(label));
  }

  /// Satu kartu integrasi: judul + saklar aktif + isi (muncul kalau aktif).
  Widget _card({
    required IconData icon,
    required String title,
    required String sub,
    required bool on,
    required ValueChanged<bool> onChanged,
    List<Widget> children = const [],
    String? stage,
    bool toggle = true,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: on ? YmColors.surface : YmColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: on ? YmColors.primary.withOpacity(0.4) : YmColors.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: on ? YmColors.primarySoft : YmColors.surfaceContainer, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 19, color: on ? YmColors.primary : YmColors.outline),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(title, style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700))),
                if (stage != null) ...[const SizedBox(width: 8), SoftChip.neutral(stage)],
              ]),
              Text(sub, style: YmTextStyles.bodySm),
            ]),
          ),
          if (toggle)
          Switch(
            value: on,
            onChanged: (v) {
              setState(() => onChanged(v));
              _save(quiet: true);
            },
          ),
        ]),
        if (on && children.isNotEmpty) ...[const SizedBox(height: 12), ...children],
      ]),
    );
  }

  Widget _tool(String key, String label) {
    final t = tools[key];
    final cmd = installCommand(key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Icon(t == null ? Icons.hourglass_empty_rounded : (t.installed ? Icons.check_circle_rounded : Icons.cancel_rounded),
            size: 18, color: t == null ? YmColors.outline : (t.installed ? YmColors.success : YmColors.danger)),
        const SizedBox(width: 8),
        SizedBox(width: 120, child: Text(label, style: YmTextStyles.labelMd)),
        Expanded(child: Text(t == null ? '…' : (t.installed ? t.version : tr('belum terpasang')), style: YmTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (t != null && !t.installed && cmd != null)
          _btn(tr('Pasang {0}', [label]), Icons.download_rounded, () async {
            final ok = await ensureTool(key, _log);
            await _checkTools();
            return ok ? tr('{0} terpasang', [label]) : tr('Gagal memasang {0} — lihat log di bawah', [label]);
          }),
        if (key == 'docker' && t != null && t.installed)
          _btn(tr('Nyalakan Docker'), Icons.play_circle_outline_rounded, () async =>
              await ensureDockerRunning(_log) ? tr('Docker siap') : tr('Docker belum siap — lihat log di bawah')),
      ]),
    );
  }

  Future<dynamic> _pickProject() async {
    final list = app.projects;
    if (list.isEmpty) throw Exception(tr('Belum ada proyek'));
    if (list.length == 1) return list.first;
    return showDialog<dynamic>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('Proyek mana?')),
        children: [for (final x in list) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, x), child: Text('${x.name} • ${x.localPath}'))],
      ),
    );
  }

  Future<String> _ciFile(String kind) async {
    final list = app.projects;
    if (list.isEmpty) throw Exception(tr('Belum ada proyek'));
    final pr = list.length == 1
        ? list.first
        : await showDialog<dynamic>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: Text(tr('Tulis file ke proyek mana?')),
              children: [for (final x in list) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, x), child: Text('${x.name} • ${x.localPath}'))],
            ),
          );
    if (pr == null) return tr('Dibatalkan');
    final path = await writeCiFile(pr.localPath, kind);
    return tr('Dibuat: {0} — commit & push supaya berjalan di server', [path]);
  }

  @override
  Widget build(BuildContext context) {
    final projects = app.projects;
    return Panel(
      title: tr('DevOps & integrasi'),
      subtitle: tr('Aktifkan hanya yang dibutuhkan. Semua bisa dipasang & dites dari sini, dan bisa dimatikan lagi kapan saja.'),
      icon: Icons.hub_rounded,
      trailing: ElevatedButton.icon(style: primaryButtonStyle(), onPressed: () => _save(), icon: const Icon(Icons.save_outlined), label: Text(tr('Simpan'))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // ───── alat di PC
        GroupLabel(tr('Alat di PC (pasang otomatis)')),
        _tool('git', 'Git'),
        _tool('docker', 'Docker'),
        _tool('gh', 'GitHub CLI'),
        _tool('glab', 'GitLab CLI'),
        _tool('java', 'Java (JDK 17+)'),
        _tool('terraform', 'Terraform'),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (tools.values.any((t) => !t.installed))
            _btn(tr('Pasang semua yang belum ada'), Icons.download_for_offline_outlined, () async {
              final missing = tools.entries.where((e) => !e.value.installed && installCommand(e.key) != null).map((e) => e.key).toList();
              final failed = <String>[];
              for (final k in missing) {
                if (!await ensureTool(k, _log)) failed.add(toolLabels[k] ?? k);
              }
              await _checkTools();
              return failed.isEmpty ? tr('Semua alat terpasang') : tr('Belum berhasil: {0} — lihat log', [failed.join(', ')]);
            }, primary: true),
          TextButton.icon(onPressed: _checkTools, icon: const Icon(Icons.refresh_rounded, size: 18), label: Text(tr('Cek lagi'))),
        ]),
        Text(tr('Tidak perlu memasang manual: fitur yang butuh alat (Docker, Terraform, dll.) akan memasangnya sendiri saat tombolnya ditekan.'), style: YmTextStyles.bodySm),
        if (toolLogs.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            constraints: const BoxConstraints(maxHeight: 200),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF0A0F1A), borderRadius: BorderRadius.circular(10)),
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(toolLogs.join('\n'), style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: Color(0xFFD7DCE3))),
            ),
          ),
        const SizedBox(height: 8),

        // ───── 1. Source
        GroupLabel(tr('1. Source — pemicu otomatis')),
        _card(
          icon: Icons.bolt_rounded,
          title: tr('Jalankan pipeline otomatis saat ada commit baru'),
          sub: tr('DeployHub mengecek branch di GitHub / GitLab / Bitbucket berkala. Ada commit baru → pipeline jalan sendiri (DeployHub harus terbuka / di tray).'),
          stage: 'Source',
          on: it.autoTriggerOn,
          onChanged: (v) => it.autoTriggerOn = v,
          children: [
            Row(children: [
              SizedBox(width: 160, child: DhField(c['triggerMin']!, tr('Cek tiap (menit)'), keyboard: TextInputType.number)),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(spacing: 8, children: [
                  QuickChip(label: tr('Build siap deploy: AAB + IPA, deploy manual 1 klik'), selected: it.autoTriggerMode == 'ready', onTap: () => setState(() => it.autoTriggerMode = 'ready')),
                  QuickChip(label: tr('CI: cek + build AAB'), selected: it.autoTriggerMode == 'ci', onTap: () => setState(() => it.autoTriggerMode = 'ci')),
                  QuickChip(label: tr('CD: build + upload ke Pengujian internal'), selected: it.autoTriggerMode == 'cd', onTap: () => setState(() => it.autoTriggerMode = 'cd')),
                ]),
              ),
            ]),
            Text(tr('Proyek yang dipantau:'), style: YmTextStyles.labelMd),
            for (final p in projects)
              CheckRow(
                label: '${p.name} (${p.branch})',
                sub: p.localPath,
                value: it.autoTriggerProjects.contains(p.id),
                onChanged: (v) => setState(() => v ? it.autoTriggerProjects.add(p.id) : it.autoTriggerProjects.remove(p.id)),
              ),
            if (app.triggerStatus.isNotEmpty) Text(tr('Terakhir dicek: {0}', [app.triggerStatus]), style: YmTextStyles.bodySm),
          ],
        ),
        _card(
          icon: Icons.description_outlined,
          title: tr('File CI di repo (trigger saat push & Pull Request di server)'),
          sub: tr('Buat file pipeline untuk GitHub Actions, GitLab CI, Jenkins, Bitbucket: analyze → test → build AAB otomatis di server setiap push / PR.'),
          stage: 'Source → Build → Test',
          on: true,
          toggle: false,
          onChanged: (_) {},
          children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              _btn('GitHub Actions', Icons.hub_outlined, () => _ciFile('github')),
              _btn('.gitlab-ci.yml', Icons.merge_type_rounded, () => _ciFile('gitlab')),
              _btn('Jenkinsfile', Icons.engineering_outlined, () => _ciFile('jenkins')),
              _btn('bitbucket-pipelines.yml', Icons.source_outlined, () => _ciFile('bitbucket')),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _btn(tr('Pasang secret signing di GitHub'), Icons.key_outlined, () async {
                final pr = await _pickProject();
                if (pr == null) return tr('Dibatalkan');
                final ok = await confirmDialog(context,
                    title: tr('Simpan keystore di GitHub Secrets?'),
                    message: tr('Keystore & key.properties dikirim terenkripsi ke GitHub Secrets repo ini (ANDROID_KEYSTORE_BASE64, ANDROID_KEY_PROPERTIES) supaya GitHub Actions bisa membuat AAB release. File-nya tetap TIDAK masuk git. Simpan cadangan keystore di tempat aman — kalau hilang, aplikasi tidak bisa diupdate.'));
                if (!ok) return tr('Dibatalkan');
                await installAndroidSigningSecrets(pr.localPath, _log);
                return tr('Secret signing tersimpan di GitHub');
              }),
              _btn(tr('Docker untuk backend (FastAPI)'), Icons.dns_outlined, () async {
                final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: tr('Pilih folder backend (FastAPI)'));
                if (dir == null) return tr('Dibatalkan');
                final made = await writeBackendDocker(dir);
                return made.isEmpty ? tr('Semua file Docker sudah ada') : tr('Dibuat: {0} — commit & push', [made.join(', ')]);
              }),
            ]),
          ],
        ),

        // ───── 2/3 Build & Test
        GroupLabel(tr('2–3. Build & Test')),
        _card(
          icon: Icons.security_rounded,
          title: tr('Security scan'),
          sub: tr('Cari password/token/private key di kode, keystore & key.properties yang ikut ke git, dan URL http:// tanpa enkripsi.'),
          stage: 'Test',
          on: it.securityScanOn,
          onChanged: (v) => it.securityScanOn = v,
        ),
        _card(
          icon: Icons.bug_report_outlined,
          title: tr('Scan kerentanan library (OSV)'),
          sub: tr('Cek setiap library di pubspec.lock ke database kerentanan OSV (osv.dev, sama dengan OSV-Scanner Google). Kerentanan CRITICAL/HIGH menahan upload sampai library dinaikkan versinya.'),
          stage: 'Test',
          on: it.vulnScanOn,
          onChanged: (v) => it.vulnScanOn = v,
        ),
        _card(
          icon: Icons.directions_boat_filled_outlined,
          title: 'Docker',
          sub: tr('Build Android di dalam container (Flutter + Android SDK + JDK 17) — hasil selalu sama di PC mana pun. Butuh Docker Desktop.'),
          stage: 'Build',
          on: it.dockerOn,
          onChanged: (v) => it.dockerOn = v,
          children: [
            CheckRow(
              label: tr('Build AAB di dalam Docker'),
              sub: tr('Image ghcr.io/cirruslabs/flutter:stable (unduh sekali ±3 GB). Signing tetap memakai keystore di folder project.'),
              value: it.dockerBuild,
              onChanged: (v) => setState(() => it.dockerBuild = v),
            ),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _btn(tr('Unduh image Flutter'), Icons.download_rounded, () async {
                if (!await ensureTool('docker', _log)) return tr('Docker belum siap — lihat log di bawah');
                final r = await Process.run('docker', ['pull', 'ghcr.io/cirruslabs/flutter:stable'], runInShell: true, environment: ToolEnv.env());
                return r.exitCode == 0 ? tr('Image siap') : '${r.stderr}'.trim();
              }),
              _btn('Dockerfile', Icons.description_outlined, () => _ciFile('docker')),
            ]),
          ],
        ),
        _card(
          icon: Icons.engineering_outlined,
          title: 'Jenkins',
          sub: tr('Picu job & lihat status build. Belum punya Jenkins? Pasang otomatis di Docker (http://localhost:8080).'),
          stage: 'CI server',
          on: it.jenkinsOn,
          onChanged: (v) => it.jenkinsOn = v,
          children: [
            fieldRow([
              DhField(c['jenkinsUrl']!, 'URL Jenkins', icon: Icons.link_rounded, hint: 'http://localhost:8080'),
              DhField(c['jenkinsJob']!, tr('Nama job'), icon: Icons.work_outline_rounded, hint: 'aplikasichat'),
            ]),
            fieldRow([
              DhField(c['jenkinsUser']!, 'Username', icon: Icons.person_outline_rounded),
              DhField(c['jenkinsToken']!, 'API token', icon: Icons.key_outlined, obscure: true),
            ]),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _btn(tr('Pasang Jenkins (Docker)'), Icons.download_rounded, () async {
                final pw = await installJenkinsDocker((l) => setState(() => logs.add(l)));
                if (pw.isNotEmpty) launchUrl(Uri.parse('http://localhost:8080'));
                return pw.isEmpty ? tr('Jenkins berjalan di http://localhost:8080') : tr('Jenkins siap. Password admin awal: {0}', [pw]);
              }),
              _btn(tr('Tes Jenkins'), Icons.wifi_tethering_rounded, it.jenkinsTest),
              _btn(tr('Picu build'), Icons.play_arrow_rounded, () async => tr('Build masuk antrian: {0}', [await it.jenkinsBuild()])),
              _btn(tr('Status terakhir'), Icons.history_rounded, () async {
                final l = await it.jenkinsLast();
                return l == null ? tr('Belum ada build') : '#${l.$1} • ${l.$2}';
              }),
            ]),
          ],
        ),
        _card(
          icon: Icons.merge_type_rounded,
          title: 'GitLab CI/CD',
          sub: tr('Jalankan pipeline GitLab & lihat statusnya. Token: GitLab → Preferences → Access tokens (scope api).'),
          stage: 'CI server',
          on: it.gitlabOn,
          onChanged: (v) => it.gitlabOn = v,
          children: [
            fieldRow([
              DhField(c['gitlabUrl']!, 'URL GitLab', icon: Icons.link_rounded, hint: 'https://gitlab.com'),
              DhField(c['gitlabProject']!, tr('Project (namespace/nama)'), icon: Icons.folder_outlined, hint: 'prakash/aplikasichat'),
            ]),
            DhField(c['gitlabToken']!, 'Access token', icon: Icons.key_outlined, obscure: true),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _btn(tr('Tes GitLab'), Icons.wifi_tethering_rounded, it.gitlabTest),
              _btn(tr('Jalankan pipeline (main)'), Icons.play_arrow_rounded, () async => await it.gitlabRunPipeline('main')),
              _btn(tr('Pipeline terbaru'), Icons.history_rounded, () async {
                final l = await it.gitlabPipelines();
                return l.isEmpty ? tr('Belum ada pipeline') : l.take(3).map((x) => '#${x.$1} ${x.$3}: ${x.$2}').join(' • ');
              }),
            ]),
          ],
        ),
        _card(
          icon: Icons.source_outlined,
          title: 'Bitbucket Pipelines',
          sub: tr('Repo di Bitbucket: buat file bitbucket-pipelines.yml (tombol di "File CI" di atas). Pemicu commit baru juga bekerja untuk Bitbucket.'),
          stage: 'CI server',
          on: it.bitbucketOn,
          onChanged: (v) => it.bitbucketOn = v,
        ),

        // ───── 4. Release
        GroupLabel(tr('4. Release — artifact repository')),
        _card(
          icon: Icons.inventory_2_outlined,
          title: tr('Arsip artefak di PC'),
          sub: tr('Setiap build: AAB + mapping R8 + laporan AAB disimpan per versi (bisa diupload ulang kapan saja).'),
          stage: 'Release',
          on: it.artifactsOn,
          onChanged: (v) => it.artifactsOn = v,
          children: [
            Wrap(spacing: 8, children: [
              _btn(tr('Buka folder artefak'), Icons.folder_open_rounded, () async {
                final dir = Directory('${Storage.dir.path}${Platform.pathSeparator}artifacts');
                await dir.create(recursive: true);
                await launchUrl(Uri.file(dir.path));
                return dir.path;
              }),
            ]),
          ],
        ),
        _card(
          icon: Icons.cloud_upload_outlined,
          title: 'Nexus / Artifactory',
          sub: tr('Upload AAB ke raw repository Nexus / JFrog Artifactory: <URL>/<package>/<versi>/app-release.aab.'),
          stage: 'Release',
          on: it.nexusOn,
          onChanged: (v) => it.nexusOn = v,
          children: [
            DhField(c['nexusUrl']!, 'URL repository', icon: Icons.link_rounded, hint: 'https://nexus.domain.com/repository/mobile-raw'),
            fieldRow([
              DhField(c['nexusUser']!, 'Username', icon: Icons.person_outline_rounded),
              DhField(c['nexusPass']!, 'Password / token', icon: Icons.key_outlined, obscure: true),
            ]),
          ],
        ),
        Text(tr('GitHub Release + lampiran AAB sudah ada di dialog Deploy (bagian GitHub).'), style: YmTextStyles.bodySm),
        const SizedBox(height: 10),

        // ───── 6. Monitoring
        GroupLabel(tr('Monitoring & notifikasi')),
        _card(
          icon: Icons.forum_outlined,
          title: 'Discord',
          sub: tr('Server → Edit channel → Integrations → Webhooks → New Webhook → Copy URL.'),
          stage: 'Feedback',
          on: it.discordOn,
          onChanged: (v) => it.discordOn = v,
          children: [
            DhField(c['discord']!, 'Webhook URL', icon: Icons.link_rounded, obscure: true, hint: 'https://discord.com/api/webhooks/...'),
            Align(
              alignment: Alignment.centerLeft,
              child: _btn(tr('Kirim pesan tes'), Icons.send_rounded, () async {
                await Integrations.sendDiscord(c['discord']!.text.trim(), '✅ DeployHub terhubung ke Discord');
                return tr('Terkirim');
              }),
            ),
          ],
        ),
        _card(
          icon: Icons.tag_rounded,
          title: 'Slack',
          sub: tr('api.slack.com/apps → Create App → Incoming Webhooks → Add New Webhook → Copy URL.'),
          stage: 'Feedback',
          on: it.slackOn,
          onChanged: (v) => it.slackOn = v,
          children: [
            DhField(c['slack']!, 'Webhook URL', icon: Icons.link_rounded, obscure: true, hint: 'https://hooks.slack.com/services/...'),
            Align(
              alignment: Alignment.centerLeft,
              child: _btn(tr('Kirim pesan tes'), Icons.send_rounded, () async {
                await Integrations.sendSlack(c['slack']!.text.trim(), '✅ DeployHub terhubung ke Slack');
                return tr('Terkirim');
              }),
            ),
          ],
        ),
        Text(tr('Telegram diatur di panel Telegram di atas. Semua kanal aktif menerima notifikasi sukses / gagal setiap pipeline.'), style: YmTextStyles.bodySm),
        if (logs.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF0A0F1A), borderRadius: BorderRadius.circular(10)),
            child: SelectableText(logs.join('\n'), style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: Color(0xFFD7DCE3))),
          ),
        ],
      ]),
    );
  }
}
