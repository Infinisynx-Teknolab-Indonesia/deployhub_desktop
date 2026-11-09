import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../theme/dh_theme.dart';
import '../services/tray_service.dart';
import '../services/window_ctl.dart';
import '../core/i18n.dart';
import 'dh_widgets.dart';

/// Title bar sendiri (sama seperti Arsip Dokumen PU / Batam ChitChat) menggantikan title bar bawaan Windows:
/// - seret untuk memindahkan jendela, klik dua kali untuk maximize
/// - tombol: Full screen / keluar full screen, Minimize, Maximize, Tutup (ke tray)
/// Selalu tampil, juga saat full screen, supaya selalu ada tombol untuk
/// kembali ke full screen atau mengecilkan jendela.
class AppTitleBar extends StatelessWidget {
  const AppTitleBar({super.key});

  void _safe(Future<void> Function() f) {
    f().catchError((e) {
      // ignore: avoid_print
      print('[AppTitleBar] $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    // Material transparan: title bar berada di atas Navigator, perlu Material untuk gaya teks.
    return Material(
      color: Colors.transparent,
      child: _bar(),
    );
  }

  Widget _bar() {
    return SizedBox(
      height: 34,
      child: Stack(
        children: [
          Positioned.fill(
            child: DragToMoveArea(
              child: Container(
                // title bar terang, menyatu dengan top bar aplikasi (ikut tema)
                decoration: BoxDecoration(
                  color: YmColors.sidebar,
                  border: Border(bottom: BorderSide(color: YmColors.line)),
                ),
              ),
            ),
          ),
          Row(
            children: [
              // macOS: sisakan tempat untuk tombol bulat merah/kuning/hijau bawaan sistem
              SizedBox(width: Platform.isMacOS ? 78 : 10),
              IgnorePointer(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const DhLogo(size: 18),
                  const SizedBox(width: 8),
                  Text(appName, style: YmTextStyles.labelMd.copyWith(color: YmColors.textMuted, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
              const Spacer(),
              ValueListenableBuilder<bool>(
                valueListenable: WindowCtl.isFull,
                builder: (_, full, __) => _TitleBarButton(
                  icon: full ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                  iconSize: 18,
                  tooltip: full ? tr('Keluar dari full screen (F11)') : tr('Full screen (F11)'),
                  onTap: () => _safe(WindowCtl.toggleFullScreen),
                ),
              ),
              // Windows: tombol jendela sendiri. macOS memakai tombol bawaan sistem.
              if (!Platform.isMacOS) ...[
              _TitleBarButton(
                icon: Icons.remove,
                tooltip: tr('Minimize'),
                onTap: () => _safe(() async {
                  if (WindowCtl.isFull.value) await WindowCtl.exitFullScreen();
                  await windowManager.minimize();
                }),
              ),
              _TitleBarButton(
                icon: Icons.crop_square,
                iconSize: 12,
                tooltip: tr('Maximize / Restore'),
                onTap: () => _safe(() async {
                  if (WindowCtl.isFull.value) {
                    await WindowCtl.exitFullScreen();
                    return;
                  }
                  if (await windowManager.isMaximized()) {
                    await windowManager.unmaximize();
                  } else {
                    await windowManager.maximize();
                  }
                }),
              ),
              _TitleBarButton(
                icon: Icons.close,
                hoverColor: YmColors.buzzRed,
                tooltip: tr('Tutup (aplikasi tetap berjalan di system tray)'),
                onTap: () => _safe(TrayService.hideToTray),
              ),
              ],
              if (Platform.isMacOS) const SizedBox(width: 6),
            ],
          ),
        ],
      ),
    );
  }
}

class _TitleBarButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double iconSize;
  final Color? hoverColor;
  final String tooltip;

  const _TitleBarButton({required this.icon, required this.onTap, required this.tooltip, this.iconSize = 14, this.hoverColor});

  @override
  State<_TitleBarButton> createState() => _TitleBarButtonState();
}

class _TitleBarButtonState extends State<_TitleBarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // Tanpa Tooltip: title bar ini berada di atas Navigator (tidak ada Overlay).
    return Semantics(
      label: widget.tooltip,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 44,
            height: 34,
            color: _hover ? (widget.hoverColor ?? YmColors.surfaceContainer) : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: widget.iconSize, color: _hover && widget.hoverColor != null ? Colors.white : YmColors.textMuted),
          ),
        ),
      ),
    );
  }
}

/// Bingkai jendela utama: title bar sendiri selalu tampil di atas (jendela biasa
/// maupun full screen) berisi tombol full screen, minimize, maximize, dan tutup ke tray.
class WindowFrame extends StatefulWidget {
  final Widget child;
  const WindowFrame({super.key, required this.child});

  @override
  State<WindowFrame> createState() => _WindowFrameState();
}

class _WindowFrameState extends State<WindowFrame> {
  /// GlobalKey: isi aplikasi tidak dibangun ulang saat mode jendela berganti.
  final _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    // Title bar SELALU tampil — juga saat full screen — supaya tombol keluar full screen,
    // minimize, dan tutup ke tray tidak pernah hilang (sebelumnya disembunyikan saat full
    // screen dan baru muncul kalau mouse di tepi atas, sehingga terlihat seperti error).
    return Column(children: [
      AppTitleBar(), // bukan const: ikut berganti saat tema diganti
      Expanded(child: KeyedSubtree(key: _contentKey, child: widget.child)),
    ]);
  }
}
