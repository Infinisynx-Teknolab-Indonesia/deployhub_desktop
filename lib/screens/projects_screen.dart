import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/play_auth.dart';
import '../services/android_pipeline.dart';
import '../services/ios_pipeline.dart';
import '../services/play_console_tasks.dart';
import '../services/project_doctor.dart';
import '../services/store_metadata.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../utils.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';
import 'deploy_dialogs.dart';
import 'journey_dialog.dart';
import 'legal_dialog.dart';
import 'play_console_dialog.dart';
import 'project_editor.dart';
import 'quick_upload_dialog.dart';
import 'ready_builds_panel.dart';
import 'rollout_dialog.dart';
import 'hub_panel.dart';
import '../services/hub_client.dart';
import '../services/devops_setup.dart';
import 'release_check_dialog.dart';

class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({super.key});

  static Future<void> addProject(BuildContext context) async {
    final p = await showDialog<Project>(
      context: context,
      builder: (_) => ProjectEditor(project: Project(id: DateTime.now().millisecondsSinceEpoch.toString())),
    );
    if (p != null) await app.upsertProject(p);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => PageBody(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(
            crumbs: [appName, tr('Proyek')],
            title: tr('Proyek'),
            subtitle: tr('Build & deploy ke Google Play dan TestFlight langsung dari PC. Klik ⋮ untuk checklist Play Console dan template listing.'),
            actions: [
              OutlinedButton.icon(
                style: outlineButtonStyle(),
                onPressed: app.isRunning ? null : () => openBuildOnly(context),
                icon: const Icon(Icons.inventory_2_outlined),
                label: Text(tr('Buat AAB / IPA')),
              ),
              OutlinedButton.icon(
                style: outlineButtonStyle(),
                onPressed: app.isRunning ? null : () => openQuickUpload(context),
                icon: const Icon(Icons.upload_file_rounded),
                label: Text(tr('Upload file AAB / IPA')),
              ),
              ElevatedButton.icon(
                style: primaryButtonStyle(),
                onPressed: () => addProject(context),
                icon: const Icon(Icons.add_rounded),
                label: Text(tr('Tambah proyek')),
              ),
            ],
          ),
          const SizedBox(height: 24),
          PlayConnectBanner(ready: PlayAuth.globalReady()),
          if (app.projects.isEmpty)
            Panel(
              child: EmptyState(
                icon: Icons.folder_copy_outlined,
                title: tr('Belum ada proyek'),
                message: tr('Tambahkan project Flutter kamu, mis. Batam ChitChat. Nama, package, dan repo GitHub terisi otomatis dari folder project. Setelah itu kamu bisa langsung "Buat AAB" (tanpa upload) atau "Deploy ke Play Store".'),
                action: ElevatedButton.icon(
                  style: primaryButtonStyle(),
                  onPressed: () => addProject(context),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(tr('Tambah proyek')),
                ),
              ),
            )
          else
            LayoutBuilder(builder: (context, c) {
              final cols = c.maxWidth > 1300 ? 3 : (c.maxWidth > 820 ? 2 : 1);
              final w = (c.maxWidth - 18 * (cols - 1)) / cols;
              return Wrap(spacing: 18, runSpacing: 18, children: [
                for (var i = 0; i < app.projects.length; i++)
                  SizedBox(width: w, child: Reveal(index: i, child: _ProjectCard(project: app.projects[i]))),
              ]);
            }),
        ]),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project});
  final Project project;

  Future<void> _edit(BuildContext context) async {
    final p = await showDialog<Project>(
        context: context, builder: (_) => ProjectEditor(project: Project.fromJson(project.toJson())));
    if (p != null) await app.upsertProject(p);
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await confirmDialog(context,
        title: tr('Hapus proyek?'),
        message: tr('"{0}" akan dihapus dari DeployHub. File project di PC tidak ikut terhapus.', [project.name]),
        ok: tr('Hapus'),
        danger: true);
    if (ok) await app.deleteProject(project.id);
  }

  /// Periksa & perbaiki keystore, key.properties, local.properties, pubspec, Gradle, manifest.
  Future<void> _doctor(BuildContext context) async {
    showSnack(context, tr('Memeriksa file project...'));
    final res = await projectDoctor(project.localPath,
        packageName: project.packageName,
        projectId: project.id,
        projectName: project.name,
        flutterCmd: app.settings.flutterCmd,
        keytool: app.settings.keytoolCmd);
    if (!context.mounted) return;
    Widget line(IconData i, Color c, String t) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 18, color: c),
            const SizedBox(width: 8),
            Expanded(child: SelectableText(t, style: YmTextStyles.bodySm.copyWith(color: YmColors.textDark))),
          ]),
        );
    await showDialog(
      context: context,
      builder: (ctx) => DhDialog(
        title: tr('Periksa & perbaiki file project'),
        subtitle: project.localPath,
        icon: Icons.healing_rounded,
        width: 760,
        actions: [ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(ctx), child: Text(tr('Tutup')))],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(tr('Yang dicek: keystore & key.properties (path, password, alias), local.properties (path Flutter & Android SDK), pubspec.yaml (versi, aset), build.gradle (import, applicationId, signing), AndroidManifest (INTERNET, AdMob), google-services.json, .gitignore. File yang diubah dibackup ke *.deployhub.bak.'),
              style: YmTextStyles.bodySm),
          const SizedBox(height: 12),
          if (res.fixed.isEmpty && res.warnings.isEmpty) line(Icons.verified_rounded, YmColors.success, tr('Semua file sudah benar.')),
          for (final m in res.fixed) line(Icons.build_circle_rounded, YmColors.primary, m),
          for (final w in res.warnings) line(Icons.warning_amber_rounded, YmColors.warning, w),
          if (res.ok.isNotEmpty) line(Icons.check_circle_rounded, YmColors.success, '${tr('Sudah benar')}: ${res.ok.join(', ')}'),
        ]),
      ),
    );
  }

  Future<void> _storeTemplate(BuildContext context) async {
    try {
      final created = await createStoreTemplate(project);
      if (!context.mounted) return;
      showSnack(context,
          created.isEmpty ? tr('Folder store/ sudah lengkap') : tr('Dibuat {0} file di {1}', [created.length, storeDir(project)]));
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  Future<void> _deployAndroid(BuildContext context, {bool buildOnly = false}) async {
    final o = await showDialog<AndroidOptions>(
        context: context, builder: (_) => AndroidDeployDialog(project: project, buildOnly: buildOnly));
    if (o == null) return;
    await app.startAndroid(project, o);
    nav.value = 'pipeline';
  }

  Future<void> _deployIos(BuildContext context, {bool buildOnly = false}) async {
    if (!project.hasIos) {
      final ok = await confirmDialog(context,
          title: tr('iOS belum diatur'),
          message: tr('Untuk deploy ke App Store, aktifkan "Rilis juga ke iPhone" dan isi folder project di MacBook + Bundle ID di Edit Proyek. Akun App Store Connect & MacBook diatur di Pengaturan.'),
          ok: tr('Atur sekarang'));
      if (ok && context.mounted) await _edit(context);
      return;
    }
    final o = await showDialog<IosOptions>(
        context: context, builder: (_) => IosDeployDialog(project: project, buildOnly: buildOnly));
    if (o == null) return;
    await app.startIos(project, o);
    nav.value = 'pipeline';
  }

  /// Jalankan penyiapan DevOps (file dibackup) lalu tampilkan apa yang berubah.
  Future<void> _setup(BuildContext context, String title, Future<SetupResult> Function() fn) async {
    final ok = await confirmDialog(context,
        title: tr('{0} — ubah file proyek?', [title]),
        message: tr('File di {0} akan ditambah / diubah. File lama dibackup ke *.deployhub.bak. Commit ke Git sesudahnya.', [project.localPath]));
    if (!ok || !context.mounted) return;
    SetupResult r;
    try {
      r = await fn();
    } catch (e) {
      r = SetupResult()..error = '$e';
    }
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r.ok ? tr('{0} siap', [title]) : tr('{0} gagal', [title])),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!r.ok) Text('✖ ${r.error}', style: TextStyle(color: YmColors.danger)),
              for (final c in r.changes) Text('✔ $c', style: YmTextStyles.bodySm.copyWith(color: YmColors.success)),
              const SizedBox(height: 6),
              for (final n in r.notes) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('ℹ $n', style: YmTextStyles.bodySm)),
            ]),
          ),
        ),
        actions: [ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(ctx), child: Text(tr('Tutup')))],
      ),
    );
  }

  Future<void> _envs(BuildContext context) async {
    final c = {
      'dev': TextEditingController(text: 'http://10.0.2.2:8000'),
      'staging': TextEditingController(),
      'prod': TextEditingController(),
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Lingkungan dev / staging / prod')),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('URL server API untuk tiap lingkungan. dev = server di PC (10.0.2.2 = localhost dari emulator Android), staging = server uji, prod = server pengguna asli.'),
                style: YmTextStyles.bodySm),
            const SizedBox(height: 10),
            DhField(c['dev']!, 'dev', icon: Icons.computer_rounded),
            DhField(c['staging']!, 'staging', icon: Icons.science_outlined, hint: 'https://staging-api.batamchitchat.com'),
            DhField(c['prod']!, 'prod', icon: Icons.public_rounded, hint: 'https://api.batamchitchat.com'),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Batal'))),
          ElevatedButton(style: primaryButtonStyle(), onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Buat'))),
        ],
      ),
    );
    final urls = {for (final e in c.entries) if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim()};
    for (final x in c.values) {
      x.dispose();
    }
    if (ok != true || urls.isEmpty || !context.mounted) return;
    await _setup(context, tr('Lingkungan dev / staging / prod'), () => setupEnvironments(project.localPath, urls));
  }

  Widget _info(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          Icon(icon, size: 15, color: YmColors.outline),
          const SizedBox(width: 8),
          Expanded(child: Text(text.isEmpty ? '—' : text, maxLines: 1, overflow: TextOverflow.ellipsis, style: YmTextStyles.bodySm)),
        ]),
      );

  Widget _lastRun(String label, IconData icon, RunRecord? r) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Icon(r == null ? icon : statusIcon(r.status), size: 18, color: r == null ? YmColors.outline : statusColor(r.status)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: YmTextStyles.labelSm),
                Text(r == null ? tr('belum pernah') : '${r.version} • ${timeAgo(r.finishedAt)}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: YmTextStyles.labelMd),
              ]),
            ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final busy = app.isRunning;
    final ct = ClosedTestStatus(project);
    final done = project.consoleDone.length;
    final total = consoleTasks(project).length;
    return HoverCard(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: YmColors.primaryFixed, borderRadius: BorderRadius.circular(12)),
            alignment: Alignment.center,
            child: Text(project.name.isEmpty ? '?' : project.name[0].toUpperCase(),
                style: YmTextStyles.headlineMd.copyWith(color: YmColors.onPrimaryFixed)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(project.name, style: YmTextStyles.headlineSm, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(project.packageName.isEmpty ? tr('package belum diisi') : project.packageName,
                  style: YmTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          PopupMenuButton<String>(
            tooltip: tr('Menu'),
            onSelected: (v) => switch (v) {
              'edit' => _edit(context),
              'check' => showDialog(context: context, builder: (_) => ReleaseCheckDialog(project: project)),
              'journey' => showDialog(context: context, builder: (_) => JourneyDialog(projectId: project.id)),
              'upload' => openQuickUpload(context, project: project),
              'console' => showDialog(context: context, builder: (_) => PlayConsoleDialog(project: project)),
              'legal' => showDialog(context: context, builder: (_) => LegalPagesDialog(project: project)),
              'rollout' => showDialog(context: context, builder: (_) => RolloutDialog(project: project)),
              'envs' => _envs(context),
              'tests' => _setup(context, tr('Test dasar'), () => createBasicTests(project.localPath)),
              'crashlytics' => _setup(context, 'Firebase Crashlytics', () => setupCrashlytics(project.localPath, app.settings.flutterCmd, (_) {})),
              'store' => _storeTemplate(context),
              'doctor' => _doctor(context),
              _ => _delete(context),
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'edit', child: Text(tr('Edit proyek'))),
              PopupMenuItem(value: 'doctor', child: Text(tr('Periksa & perbaiki file project'))),
              PopupMenuItem(value: 'upload', child: Text(tr('Upload file AAB / IPA langsung'))),
              PopupMenuItem(value: 'journey', child: Text(tr('Perjalanan rilis'))),
              PopupMenuItem(value: 'check', child: Text(tr('Cek kelayakan rilis'))),
              PopupMenuItem(value: 'console', child: Text(tr('Checklist Play Console'))),
              PopupMenuItem(value: 'legal', child: Text(tr('Buat kebijakan privasi & halaman wajib'))),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'rollout', child: Text(tr('Rollout & crash (Google Play)'))),
              PopupMenuItem(value: 'envs', child: Text(tr('Siapkan dev / staging / prod'))),
              PopupMenuItem(value: 'tests', child: Text(tr('Buat test dasar + coverage'))),
              PopupMenuItem(value: 'crashlytics', child: Text(tr('Pasang Crashlytics (laporan crash)'))),
              PopupMenuItem(value: 'store', child: Text(tr('Buat template store/'))),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'delete', child: Text(tr('Hapus'), style: TextStyle(color: YmColors.danger))),
            ],
          ),
        ]),
        const SizedBox(height: 14),
        _info(Icons.folder_outlined, project.localPath),
        _info(
            Icons.hub_outlined,
            !project.useGithub
                ? tr('Tanpa GitHub')
                : (project.hasGithub ? '${project.githubOwner}/${project.githubRepo} (${project.branch})' : tr('GitHub belum diatur'))),
        _info(Icons.laptop_mac_rounded,
            !project.useIos ? tr('Hanya Android') : (project.hasIos ? project.macProjectPath : tr('iOS belum diatur'))),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (project.isSocialApp) SoftChip.primary(tr('Chat / sosial'), icon: Icons.forum_outlined),
          if (project.alreadyLive)
            SoftChip.success(tr('Sudah live di Play Store'), icon: Icons.rocket_launch_outlined)
          else
            done >= total
                ? SoftChip.success('Play Console $done/$total', icon: Icons.checklist_rounded)
                : SoftChip.warning('Play Console $done/$total', icon: Icons.checklist_rounded),
          if (project.isPersonalAccount && !project.alreadyLive)
            ct.ready
                ? SoftChip.success(tr('Pengujian tertutup selesai'), icon: Icons.groups_outlined)
                : SoftChip.neutral(
                    ct.started ? tr('Pengujian: hari {0}/14', [ct.days]) : tr('Pengujian belum mulai'),
                    icon: Icons.groups_outlined),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          _lastRun('Android', Icons.android_rounded, app.lastRun(project.id, 'android')),
          const SizedBox(width: 8),
          _lastRun('iOS', Icons.apple, app.lastRun(project.id, 'ios')),
        ]),
        ReadyBuildsPanel(key: ValueKey('ready-${project.id}'), project: project),
        if (Hub.instance.ready && Hub.instance.cfg(project.id).syncedAt.isNotEmpty)
          HubProjectSection(key: ValueKey('hub-${project.id}'), project: project),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: _DeployButton(
              icon: Icons.shop_rounded,
              title: tr('Deploy ke Play Store'),
              sub: 'Android • AAB',
              color: const Color(0xFF0F9D58),
              onTap: busy ? null : () => _deployAndroid(context),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _DeployButton(
              icon: Icons.apple,
              title: tr('Deploy ke App Store'),
              sub: project.hasIos ? 'iOS • TestFlight / App Store' : tr('iOS belum diatur'),
              color: YmColors.isDark ? const Color(0xFF3A3F4B) : const Color(0xFF111318),
              onTap: busy ? null : () => _deployIos(context),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              style: outlineButtonStyle(),
              onPressed: busy ? null : () => _deployAndroid(context, buildOnly: true),
              icon: const Icon(Icons.inventory_2_outlined, size: 18),
              label: Text(tr('Buat AAB saja (tanpa upload)')),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              style: outlineButtonStyle(),
              onPressed: busy || !project.hasIos ? null : () => _deployIos(context, buildOnly: true),
              icon: const Icon(Icons.phone_iphone_rounded, size: 18),
              label: Text(tr('Buat IPA saja (tanpa upload)')),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextButton.icon(
              onPressed: () => showDialog(context: context, builder: (_) => JourneyDialog(projectId: project.id)),
              icon: const Icon(Icons.route_outlined, size: 18),
              label: Text(tr('Perjalanan rilis')),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: () => showDialog(context: context, builder: (_) => ReleaseCheckDialog(project: project)),
              icon: const Icon(Icons.fact_check_outlined, size: 18),
              label: Text(tr('Cek kelayakan rilis')),
            ),
          ),
        ]),
      ]),
    );
  }
}


/// Tombol deploy besar: ikon toko + judul + keterangan platform.
class _DeployButton extends StatefulWidget {
  const _DeployButton({required this.icon, required this.title, required this.sub, required this.color, this.onTap});
  final IconData icon;
  final String title;
  final String sub;
  final Color color;
  final VoidCallback? onTap;

  @override
  State<_DeployButton> createState() => _DeployButtonState();
}

class _DeployButtonState extends State<_DeployButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final enabled = w.onTap != null;
    final bg = enabled ? (_hover ? Color.lerp(w.color, Colors.white, 0.12)! : w.color) : YmColors.surfaceContainer;
    final fg = enabled ? Colors.white : YmColors.outline;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: w.onTap,
        child: AnimatedContainer(
          duration: motion(context, const Duration(milliseconds: 150)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            boxShadow: enabled ? shadowSm : null,
          ),
          child: Row(children: [
            Icon(w.icon, color: fg, size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(w.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: YmTextStyles.labelLg.copyWith(color: fg, fontWeight: FontWeight.w700)),
                Text(w.sub, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: YmTextStyles.labelSm.copyWith(color: fg.withOpacity(0.8))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}


/// Build file AAB / IPA saja (tanpa upload). Kalau belum ada proyek, tambah dulu.
Future<void> openBuildOnly(BuildContext context) async {
  Project? pr;
  if (app.projects.isEmpty) {
    final ok = await confirmDialog(context,
        title: tr('Tambah proyek dulu'),
        message: tr('Untuk membuat AAB, DeployHub perlu tahu folder project Flutter-nya. Pilih foldernya sekali (nama, package, signing terdeteksi otomatis), lalu file AAB langsung dibuat.'),
        ok: tr('Pilih folder project'));
    if (!ok || !context.mounted) return;
    final p = await showDialog<Project>(
      context: context,
      builder: (_) => ProjectEditor(project: Project(id: DateTime.now().millisecondsSinceEpoch.toString())),
    );
    if (p == null || !context.mounted) return;
    await app.upsertProject(p);
    if (app.isRunning) return; // "Simpan & buat AAB" di editor sudah menjalankan build
    pr = p;
  }
  if (!context.mounted) return;
  final choice = await showDialog<(Project, bool)>(context: context, builder: (_) => _BuildPicker(initial: pr));
  if (choice == null || !context.mounted) return;
  final (project, ios) = choice;
  if (ios) {
    final o = await showDialog<IosOptions>(context: context, builder: (_) => IosDeployDialog(project: project, buildOnly: true));
    if (o == null) return;
    await app.startIos(project, o);
  } else {
    final o = await showDialog<AndroidOptions>(context: context, builder: (_) => AndroidDeployDialog(project: project, buildOnly: true));
    if (o == null) return;
    await app.startAndroid(project, o);
  }
  nav.value = 'pipeline';
}

class _BuildPicker extends StatefulWidget {
  const _BuildPicker({this.initial});
  final Project? initial;

  @override
  State<_BuildPicker> createState() => _BuildPickerState();
}

class _BuildPickerState extends State<_BuildPicker> {
  late Project project = widget.initial ?? app.projects.first;

  Widget _card(IconData icon, String title, String sub, bool ios, {bool enabled = true}) => Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? () => Navigator.pop(context, (project, ios)) : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: YmColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: YmColors.line),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icon, size: 28, color: YmColors.primary),
                const SizedBox(height: 8),
                Text(title, style: YmTextStyles.headlineSm),
                const SizedBox(height: 4),
                Text(sub, style: YmTextStyles.bodySm),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return DhDialog(
      title: tr('Buat file AAB / IPA'),
      subtitle: tr('Hanya build, tidak ada yang diupload'),
      icon: Icons.inventory_2_outlined,
      width: 620,
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Batal')))],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DropdownButtonFormField<String>(
          value: project.id,
          isExpanded: true,
          decoration: fieldDecoration(tr('Proyek')),
          items: [for (final p in app.projects) DropdownMenuItem(value: p.id, child: Text('${p.name}  •  ${p.localPath}', overflow: TextOverflow.ellipsis))],
          onChanged: (id) => setState(() => project = app.projects.firstWhere((p) => p.id == id)),
        ),
        const SizedBox(height: 16),
        Row(children: [
          _card(Icons.android_rounded, tr('File AAB (Android)'),
              tr('Dibuat di PC ini. Hasil: build/app/outputs/bundle/release/app-release.aab + laporan AAB.'), false),
          const SizedBox(width: 12),
          _card(Icons.apple, tr('File IPA (iPhone)'),
              project.hasIos ? tr('Dibuat di MacBook lewat SSH, lalu disalin ke PC.') : tr('iOS belum diatur di Edit proyek (folder MacBook + Bundle ID).'),
              true,
              enabled: project.hasIos),
        ]),
        const SizedBox(height: 12),
        Text(tr('Setelah file jadi, upload kapan saja lewat "Upload file AAB / IPA".'), style: YmTextStyles.bodySm),
      ]),
    );
  }
}
