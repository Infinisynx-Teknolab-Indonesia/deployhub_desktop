import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/i18n.dart';
import '../theme/dh_theme.dart';
import 'window_ctl.dart';

/// System tray — sama seperti Arsip Dokumen PU / Batam ChitChat:
/// - Ikon di pojok kanan bawah taskbar
/// - Klik kiri  : buka / munculkan jendela
/// - Klik kanan : menu  Buka DeployHub | Pipeline berjalan | Riwayat deploy | Keluar
/// - Tombol X jendela: sembunyikan ke tray (pipeline tetap jalan di belakang)
///
/// Kalau ikon atau menu gagal dipasang, tombol X tetap menutup aplikasi biasa supaya
/// jendela tidak "hilang" tanpa jalan kembali.
class TrayService {
  static bool _initialized = false;
  static bool _ready = false;

  static void Function()? _onExit;
  static void Function(String page)? _onOpenPage;

  static bool get isReady => _ready;

  static Future<void> init({
    required void Function() onExitRequested,
    required void Function(String page) onOpenPage,
  }) async {
    _onExit = onExitRequested;
    _onOpenPage = onOpenPage;
    if (_initialized) return;
    _initialized = true;

    trayManager.addListener(_TrayServiceListener());

    bool iconOk = false;
    bool menuOk = false;

    try {
      if (Platform.isMacOS) {
        await trayManager.setIcon('assets/icons/tray_icon_mac.png', isTemplate: true, iconSize: 18);
        iconOk = true;
      } else {
        final bytes = await rootBundle.load('assets/icons/app_icon.ico');
        final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}deployhub');
        await dir.create(recursive: true);
        final iconFile = File('${dir.path}${Platform.pathSeparator}deployhub_tray.ico');
        await iconFile.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
        await trayManager.setIcon(iconFile.path);
        iconOk = true;
        // ikon jendela/taskbar juga (berlaku walau exe masih ikon bawaan Flutter)
        try {
          await windowManager.setIcon(iconFile.path);
        } catch (_) {}
      }
    } catch (e) {
      // ignore: avoid_print
      print('[TrayService] setIcon gagal: $e');
    }

    await setTooltip(ThemeCtl.instance.appName);
    menuOk = await _buildMenu();

    if (iconOk && menuOk) {
      try {
        await windowManager.setPreventClose(true);
        windowManager.addListener(_WindowCloseListener());
        _ready = true;
      } catch (e) {
        // ignore: avoid_print
        print('[TrayService] setPreventClose gagal: $e');
      }
    }
  }

  static Future<bool> _buildMenu() async {
    try {
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: trL('Buka {0}', [ThemeCtl.instance.appName])),
        MenuItem.separator(),
        MenuItem(key: 'pipeline', label: trL('Pipeline berjalan')),
        MenuItem(key: 'history', label: trL('Riwayat deploy')),
        MenuItem(key: 'projects', label: trL('Proyek')),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: trL('Keluar')),
      ]));
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('[TrayService] setContextMenu gagal: $e');
      return false;
    }
  }

  /// Bangun ulang menu (setelah bahasa diganti).
  static Future<void> refreshMenu() async {
    if (_initialized) await _buildMenu();
  }

  /// Teks saat mouse di atas ikon tray (mis. "DeployHub — Deploy X berjalan").
  static Future<void> setTooltip(String text) async {
    try {
      await trayManager.setToolTip(text);
    } catch (_) {}
  }

  static Future<void> showWindow() => WindowCtl.show();

  /// Sembunyikan jendela ke tray (tombol X).
  static Future<void> hideToTray() async {
    if (WindowCtl.isFull.value) await WindowCtl.exitFullScreen();
    if (_ready) {
      await windowManager.hide();
    } else {
      await windowManager.minimize();
    }
  }

  /// Tutup aplikasi sepenuhnya: hapus ikon tray dulu supaya tidak tertinggal.
  static Future<void> quit() async {
    try {
      await trayManager.destroy();
    } catch (_) {}
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {}
    exit(0);
  }
}

class _TrayServiceListener with TrayListener {
  @override
  void onTrayIconMouseDown() => WindowCtl.show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'exit':
        TrayService._onExit?.call();
      case 'show':
        WindowCtl.show();
      default:
        WindowCtl.show();
        TrayService._onOpenPage?.call(menuItem.key ?? 'dashboard');
    }
  }
}

class _WindowCloseListener with WindowListener {
  @override
  void onWindowClose() async {
    if (await windowManager.isPreventClose()) await TrayService.hideToTray();
  }
}
