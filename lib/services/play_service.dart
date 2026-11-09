import 'dart:convert';
import 'dart:io';

import 'package:googleapis/androidpublisher/v3.dart' as ap;
import 'package:http/http.dart' as http;

import '../core/i18n.dart';
import '../utils.dart';
import 'play_auth.dart';
import 'store_metadata.dart';

/// Versi yang sudah ada di Google Play untuk satu aplikasi.
class PlayVersions {
  int maxCode = 0; // versionCode tertinggi yang PERNAH diupload (semua track + bundle draft)
  final tracks = <String, List<(String code, String name, String status)>>{}; // track → rilis
  String error = '';
  bool appMissing = false; // aplikasi belum dibuat di Play Console

  /// Rilis terbaru di track (versionCode tertinggi).
  (String code, String name, String status)? latest(String track) {
    final l = tracks[track];
    if (l == null || l.isEmpty) return null;
    final sorted = [...l]..sort((a, b) => (int.tryParse(b.$1) ?? 0).compareTo(int.tryParse(a.$1) ?? 0));
    return sorted.first;
  }
}

/// Google Play Developer API (upload AAB, atur track).
class PlayService {
  /// Semua versi di Google Play: tiap track + semua bundle/APK yang pernah diupload.
  /// versionCode baru WAJIB lebih besar dari [PlayVersions.maxCode].
  static Future<PlayVersions> versions(String jsonPath, String packageName) async {
    final out = PlayVersions();
    http.Client? client;
    try {
      client = await _client(jsonPath);
      final api = ap.AndroidPublisherApi(client);
      final edit = await api.edits.insert(ap.AppEdit(), packageName);
      try {
        final res = await api.edits.tracks.list(packageName, edit.id!);
        for (final t in res.tracks ?? const <ap.Track>[]) {
          for (final r in t.releases ?? const <ap.TrackRelease>[]) {
            for (final c in r.versionCodes ?? const <String>[]) {
              out.tracks.putIfAbsent(t.track ?? '?', () => []).add((c, r.name ?? '', r.status ?? ''));
              final v = int.tryParse(c) ?? 0;
              if (v > out.maxCode) out.maxCode = v;
            }
          }
        }
        // Bundle yang sudah diupload tapi belum dirilis juga "memakai" versionCode
        try {
          final b = await api.edits.bundles.list(packageName, edit.id!);
          for (final x in b.bundles ?? const <ap.Bundle>[]) {
            if ((x.versionCode ?? 0) > out.maxCode) out.maxCode = x.versionCode!;
          }
        } catch (_) {}
        try {
          final a = await api.edits.apks.list(packageName, edit.id!);
          for (final x in a.apks ?? const <ap.Apk>[]) {
            if ((x.versionCode ?? 0) > out.maxCode) out.maxCode = x.versionCode!;
          }
        } catch (_) {}
      } finally {
        try {
          await api.edits.delete(packageName, edit.id!);
        } catch (_) {}
      }
    } on ap.DetailedApiRequestError catch (e) {
      out.error = '${e.status}: ${e.message}';
      out.appMissing = e.status == 404 || '${e.message}'.contains('not found');
    } catch (e) {
      out.error = '$e';
    } finally {
      client?.close();
    }
    return out;
  }

  static Future<http.Client> _client(String jsonPath) => PlayAuth.client(jsonPath);

  /// versionCode tertinggi yang pernah ada di semua track.
  static Future<int> maxVersionCode(String jsonPath, String packageName) async {
    final client = await _client(jsonPath);
    try {
      final api = ap.AndroidPublisherApi(client);
      final edit = await api.edits.insert(ap.AppEdit(), packageName);
      final res = await api.edits.tracks.list(packageName, edit.id!);
      var maxCode = 0;
      for (final t in res.tracks ?? const <ap.Track>[]) {
        for (final r in t.releases ?? const <ap.TrackRelease>[]) {
          for (final c in r.versionCodes ?? const <String>[]) {
            final v = int.tryParse(c) ?? 0;
            if (v > maxCode) maxCode = v;
          }
        }
      }
      await api.edits.delete(packageName, edit.id!);
      return maxCode;
    } finally {
      client.close();
    }
  }

  /// true kalau upload terakhir terpaksa jadi DRAFT (aplikasi masih Draf di Play Console).
  static bool lastUploadWasDraft = false;

  /// Upload AAB lalu rilis ke [track]. Mengembalikan versionCode.
  static Future<int> uploadBundle({
    required String jsonPath,
    required String packageName,
    required File aab,
    required String track,
    required String releaseStatus, // completed | draft
    required String releaseNotes,
    required void Function(String) log,
    File? mapping,
    double? fraction, // production: staged rollout (0.1 = 10% pengguna)
  }) async {
    lastUploadWasDraft = releaseStatus == 'draft';
    final staged = fraction != null && fraction > 0 && fraction < 1 && releaseStatus == 'completed';
    final client = await _client(jsonPath);
    try {
      final api = ap.AndroidPublisherApi(client);
      log(trL('Membuat edit di Google Play...'));
      final edit = await api.edits.insert(ap.AppEdit(), packageName);
      final editId = edit.id!;

      final len = await aab.length();
      log(trL('Mengupload AAB ({0})... ini bisa beberapa menit.', [fmtMb(len)]));
      final bundle = await api.edits.bundles.upload(
        packageName,
        editId,
        uploadOptions: ap.ResumableUploadOptions(),
        uploadMedia: ap.Media(aab.openRead(), len,
            contentType: 'application/octet-stream'),
      );
      final code = bundle.versionCode!;
      log('✔ ${trL('AAB terupload, versionCode {0}', [code])}');

      if (mapping != null) {
        log(trL('Mengupload mapping R8 (deobfuscation file)...'));
        await api.edits.deobfuscationfiles.upload(packageName, editId, code, 'proguard',
            uploadMedia: ap.Media(mapping.openRead(), await mapping.length()));
        log('✔ ${trL('Mapping R8 terupload — crash report di Play Console tetap terbaca')}');
      }

      Future<void> setTrack(String status) => api.edits.tracks.update(
            ap.Track(track: track, releases: [
              ap.TrackRelease(
                versionCodes: ['$code'],
                status: staged && status == 'completed' ? 'inProgress' : status,
                userFraction: staged && status == 'completed' ? fraction : null,
                releaseNotes: releaseNotes.trim().isEmpty
                    ? null
                    : [ap.LocalizedText(language: 'id-ID', text: releaseNotes.trim())],
              ),
            ]),
            packageName,
            editId,
            track,
          );
      bool draftOnly(Object e) => '$e'.contains('draft app') || '$e'.contains('status draft');

      log(trL('Mengatur track "{0}" (status: {1})...', [track, staged ? 'inProgress ${(fraction * 100).round()}%' : releaseStatus]));
      try {
        await setTrack(releaseStatus);
        log('Commit edit...');
        await api.edits.commit(packageName, editId);
      } catch (e) {
        // Aplikasi yang belum pernah dipublikasikan ("Draf" di Play Console) hanya menerima rilis draft.
        if (releaseStatus == 'draft' || !draftOnly(e)) rethrow;
        log('ℹ ${trL('Aplikasi masih Draf di Play Console — Google hanya menerima rilis berstatus draft. Diulang otomatis sebagai draft.')}');
        await setTrack('draft');
        log('Commit edit...');
        await api.edits.commit(packageName, editId);
        lastUploadWasDraft = true;
      }
      return code;
    } finally {
      client.close();
    }
  }

  static String _mime(File f) =>
      f.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';

  /// Sinkron listing (teks + gambar), detail kontak, dan tester pengujian tertutup.
  // ───────────────────────── Staged rollout & monitoring
  /// Rilis di track (urut versionCode terbaru dulu): (versionCode, status, fraction 0–1, nama).
  static Future<List<({int code, String status, double fraction, String name})>> trackReleases(String jsonPath, String packageName, String track) async {
    final client = await _client(jsonPath);
    try {
      final api = ap.AndroidPublisherApi(client);
      final edit = await api.edits.insert(ap.AppEdit(), packageName);
      try {
        final t = await api.edits.tracks.get(packageName, edit.id!, track);
        final out = [
          for (final r in t.releases ?? const <ap.TrackRelease>[])
            for (final c in r.versionCodes ?? const <String>[])
              (code: int.tryParse(c) ?? 0, status: r.status ?? '', fraction: r.userFraction ?? (r.status == 'completed' ? 1.0 : 0.0), name: r.name ?? ''),
        ]..sort((a, b) => b.code.compareTo(a.code));
        return out;
      } finally {
        try {
          await api.edits.delete(packageName, edit.id!);
        } catch (_) {}
      }
    } finally {
      client.close();
    }
  }

  /// Ubah rilis: status inProgress (naikkan %), halted (hentikan), completed (100%).
  static Future<void> updateRelease(String jsonPath, String packageName, String track, int versionCode,
      {required String status, double? fraction}) async {
    final client = await _client(jsonPath);
    try {
      final api = ap.AndroidPublisherApi(client);
      final edit = await api.edits.insert(ap.AppEdit(), packageName);
      final t = await api.edits.tracks.get(packageName, edit.id!, track);
      final releases = t.releases ?? <ap.TrackRelease>[];
      final target = releases.where((r) => (r.versionCodes ?? const []).contains('$versionCode')).firstOrNull;
      if (target == null) {
        await api.edits.delete(packageName, edit.id!);
        throw Exception('versionCode $versionCode tidak ada di track $track');
      }
      target.status = status;
      target.userFraction = status == 'completed' ? null : (fraction ?? target.userFraction);
      await api.edits.tracks.update(ap.Track(track: track, releases: releases), packageName, edit.id!, track);
      await api.edits.commit(packageName, edit.id!);
    } finally {
      client.close();
    }
  }

  /// Crash rate & ANR rate harian dari Play Developer Reporting API (data tertunda ±1–2 hari).
  /// Hasil: {'crash': [(tanggal, rate, userPerceived, users)], 'anr': [...]}; rate dalam persen.
  static Future<Map<String, List<({String date, double rate, double perceived, int users})>>> vitals(
      String jsonPath, String packageName, {int days = 14, int? versionCode}) async {
    final client = await PlayAuth.reportingClient(jsonPath);
    try {
      final end = DateTime.now().subtract(const Duration(days: 1));
      final start = end.subtract(Duration(days: days));
      Map<String, Object> d(DateTime t) => {'year': t.year, 'month': t.month, 'day': t.day, 'timeZone': {'id': 'America/Los_Angeles'}};
      final out = <String, List<({String date, double rate, double perceived, int users})>>{};
      for (final (key, metric) in [('crash', 'crashRate'), ('anr', 'anrRate')]) {
        final up = 'userPerceived${metric[0].toUpperCase()}${metric.substring(1)}';
        final body = {
          'timelineSpec': {'aggregationPeriod': 'DAILY', 'startTime': d(start), 'endTime': d(end)},
          'metrics': [metric, up, 'distinctUsers'],
          if (versionCode != null) 'dimensions': ['versionCode'],
          if (versionCode != null) 'filter': 'versionCode = $versionCode',
        };
        final r = await client.post(
          Uri.parse('https://playdeveloperreporting.googleapis.com/v1beta1/apps/$packageName/${metric}MetricSet:query'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        );
        if (r.statusCode >= 300) {
          throw Exception('Play Developer Reporting API HTTP ${r.statusCode}: ${r.body.length > 300 ? r.body.substring(0, 300) : r.body}');
        }
        final rows = (jsonDecode(r.body)['rows'] as List?) ?? const [];
        out[key] = [
          for (final row in rows)
            () {
              final t = row['startTime'] ?? {};
              double v(String m) => double.tryParse('${(row['metrics'] as List).firstWhere((x) => x['metric'] == m, orElse: () => {})['decimalValue']?['value'] ?? 0}') ?? 0;
              return (
                date: '${t['year']}-${'${t['month']}'.padLeft(2, '0')}-${'${t['day']}'.padLeft(2, '0')}',
                rate: v(metric) * 100,
                perceived: v(up) * 100,
                users: v('distinctUsers').round(),
              );
            }(),
        ];
      }
      return out;
    } finally {
      client.close();
    }
  }

  static Future<void> syncStore({
    required String jsonPath,
    required String packageName,
    required StoreMeta meta,
    required bool images,
    required List<String> testerGroups,
    required String testerTrack,
    required void Function(String) log,
  }) async {
    final client = await _client(jsonPath);
    try {
      final api = ap.AndroidPublisherApi(client);
      final edit = await api.edits.insert(ap.AppEdit(), packageName);
      final editId = edit.id!;

      final d = meta.details;
      if (d.isNotEmpty && !d.containsKey('_error')) {
        await api.edits.details.update(
          ap.AppDetails(
            contactEmail: d['contactEmail'] as String?,
            contactWebsite: (d['contactWebsite'] as String?)?.isEmpty == true ? null : d['contactWebsite'] as String?,
            contactPhone: (d['contactPhone'] as String?)?.isEmpty == true ? null : d['contactPhone'] as String?,
            defaultLanguage: d['defaultLanguage'] as String?,
          ),
          packageName,
          editId,
        );
        log('✔ ${trL('Detail kontak')}: ${d['contactEmail']}');
      }

      for (final l in meta.listings) {
        await api.edits.listings.update(
          ap.Listing(
            language: l.language,
            title: l.title,
            shortDescription: l.shortDescription,
            fullDescription: l.fullDescription,
            video: l.video.isEmpty ? null : l.video,
          ),
          packageName,
          editId,
          l.language,
        );
        log('✔ Listing ${l.language}: "${l.title}"');

        if (!images) continue;
        final sets = <String, List<File>>{
          if (l.icon != null) 'icon': [l.icon!],
          if (l.featureGraphic != null) 'featureGraphic': [l.featureGraphic!],
          ...l.screenshots,
        };
        for (final entry in sets.entries) {
          await api.edits.images.deleteall(packageName, editId, l.language, entry.key);
          for (final f in entry.value) {
            final len = await f.length();
            await api.edits.images.upload(packageName, editId, l.language, entry.key,
                uploadMedia: ap.Media(f.openRead(), len, contentType: _mime(f)));
          }
          log('✔ ${trL('Gambar')} ${l.language}/${entry.key}: ${entry.value.length} file');
        }
      }

      if (testerGroups.isNotEmpty) {
        await api.edits.testers.update(
            ap.Testers(googleGroups: testerGroups), packageName, editId, testerTrack);
        log('✔ Tester track "$testerTrack": ${testerGroups.join(', ')}');
      }

      log(trL('Commit perubahan listing...'));
      await api.edits.commit(packageName, editId);
    } finally {
      client.close();
    }
  }

  /// Upload formulir Keamanan Data (CSV hasil export Play Console).
  static Future<void> uploadDataSafety(String jsonPath, String packageName, String csv) async {
    final client = await _client(jsonPath);
    try {
      final api = ap.AndroidPublisherApi(client);
      await api.applications
          .dataSafety(ap.SafetyLabelsUpdateRequest(safetyLabels: csv), packageName);
    } finally {
      client.close();
    }
  }
}
