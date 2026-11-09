import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../services/ai_fixer.dart';
import '../services/infra.dart';
import '../services/server_ops.dart';
import '../services/server_setup.dart';
import '../services/storage.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

// ═════════════════════════════════════════════ AI perbaikan otomatis
class AiPanel extends StatefulWidget {
  const AiPanel({super.key});

  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<AiPanel> {
  final ai = AiFixer.instance;
  late final url = TextEditingController(text: ai.url);
  late final model = TextEditingController(text: ai.model);
  final key = TextEditingController();
  List<String> models = [];
  String? busy;

  static const presets = <String, (String, String)>{
    'Prakash AI': ('openai', 'http://localhost:5088/v1'),
    'LM Studio': ('openai', 'http://localhost:1234/v1'),
    'Ollama': ('ollama', 'http://localhost:11434'),
    'llama.cpp server': ('openai', 'http://localhost:8080/v1'),
    'OpenAI': ('openai', 'https://api.openai.com/v1'),
    'Claude API': ('anthropic', 'https://api.anthropic.com'),
  };

  @override
  void initState() {
    super.initState();
    Storage.secret(AiFixer.kKey).then((v) => key.text = v);
  }

  @override
  void dispose() {
    url.dispose();
    model.dispose();
    key.dispose();
    super.dispose();
  }

  Future<void> _save({bool quiet = false}) async {
    ai.url = url.text.trim();
    ai.model = model.text.trim();
    await Storage.setSecret(AiFixer.kKey, key.text.trim());
    await ai.save();
    if (!quiet && mounted) showSnack(context, tr('Pengaturan AI disimpan'));
  }

  Future<void> _do(String name, Future<String> Function() fn) async {
    setState(() => busy = name);
    try {
      await _save(quiet: true);
      final m = await fn();
      if (mounted) showSnack(context, m);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Widget _btn(String label, IconData icon, Future<String> Function() fn) => OutlinedButton.icon(
        style: outlineButtonStyle(),
        onPressed: busy != null ? null : () => _do(label, fn),
        icon: busy == label ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon, size: 18),
        label: Text(label),
      );

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: tr('AI perbaikan otomatis'),
      subtitle: tr('Nonaktif: perbaikan otomatis biasa (aturan). Aktif: kalau aturan tidak cukup, AI-mu membaca log error + file terkait lalu memperbaiki kodenya lebih dalam.'),
      icon: Icons.psychology_alt_outlined,
      trailing: Switch(
        value: ai.on,
        onChanged: (v) {
          setState(() => ai.on = v);
          _save(quiet: true);
        },
      ),
      child: !ai.on
          ? Text(tr('AI nonaktif — DeployHub memakai perbaikan otomatis biasa.'), style: YmTextStyles.bodySm)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in presets.entries)
                  QuickChip(
                    label: e.key,
                    selected: ai.provider == e.value.$1 && url.text.trim() == e.value.$2,
                    onTap: () => setState(() {
                      ai.provider = e.value.$1;
                      url.text = e.value.$2;
                      models = [];
                    }),
                  ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                SizedBox(
                  width: 210,
                  child: DropdownButtonFormField<String>(
                    value: ai.provider,
                    decoration: InputDecoration(labelText: tr('Jenis API'), isDense: true),
                    items: [
                      DropdownMenuItem(value: 'openai', child: Text(tr('Kompatibel OpenAI'))),
                      const DropdownMenuItem(value: 'ollama', child: Text('Ollama')),
                      const DropdownMenuItem(value: 'anthropic', child: Text('Claude (Anthropic)')),
                    ],
                    onChanged: (v) => setState(() => ai.provider = v ?? 'openai'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: DhField(url, 'URL', icon: Icons.link_rounded, hint: 'http://localhost:5088/v1')),
              ]),
              fieldRow([
                models.isEmpty
                    ? DhField(model, tr('Model'), icon: Icons.memory_rounded, hint: 'qwen3-coder-30b')
                    : DropdownButtonFormField<String>(
                        value: models.contains(model.text) ? model.text : null,
                        isExpanded: true,
                        decoration: InputDecoration(labelText: tr('Model'), isDense: true),
                        items: [for (final m in models) DropdownMenuItem(value: m, child: Text(m, overflow: TextOverflow.ellipsis))],
                        onChanged: (v) => setState(() => model.text = v ?? ''),
                      ),
                DhField(key, tr('API key (kosongkan untuk AI lokal)'), icon: Icons.key_outlined, obscure: true),
              ]),
              CheckRow(
                label: tr('Mode dalam (deep)'),
                sub: tr('Kirim lebih banyak file (Gradle, manifest, file yang disebut di error) dan log lebih panjang. Lebih akurat, lebih lambat.'),
                value: ai.deep,
                onChanged: (v) => setState(() => ai.deep = v),
              ),
              CheckRow(
                label: tr('Perbaiki otomatis di dalam pipeline'),
                sub: tr('Mati = AI hanya lewat tombol "Perbaiki dengan AI" saat pipeline gagal.'),
                value: ai.autoApply,
                onChanged: (v) => setState(() => ai.autoApply = v),
              ),
              Row(children: [
                Text(tr('Putaran AI per langkah'), style: YmTextStyles.labelMd),
                const SizedBox(width: 12),
                for (final n in [1, 2, 3])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: QuickChip(label: '$n', selected: ai.maxRounds == n, onTap: () => setState(() => ai.maxRounds = n)),
                  ),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _btn(tr('Ambil daftar model'), Icons.list_alt_rounded, () async {
                  final l = await ai.models();
                  setState(() => models = l);
                  if (model.text.isEmpty && l.isNotEmpty) model.text = l.first;
                  return tr('{0} model ditemukan', [l.length]);
                }),
                _btn(tr('Tes AI'), Icons.wifi_tethering_rounded, ai.test),
                ElevatedButton.icon(style: primaryButtonStyle(), onPressed: () => _save(), icon: const Icon(Icons.save_outlined), label: Text(tr('Simpan'))),
              ]),
              const SizedBox(height: 8),
              Text(
                tr('Aman: key.properties, keystore, google-services.json, .env dan file service account tidak pernah dikirim ke AI; password di file disamarkan. Setiap file yang diubah AI dibackup ke *.deployhub.bak.'),
                style: YmTextStyles.bodySm,
              ),
            ]),
    );
  }
}

// ═════════════════════════════════════════════ Server & infrastruktur
class ServerOpsPanel extends StatefulWidget {
  const ServerOpsPanel({super.key});

  @override
  State<ServerOpsPanel> createState() => _ServerOpsPanelState();
}

class _ServerOpsPanelState extends State<ServerOpsPanel> {
  final ops = ServerOps.instance;

  Future<void> _save() async {
    await ops.save();
    ops.restart();
    if (mounted) setState(() {});
  }

  Future<void> _edit([ServerTarget? s]) async {
    final res = await showDialog<ServerTarget>(context: context, builder: (_) => _ServerEditor(server: s));
    if (res == null) return;
    final i = ops.servers.indexWhere((x) => x.id == res.id);
    if (i >= 0) {
      ops.servers[i] = res;
    } else {
      ops.servers.add(res);
    }
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: tr('Otomatisasi Deployment & Infrastruktur'),
      subtitle: tr('Untuk server backend (VPS / cloud): deploy lewat SSH (git pull → docker compose build → restart), backup & restore database, dan pantau kesehatan server dengan alert.'),
      icon: Icons.dns_outlined,
      trailing: Switch(
        value: ops.on,
        onChanged: (v) {
          setState(() => ops.on = v);
          _save();
        },
      ),
      child: !ops.on
          ? Text(tr('Nonaktif — tidak ada koneksi ke server dan tidak ada jadwal yang berjalan.'), style: YmTextStyles.bodySm)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final s in ops.servers) _ServerCard(server: s, onEdit: () => _edit(s), onDelete: () async {
                    final ok = await confirmDialog(context, title: tr('Hapus server {0}?', [s.name]), message: tr('Pengaturan server ini dihapus dari DeployHub. Server-nya sendiri tidak diubah.'), danger: true);
                    if (!ok) return;
                    ops.servers.remove(s);
                    await Storage.setSecret(s.secretKey, '');
                    await _save();
                  }, onChanged: _save),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(style: outlineButtonStyle(), onPressed: () => _edit(), icon: const Icon(Icons.add_rounded), label: Text(tr('Tambah server'))),
                OutlinedButton.icon(
                  style: outlineButtonStyle(),
                  onPressed: ops.servers.isEmpty
                      ? null
                      : () async {
                          final path = await Infra.instance.writeAnsible(ops.servers);
                          await launchUrl(Uri.file(path));
                        },
                  icon: const Icon(Icons.description_outlined),
                  label: Text(tr('Playbook Ansible (semua server)')),
                ),
                OutlinedButton.icon(
                  style: outlineButtonStyle(),
                  onPressed: () async {
                    final path = await Infra.instance.writeRunbook();
                    await launchUrl(Uri.file(path));
                    if (context.mounted) showSnack(context, tr('Runbook dibuat: {0}', [path]));
                  },
                  icon: const Icon(Icons.menu_book_outlined),
                  label: Text(tr('Buat runbook (dokumentasi)')),
                ),
              ]),
            ]),
    );
  }
}

class _ServerCard extends StatefulWidget {
  const _ServerCard({required this.server, required this.onEdit, required this.onDelete, required this.onChanged});
  final ServerTarget server;
  final VoidCallback onEdit, onDelete;
  final Future<void> Function() onChanged;

  @override
  State<_ServerCard> createState() => _ServerCardState();
}

class _ServerCardState extends State<_ServerCard> {
  final logs = <String>[];
  String? busy;
  ServerTarget get s => widget.server;
  final ops = ServerOps.instance;

  Future<void> _run(String name, Future<String?> Function() fn) async {
    setState(() {
      busy = name;
      logs.clear();
    });
    try {
      final m = await fn();
      if (mounted && m != null) showSnack(context, m);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  void _log(String l) {
    if (!mounted) return;
    setState(() {
      logs.add(l);
      if (logs.length > 400) logs.removeAt(0);
    });
  }

  Widget _btn(String label, IconData icon, Future<String?> Function() fn, {bool primary = false}) {
    final child = busy == label ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon, size: 18);
    final on = busy != null ? null : () => _run(label, fn);
    return primary
        ? ElevatedButton.icon(style: primaryButtonStyle(), onPressed: on, icon: child, label: Text(label))
        : OutlinedButton.icon(style: outlineButtonStyle(), onPressed: on, icon: child, label: Text(label));
  }

  Future<String?> _restore() async {
    final list = await ops.listBackups(s);
    if (!mounted) return null;
    if (list.isEmpty) return tr('Belum ada backup di ~/backups');
    final f = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('Restore dari backup mana?')),
        children: [for (final x in list) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, x), child: Text(x))],
      ),
    );
    if (f == null || !mounted) return null;
    final ok = await confirmDialog(context,
        title: tr('Restore {0}?', [f]), message: tr('Data database sekarang akan ditimpa isi backup ini. Lakukan backup dulu kalau ragu.'), danger: true, ok: tr('Restore'));
    if (!ok) return null;
    return await ops.restore(s, f, _log) ? tr('Restore berhasil') : tr('Restore gagal — lihat log');
  }

  @override
  Widget build(BuildContext context) {
    final hc = s.healthy == null ? YmColors.outline : (s.healthy! ? YmColors.success : YmColors.danger);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: YmColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: YmColors.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.circle, size: 12, color: hc),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.name, style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700)),
              Text('${s.user}@${s.host}:${s.port} • ${s.workdir}', style: YmTextStyles.bodySm),
              if (s.lastHealth.isNotEmpty) Text(s.lastHealth, style: YmTextStyles.bodySm.copyWith(color: hc)),
            ]),
          ),
          IconButton(tooltip: tr('Edit'), onPressed: widget.onEdit, icon: const Icon(Icons.edit_outlined)),
          IconButton(tooltip: tr('Hapus'), onPressed: widget.onDelete, icon: const Icon(Icons.delete_outline_rounded)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _btn(tr('Tes SSH'), Icons.wifi_tethering_rounded, () => ops.test(s)),
          _btn(tr('Deploy sekarang'), Icons.rocket_launch_outlined, () async => await ops.deploy(s, _log) ? tr('Deploy berhasil') : tr('Deploy gagal — lihat log'), primary: true),
          _btn(tr('Backup sekarang'), Icons.backup_outlined, () async => tr('Backup: {0}', [await ops.backup(s, _log) ?? '-'])),
          _btn(tr('Restore'), Icons.settings_backup_restore_rounded, _restore),
          _btn(tr('Cek kesehatan'), Icons.monitor_heart_outlined, () async => await ops.healthCheck(s, log: _log, notifyOnFail: false) ? tr('Server sehat') : tr('Server bermasalah')),
          _btn(tr('1. Siapkan project di server'), Icons.cloud_download_outlined, () async {
            final v = await askFields(context, tr('Siapkan project di server'), [
              (tr('URL repo GitHub'), 'https://github.com/prakash/fjbbatam-api'),
            ], note: tr('Repo di-clone ke {0}. Untuk repo private, DeployHub memasang deploy key (read-only) di GitHub — token GitHub-mu tidak disimpan di server.', [s.workdir]));
            if (v == null) return null;
            return await setupProjectOnServer(s, v[0], _log) ? tr('Project siap di server — lanjut Deploy sekarang') : tr('Gagal — lihat log');
          }),
          _btn(tr('2. Domain & HTTPS'), Icons.lock_outline_rounded, () async {
            final v = await askFields(context, tr('Domain & HTTPS (Caddy)'), [
              (tr('Domain'), 'api.fjbbatam.com'),
              (tr('Port aplikasi di server'), '8000'),
              (tr('Email (untuk Let\'s Encrypt)'), 'admin@fjbbatam.com'),
            ], note: tr('Buat dulu record DNS A: domain → {0}. Sertifikat HTTPS dibuat & diperpanjang otomatis.', [s.host]));
            if (v == null) return null;
            final ok = await installHttps(s, v[0], int.tryParse(v[1]) ?? 8000, v[2], _log);
            await widget.onChanged();
            return ok ? tr('https://{0} aktif', [v[0].trim()]) : tr('Gagal — lihat log');
          }),
          _btn(tr('3. CD via GitHub Actions'), Icons.hub_outlined, () async {
            final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: tr('Pilih folder repo backend di PC'));
            if (dir == null) return null;
            final wf = await installServerCd(s, dir, _log);
            return tr('Dibuat {0} + 6 secret di GitHub. Commit & push → setiap push ke main otomatis deploy ke server.', [wf]);
          }),
          _btn(tr('Setup server (SSH)'), Icons.build_circle_outlined, () async {
            final ok = await confirmDialog(context,
                title: tr('Setup server {0}?', [s.name]),
                message: tr('Memasang Docker, firewall (22/80/443/3000), fail2ban, update keamanan otomatis, swap 2 GB dan zona waktu Asia/Jakarta. Aman dijalankan ulang.'));
            if (!ok) return null;
            return await Infra.instance.provisionSsh(s, _log) == 0 ? tr('Server siap') : tr('Setup gagal — lihat log');
          }),
          _btn(tr('Setup (Ansible)'), Icons.playlist_play_rounded, () async =>
              await Infra.instance.runAnsible([s], _log) == 0 ? tr('Playbook Ansible selesai') : tr('Ansible gagal — lihat log (butuh Docker di PC)')),
          _btn(s.monitoringOn ? tr('Pasang ulang monitoring') : tr('Pasang monitoring'), Icons.insights_rounded, () async {
            final pw = await Infra.instance.installMonitoring(s, _log);
            setState(() {});
            await widget.onChanged();
            launchUrl(Uri.parse(Infra.instance.grafanaUrl(s)));
            return tr('Grafana: {0} • user admin • password {1}', [Infra.instance.grafanaUrl(s), pw]);
          }),
          if (s.monitoringOn)
            _btn(tr('Buka Grafana'), Icons.open_in_new_rounded, () async {
              await launchUrl(Uri.parse(Infra.instance.grafanaUrl(s)));
              final pw = await Storage.secret('grafana_pw_${s.id}');
              return tr('user admin • password {0}', [pw]);
            }),
          _btn(tr('Skrip Python (Fabric)'), Icons.code_rounded, () async {
            final path = await FilePicker.platform.saveFile(
              dialogTitle: tr('Simpan skrip Python'),
              fileName: 'deploy_${s.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}.py',
            );
            if (path == null) return null;
            await File(path).writeAsString(ops.pythonScript(s));
            return tr('Disimpan: {0}', [path]);
          }),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 16, children: [
          _toggle(tr('Deploy otomatis saat commit baru'), s.autoDeploy, (v) => s.autoDeploy = v),
          _toggle(tr('Backup harian jam {0}:00', [s.backupHour]), s.backupDaily, (v) => s.backupDaily = v),
          _toggle(tr('Pantau kesehatan tiap {0} menit', [s.healthMinutes]), s.healthOn, (v) => s.healthOn = v),
          _toggle(tr('Self-healing (perbaiki sendiri)'), s.selfHeal, (v) => s.selfHeal = v),
          _toggle(tr('Rollback otomatis kalau deploy gagal'), s.autoRollback, (v) => s.autoRollback = v),
          _toggle(tr('AI diagnosis masalah server'), s.aiRemediate, (v) => s.aiRemediate = v),
          if (s.aiRemediate) _toggle(tr('AI boleh menjalankan perintah perbaikan'), s.aiRunCommands, (v) => s.aiRunCommands = v),
        ]),
        if (s.selfHeal)
          Text(
            tr('Self-healing: container mati → dinyalakan lagi • aplikasi tidak menjawab → restart • disk ≥ 90% → hapus image/cache/log lama. Data & volume tidak pernah dihapus. Perintah AI yang berbahaya selalu ditolak.'),
            style: YmTextStyles.bodySm,
          ),
        if (logs.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            constraints: const BoxConstraints(maxHeight: 220),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF0A0F1A), borderRadius: BorderRadius.circular(10)),
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(logs.join('\n'), style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: Color(0xFFD7DCE3))),
            ),
          ),
      ]),
    );
  }

  Widget _toggle(String label, bool v, void Function(bool) set) => Row(mainAxisSize: MainAxisSize.min, children: [
        Switch(
          value: v,
          onChanged: (x) {
            setState(() => set(x));
            widget.onChanged();
          },
        ),
        Text(label, style: YmTextStyles.bodySm),
      ]);
}

class _ServerEditor extends StatefulWidget {
  const _ServerEditor({this.server});
  final ServerTarget? server;

  @override
  State<_ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<_ServerEditor> {
  late final ServerTarget s = widget.server == null
      ? ServerTarget(id: DateTime.now().millisecondsSinceEpoch.toString())
      : ServerTarget.fromJson(widget.server!.toJson());
  late final c = <String, TextEditingController>{
    'name': TextEditingController(text: s.name),
    'host': TextEditingController(text: s.host),
    'port': TextEditingController(text: '${s.port}'),
    'user': TextEditingController(text: s.user),
    'key': TextEditingController(text: s.keyPath),
    'pw': TextEditingController(),
    'workdir': TextEditingController(text: s.workdir),
    'branch': TextEditingController(text: s.branch),
    'deploy': TextEditingController(text: s.deployCmd),
    'backup': TextEditingController(text: s.backupCmd),
    'restore': TextEditingController(text: s.restoreCmd),
    'health': TextEditingController(text: s.healthUrl),
    'hour': TextEditingController(text: '${s.backupHour}'),
    'keep': TextEditingController(text: '${s.backupKeepDays}'),
    'hmin': TextEditingController(text: '${s.healthMinutes}'),
  };
  final container = TextEditingController(text: 'mysql');

  @override
  void initState() {
    super.initState();
    Storage.secret(s.secretKey).then((v) => c['pw']!.text = v);
  }

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    container.dispose();
    super.dispose();
  }

  Future<void> _ok() async {
    String v(String k) => c[k]!.text.trim();
    if (v('host').isEmpty || v('name').isEmpty) {
      showSnack(context, tr('Nama dan host wajib diisi'), error: true);
      return;
    }
    s
      ..name = v('name')
      ..host = v('host')
      ..port = int.tryParse(v('port')) ?? 22
      ..user = v('user')
      ..keyPath = v('key')
      ..workdir = v('workdir')
      ..branch = v('branch').isEmpty ? 'main' : v('branch')
      ..deployCmd = v('deploy')
      ..backupCmd = v('backup')
      ..restoreCmd = v('restore')
      ..healthUrl = v('health')
      ..backupHour = (int.tryParse(v('hour')) ?? 2).clamp(0, 23).toInt()
      ..backupKeepDays = int.tryParse(v('keep')) ?? 7
      ..healthMinutes = int.tryParse(v('hmin')) ?? 5;
    await Storage.setSecret(s.secretKey, c['pw']!.text);
    if (mounted) Navigator.pop(context, s);
  }

  @override
  Widget build(BuildContext context) {
    return DhDialog(
      title: widget.server == null ? tr('Tambah server') : tr('Edit server'),
      subtitle: tr('VPS / cloud (AWS, GCP, DigitalOcean, dll.) yang bisa diakses lewat SSH'),
      icon: Icons.dns_outlined,
      width: 760,
      height: 720,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Batal'))),
        ElevatedButton(style: primaryButtonStyle(), onPressed: _ok, child: Text(tr('Simpan'))),
      ],
      child: ListView(children: [
        GroupLabel(tr('Koneksi SSH')),
        fieldRow([
          DhField(c['name']!, tr('Nama'), icon: Icons.label_outline, hint: 'VPS FJBBatam'),
          DhField(c['host']!, 'Host / IP', icon: Icons.public_rounded, hint: '103.xx.xx.xx'),
        ]),
        fieldRow([
          DhField(c['user']!, 'User', icon: Icons.person_outline_rounded),
          DhField(c['port']!, 'Port', icon: Icons.numbers_rounded, keyboard: TextInputType.number),
        ], flex: [3, 1]),
        Row(children: [
          Expanded(child: DhField(c['key']!, tr('File private key (opsional)'), icon: Icons.vpn_key_outlined, hint: r'C:\Users\...\.ssh\id_ed25519')),
          IconButton(
            onPressed: () async {
              final r = await FilePicker.platform.pickFiles(dialogTitle: tr('Pilih private key SSH'));
              final path = r?.files.single.path;
              if (path != null) setState(() => c['key']!.text = path);
            },
            icon: const Icon(Icons.folder_open_rounded),
          ),
        ]),
        DhField(c['pw']!, tr('Password SSH / passphrase key'), icon: Icons.lock_outline_rounded, obscure: true),
        GroupLabel(tr('Deploy')),
        fieldRow([
          DhField(c['workdir']!, tr('Folder project di server'), icon: Icons.folder_outlined, hint: '/opt/fjbbatam'),
          DhField(c['branch']!, 'Branch', icon: Icons.call_split_rounded),
        ], flex: [3, 1]),
        DhField(c['deploy']!, tr('Perintah deploy'), icon: Icons.terminal_rounded, maxLines: 2),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final t in {
            'Docker Compose': 'git pull origin {branch} && docker compose up -d --build && docker image prune -f',
            'systemd (Python)': 'git pull origin {branch} && pip install -r requirements.txt && sudo systemctl restart myapp',
            'PM2 (Node)': 'git pull origin {branch} && npm ci && pm2 reload all',
          }.entries)
            QuickChip(label: t.key, selected: c['deploy']!.text == t.value, onTap: () => setState(() => c['deploy']!.text = t.value)),
        ]),
        const SizedBox(height: 8),
        DhField(c['health']!, tr('URL health check (opsional)'), icon: Icons.monitor_heart_outlined, hint: 'https://api.fjbbatam.com/health'),
        GroupLabel(tr('Backup & restore database')),
        Row(children: [
          SizedBox(width: 200, child: DhField(container, tr('Nama container DB'), icon: Icons.inventory_2_outlined)),
          const SizedBox(width: 10),
          Expanded(
            child: Wrap(spacing: 8, runSpacing: 6, children: [
              for (final t in backupTemplates.entries)
                QuickChip(
                  label: t.key,
                  selected: false,
                  onTap: () => setState(() {
                    c['backup']!.text = t.value.$1.replaceAll('{container}', container.text.trim());
                    c['restore']!.text = t.value.$2.replaceAll('{container}', container.text.trim());
                  }),
                ),
            ]),
          ),
        ]),
        DhField(c['backup']!, tr('Perintah backup (hasil di ~/backups)'), icon: Icons.backup_outlined, maxLines: 2),
        DhField(c['restore']!, tr('Perintah restore ({file} = file backup)'), icon: Icons.settings_backup_restore_rounded, maxLines: 2),
        fieldRow([
          DhField(c['hour']!, tr('Jam backup harian (0-23)'), icon: Icons.schedule_rounded, keyboard: TextInputType.number),
          DhField(c['keep']!, tr('Simpan backup (hari)'), icon: Icons.history_rounded, keyboard: TextInputType.number),
          DhField(c['hmin']!, tr('Health check tiap (menit)'), icon: Icons.timer_outlined, keyboard: TextInputType.number),
        ]),
        CheckRow(
          label: tr('Salin backup ke PC ini'),
          sub: tr('Disaster recovery: backup juga disimpan di luar server (folder DeployHub/backups).'),
          value: s.downloadBackup,
          onChanged: (v) => setState(() => s.downloadBackup = v),
        ),
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: () => launchUrl(Uri.parse('https://docs.fabfile.org/en/latest/getting-started.html')),
          icon: const Icon(Icons.open_in_new_rounded, size: 16),
          label: Text(tr('Dokumentasi Fabric (Python) untuk skrip yang diekspor')),
        ),
      ]),
    );
  }
}

// ═════════════════════════════════════════════ Infrastructure as Code (Terraform)
class InfraPanel extends StatefulWidget {
  const InfraPanel({super.key});

  @override
  State<InfraPanel> createState() => _InfraPanelState();
}

class _InfraPanelState extends State<InfraPanel> {
  final infra = Infra.instance;
  final c = <String, TextEditingController>{
    Infra.kDoToken: TextEditingController(),
    Infra.kAwsKey: TextEditingController(),
    Infra.kAwsSecret: TextEditingController(),
    Infra.kGcpJson: TextEditingController(),
  };
  final logs = <String>[];
  String? busy;

  @override
  void initState() {
    super.initState();
    for (final k in c.keys) {
      Storage.secret(k).then((v) => c[k]!.text = v);
    }
  }

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  Future<void> _saveCreds() async {
    for (final e in c.entries) {
      await Storage.setSecret(e.key, e.value.text.trim());
    }
  }

  void _log(String l) {
    if (!mounted) return;
    setState(() {
      logs.add(l);
      if (logs.length > 600) logs.removeAt(0);
    });
  }

  Future<void> _run(String name, Future<String?> Function() fn) async {
    setState(() {
      busy = name;
      logs.clear();
    });
    try {
      await _saveCreds();
      final m = await fn();
      if (mounted && m != null) showSnack(context, m);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Widget _btn(String label, IconData icon, Future<String?> Function() fn, {bool primary = false, bool danger = false}) {
    final child = busy == label ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon, size: 18);
    final on = busy != null ? null : () => _run(label, fn);
    if (primary || danger) {
      return ElevatedButton.icon(style: primaryButtonStyle(color: danger ? YmColors.danger : null), onPressed: on, icon: child, label: Text(label));
    }
    return OutlinedButton.icon(style: outlineButtonStyle(), onPressed: on, icon: child, label: Text(label));
  }

  /// plan → tampilkan ringkasan → setujui → apply → daftarkan servernya.
  Future<String?> _create(InfraProject x) async {
    final code = await infra.plan(x, _log);
    if (code != 0) return tr('terraform plan gagal — lihat log');
    final summary = logs.lastWhere((l) => l.startsWith('Plan:') || l.contains('No changes'), orElse: () => '');
    if (!mounted) return null;
    final ok = await confirmDialog(context,
        title: tr('Terapkan perubahan infrastruktur?'),
        message: tr('{0}\n\nIni membuat / mengubah server sungguhan di {1} dan bisa dikenai biaya.', [summary, providerDefaults[x.provider]!.$4]),
        ok: tr('Apply'));
    if (!ok) return tr('Dibatalkan — tidak ada yang dibuat');
    if (await infra.apply(x, _log) != 0) return tr('terraform apply gagal — lihat log');
    final ip = await infra.outputIp(x);
    if (ip == null) return tr('Selesai, tapi IP tidak terbaca dari terraform output');
    final s = await infra.addAsServer(x, ip);
    return tr('Server {0} siap di {1} — sudah ditambahkan ke Server & infrastruktur (tunggu ±2 menit sampai cloud-init selesai).', [s.name, ip]);
  }

  Future<void> _newProject() async {
    final x = await showDialog<InfraProject>(context: context, builder: (_) => const _InfraEditor());
    if (x == null) return;
    infra.projects.add(x);
    await infra.save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: tr('Infrastructure as Code (Terraform)'),
      subtitle: tr('Buat VPS baru di DigitalOcean / AWS / Google Cloud dari kode: plan → setujui → apply. Server baru otomatis berisi Docker, firewall, fail2ban dan langsung masuk ke daftar server.'),
      icon: Icons.account_tree_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GroupLabel(tr('Kredensial cloud (disimpan aman di Credential Manager)')),
        fieldRow([
          DhField(c[Infra.kDoToken]!, 'DigitalOcean API token', icon: Icons.water_drop_outlined, obscure: true),
          DhField(c[Infra.kGcpJson]!, tr('GCP: path file JSON service account'), icon: Icons.cloud_outlined, hint: r'D:\keys\gcp.json'),
        ]),
        fieldRow([
          DhField(c[Infra.kAwsKey]!, 'AWS Access Key ID', icon: Icons.key_outlined),
          DhField(c[Infra.kAwsSecret]!, 'AWS Secret Access Key', icon: Icons.lock_outline_rounded, obscure: true),
        ]),
        const SizedBox(height: 6),
        for (final x in infra.projects)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: YmColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: YmColors.line)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(Icons.cloud_queue_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(x.name, style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700)),
                    Text('${providerDefaults[x.provider]?.$4 ?? x.provider} • ${x.region} • ${x.size}', style: YmTextStyles.bodySm),
                  ]),
                ),
                IconButton(
                  tooltip: tr('Hapus dari daftar'),
                  onPressed: () async {
                    final ok = await confirmDialog(context,
                        title: tr('Hapus {0} dari daftar?', [x.name]),
                        message: tr('Hanya dihapus dari DeployHub. Server di cloud TIDAK dihapus — gunakan tombol Destroy untuk itu.'));
                    if (!ok) return;
                    infra.projects.remove(x);
                    await infra.save();
                    setState(() {});
                  },
                  icon: const Icon(Icons.close_rounded),
                ),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _btn(tr('Plan (lihat rencana)'), Icons.preview_outlined, () async => await infra.plan(x, _log) == 0 ? tr('Plan selesai — lihat log') : tr('Plan gagal')),
                _btn(tr('Buat / perbarui server'), Icons.rocket_launch_outlined, () => _create(x), primary: true),
                _btn(tr('Buka folder .tf'), Icons.folder_open_rounded, () async {
                  await infra.writeTerraform(x);
                  await launchUrl(Uri.file(x.dir));
                  return null;
                }),
                _btn('Destroy', Icons.delete_forever_outlined, () async {
                  final ok = await confirmDialog(context,
                      title: tr('Hapus server {0} di cloud?', [x.name]),
                      message: tr('terraform destroy menghapus VPS beserta SEMUA datanya di cloud. Pastikan sudah backup.'),
                      danger: true,
                      ok: 'Destroy');
                  if (!ok) return null;
                  return await infra.destroy(x, _log) == 0 ? tr('Infrastruktur dihapus') : tr('Destroy gagal — lihat log');
                }, danger: true),
              ]),
            ]),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(style: outlineButtonStyle(), onPressed: _newProject, icon: const Icon(Icons.add_rounded), label: Text(tr('Infrastruktur baru'))),
        ),
        Text(
          tr('Butuh Terraform (Pengaturan → Alat di PC → Pasang Terraform). Ansible dijalankan lewat Docker dari kartu server.'),
          style: YmTextStyles.bodySm,
        ),
        if (logs.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            constraints: const BoxConstraints(maxHeight: 260),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF0A0F1A), borderRadius: BorderRadius.circular(10)),
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(logs.join('\n'), style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: Color(0xFFD7DCE3))),
            ),
          ),
      ]),
    );
  }
}

class _InfraEditor extends StatefulWidget {
  const _InfraEditor();

  @override
  State<_InfraEditor> createState() => _InfraEditorState();
}

class _InfraEditorState extends State<_InfraEditor> {
  String provider = 'digitalocean';
  final name = TextEditingController(text: 'vps-app');
  late final region = TextEditingController(text: providerDefaults[provider]!.$1);
  late final size = TextEditingController(text: providerDefaults[provider]!.$2);
  final gcp = TextEditingController();

  static const sizes = <String, List<String>>{
    'digitalocean': ['s-1vcpu-1gb', 's-1vcpu-2gb', 's-2vcpu-4gb', 's-4vcpu-8gb'],
    'aws': ['t3.micro', 't3.small', 't3.medium', 't3.large'],
    'gcp': ['e2-micro', 'e2-small', 'e2-medium', 'e2-standard-2'],
  };
  static const regions = <String, List<String>>{
    'digitalocean': ['sgp1', 'blr1', 'syd1', 'fra1', 'nyc3'],
    'aws': ['ap-southeast-1', 'ap-southeast-3', 'ap-southeast-2', 'us-east-1'],
    'gcp': ['asia-southeast2', 'asia-southeast1', 'us-central1'],
  };

  @override
  void dispose() {
    name.dispose();
    region.dispose();
    size.dispose();
    gcp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DhDialog(
      title: tr('Infrastruktur baru'),
      subtitle: tr('File Terraform dibuat otomatis — bisa diedit sendiri di folder .tf'),
      icon: Icons.account_tree_outlined,
      width: 640,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Batal'))),
        ElevatedButton(
          style: primaryButtonStyle(),
          onPressed: () {
            final n = name.text.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]+'), '-');
            if (n.isEmpty) return;
            Navigator.pop(
              context,
              InfraProject(
                id: '${n}_${DateTime.now().millisecondsSinceEpoch}',
                name: n,
                provider: provider,
                region: region.text.trim(),
                size: size.text.trim(),
                gcpProject: gcp.text.trim(),
                sshUser: providerDefaults[provider]!.$3,
              ),
            );
          },
          child: Text(tr('Buat')),
        ),
      ],
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, children: [
          for (final e in providerDefaults.entries)
            QuickChip(
              label: e.value.$4,
              selected: provider == e.key,
              onTap: () => setState(() {
                provider = e.key;
                region.text = e.value.$1;
                size.text = e.value.$2;
              }),
            ),
        ]),
        const SizedBox(height: 10),
        DhField(name, tr('Nama server'), icon: Icons.label_outline, hint: 'fjbbatam-api'),
        DhField(region, 'Region', icon: Icons.public_rounded),
        Wrap(spacing: 6, children: [for (final r in regions[provider]!) QuickChip(label: r, selected: region.text == r, onTap: () => setState(() => region.text = r))]),
        const SizedBox(height: 8),
        DhField(size, tr('Ukuran'), icon: Icons.memory_rounded),
        Wrap(spacing: 6, children: [for (final r in sizes[provider]!) QuickChip(label: r, selected: size.text == r, onTap: () => setState(() => size.text = r))]),
        if (provider == 'gcp') ...[const SizedBox(height: 8), DhField(gcp, 'GCP project ID', icon: Icons.folder_outlined)],
      ]),
    );
  }
}


/// Dialog isian sederhana: [(label, contoh)] → nilai yang diisi (null = batal).
Future<List<String>?> askFields(BuildContext context, String title, List<(String, String)> fields, {String? note}) async {
  final cs = [for (final _ in fields) TextEditingController()];
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (note != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(note, style: YmTextStyles.bodySm)),
          for (var i = 0; i < fields.length; i++) DhField(cs[i], fields[i].$1, hint: fields[i].$2),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Batal'))),
        ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Lanjut'))),
      ],
    ),
  );
  final v = [for (final c in cs) c.text.trim()];
  for (final c in cs) {
    c.dispose();
  }
  if (ok != true || v.any((x) => x.isEmpty)) return null;
  return v;
}
