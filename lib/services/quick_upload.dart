import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import '../core/i18n.dart';
import '../models.dart';
import '../utils.dart';
import 'aab_inspect.dart';
import 'aab_report.dart';
import 'mac_service.dart';
import 'pipeline.dart';
import 'play_auth.dart';
import 'play_service.dart';
import 'release_checks.dart';

class QuickUploadOptions {
  QuickUploadOptions({required this.file, required this.project});
  final File file;
  final Project project; // proyek terdaftar, atau proyek sementara (hanya package / bundle ID)
  String track = 'internal';
  String releaseStatus = 'completed';
  String releaseNotes = '';
  // IPA
  bool submitReview = false; // setelah TestFlight, kirim versi ini untuk review App Store (fastlane)
  String bundleId = '';
  String appVersion = '';
  String buildNumber = '';
  bool get isIpa => file.path.toLowerCase().endsWith('.ipa');

  /// Deploy "Build siap": cek kelayakan rilis + laporan AAB + persetujuan sebelum upload.
  bool fullChecks = false;
  String demoPassword = '';
  String commit = '';
  DateTime? builtAt;
}

/// Cek kelayakan rilis untuk deploy build siap — masalah dicatat (bukan langsung gagal)
/// supaya semuanya tampil sekaligus di panel persetujuan.
PipelineStep _releaseCheckStep(QuickUploadOptions o, AppSettings s, {required bool android}) =>
    PipelineStep(android ? tr('Cek kelayakan rilis') : tr('Cek kelayakan rilis (iOS)'), (r) async {
      final checker = ReleaseChecker(o.project, s, demoPassword: o.demoPassword, log: r.log);
      await checker.runAll(android: android, ios: !android, track: android ? o.track : '');
      r.log(trL('Hasil: {0} gagal, {1} peringatan, {2} pemeriksaan', [checker.failCount, checker.warnCount, checker.results.length]));
      r.vars['checkFails'] = checker.results.where((c) => c.level == CheckLevel.fail).map((c) => '${c.category}: ${c.title}').join('\n');
      r.vars['checkWarns'] = '${checker.warnCount}';
      if (checker.failCount > 0) r.log('⚠ ${trL('{0} pemeriksaan gagal — lihat panel persetujuan sebelum upload.', [checker.failCount])}');
    }, enabled: o.fullChecks);

/// Panel persetujuan: ringkasan + semua masalah → klik "Upload sekarang" / "Jangan upload".
PipelineStep _approvalStep(QuickUploadOptions o, {required String target}) => PipelineStep(tr('Persetujuan upload'), (r) async {
      final blockers = <String>[
        for (final l in (r.vars['checkFails'] ?? '').split('\n')) if (l.isNotEmpty) trL('Cek kelayakan: {0}', [l]),
        for (final l in (r.vars['aabFails'] ?? '').split('\n')) if (l.isNotEmpty) trL('Laporan AAB: {0}', [l]),
      ];
      final info = <String>[
        trL('Build {0}{1}{2}', [
          r.version,
          o.commit.isEmpty ? '' : ' • commit ${o.commit.length > 7 ? o.commit.substring(0, 7) : o.commit}',
          o.builtAt == null ? '' : ' • ${trL('dibuat {0}', [o.builtAt!.toString().substring(0, 16)])}',
        ]),
        if (r.vars['versionOk'] != null) r.vars['versionOk']!,
        if ((int.tryParse(r.vars['checkWarns'] ?? '') ?? 0) > 0) trL('{0} peringatan cek kelayakan (tidak menghalangi rilis)', [r.vars['checkWarns']]),
        if ((int.tryParse(r.vars['r8Lowest'] ?? '') ?? -1) >= 0)
          (int.parse(r.vars['r8Lowest']!) < 50 ? trL('⚠ Optimasi R8 terendah {0}% (di bawah 50%)', [r.vars['r8Lowest']]) : trL('Optimasi R8 terendah {0}% ✔', [r.vars['r8Lowest']])),
        trL('Tujuan: {0}', [target]),
      ];
      final ok = await r.waitApproval(blockers: blockers, info: info);
      if (!ok) {
        r.log('⏹ ${trL('Tidak diupload. Build tetap tersimpan dan bisa dideploy nanti.')}');
        r.summary = '${r.version} • ${trL('tidak diupload')}';
        r.stopRequested = true;
        return;
      }
      r.log('✔ ${trL('Upload disetujui')}');
    }, enabled: o.fullChecks);

/// Langkah upload file yang sudah jadi (tanpa build).
List<PipelineStep> quickUploadSteps(QuickUploadOptions o, AppSettings s, String macPassword) {
  final pr = o.project;
  if (!o.isIpa) {
    return [
      PipelineStep(tr('Periksa file AAB'), (r) async {
        if (!await o.file.exists()) throw PipelineError(trL('File tidak ditemukan: {0}', [o.file.path]));
        final info = await inspectBinary(o.file);
        if (info.error.isNotEmpty) throw PipelineError(info.error);
        r.log('File    : ${o.file.path} (${fmtMb(info.size)})');
        r.log('Package : ${info.packageName.isEmpty ? '?' : info.packageName}');
        r.log('${trL('Versi')}   : ${info.versionName}+${info.versionCode}');
        r.version = '${info.versionName}+${info.versionCode}';
        switch (info.sign) {
          case SignState.debug:
            throw PipelineError(trL('AAB ditandatangani dengan DEBUG key — Google Play pasti menolak. Build ulang dengan keystore upload.'));
          case SignState.unsigned:
            throw PipelineError(trL('AAB belum ditandatangani — Google Play pasti menolak.'));
          case SignState.upload:
            r.log('✔ ${trL('Ditandatangani dengan upload key ({0})', [info.signer])}');
          case SignState.unknown:
            break;
        }
        if (info.packageName.isNotEmpty && pr.packageName.isNotEmpty && info.packageName != pr.packageName) {
          throw PipelineError(trL('Package di file ({0}) berbeda dengan package tujuan ({1})', [info.packageName, pr.packageName]));
        }
        if (!await PlayAuth.available(pr)) {
          throw PipelineError(trL('Google Play belum terhubung. Buka Pengaturan → Akun & Koneksi.'));
        }
        // Jangan mengulang versi yang sudah ada di Google Play
        final pv = await PlayService.versions(pr.serviceAccountPath, pr.packageName.isEmpty ? info.packageName : pr.packageName);
        final code = int.tryParse(info.versionCode) ?? 0;
        if (pv.error.isEmpty) {
          r.log('${trL('versionCode tertinggi di Google Play')}: ${pv.maxCode}');
          if (code > 0 && code <= pv.maxCode) {
            throw PipelineError(o.fullChecks
                ? trL('versionCode {0} sudah dipakai di Google Play (tertinggi {1}) — build ini sudah kedaluwarsa. Klik "Build AAB sekarang" di kartu proyek untuk build baru (versionCode dihitung otomatis).', [code, pv.maxCode])
                : trL('versionCode {0} sudah dipakai / lebih kecil dari yang ada di Google Play (tertinggi {1}). Ubah version di pubspec.yaml menjadi {2}+{3} lalu build ulang.',
                    [code, pv.maxCode, info.versionName, pv.maxCode + 1]));
          }
          r.log('✔ ${trL('versionCode {0} belum pernah dipakai', [code])}');
          r.vars['versionOk'] = trL('versionCode {0} belum pernah dipakai (tertinggi di Play: {1}) ✔', [code, pv.maxCode]);
        } else {
          r.log('⚠ ${trL('Versi di Google Play tidak bisa dicek: {0}', [pv.error])}');
        }
      }),
      PipelineStep(tr('Laporan AAB (seperti Play Console)'), (r) async {
        final rep = await analyzeAab(o.file, track: o.track, minTargetSdk: s.minTargetSdk, projectRoot: o.project.localPath);
        await saveReport(r.id, rep);
        logReport(rep, r.log);
        r.vars['r8Lowest'] = '${(rep.r8.lowest ?? -1).round()}';
        if (o.fullChecks) {
          r.vars['aabFails'] = rep.findings.where((f) => f.level == 'fail').map((f) => '${f.group}: ${f.title}').join('\n');
        } else if (rep.failCount > 0) {
          throw PipelineError(trL('{0} masalah di AAB yang pasti ditolak Google Play — lihat Laporan AAB', [rep.failCount]));
        }
      }),
      _releaseCheckStep(o, s, android: true),
      _approvalStep(o, target: 'Google Play — ${o.track} (${o.releaseStatus})'),
      PipelineStep(tr('Upload ke Google Play'), (r) async {
        final code = await PlayService.uploadBundle(
          jsonPath: pr.serviceAccountPath,
          packageName: pr.packageName,
          aab: o.file,
          track: o.track,
          releaseStatus: o.releaseStatus,
          releaseNotes: o.releaseNotes,
          log: r.log,
        );
        r.track = o.track;
        r.vars['uploaded'] = '1';
        if (PlayService.lastUploadWasDraft) {
          r.vars['playDraft'] = '1';
          r.log('⚠ ${trL('versionCode {0} masuk ke "{1}" sebagai DRAFT — BELUM dipublikasikan.', [code, o.track])}');
          r.log('   ${trL('Solusi (SEKALI saja): Play Console → Uji dan rilis → Pengujian internal → rilis draft → Simpan dan publikasikan. Setelah itu upload berikutnya langsung terpublikasi otomatis.')}');
          r.summary = 'Google Play ${o.track} • versionCode $code • ⚠ ${trL('draft — klik "Simpan dan publikasikan" di Play Console')}';
        } else {
          r.log('✔ ${trL('versionCode {0} DIPUBLIKASIKAN ke track "{1}"', [code, o.track])}');
          r.summary = 'Google Play ${o.track} • versionCode $code • ${trL('terpublikasi')}';
        }
      }),
    ];
  }

  final keyId = pr.ascKeyId.isNotEmpty ? pr.ascKeyId : s.ascKeyId;
  final issuer = pr.ascIssuerId.isNotEmpty ? pr.ascIssuerId : s.ascIssuerId;
  final remote = 'deployhub_upload/${p.basename(o.file.path).replaceAll(' ', '_')}';
  return [
    PipelineStep(tr('Periksa file IPA'), (r) async {
      if (!await o.file.exists()) throw PipelineError(trL('File tidak ditemukan: {0}', [o.file.path]));
      final info = await inspectBinary(o.file);
      if (info.error.isNotEmpty) throw PipelineError(info.error);
      r.log('File: ${o.file.path} (${fmtMb(info.size)})');
      if (s.macHost.isEmpty || s.macUser.isEmpty) throw PipelineError(trL('Host/user MacBook belum diisi di Pengaturan'));
      if (keyId.isEmpty || issuer.isEmpty) throw PipelineError(trL('App Store Connect Key ID / Issuer ID belum diisi'));
    }),
    _releaseCheckStep(o, s, android: false),
    _approvalStep(o, target: o.submitReview ? 'TestFlight + review App Store' : 'TestFlight'),
    PipelineStep(tr('Konek ke MacBook (SSH)'), (r) async {
      r.ssh = await MacService.connect(s, password: macPassword);
      r.log('✔ ${trL('Terhubung')}');
    }),
    PipelineStep(tr('Kirim IPA ke MacBook'), (r) async {
      await r.mac('mkdir -p ~/deployhub_upload ~/.appstoreconnect/private_keys', inProject: false);
      final sftp = await r.ssh!.sftp();
      Future<void> put(String path, List<int> bytes) async {
        final f = await sftp.open(path, mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
        await f.writeBytes(Uint8List.fromList(bytes));
        await f.close();
      }

      try {
        await put(remote, await o.file.readAsBytes());
        if (s.ascP8Path.isNotEmpty) {
          final p8 = await File(s.ascP8Path).readAsString();
          await put('.appstoreconnect/private_keys/AuthKey_$keyId.p8', utf8.encode(p8));
          await put('.appstoreconnect/deployhub_api_key.json',
              utf8.encode(jsonEncode({'key_id': keyId, 'issuer_id': issuer, 'key': p8, 'in_house': false})));
        }
      } finally {
        sftp.close();
      }
      r.log('✔ ~/$remote');
    }),
    PipelineStep(tr('Upload ke App Store Connect (TestFlight)'), (r) async {
      await r.mac('xcrun altool --upload-app --type ios --file ~/${shq(remote)} --apiKey ${shq(keyId)} --apiIssuer ${shq(issuer)}',
          inProject: false);
      await r.mac('rm -f ~/${shq(remote)}', inProject: false, allowFail: true);
      r.log('✔ ${trL('Build terkirim. Apple memproses build 5–30 menit, lalu muncul di TestFlight.')}');
      r.track = 'testflight';
      r.vars['uploaded'] = '1';
      r.summary = 'TestFlight ${o.appVersion}+${o.buildNumber} • ${trL('upload file')}';
    }),
    PipelineStep(tr('Kirim ke review App Store (fastlane)'), (r) async {
      final has = await r.macOut('command -v fastlane || echo NONE', inProject: false);
      if (has.endsWith('NONE')) {
        throw PipelineError(trL(
            'fastlane belum terpasang di MacBook. Jalankan di Mac: brew install fastlane — atau kirim review manual di App Store Connect.'));
      }
      r.log(trL('Menunggu Apple selesai memproses build lalu mengirim versi {0} untuk review...', [o.appVersion]));
      final deliver = 'fastlane deliver --api_key_path ~/.appstoreconnect/deployhub_api_key.json '
          '--app_identifier ${shq(o.bundleId)} --app_version ${shq(o.appVersion)} --build_number ${shq(o.buildNumber)} '
          '--submit_for_review true --automatic_release false --force true '
          '--skip_screenshots true --skip_metadata true --skip_binary_upload true '
          '--precheck_include_in_app_purchases false '
          "--submission_information '{\"add_id_info_uses_idfa\": false}'";
      await r.mac(
        'ok=0; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do '
        'if $deliver; then ok=1; break; fi; '
        'echo "Build belum siap di App Store Connect, coba lagi 2 menit (\$i/12)..."; sleep 120; '
        'done; [ \$ok = 1 ]',
        inProject: false,
      );
      r.log('✔ ${trL('Versi {0} dikirim untuk review App Store. Apple biasanya mereview 1–2 hari.', [o.appVersion])}');
      r.track = 'appstore';
      r.summary = 'App Store review ${o.appVersion}+${o.buildNumber} • ${trL('upload file')}';
    }, enabled: o.submitReview),
  ];
}
