import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// Kontrol jendela utama: full screen <-> jendela biasa.
///
/// window_manager di Windows punya beberapa kebiasaan saat keluar dari full screen:
///  - ukuran/posisi jendela tidak kembali (isi tampak terpotong / bergeser),
///  - tombol aplikasi di taskbar bisa hilang.
/// Karena itu ukuran jendela disimpan sebelum masuk full screen lalu dipulihkan
/// sendiri, dan tombol taskbar dipaksa tampil lagi (setSkipTaskbar(false)).
class WindowCtl {
  WindowCtl._();

  static const defaultSize = Size(1366, 768);

  /// true = sedang full screen (dipakai title bar untuk ikon tombolnya).
  static final isFull = ValueNotifier<bool>(false);

  static Rect? _normalBounds;
  static bool _watching = false;

  /// Pasang pengawas jendela (dipanggil sekali di main.dart).
  /// Jendela bisa keluar dari full screen TANPA lewat tombol aplikasi
  /// (Win+Panah bawah, snap, klik dua kali, dsb.). Kalau status tidak ikut
  /// diperbarui, title bar tetap tersembunyi -> tidak ada tombol & tidak bisa
  /// digeser. Pengawas ini selalu mencocokkan status dengan kondisi nyata.
  static void init() {
    if (_watching) return;
    _watching = true;
    windowManager.addListener(_Watcher());
  }

  /// Full screen sungguhan = window_manager bilang full screen DAN jendela
  /// menutupi seluruh layar.
  static Future<bool> _reallyFull() async {
    try {
      final flag = await windowManager.isFullScreen();
      if (!flag) return false;
      final b = await windowManager.getBounds();
      final views = PlatformDispatcher.instance.views;
      final display = views.isEmpty ? null : views.first.display;
      if (display == null) return flag;
      final w = display.size.width / display.devicePixelRatio;
      final h = display.size.height / display.devicePixelRatio;
      return b.width >= w - 4 && b.height >= h - 4;
    } catch (_) {
      return isFull.value;
    }
  }

  static bool _syncing = false;

  /// Cocokkan [isFull] dengan kondisi jendela yang sebenarnya.
  static Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      await Future.delayed(const Duration(milliseconds: 150));
      final real = await _reallyFull();
      if (real != isFull.value) {
        isFull.value = real;
        if (!real) await reactivate(); // keluar full screen lewat Windows -> tetap bisa diklik
      }
    } finally {
      _syncing = false;
    }
  }

  static Future<void> enterFullScreen() async {
    try {
      if (!isFull.value) {
        final b = await windowManager.getBounds();
        if (b.width >= 600 && b.height >= 400) _normalBounds = b;
        // status internal window_manager bisa masih "full screen" kalau jendela
        // dikecilkan lewat Windows -> reset dulu supaya full screen benar-benar jalan
        if (await windowManager.isFullScreen()) await windowManager.setFullScreen(false);
      }
      await windowManager.setFullScreen(true);
      isFull.value = true;
      await windowManager.setSkipTaskbar(false);
    } catch (e) {
      debugPrint('[WindowCtl] enterFullScreen: $e');
    }
  }

  static Future<void> exitFullScreen() async {
    try {
      await windowManager.setFullScreen(false);
      isFull.value = false;
      await Future.delayed(const Duration(milliseconds: 120));
      final b = _normalBounds;
      if (b != null) {
        await windowManager.setBounds(b);
      } else {
        await windowManager.setSize(defaultSize);
        await windowManager.center();
      }
      await reactivate();
    } catch (e) {
      debugPrint('[WindowCtl] exitFullScreen: $e');
    }
  }

  /// Setelah keluar full screen, window_manager di Windows mengembalikan ukuran
  /// jendela TANPA mengaktifkannya (SWP_NOACTIVATE). Akibatnya jendela tampak
  /// mengecil tapi tidak bisa diklik sampai ikon tray diklik. Di sini dilakukan
  /// hal yang sama seperti klik ikon tray: tampilkan + fokus + taskbar, lalu
  /// ukuran disentuh 1 px supaya Windows menggambar ulang & menyetel ulang area klik.
  static Future<void> reactivate() async {
    await windowManager.show();
    await windowManager.setSkipTaskbar(false); // pastikan tombol taskbar muncul lagi
    await windowManager.focus();
    try {
      final b = await windowManager.getBounds();
      await windowManager.setBounds(Rect.fromLTWH(b.left, b.top, b.width + 1, b.height));
      await windowManager.setBounds(b);
    } catch (_) {}
    await windowManager.focus();
  }

  static Future<void> toggleFullScreen() async {
    final full = await _reallyFull();
    if (full) {
      await exitFullScreen();
    } else {
      await enterFullScreen();
    }
  }

  /// Tampilkan jendela (dari tray) — tombol taskbar ikut dipastikan muncul.
  static Future<void> show() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.setSkipTaskbar(false);
    await windowManager.focus();
    await sync();
  }
}

class _Watcher with WindowListener {
  @override
  void onWindowEnterFullScreen() => WindowCtl.sync();
  @override
  void onWindowLeaveFullScreen() => WindowCtl.sync();
  @override
  void onWindowResized() => WindowCtl.sync();
  @override
  void onWindowRestore() => WindowCtl.sync();
  @override
  void onWindowMaximize() => WindowCtl.sync();
  @override
  void onWindowUnmaximize() => WindowCtl.sync();
  @override
  void onWindowFocus() => WindowCtl.sync();
}
