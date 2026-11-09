import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/github_service.dart';
import '../services/storage.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../utils.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';

class GitHubScreen extends StatefulWidget {
  const GitHubScreen({super.key});

  @override
  State<GitHubScreen> createState() => _GitHubScreenState();
}

class _GitHubScreenState extends State<GitHubScreen> {
  String? projectId;
  bool loading = false;
  String? error;
  List<Map<String, dynamic>> workflows = [];
  List<Map<String, dynamic>> runs = [];

  Project? get project {
    for (final p in app.projects) {
      if (p.id == projectId) return p;
    }
    return null;
  }

  Future<GitHubService?> _svc() async {
    final token = await Storage.secret(Secrets.github);
    if (token.isEmpty) {
      setState(() => error = tr('Token GitHub belum diisi. Buka Pengaturan → Akun & Koneksi.'));
      return null;
    }
    return GitHubService(token);
  }

  Future<void> _load() async {
    final p = project;
    if (p == null) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final gh = await _svc();
      if (gh == null) return;
      final res = await Future.wait([gh.workflows(p.githubOwner, p.githubRepo), gh.runs(p.githubOwner, p.githubRepo)]);
      workflows = res[0];
      runs = res[1];
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _dispatch(Map<String, dynamic> wf) async {
    final p = project!;
    try {
      final gh = await _svc();
      if (gh == null) return;
      await gh.dispatch(p.githubOwner, p.githubRepo, (wf['id'] as num).toInt(), p.branch);
      if (mounted) showSnack(context, tr('Workflow "{0}" dijalankan di branch {1}', [wf['name'], p.branch]));
      await Future.delayed(const Duration(seconds: 3));
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, '$e — ${tr('pastikan workflow punya trigger workflow_dispatch')}', error: true);
    }
  }

  Widget _runChip(Map<String, dynamic> r) {
    if (r['status'] != 'completed') return SoftChip.primary(tr('Berjalan'), dot: YmColors.primary);
    return switch (r['conclusion']) {
      'success' => SoftChip.success(tr('Sukses'), icon: Icons.check_rounded),
      'cancelled' => SoftChip.warning(tr('Dibatalkan')),
      'skipped' => SoftChip.neutral(tr('Dilewati')),
      _ => SoftChip.danger(tr('Gagal'), icon: Icons.close_rounded),
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final withRepo = app.projects.where((p) => p.hasGithub).toList();
        if (projectId != null && !withRepo.any((p) => p.id == projectId)) projectId = null;
        projectId ??= withRepo.isEmpty ? null : withRepo.first.id;
        return PageBody(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PageHeader(
              crumbs: [appName, tr('Integrasi'), 'GitHub Actions'],
              title: 'GitHub Actions',
              subtitle: tr('Lihat run terbaru dan jalankan workflow repo proyek tanpa membuka browser.'),
              actions: [
                if (withRepo.isNotEmpty)
                  FilterDropdown<String>(
                    width: 260,
                    icon: Icons.folder_outlined,
                    value: projectId!,
                    items: [for (final p in withRepo) DropdownMenuItem(value: p.id, child: Text(p.name))],
                    onChanged: (v) {
                      setState(() => projectId = v);
                      _load();
                    },
                  ),
                OutlinedButton.icon(
                  style: outlineButtonStyle(),
                  onPressed: project == null || loading ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(tr('Muat ulang')),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (loading) const Padding(padding: EdgeInsets.only(bottom: 12), child: LinearProgressIndicator()),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Panel(
                  color: YmColors.dangerSoft,
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    Icon(Icons.error_outline_rounded, color: YmColors.danger),
                    const SizedBox(width: 10),
                    Expanded(child: Text(error!, style: YmTextStyles.chatText.copyWith(color: YmColors.onDangerSoft))),
                  ]),
                ),
              ),
            if (project == null)
              Panel(
                child: EmptyState(
                  icon: Icons.hub_outlined,
                  title: tr('Belum ada proyek dengan repo GitHub'),
                  message: tr('Isi owner dan nama repo di Edit Proyek. Kalau folder project berisi .git, terisi otomatis.'),
                ),
              )
            else
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 380,
                  child: Panel(
                    title: 'Workflow',
                    icon: Icons.account_tree_outlined,
                    subtitle: '${project!.githubOwner}/${project!.githubRepo}',
                    child: Column(children: [
                      if (workflows.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(loading ? '…' : tr('Klik "Muat ulang" untuk memuat workflow'), style: YmTextStyles.bodySm),
                        ),
                      for (final wf in workflows)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(children: [
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('${wf['name']}', style: YmTextStyles.username),
                                Text('${wf['path']}', style: YmTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ]),
                            ),
                            TextButton.icon(
                              style: softButtonStyle(),
                              onPressed: () => _dispatch(wf),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: Text(tr('Jalankan')),
                            ),
                          ]),
                        ),
                    ]),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Panel(
                    title: tr('Run terbaru'),
                    icon: Icons.history_rounded,
                    padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
                    child: Column(children: [
                      for (final r in runs)
                        HoverCard(
                          onTap: () => launchUrl(Uri.parse('${r['html_url']}')),
                          color: Colors.transparent,
                          hoverColor: YmColors.surfaceContainer,
                          baseShadowOverride: const [],
                          hoverShadowOverride: const [],
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Row(children: [
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('${r['display_title'] ?? r['name']}',
                                    style: YmTextStyles.username, maxLines: 1, overflow: TextOverflow.ellipsis),
                                Text(
                                  '${r['name']} • ${r['head_branch']} • ${r['event']} • '
                                  '${timeAgo(DateTime.tryParse('${r['created_at']}')?.toLocal() ?? DateTime.now())}',
                                  style: YmTextStyles.bodySm,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ]),
                            ),
                            _runChip(r),
                            const SizedBox(width: 8),
                            Icon(Icons.open_in_new_rounded, size: 16, color: YmColors.outline),
                          ]),
                        ),
                    ]),
                  ),
                ),
              ]),
          ]),
        );
      },
    );
  }
}
