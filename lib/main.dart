import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'core/i18n.dart';
import 'screens/dashboard_screen.dart';
import 'screens/github_screen.dart';
import 'screens/history_screen.dart';
import 'screens/pipeline_screen.dart';
import 'screens/projects_screen.dart';
import 'screens/settings_screen.dart';
import 'services/play_auth.dart';
import 'services/storage.dart';
import 'services/ai_fixer.dart';
import 'services/infra.dart';
import 'services/ready_builds.dart';
import 'services/hub_client.dart';
import 'services/integrations.dart';
import 'services/server_ops.dart';
import 'services/tool_env.dart';
import 'services/tray_service.dart';
import 'services/window_ctl.dart';
import 'state.dart';
import 'theme/dh_theme.dart';
import 'widgets/app_title_bar.dart';
import 'widgets/dh_widgets.dart';
import 'widgets/ui.dart';

/// Untuk dialog yang dibuka dari menu tray (di luar widget tree).
final appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  WindowCtl.init(); // status full screen selalu sesuai kondisi jendela
  await Storage.init();
  await ToolEnv.init(); // PATH alat (Homebrew/Flutter di macOS, Node.js di drive lain di Windows)
  await ThemeCtl.instance.load();
  await app.load();
  await Integrations.instance.load();
  await AiFixer.instance.load();
  await ServerOps.instance.load();
  await Infra.instance.load();
  await ReadyBuilds.instance.load();
  await Hub.instance.load();
  ServerOps.instance.restart(); // health check / backup / deploy server terjadwal (kalau diaktifkan)
  app.restartAutoTrigger(); // pipeline otomatis saat ada commit baru (kalau diaktifkan)
  app.startServerSync(); // sinkron riwayat deploy PC ↔ DeployHub Server (kalau server diaktifkan)

  final options = WindowOptions(
    size: WindowCtl.defaultSize,
    minimumSize: const Size(1100, 680),
    center: true,
    title: ThemeCtl.instance.appName,
    backgroundColor: YmColors.paper,
    // Title bar bawaan Windows disembunyikan, diganti AppTitleBar (sama seperti Arsip PU)
    titleBarStyle: TitleBarStyle.hidden,
    skipTaskbar: false,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
    await WindowCtl.enterFullScreen(); // mulai full screen, seperti Arsip PU
  });

  // System tray: klik kiri = buka, klik kanan = menu. Tombol X = sembunyikan ke tray.
  await TrayService.init(
    onExitRequested: _requestExit,
    onOpenPage: (page) => nav.value = page,
  );
  app.addListener(_syncTrayTooltip);
  // bahasa / nama aplikasi diganti -> menu tray, tooltip, dan judul jendela ikut
  ThemeCtl.instance.addListener(() {
    TrayService.refreshMenu();
    _lastTip = '';
    _syncTrayTooltip();
    windowManager.setTitle(ThemeCtl.instance.appName);
  });
  runApp(const DeployHubApp());
}

String _lastTip = '';
void _syncTrayTooltip() {
  final name = ThemeCtl.instance.appName;
  final tip = app.isRunning ? '$name — ${trL('Deploy {0} berjalan', [app.currentRun!.project.name])}' : name;
  if (tip == _lastTip) return;
  _lastTip = tip;
  TrayService.setTooltip(tip);
}

/// "Keluar" dari tray: kalau pipeline masih jalan, tanya dulu.
Future<void> _requestExit() async {
  final ctx = appNavigatorKey.currentContext;
  if (!app.isRunning || ctx == null) return TrayService.quit();
  await WindowCtl.show();
  final ok = await confirmDialog(ctx,
      title: trL('Keluar dari {0}?', [ThemeCtl.instance.appName]),
      message: trL('Pipeline "{0}" masih berjalan dan akan dihentikan. Tutup jendela saja (tombol X) kalau ingin tetap berjalan di tray.',
          [app.currentRun!.project.name]),
      ok: trL('Keluar'),
      danger: true);
  if (ok) await TrayService.quit();
}

class DeployHubApp extends StatelessWidget {
  const DeployHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    final t = ThemeCtl.instance;
    return ListenableBuilder(
      listenable: t,
      builder: (context, _) => MaterialApp(
        key: ValueKey(t.generation),
        title: appName,
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: t.lessMotion || MediaQuery.of(context).disableAnimations),
          // F11 = full screen / keluar full screen (sama seperti Arsip PU)
          child: CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.f11): () => WindowCtl.toggleFullScreen()},
            child: Focus(
              autofocus: true,
              child: Platform.isWindows || Platform.isLinux || Platform.isMacOS ? WindowFrame(child: child!) : child!,
            ),
          ),
        ),
        navigatorKey: appNavigatorKey,
        home: const Shell(),
      ),
    );
  }
}

class _Page {
  const _Page(this.id, this.icon, this.label, this.group);
  final String id;
  final IconData icon;
  final String label;
  final String group;
}

List<_Page> get _pages => [
      _Page('dashboard', Icons.space_dashboard_outlined, tr('Dasbor'), ''),
      _Page('projects', Icons.folder_copy_outlined, tr('Proyek'), ''),
      _Page('pipeline', Icons.play_circle_outline_rounded, tr('Pipeline berjalan'), tr('Deploy')),
      _Page('history', Icons.history_rounded, tr('Riwayat deploy'), tr('Deploy')),
      _Page('github', Icons.hub_outlined, 'GitHub Actions', tr('Integrasi')),
    ];

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final _opened = <String>{};

  @override
  void initState() {
    super.initState();
    nav.addListener(_changed);
  }

  @override
  void dispose() {
    nav.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  Widget _build(String id) => switch (id) {
        'projects' => const ProjectsScreen(),
        'pipeline' => const PipelineScreen(),
        'history' => const HistoryScreen(),
        'github' => const GitHubScreen(),
        'settings' => const SettingsScreen(),
        _ => const DashboardScreen(),
      };

  @override
  Widget build(BuildContext context) {
    const ids = ['dashboard', 'projects', 'pipeline', 'history', 'github', 'settings'];
    final current = ids.contains(nav.value) ? nav.value : 'dashboard';
    _opened.add(current);
    return Scaffold(
      backgroundColor: YmColors.paper,
      body: Column(children: [
        const _TopBar(),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Sidebar(active: current),
            Expanded(
              child: IndexedStack(
                index: ids.indexOf(current),
                sizing: StackFit.expand,
                children: [for (final id in ids) _opened.contains(id) ? _build(id) : const SizedBox.shrink()],
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ============================================================================
//  TOP BAR
// ============================================================================
class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: YmColors.surface.withOpacity(0.9),
        border: YmColors.isDark ? Border(bottom: BorderSide(color: YmColors.line)) : null,
        boxShadow: YmColors.isDark ? null : const [BoxShadow(color: Color(0x0A0F172A), blurRadius: 8, offset: Offset(0, 1))],
      ),
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) => Row(children: [
          const DhLogo(size: 36),
          const SizedBox(width: 12),
          Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(appName, style: YmTextStyles.headlineSm.copyWith(height: 1.1)),
            Text(appTagline, style: YmTextStyles.labelSm.copyWith(color: YmColors.outline)),
          ]),
          const Spacer(),
          if (app.isRunning) ...[
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => nav.value = 'pipeline',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(color: YmColors.primarySoft, borderRadius: BorderRadius.circular(999)),
                child: Row(children: [
                  PulseDot(color: YmColors.primary),
                  const SizedBox(width: 6),
                  Text(tr('Deploy {0} berjalan', [app.currentRun!.project.name]),
                      style: YmTextStyles.labelMd.copyWith(color: YmColors.onPrimaryFixed, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
            const SizedBox(width: 12),
          ],
          const _ConnectionPills(),
          const SizedBox(width: 12),
          // Tombol jendela cadangan di top bar aplikasi (selalu terlihat)
          ValueListenableBuilder<bool>(
            valueListenable: WindowCtl.isFull,
            builder: (_, full, __) => IconButton(
              tooltip: full ? tr('Keluar dari full screen (F11)') : tr('Full screen (F11)'),
              onPressed: () => WindowCtl.toggleFullScreen(),
              icon: Icon(full ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
            ),
          ),
          IconButton(
            tooltip: tr('Sembunyikan ke system tray'),
            onPressed: () async {
              if (WindowCtl.isFull.value) await WindowCtl.exitFullScreen();
              await TrayService.hideToTray();
            },
            icon: const Icon(Icons.move_to_inbox_rounded),
          ),
          IconButton(
            tooltip: tr('Pengaturan'),
            onPressed: () => nav.value = 'settings',
            icon: const Icon(Icons.settings_outlined),
          ),
        ]),
      ),
    );
  }
}

class _ConnectionPills extends StatefulWidget {
  const _ConnectionPills();

  @override
  State<_ConnectionPills> createState() => _ConnectionPillsState();
}

class _ConnectionPillsState extends State<_ConnectionPills> {
  bool play = false;
  bool github = false;

  @override
  void initState() {
    super.initState();
    app.addListener(_refresh);
    _refresh();
  }

  @override
  void dispose() {
    app.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    final p = await PlayAuth.globalReady();
    final g = (await Storage.secret('github_token')).isNotEmpty;
    if (mounted && (p != play || g != github)) setState(() {
      play = p;
      github = g;
    });
  }

  Widget _pill(String label, bool ok) => Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Tooltip(
          message: ok ? tr('Terhubung') : tr('Belum terhubung — buka Pengaturan'),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => nav.value = 'settings',
            child: ok
                ? SoftChip.success(label, dot: YmColors.success)
                : SoftChip.neutral(label, icon: Icons.link_off_rounded),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final mac = app.settings.macHost.isNotEmpty;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _pill('Google Play', play),
      _pill('App Store', app.settings.ascVerifiedTeam.isNotEmpty),
      _pill('GitHub', github),
      _pill('MacBook', mac),
    ]);
  }
}

// ============================================================================
//  SIDEBAR
// ============================================================================
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.active});
  final String active;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<_Page>>{};
    for (final p in _pages) {
      groups.putIfAbsent(p.group, () => []).add(p);
    }
    return Container(
      width: 256,
      decoration: BoxDecoration(
        color: Color.alphaBlend(YmColors.surfaceAlt.withOpacity(0.7), YmColors.paper),
        border: YmColors.isDark ? Border(right: BorderSide(color: YmColors.line)) : null,
        boxShadow: YmColors.isDark ? null : const [BoxShadow(color: Color(0x050F172A), blurRadius: 12, offset: Offset(1, 0))],
      ),
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 0), children: [
              for (final e in groups.entries) ...[
                if (e.key.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(e.key.toUpperCase(), style: YmTextStyles.labelSm.copyWith(color: YmColors.outline, letterSpacing: 0.55)),
                  ),
                for (final p in e.value)
                  _SideItem(
                    icon: p.icon,
                    label: p.label,
                    active: active == p.id,
                    badge: switch (p.id) {
                      'projects' => '${app.projects.length}',
                      'pipeline' => app.isRunning ? '●' : null,
                      'history' => app.history.isEmpty ? null : '${app.history.length}',
                      _ => null,
                    },
                    onTap: () => nav.value = p.id,
                  ),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _SideItem(icon: Icons.settings_outlined, label: tr('Pengaturan'), active: active == 'settings', onTap: () => nav.value = 'settings'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text('$appName v1.25', style: YmTextStyles.labelSm.copyWith(color: YmColors.outline)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _SideItem extends StatefulWidget {
  const _SideItem({required this.icon, required this.label, required this.active, required this.onTap, this.badge});
  final IconData icon;
  final String label;
  final bool active;
  final String? badge;
  final VoidCallback onTap;

  @override
  State<_SideItem> createState() => _SideItemState();
}

class _SideItemState extends State<_SideItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final fg = w.active ? YmColors.primary : (_hover ? YmColors.textDark : YmColors.textMuted);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: w.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: motion(context, const Duration(milliseconds: 150)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: w.active ? YmColors.surfaceHigh : (_hover ? YmColors.surfaceContainer : Colors.transparent),
              borderRadius: BorderRadius.circular(12),
              boxShadow: w.active ? shadowSm : null,
            ),
            child: Row(children: [
              Icon(w.icon, color: w.active ? YmColors.primary : (_hover ? YmColors.primary : YmColors.outline), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(w.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: YmTextStyles.labelLg.copyWith(color: fg, fontWeight: w.active ? FontWeight.w600 : FontWeight.w500)),
              ),
              if (w.badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: w.badge == '●' ? YmColors.primarySoft : YmColors.surfaceContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(w.badge!,
                      style: YmTextStyles.labelSm.copyWith(color: w.badge == '●' ? YmColors.primary : YmColors.textMuted)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
