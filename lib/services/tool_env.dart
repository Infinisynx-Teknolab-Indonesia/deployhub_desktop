import 'dart:io';

import 'storage.dart';

/// PATH tambahan untuk semua perintah yang dijalankan DeployHub (flutter, git, keytool,
/// node/npm, firebase, flutterfire, pod, fastlane …).
///
/// Kenapa perlu:
/// - **Windows**: PATH proses ini tidak berubah sampai VS Code / DeployHub ditutup, jadi alat
///   yang baru dipasang tidak terbaca. Node.js juga bisa dipasang di drive lain (D:).
/// - **macOS**: aplikasi yang dibuka dari Finder/Launchpad TIDAK membaca ~/.zshrc, jadi PATH
///   hanya /usr/bin:/bin. Homebrew, Flutter, ~/.pub-cache/bin, npm global tidak terbaca.
///   Karena itu PATH login shell (`zsh -lic`) dibaca sekali saat aplikasi mulai.
class ToolEnv {
  ToolEnv._();

  /// Folder Node.js yang ditemukan / dipilih pengguna (berisi node atau node.exe).
  static String? nodeDir;
  static String? _shellPath; // PATH dari login shell macOS / PATH terbaru dari registry Windows
  static Map<String, String>? _cache;

  static String get _sep => Platform.isWindows ? ';' : ':';
  static String get _home => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

  /// Panggil sekali di main() (dan setelah memasang alat baru).
  static Future<void> init() async {
    _cache = null;
    if (Platform.isMacOS || Platform.isLinux) {
      try {
        final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
        final r = await Process.run(shell, ['-lic', 'echo "__P__\$PATH"']).timeout(const Duration(seconds: 8));
        final m = RegExp(r'__P__(.*)').firstMatch('${r.stdout}');
        if (m != null) _shellPath = m.group(1)!.trim();
      } catch (_) {}
    }
    if (Platform.isWindows) _shellPath = await _windowsRegistryPath();
    await detectNode();
  }

  /// PATH TERBARU dari registry (Sistem + User). Alat yang dipasang lewat winget / installer
  /// SETELAH DeployHub dibuka langsung terbaca tanpa menutup aplikasi / logout.
  static Future<String?> _windowsRegistryPath() async {
    final parts = <String>[];
    for (final key in [r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment', r'HKCU\Environment']) {
      try {
        final r = await Process.run('reg', ['query', key, '/v', 'Path']).timeout(const Duration(seconds: 5));
        final m = RegExp(r'Path\s+REG_(?:EXPAND_)?SZ\s+(.*)', caseSensitive: false).firstMatch('${r.stdout}');
        if (m != null) parts.add(m.group(1)!.trim());
      } catch (_) {}
    }
    if (parts.isEmpty) return null;
    final e = Platform.environment;
    // %VAR% → nilai (mis. %USERPROFILE%, %SystemRoot%)
    final expanded = parts.join(';').replaceAllMapped(RegExp(r'%([^%]+)%'), (m) {
      final k = e.keys.firstWhere((x) => x.toLowerCase() == m[1]!.toLowerCase(), orElse: () => '');
      return k.isEmpty ? m[0]! : e[k]!;
    });
    // gabungkan dengan PATH proses (supaya tidak ada yang hilang)
    return '$expanded;${e['PATH'] ?? e['Path'] ?? ''}';
  }

  static List<String> _extraDirs() {
    final e = Platform.environment;
    if (Platform.isWindows) {
      return [
        if (nodeDir != null) nodeDir!,
        if (e['APPDATA'] != null) '${e['APPDATA']}\\npm',
        if (e['LOCALAPPDATA'] != null) '${e['LOCALAPPDATA']}\\Pub\\Cache\\bin',
        // lokasi default alat DevOps (winget / installer resmi)
        if (e['LOCALAPPDATA'] != null) '${e['LOCALAPPDATA']}\\Microsoft\\WinGet\\Links',
        for (final pf in {e['ProgramFiles'], e['ProgramW6432'], e['ProgramFiles(x86)'], r'C:\Program Files', r'C:\Program Files (x86)'}.whereType<String>()) ...[
          '$pf\\GitHub CLI',
          '$pf\\glab',
          '$pf\\GitLab\\glab',
          '$pf\\Git\\cmd',
          '$pf\\Docker\\Docker\\resources\\bin',
        ],
        if (e['LOCALAPPDATA'] != null) ...[
          '${e['LOCALAPPDATA']}\\Programs\\glab',
          '${e['LOCALAPPDATA']}\\Programs\\GitHub CLI',
        ],
      ];
    }
    final h = _home;
    return [
      if (nodeDir != null) nodeDir!,
      '/opt/homebrew/bin', '/opt/homebrew/sbin', // Homebrew Apple Silicon (M1/M2/M3/M4)
      '/usr/local/bin', // Homebrew Intel, installer resmi Node.js (.pkg), Firebase standalone
      '$h/.pub-cache/bin', // flutterfire
      '$h/.npm-global/bin',
      '$h/development/flutter/bin', '$h/flutter/bin', '$h/fvm/default/bin',
      '$h/.rbenv/shims', '$h/.gem/bin', // fastlane / cocoapods via gem
      '/usr/local/opt/openjdk/bin', '/opt/homebrew/opt/openjdk/bin', // keytool
      '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin', // keytool bawaan Android Studio
    ];
  }

  /// Environment untuk Process.run / Process.start.
  static Map<String, String> env() {
    if (_cache != null) return _cache!;
    final e = Platform.environment;
    final base = _shellPath ?? e['PATH'] ?? e['Path'] ?? '';
    final seen = <String>{};
    final dirs = [
      ..._extraDirs().where((d) => Directory(d).existsSync()),
      ...base.split(_sep),
    ].where((d) => d.isNotEmpty && seen.add(d));
    return _cache = {
      'PATH': dirs.join(_sep),
      if (!Platform.isWindows) 'LANG': e['LANG'] ?? 'en_US.UTF-8',
    };
  }

  static bool _hasNode(String dir) =>
      File('$dir${Platform.pathSeparator}${Platform.isWindows ? 'node.exe' : 'node'}').existsSync();

  /// Cari Node.js. Windows: pilihan pengguna → registry → "<drive>:\Program Files\nodejs".
  /// macOS: pilihan pengguna → Homebrew → /usr/local/bin → nvm / volta / fnm.
  static Future<String?> detectNode() async {
    _cache = null;
    final saved = await Storage.readJson('tools.json');
    final cands = <String>[
      if (saved is Map && saved['nodeDir'] is String) saved['nodeDir'] as String,
    ];
    final e = Platform.environment;
    if (Platform.isWindows) {
      for (final key in [r'HKLM\SOFTWARE\Node.js', r'HKCU\SOFTWARE\Node.js', r'HKLM\SOFTWARE\WOW6432Node\Node.js']) {
        try {
          final r = await Process.run('reg', ['query', key, '/v', 'InstallPath']);
          final m = RegExp(r'InstallPath\s+REG_\w+\s+(.+)').firstMatch('${r.stdout}');
          if (m != null) cands.add(m.group(1)!.trim().replaceAll(RegExp(r'\\$'), ''));
        } catch (_) {}
      }
      for (final v in ['ProgramFiles', 'ProgramW6432', 'ProgramFiles(x86)', 'LOCALAPPDATA']) {
        if (e[v] != null) cands.add('${e[v]}\\nodejs');
      }
      for (final d in 'CDEFGH'.split('')) {
        cands.addAll(['$d:\\Program Files\\nodejs', '$d:\\nodejs', '$d:\\Program Files (x86)\\nodejs']);
      }
    } else {
      final h = _home;
      cands.addAll(['/opt/homebrew/bin', '/usr/local/bin', '$h/.volta/bin']);
      // nvm: ambil versi terbaru di ~/.nvm/versions/node/*/bin
      final nvm = Directory('$h/.nvm/versions/node');
      if (nvm.existsSync()) {
        final vs = nvm.listSync().whereType<Directory>().map((d) => d.path).toList()..sort();
        cands.addAll(vs.reversed.map((v) => '$v/bin'));
      }
    }
    for (final c in cands) {
      if (_hasNode(c)) return nodeDir = c;
    }
    return nodeDir = null;
  }

  /// Simpan folder Node.js pilihan pengguna.
  static Future<bool> setNodeDir(String dir) async {
    // macOS: pengguna bisa memilih folder "nodejs" atau langsung "bin"
    for (final d in [dir, '$dir${Platform.pathSeparator}bin']) {
      if (_hasNode(d)) {
        nodeDir = d;
        _cache = null;
        await Storage.writeJson('tools.json', {'nodeDir': d});
        return true;
      }
    }
    return false;
  }
}
