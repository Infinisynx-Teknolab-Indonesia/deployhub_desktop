import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/i18n.dart';
import '../models.dart';
import '../services/github_service.dart';
import '../services/storage.dart';
import '../services/tool_env.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

/// Hubungkan folder project ke GitHub: pilih repo yang sudah ada ATAU buat repo baru.
/// Semua lewat GitHub API + git di PC — tidak perlu buka PowerShell.
class GitHubConnectPanel extends StatefulWidget {
  const GitHubConnectPanel({super.key, required this.root, required this.onConnected});
  final String root;
  final void Function(String owner, String repo) onConnected;

  @override
  State<GitHubConnectPanel> createState() => _GitHubConnectPanelState();
}

class _GitHubConnectPanelState extends State<GitHubConnectPanel> {
  String mode = 'existing'; // existing | new
  String token = '';
  String login = '';
  bool loading = true;
  String error = '';
  List<Map<String, dynamic>> repos = [];
  String filter = '';
  Map<String, dynamic>? picked;
  bool pushNow = true;
  bool busy = false;
  final logs = <String>[];

  late final newName = TextEditingController(text: _slug(p.basename(widget.root)));
  final newDesc = TextEditingController();
  bool newPrivate = true;

  static String _slug(String s) => s.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    newName.dispose();
    newDesc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = '';
    });
    token = await Storage.secret(Secrets.github);
    if (token.isEmpty) {
      setState(() {
        loading = false;
        error = tr('Token GitHub belum diisi. Buka Pengaturan → GitHub, isi Personal Access Token (izin: repo).');
      });
      return;
    }
    try {
      final gh = GitHubService(token);
      login = await gh.currentUser();
      repos = await gh.repos();
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  void _log(String l) => setState(() => logs.add(l));

  String get _git => app.settings.gitCmd.isEmpty ? 'git' : app.settings.gitCmd;

  /// Jalankan git di folder project. [auth] = sertakan token (hanya untuk perintah itu, tidak disimpan).
  Future<bool> _g(List<String> args, {bool auth = false, bool quiet = false}) async {
    final pre = <String>[
      '-c', 'user.name=$login',
      '-c', 'user.email=$login@users.noreply.github.com',
      if (auth) ...['-c', 'http.https://github.com/.extraheader=AUTHORIZATION: basic ${base64Encode(utf8.encode('x-access-token:$token'))}'],
    ];
    if (!quiet) _log('\$ git ${args.join(' ')}');
    try {
      final r = await Process.run(_git, [...pre, ...args],
          workingDirectory: widget.root, runInShell: true, environment: ToolEnv.env());
      final out = '${r.stdout}${r.stderr}'.trim();
      if (out.isNotEmpty && !quiet) _log(out.length > 600 ? '${out.substring(0, 600)}…' : out);
      return r.exitCode == 0;
    } catch (e) {
      _log('✖ $e');
      return false;
    }
  }

  Future<void> _ensureGitignore() async {
    final f = File(p.join(widget.root, '.gitignore'));
    final cur = await f.exists() ? await f.readAsString() : '';
    const must = ['android/key.properties', '*.jks', '*.keystore', '*.p8', '*.deployhub.bak', 'build/'];
    final add = must.where((x) => !cur.split('\n').map((l) => l.trim()).contains(x)).toList();
    if (add.isEmpty) return;
    await f.writeAsString('${cur.trimRight()}\n\n# DeployHub: rahasia tidak boleh ikut ke GitHub\n${add.join('\n')}\n');
    _log('✔ .gitignore: + ${add.join(', ')}');
  }

  /// Hubungkan ke repo (owner/repo). [push] = commit semua & push ke main.
  Future<void> _connect(String owner, String repo, {required bool push, required bool remoteEmpty}) async {
    final url = 'https://github.com/$owner/$repo.git';
    final hasGit = await Directory(p.join(widget.root, '.git')).exists();
    if (!hasGit && !await _g(['init'])) return _fail();
    await _ensureGitignore();
    final hasOrigin = await _g(['remote', 'get-url', 'origin'], quiet: true);
    if (!await _g(hasOrigin ? ['remote', 'set-url', 'origin', url] : ['remote', 'add', 'origin', url])) return _fail();
    if (push) {
      if (!remoteEmpty) {
        _log('ℹ ${tr('Repo sudah berisi kode — tidak di-push otomatis supaya tidak menimpa. Remote origin sudah dihubungkan; tarik dulu dengan git pull.')}');
      } else {
        await _g(['add', '-A']);
        await _g(['commit', '-m', 'Initial commit (DeployHub)']); // gagal kalau tidak ada perubahan — tidak masalah
        await _g(['branch', '-M', 'main']);
        if (!await _g(['push', '-u', 'origin', 'main'], auth: true)) return _fail();
      }
    } else {
      await _g(['fetch', 'origin'], auth: true);
    }
    _log('✔ ${tr('Terhubung ke {0}', ['$owner/$repo'])}');
    widget.onConnected(owner, repo);
  }

  void _fail() => _log('✖ ${tr('Gagal — lihat pesan git di atas.')}');

  Future<void> _useExisting() async {
    final r = picked;
    if (r == null) return;
    setState(() => busy = true);
    final full = '${r['full_name']}'.split('/');
    final empty = (r['size'] ?? 0) == 0;
    await _connect(full[0], full[1], push: pushNow, remoteEmpty: empty);
    if (mounted) setState(() => busy = false);
  }

  Future<void> _createNew() async {
    final name = _slug(newName.text);
    if (name.isEmpty) return;
    setState(() => busy = true);
    try {
      _log(tr('Membuat repo {0}/{1} ({2})…', [login, name, newPrivate ? 'private' : 'public']));
      final r = await GitHubService(token).createRepo(name, private: newPrivate, description: newDesc.text.trim());
      _log('✔ ${r['html_url']}');
      final full = '${r['full_name']}'.split('/');
      await _connect(full[0], full[1], push: true, remoteEmpty: true);
    } catch (e) {
      _log('✖ $e');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator());
    if (error.isNotEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: YmColors.warningSoft, borderRadius: BorderRadius.circular(10)),
          child: Text(error, style: YmTextStyles.bodySm.copyWith(color: YmColors.onWarningSoft)),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr('Coba lagi'))),
        ),
      ]);
    }
    final shown = repos.where((r) => filter.isEmpty || '${r['full_name']}'.toLowerCase().contains(filter.toLowerCase())).take(60).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Masuk sebagai {0} • {1} repo', [login, repos.length]), style: YmTextStyles.bodySm),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        QuickChip(label: tr('Pilih repo yang sudah ada'), icon: Icons.list_alt_rounded, selected: mode == 'existing', onTap: () => setState(() => mode = 'existing')),
        QuickChip(label: tr('Buat repo baru'), icon: Icons.add_rounded, selected: mode == 'new', onTap: () => setState(() => mode = 'new')),
      ]),
      const SizedBox(height: 12),
      if (mode == 'existing') ...[
        TextField(
          decoration: fieldDecoration(tr('Cari repo'), icon: Icons.search_rounded),
          onChanged: (v) => setState(() => filter = v),
        ),
        const SizedBox(height: 8),
        Container(
          height: 220,
          decoration: BoxDecoration(border: Border.all(color: YmColors.line), borderRadius: BorderRadius.circular(10)),
          child: ListView(children: [
            for (final r in shown)
              ListTile(
                dense: true,
                selected: picked?['full_name'] == r['full_name'],
                selectedTileColor: YmColors.primarySoft,
                leading: Icon(r['private'] == true ? Icons.lock_outline_rounded : Icons.public_rounded, size: 18),
                title: Text('${r['full_name']}', style: YmTextStyles.labelLg),
                subtitle: Text(
                  [
                    if ((r['size'] ?? 0) == 0) tr('kosong'),
                    if ('${r['description'] ?? ''}'.isNotEmpty) '${r['description']}',
                    '${r['default_branch'] ?? ''}',
                  ].join(' • '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => setState(() => picked = r),
              ),
            if (shown.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('Tidak ada repo yang cocok.'))),
          ]),
        ),
        CheckRow(
          label: tr('Push kode ke repo ini sekarang (hanya kalau repo masih kosong)'),
          sub: tr('Repo yang sudah berisi kode hanya dihubungkan (remote origin), tidak ditimpa.'),
          value: pushNow,
          onChanged: (v) => setState(() => pushNow = v),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            style: primaryButtonStyle(),
            onPressed: picked == null || busy ? null : _useExisting,
            icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.link_rounded),
            label: Text(picked == null ? tr('Pilih repo dulu') : tr('Hubungkan ke {0}', ['${picked!['full_name']}'])),
          ),
        ),
      ] else ...[
        fieldRow([
          DhField(newName, tr('Nama repo'), icon: Icons.drive_file_rename_outline_rounded, hint: 'aplikasichat'),
          DhField(newDesc, tr('Deskripsi (opsional)'), icon: Icons.notes_rounded),
        ]),
        CheckRow(
          label: tr('Private (disarankan)'),
          sub: tr('Hanya kamu dan orang yang diundang yang bisa melihat kode.'),
          value: newPrivate,
          onChanged: (v) => setState(() => newPrivate = v),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            style: primaryButtonStyle(),
            onPressed: busy ? null : _createNew,
            icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.rocket_launch_rounded),
            label: Text(tr('Buat repo & push kode')),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            tr('DeployHub membuat repo di GitHub, menambahkan key.properties / *.jks ke .gitignore, git init, commit, lalu push ke branch main.'),
            style: YmTextStyles.bodySm,
          ),
        ),
      ],
      if (logs.isNotEmpty) ...[
        const SizedBox(height: 10),
        Container(
          constraints: const BoxConstraints(maxHeight: 160),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFF0A0F1A), borderRadius: BorderRadius.circular(10)),
          child: SingleChildScrollView(
            reverse: true,
            child: SelectableText(logs.join('\n'),
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.4, color: Color(0xFFD7DCE3))),
          ),
        ),
      ],
    ]);
  }
}
