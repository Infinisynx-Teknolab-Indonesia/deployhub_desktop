import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../models.dart';
import '../utils.dart';

/// Koneksi SSH ke MacBook untuk build iOS (Xcode hanya jalan di macOS).
class MacService {
  static Future<SSHClient> connect(AppSettings s, {String password = ''}) async {
    final socket = await SSHSocket.connect(s.macHost, s.macPort,
        timeout: const Duration(seconds: 10));
    List<SSHIdentity>? identities;
    if (s.macKeyPath.isNotEmpty) {
      identities = [...SSHKeyPair.fromPem(await File(s.macKeyPath).readAsString())];
    }
    final client = SSHClient(
      socket,
      username: s.macUser,
      identities: identities,
      onPasswordRequest: password.isEmpty ? null : () => password,
    );
    await client.authenticated;
    return client;
  }

  /// Bungkus perintah supaya PATH Flutter/CocoaPods/Homebrew ikut termuat
  /// (sesi SSH non-interaktif tidak membaca ~/.zshrc secara otomatis).
  static String wrap(String cmd, {String cwd = ''}) {
    final cd = cwd.isEmpty ? '' : 'cd ${shPath(cwd)} && ';
    final inner = 'source ~/.zprofile >/dev/null 2>&1; '
        'source ~/.zshrc >/dev/null 2>&1; '
        'export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH"; '
        'export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8; '
        '$cd$cmd';
    return 'zsh -c ${shq(inner)}';
  }

  static Future<int> run(
      SSHClient client, String command, void Function(String) log) async {
    final session = await client.execute(command);
    const dec = Utf8Decoder(allowMalformed: true);
    final a = session.stdout
        .cast<List<int>>()
        .transform(dec)
        .transform(const LineSplitter())
        .forEach(log);
    final b = session.stderr
        .cast<List<int>>()
        .transform(dec)
        .transform(const LineSplitter())
        .forEach(log);
    await session.done;
    try {
      await Future.wait([a, b]);
    } catch (_) {}
    return session.exitCode ?? -1;
  }

  /// Tes koneksi: kembalikan info versi macOS, Xcode, Flutter.
  static Future<String> check(AppSettings s, String password) async {
    final client = await connect(s, password: password);
    try {
      final lines = <String>[];
      await run(
        client,
        wrap('echo "macOS: \$(sw_vers -productVersion)"; '
            'xcodebuild -version | head -1; '
            'flutter --version | head -1; '
            'pod --version | sed "s/^/CocoaPods /"'),
        lines.add,
      );
      return lines.join('\n');
    } finally {
      client.close();
    }
  }
}
