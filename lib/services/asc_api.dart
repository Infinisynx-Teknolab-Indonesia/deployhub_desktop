import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;

import '../core/i18n.dart';
import '../models.dart';

/// App Store Connect API — jalan langsung dari Windows (tanpa MacBook).
/// Login resmi Apple untuk alat otomatis memakai API key (.p8), bukan Apple ID + password.
class AscApi {
  AscApi(this.keyId, this.issuerId, this.p8);
  final String keyId;
  final String issuerId;
  final String p8; // isi file AuthKey_XXXX.p8 (PEM)

  static const _base = 'https://api.appstoreconnect.apple.com';

  static Future<AscApi> fromSettings(AppSettings s, {Project? project}) async {
    final keyId = (project?.ascKeyId.isNotEmpty ?? false) ? project!.ascKeyId : s.ascKeyId;
    final issuer = (project?.ascIssuerId.isNotEmpty ?? false) ? project!.ascIssuerId : s.ascIssuerId;
    if (keyId.isEmpty || issuer.isEmpty || s.ascP8Path.isEmpty) {
      throw Exception(trL('Key ID, Issuer ID, dan file .p8 App Store Connect belum lengkap'));
    }
    return AscApi(keyId, issuer, await File(s.ascP8Path).readAsString());
  }

  /// JWT ES256 berlaku 20 menit (batas maksimal Apple).
  String _token() => JWT(
        {'aud': 'appstoreconnect-v1'},
        issuer: issuerId,
        header: {'kid': keyId, 'typ': 'JWT'},
      ).sign(ECPrivateKey(p8), algorithm: JWTAlgorithm.ES256, expiresIn: const Duration(minutes: 19));

  Future<Map<String, dynamic>> _get(String path) async {
    final r = await http.get(Uri.parse('$_base$path'), headers: {'Authorization': 'Bearer ${_token()}'});
    if (r.statusCode >= 300) {
      var msg = r.body;
      try {
        final e = (jsonDecode(r.body)['errors'] as List).first as Map;
        msg = '${e['title']}: ${e['detail']}';
      } catch (_) {}
      if (r.statusCode == 401) msg = '${trL('Ditolak Apple (401) — cek Key ID, Issuer ID, dan file .p8')} • $msg';
      throw Exception('App Store Connect ${r.statusCode}: $msg');
    }
    return Map<String, dynamic>.from(jsonDecode(r.body));
  }

  /// Daftar aplikasi: (id, nama, bundleId).
  Future<List<(String, String, String)>> apps() async {
    final j = await _get('/v1/apps?fields[apps]=name,bundleId&limit=200');
    return [
      for (final a in (j['data'] as List))
        ('${a['id']}', '${a['attributes']['name']}', '${a['attributes']['bundleId']}'),
    ];
  }

  Future<String?> appIdForBundle(String bundleId) async {
    final j = await _get('/v1/apps?filter[bundleId]=${Uri.encodeQueryComponent(bundleId)}&fields[apps]=name');
    final d = j['data'] as List;
    return d.isEmpty ? null : '${d.first['id']}';
  }

  /// Build terakhir: (versi build, status proses Apple, waktu upload).
  Future<List<(String, String, String)>> latestBuilds(String appId, {int limit = 3}) async {
    final j = await _get('/v1/builds?filter[app]=$appId&sort=-uploadedDate&limit=$limit&fields[builds]=version,processingState,uploadedDate');
    return [
      for (final b in (j['data'] as List))
        ('${b['attributes']['version']}', '${b['attributes']['processingState']}', '${b['attributes']['uploadedDate']}'),
    ];
  }

  /// Versi App Store: (versi, status review/rilis).
  Future<List<(String, String)>> versions(String appId, {int limit = 3}) async {
    final j = await _get('/v1/apps/$appId/appStoreVersions?limit=$limit&fields[appStoreVersions]=versionString,appStoreState');
    return [
      for (final v in (j['data'] as List)) ('${v['attributes']['versionString']}', '${v['attributes']['appStoreState']}'),
    ];
  }
}

/// Status App Store dalam bahasa manusia.
String ascStateText(String s) => switch (s) {
      'PREPARE_FOR_SUBMISSION' => trL('Disiapkan (belum dikirim review)'),
      'WAITING_FOR_REVIEW' => trL('Menunggu review Apple (biasanya 1–2 hari)'),
      'IN_REVIEW' => trL('Sedang direview Apple'),
      'PENDING_DEVELOPER_RELEASE' => trL('Disetujui — tinggal klik Release'),
      'PENDING_APPLE_RELEASE' => trL('Disetujui — menunggu Apple merilis'),
      'READY_FOR_SALE' => trL('Tayang di App Store'),
      'REJECTED' => trL('Ditolak — buka App Store Connect → Resolution Center'),
      'METADATA_REJECTED' => trL('Metadata ditolak — perbaiki info App Store'),
      'DEVELOPER_REJECTED' => trL('Dibatalkan oleh developer'),
      'PROCESSING' => trL('Diproses Apple (5–30 menit)'),
      'VALID' => trL('Siap dipakai di TestFlight'),
      'INVALID' => trL('Ditolak saat diproses — cek email dari Apple'),
      'FAILED' => trL('Gagal diproses'),
      _ => s,
    };
