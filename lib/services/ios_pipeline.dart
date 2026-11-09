import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import '../core/i18n.dart';
import '../models.dart';
import '../utils.dart';
import 'mac_service.dart';
import 'pipeline.dart';
import 'release_checks.dart';
import 'version.dart';

class IosOptions {
  String mode; // testflight (uji) | appstore (rilis publik, optimal)
  bool releaseChecks;
  bool pushFromPc;
  bool gitPull;
  bool podInstall;
  bool unlockKeychain;
  bool autoBuildNumber; // build number unik otomatis (tanggal-jam)
  String buildNumber; // manual, dipakai kalau autoBuildNumber = false
  bool upload;
  bool submitReview; // mode appstore: kirim ke review App Store (fastlane di MacBook)
  bool downloadIpa; // salin file .ipa ke PC

  IosOptions({
    this.mode = 'testflight',
    this.releaseChecks = true,
    this.pushFromPc = true,
    this.gitPull = true,
    this.podInstall = true,
    this.unlockKeychain = true,
    this.autoBuildNumber = true,
    this.buildNumber = '',
    this.upload = true,
    this.submitReview = true,
    this.downloadIpa = true,
  });
}

/// Upload satu file ke MacBook lewat SFTP (path relatif dihitung dari folder home).
Future<void> _sftpPut(PipelineRun r, String target, List<int> bytes) async {
  final remote = target.startsWith('~/') ? target.substring(2) : target;
  final sftp = await r.ssh!.sftp();
  try {
    final f = await sftp.open(remote, mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
    await f.writeBytes(Uint8List.fromList(bytes));
    await f.close();
  } finally {
    sftp.close();
  }
}

/// Unduh satu file dari MacBook lewat SFTP.
Future<Uint8List> _sftpGet(PipelineRun r, String target) async {
  final remote = target.startsWith('~/') ? target.substring(2) : target;
  final sftp = await r.ssh!.sftp();
  try {
    final f = await sftp.open(remote);
    final bytes = await f.readBytes();
    await f.close();
    return bytes;
  } finally {
    sftp.close();
  }
}

List<PipelineStep> iosSteps(Project pr, IosOptions o, AppSettings s, String macPassword, {String demoPassword = ''}) {
  final keyId = pr.ascKeyId.isNotEmpty ? pr.ascKeyId : s.ascKeyId;
  final issuer = pr.ascIssuerId.isNotEmpty ? pr.ascIssuerId : s.ascIssuerId;
  final production = o.mode == 'appstore';
  final now = DateTime.now();
  final autoBuild = '${now.year}${two(now.month)}${two(now.day)}${two(now.hour)}${two(now.minute)}';
  String buildNumber() => o.autoBuildNumber ? autoBuild : o.buildNumber;

  return [
    PipelineStep(tr('Cek konfigurasi'), (r) async {
      if (s.macHost.isEmpty || s.macUser.isEmpty) {
        throw PipelineError(trL('Host/user MacBook belum diisi di Pengaturan'));
      }
      if (pr.macProjectPath.isEmpty) {
        throw PipelineError(trL('Folder project di MacBook belum diisi (Edit Proyek)'));
      }
      if (o.upload && (keyId.isEmpty || issuer.isEmpty)) {
        throw PipelineError(trL('App Store Connect Key ID / Issuer ID belum diisi'));
      }
      if (production && o.submitReview && (pr.iosBundleId.isEmpty || s.ascP8Path.isEmpty)) {
        throw PipelineError(trL('Kirim review butuh Bundle ID (Edit Proyek → iOS) dan file .p8 (Pengaturan → App Store Connect)'));
      }
      if (o.unlockKeychain && macPassword.isEmpty) {
        r.log('⚠ ${trL('Password Mac kosong — unlock keychain dilewati, codesign bisa gagal lewat SSH.')}');
      }
      final pub = File(p.join(pr.localPath, 'pubspec.yaml'));
      if (await pub.exists()) {
        final v = readVersion(await pub.readAsString());
        if (v != null) r.version = v.toString();
      }
      if (buildNumber().isNotEmpty) r.version = '${r.version.split('+').first}+${buildNumber()}';
      r.log('${trL('Versi')}: ${r.version}');
      r.log('Mode: ${production ? 'App Store' : 'TestFlight'}');
    }),
    PipelineStep(tr('Cek kelayakan rilis (iOS)'), (r) async {
      final checker = ReleaseChecker(pr, s, demoPassword: demoPassword, log: r.log);
      await checker.runAll(android: false, ios: true);
      r.log(trL('Hasil: {0} gagal, {1} peringatan, {2} pemeriksaan',
          [checker.failCount, checker.warnCount, checker.results.length]));
      if (checker.failCount > 0) {
        throw PipelineError(trL('{0} pemeriksaan gagal — perbaiki dulu sebelum rilis', [checker.failCount]));
      }
    }, enabled: o.releaseChecks),
    PipelineStep(tr('Push kode dari PC ke GitHub'), (r) => r.git(['push', 'origin', pr.branch], cwd: pr.localPath),
        enabled: o.pushFromPc),
    PipelineStep(tr('Konek ke MacBook (SSH)'), (r) async {
      r.log(trL('Menghubungkan ke {0}...', ['${s.macUser}@${s.macHost}:${s.macPort}']));
      r.ssh = await MacService.connect(s, password: macPassword);
      r.log('✔ ${trL('Terhubung')}');
      await r.mac(
        'echo "macOS \$(sw_vers -productVersion)"; xcodebuild -version | head -1; flutter --version | head -1',
        inProject: false,
      );
    }),
    PipelineStep(
      tr('Git pull di MacBook'),
      (r) => r.mac('git fetch origin && git checkout ${shq(pr.branch)} && git pull origin ${shq(pr.branch)}'),
      enabled: o.gitPull,
    ),
    PipelineStep(tr('Pasang GoogleService-Info.plist di MacBook'), (r) async {
      final target = '${pr.macProjectPath}/ios/Runner/GoogleService-Info.plist';
      await _sftpPut(r, target, await File(pr.googleServiceInfoPlistPath).readAsBytes());
      r.log('✔ ${trL('Diupload ke {0}', [target])}');
    }, enabled: pr.googleServiceInfoPlistPath.isNotEmpty),
    PipelineStep(tr('Pasang API key App Store Connect di MacBook'), (r) async {
      await r.mac('mkdir -p ~/.appstoreconnect/private_keys', inProject: false);
      final p8 = await File(s.ascP8Path).readAsString();
      await _sftpPut(r, '~/.appstoreconnect/private_keys/AuthKey_$keyId.p8', utf8.encode(p8));
      // file JSON untuk fastlane (kirim review App Store)
      await _sftpPut(r, '~/.appstoreconnect/deployhub_api_key.json',
          utf8.encode(jsonEncode({'key_id': keyId, 'issuer_id': issuer, 'key': p8, 'in_house': false})));
      r.log('✔ ${trL('API key terpasang di ~/.appstoreconnect/')}');
    }, enabled: o.upload && s.ascP8Path.isNotEmpty && keyId.isNotEmpty),
    PipelineStep('flutter pub get + pod install', (r) => r.mac('flutter pub get && cd ios && pod install --repo-update'),
        enabled: o.podInstall),
    PipelineStep(tr('Unlock keychain (untuk codesign)'), (r) async {
      if (macPassword.isEmpty) {
        r.log(trL('Password Mac kosong, dilewati.'));
        return;
      }
      const kc = '~/Library/Keychains/login.keychain-db';
      await r.mac(
        'security unlock-keychain -p ${shq(macPassword)} $kc && security set-keychain-settings -t 3600 -l $kc',
        inProject: false,
        display: 'security unlock-keychain -p ******** $kc',
      );
    }, enabled: o.unlockKeychain),
    PipelineStep(production ? tr('Build IPA produksi (obfuscate + split debug info)') : tr('Build IPA (release)'), (r) async {
      final cmd = StringBuffer('flutter build ipa --release');
      if (pr.iosExportOptions.isNotEmpty) cmd.write(' --export-options-plist=${shq(pr.iosExportOptions)}');
      if (buildNumber().isNotEmpty) cmd.write(' --build-number=${buildNumber()}');
      if (production) cmd.write(' --obfuscate --split-debug-info=build/symbols/ios-${r.version.replaceAll('+', '-')}');
      await r.mac(cmd.toString());
      final ipa = await r.macOut('ls -t build/ios/ipa/*.ipa | head -1');
      final size = int.tryParse(await r.macOut('stat -f%z ${shq(ipa)}')) ?? 0;
      r.vars['ipa'] = ipa;
      r.log('IPA: $ipa (${fmtMb(size)})');
      r.summary = 'IPA ${r.version} • ${fmtMb(size)}';
    }),
    PipelineStep(tr('Salin IPA ke PC'), (r) async {
      final ipa = r.vars['ipa'] ?? '';
      final bytes = await _sftpGet(r, ipa.startsWith('/') ? ipa : '${pr.macProjectPath}/$ipa');
      final dir = Directory(p.join(pr.localPath, 'build', 'ios_from_mac'));
      await dir.create(recursive: true);
      final local = File(p.join(dir.path, '${pr.name.replaceAll(' ', '_')}-${r.version.replaceAll('+', '-')}.ipa'));
      await local.writeAsBytes(bytes);
      r.vars['ipaLocal'] = local.path;
      r.log('✔ ${trL('Disalin ke {0}', [local.path])}');
    }, enabled: o.downloadIpa),
    PipelineStep(tr('Upload ke App Store Connect (TestFlight)'), (r) async {
      await r.mac(
        'xcrun altool --upload-app --type ios --file ${shq(r.vars['ipa'] ?? '')} '
        '--apiKey ${shq(keyId)} --apiIssuer ${shq(issuer)}',
      );
      r.log('✔ ${trL('Build terkirim. Apple memproses build 5–30 menit, lalu muncul di TestFlight.')}');
      r.track = 'testflight';
      r.summary = 'TestFlight ${r.version}';
    }, enabled: o.upload),
    PipelineStep(tr('Kirim ke review App Store (fastlane)'), (r) async {
      final has = await r.macOut('command -v fastlane || echo NONE', inProject: false);
      if (has.endsWith('NONE')) {
        throw PipelineError(trL(
            'fastlane belum terpasang di MacBook. Jalankan di Mac: brew install fastlane — atau kirim review manual di App Store Connect.'));
      }
      final version = r.version.split('+').first;
      r.log(trL('Menunggu Apple selesai memproses build lalu mengirim versi {0} untuk review...', [version]));
      final deliver = 'fastlane deliver --api_key_path ~/.appstoreconnect/deployhub_api_key.json '
          '--app_identifier ${shq(pr.iosBundleId)} --app_version ${shq(version)} --build_number ${shq(buildNumber())} '
          '--submit_for_review true --automatic_release false --force true '
          '--skip_screenshots true --skip_metadata true --skip_binary_upload true '
          '--precheck_include_in_app_purchases false '
          "--submission_information '{\"add_id_info_uses_idfa\": false}'";
      // Build baru perlu diproses Apple dulu — coba ulang tiap 2 menit, maksimal ~24 menit.
      await r.mac(
        'ok=0; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do '
        'if $deliver; then ok=1; break; fi; '
        'echo "Build belum siap di App Store Connect, coba lagi 2 menit (\$i/12)..."; sleep 120; '
        'done; [ \$ok = 1 ]',
        inProject: false,
      );
      r.log('✔ ${trL('Versi {0} dikirim untuk review App Store. Apple biasanya mereview 1–2 hari.', [version])}');
      r.track = 'appstore';
      r.summary = 'App Store review ${r.version}';
    }, enabled: production && o.upload && o.submitReview),
  ];
}
