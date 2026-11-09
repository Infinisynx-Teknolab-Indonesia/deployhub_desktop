import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:googleapis/androidpublisher/v3.dart' as ap;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import 'storage.dart';

/// Akses resmi ke Google Play Developer API. Dua cara:
///  1. **Login dengan Google** (OAuth Desktop) — akun Google yang punya akses Play Console.
///  2. **Service Account JSON** — cara standar untuk CI/CD (tanpa browser).
/// Proyek boleh punya Service Account sendiri; kalau kosong dipakai setelan global.
class PlayAuth {
  static AppSettings settings = AppSettings();

  static const reportingScope = 'https://www.googleapis.com/auth/playdeveloperreporting';
  static const scopes = [ap.AndroidPublisherApi.androidpublisherScope, reportingScope, 'openid', 'email'];

  /// true kalau file JSON benar-benar Service Account (bukan client_secret OAuth).
  static bool isServiceAccountFile(String path) {
    try {
      final j = jsonDecode(File(path).readAsStringSync());
      return j is Map && j['type'] == 'service_account';
    } catch (_) {
      return false;
    }
  }

  static Future<http.Client> _serviceAccount(String path, {List<String>? scopes}) async {
    final json = jsonDecode(await File(path).readAsString());
    if (json is Map && (json['installed'] != null || json['web'] != null)) {
      throw Exception('File ${path.split(RegExp(r'[\\/]')).last} adalah OAuth client (client_secret), bukan Service Account. '
          'Buka Pengaturan → Google Play → klik "Pakai untuk Login Google", lalu "Login dengan Google".');
    }
    return clientViaServiceAccount(
        ServiceAccountCredentials.fromJson(json), scopes ?? [ap.AndroidPublisherApi.androidpublisherScope]);
  }

  /// Client untuk Play Developer Reporting API (crash rate / ANR).
  /// Service Account: scope reporting. Login Google (OAuth): login ulang sekali kalau token lama belum punya scope ini.
  static Future<http.Client> reportingClient(String projectJsonPath) async {
    String path = '';
    if (projectJsonPath.isNotEmpty && await File(projectJsonPath).exists()) {
      path = projectJsonPath;
    } else if (settings.playAuthMode != 'oauth' && settings.playServiceAccountPath.isNotEmpty) {
      path = settings.playServiceAccountPath;
    }
    if (path.isNotEmpty) return _serviceAccount(path, scopes: [reportingScope]);
    return client(projectJsonPath);
  }

  static Future<bool> available(Project pr) async {
    if (pr.serviceAccountPath.isNotEmpty && isServiceAccountFile(pr.serviceAccountPath)) return true;
    return globalReady();
  }

  static Future<bool> globalReady() async {
    final s = settings;
    if (s.playAuthMode == 'oauth') {
      return s.playOAuthClientId.isNotEmpty && (await Storage.secret(Secrets.playOAuthCreds)).isNotEmpty;
    }
    return s.playServiceAccountPath.isNotEmpty && isServiceAccountFile(s.playServiceAccountPath);
  }

  /// Client terautentikasi untuk proyek (Service Account proyek → setelan global).
  static Future<http.Client> client(String projectJsonPath) async {
    if (projectJsonPath.isNotEmpty && await File(projectJsonPath).exists()) {
      return _serviceAccount(projectJsonPath);
    }
    final s = settings;
    if (s.playAuthMode == 'oauth') {
      final raw = await Storage.secret(Secrets.playOAuthCreds);
      if (raw.isEmpty || s.playOAuthClientId.isEmpty) {
        throw Exception('Belum login Google Play. Buka Pengaturan → Akun & Koneksi.');
      }
      final secret = await Storage.secret(Secrets.playOAuthSecret);
      final c = autoRefreshingClient(
        ClientId(s.playOAuthClientId, secret.isEmpty ? null : secret),
        _decode(raw),
        http.Client(),
      );
      c.credentialUpdates.listen((cr) => Storage.setSecret(Secrets.playOAuthCreds, _encode(cr)));
      return c;
    }
    if (s.playServiceAccountPath.isNotEmpty && await File(s.playServiceAccountPath).exists()) {
      return _serviceAccount(s.playServiceAccountPath);
    }
    throw Exception('Google Play belum terhubung. Buka Pengaturan → Akun & Koneksi.');
  }

  /// Login Google lewat browser (OAuth Desktop). Mengembalikan email akun.
  static Future<String> login(String clientId, String clientSecret) async {
    final c = await clientViaUserConsent(
      ClientId(clientId, clientSecret.isEmpty ? null : clientSecret),
      scopes,
      (url) => launchUrl(Uri.parse(url)),
    );
    try {
      await Storage.setSecret(Secrets.playOAuthCreds, _encode(c.credentials));
      await Storage.setSecret(Secrets.playOAuthSecret, clientSecret);
      return emailFromIdToken(c.credentials.idToken) ?? '';
    } finally {
      c.close();
    }
  }

  static Future<void> logout() async {
    await Storage.setSecret(Secrets.playOAuthCreds, '');
  }

  /// Tes: buat edit lalu hapus lagi untuk package tertentu.
  static Future<String> test(String packageName, {String projectJsonPath = ''}) async {
    final c = await client(projectJsonPath);
    try {
      final api = ap.AndroidPublisherApi(c);
      final edit = await api.edits.insert(ap.AppEdit(), packageName);
      final details = await api.edits.details.get(packageName, edit.id!);
      await api.edits.delete(packageName, edit.id!);
      return '$packageName • ${details.contactEmail ?? '-'} • ${details.defaultLanguage ?? '-'}';
    } finally {
      c.close();
    }
  }

  static String? emailFromIdToken(String? idToken) {
    if (idToken == null) return null;
    final parts = idToken.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      return (jsonDecode(payload) as Map)['email']?.toString();
    } catch (_) {
      return null;
    }
  }

  static String _encode(AccessCredentials c) => jsonEncode({
        'type': c.accessToken.type,
        'data': c.accessToken.data,
        'expiry': c.accessToken.expiry.toUtc().toIso8601String(),
        'refreshToken': c.refreshToken,
        'scopes': c.scopes,
        'idToken': c.idToken,
      });

  static AccessCredentials _decode(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return AccessCredentials(
      AccessToken(j['type'] as String, j['data'] as String, DateTime.parse(j['expiry'] as String).toUtc()),
      j['refreshToken'] as String?,
      List<String>.from(j['scopes'] as List),
      idToken: j['idToken'] as String?,
    );
  }
}
