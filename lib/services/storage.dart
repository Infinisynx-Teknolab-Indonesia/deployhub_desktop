import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class Storage {
  static late Directory dir;
  static const _secure = FlutterSecureStorage();

  static Future<void> init() async {
    dir = await getApplicationSupportDirectory();
    await Directory(p.join(dir.path, 'logs')).create(recursive: true);
  }

  static String get logsDir => p.join(dir.path, 'logs');

  static File _file(String name) => File(p.join(dir.path, name));

  static Future<dynamic> readJson(String name) async {
    final f = _file(name);
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeJson(String name, Object data) async {
    await _file(name)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  // macOS tanpa tanda tangan Apple / entitlement Keychain: flutter_secure_storage bisa
  // gagal (-34018). Kalau itu terjadi, rahasia disimpan di secrets.json di folder data
  // aplikasi (hanya bisa dibaca akun Mac kamu) supaya DeployHub tetap jalan.
  static Map<String, dynamic>? _fallback;

  static Future<Map<String, dynamic>> _fb() async {
    final j = await readJson('secrets.json');
    return _fallback ??= j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};
  }

  static Future<String> secret(String key) async {
    try {
      final v = await _secure.read(key: key);
      if (v != null) return v;
    } catch (_) {}
    return '${(await _fb())[key] ?? ''}';
  }

  static Future<void> setSecret(String key, String value) async {
    try {
      if (value.isEmpty) {
        await _secure.delete(key: key);
      } else {
        await _secure.write(key: key, value: value);
      }
      return;
    } catch (_) {}
    final m = await _fb();
    if (value.isEmpty) {
      m.remove(key);
    } else {
      m[key] = value;
    }
    await writeJson('secrets.json', m);
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', _file('secrets.json').path]);
      } catch (_) {}
    }
  }
}
