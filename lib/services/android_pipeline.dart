import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/i18n.dart';
import '../models.dart';
import '../utils.dart';
import 'aab_report.dart';
import 'build_optimizer.dart';
import 'github_service.dart';
import 'gradle_fixer.dart';
import 'integrations.dart';
import 'ai_fixer.dart';
import 'osv_scan.dart';
import 'security_scan.dart';
import 'project_doctor.dart';
import 'keystore_tool.dart';
import 'pipeline.dart';
import 'play_auth.dart';
import 'play_service.dart';
import 'release_checks.dart';
import 'store_metadata.dart';
import 'storage.dart';
import 'version.dart';
import 'devops_setup.dart';

class AndroidOptions {
  String mode; // internal (uji cepat) | production (optimal: R8, shrink, obfuscate)
  bool applyR8; // mode produksi: aktifkan R8 + shrinkResources di build.gradle (dengan backup)
  String track; // internal | alpha | beta | production
  String releaseStatus; // completed | draft
  String releaseNotes;
  bool gitPull;
  bool analyze;
  bool test;
  bool bumpVersion;
  bool upload;
  bool gitTag;
  bool githubRelease;
  bool releaseChecks;
  bool integrationTest;
  bool syncStore;
  bool syncImages;
  bool askBeforeUpload; // cek & build dulu, upload baru jalan setelah disetujui
  /// Build siap deploy (tanpa upload): versionCode dihitung dari Google Play supaya tidak bentrok,
  /// pubspec.yaml dikembalikan seperti semula setelah build (repo tetap bersih untuk git pull berikutnya).
  bool readyBuild;
  /// Lingkungan: dev | staging | prod → --dart-define-from-file=env/<env>.json (kalau file ada)
  String env;
  /// Production: persentase pengguna yang menerima rilis (staged rollout). 100 = semua.
  int rolloutPercent;

  AndroidOptions({
    this.mode = 'internal',
    this.applyR8 = true,
    this.track = 'internal',
    this.releaseStatus = 'completed',
    this.releaseNotes = '',
    this.gitPull = false,
    this.analyze = true,
    this.test = true,
    this.bumpVersion = true,
    this.upload = true,
    this.gitTag = false,
    this.githubRelease = false,
    this.releaseChecks = true,
    this.integrationTest = false,
    this.syncStore = true,
    this.syncImages = true,
    this.askBeforeUpload = true,
    this.readyBuild = false,
    this.env = 'prod',
    this.rolloutPercent = 100,
  });
}

/// Semua file di lib/ yang ikut dikompilasi: ditelusuri dari lib/main.dart lewat import/export/part.
/// null kalau main.dart tidak ada (dianggap semua file dipakai).
Future<Set<String>?> _reachableFromMain(String root) async {
  final main = File(p.join(root, 'lib', 'main.dart'));
  if (!await main.exists()) return null;
  final pub = await File(p.join(root, 'pubspec.yaml')).readAsString().catchError((_) => '');
  final pkg = RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(pub)?.group(1) ?? '';
  final seen = <String>{};
  final queue = <String>['lib/main.dart'];
  final dirRe = RegExp(r'''^\s*(import|export|part)\s+[^;]*;''', multiLine: true);
  final strRe = RegExp(r'''['"]([^'"]+\.dart)['"]''');
  while (queue.isNotEmpty) {
    final rel = queue.removeLast();
    if (!seen.add(rel)) continue;
    final f = File(p.join(root, rel));
    if (!await f.exists()) continue;
    final src = await f.readAsString();
    for (final d in dirRe.allMatches(src)) {
      for (final m in strRe.allMatches(d.group(0)!)) {
        final u = m.group(1)!;
        String? target;
        if (u.startsWith('package:$pkg/')) {
          target = 'lib/${u.substring('package:$pkg/'.length)}';
        } else if (!u.contains(':')) {
          target = p.posix.normalize(p.posix.join(p.posix.dirname(rel), u));
        }
        if (target != null && !seen.contains(target)) queue.add(target);
      }
    }
  }
  return seen;
}

Future<File?> _findNewestAab(String root) async {
  final dir = Directory(p.join(root, 'build', 'app', 'outputs', 'bundle'));
  if (!await dir.exists()) return null;
  final files = await dir
      .list(recursive: true)
      .where((e) => e is File && e.path.endsWith('.aab'))
      .cast<File>()
      .toList();
  if (files.isEmpty) return null;
  files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  return files.first;
}

List<PipelineStep> androidSteps(Project pr, AndroidOptions o, AppSettings settings,
    {String githubToken = '', String demoPassword = ''}) {
  final root = pr.localPath;
  File pubspec() => File(p.join(root, 'pubspec.yaml'));

  Future<void> needPlay() async {
    if (pr.packageName.isEmpty) throw PipelineError(trL('Package name belum diisi'));
    if (!await PlayAuth.available(pr)) {
      throw PipelineError(trL('Google Play belum terhubung. Buka Pengaturan → Akun & Koneksi.'));
    }
  }

  return [
    PipelineStep(tr('Cek konfigurasi'), (r) async {
      if (!await pubspec().exists()) {
        throw PipelineError(trL('pubspec.yaml tidak ditemukan di {0}', [root]));
      }
      if (o.upload) await needPlay();
      if (o.githubRelease && (!pr.hasGithub || githubToken.isEmpty)) {
        throw PipelineError(trL('GitHub Release butuh owner/repo dan token GitHub di Pengaturan'));
      }
      // Periksa & perbaiki file project: keystore, key.properties, local.properties, pubspec, Gradle, manifest
      var firstUpload = false;
      if (o.upload) {
        try {
          final pv = await PlayService.versions(pr.serviceAccountPath, pr.packageName);
          firstUpload = pv.error.isEmpty && pv.maxCode == 0;
        } catch (_) {}
      }
      final doc = await projectDoctor(root,
          packageName: pr.packageName,
          projectId: pr.id,
          projectName: pr.name,
          flutterCmd: settings.flutterCmd,
          keytool: settings.keytoolCmd,
          allowNewKeystore: firstUpload || !o.upload);
      for (final m in doc.fixed) {
        r.log('🔧 ${trL('Diperbaiki otomatis')}: $m');
      }
      for (final w in doc.warnings) {
        r.log('⚠ $w');
      }
      if (doc.ok.isNotEmpty) r.log('✔ ${trL('Sudah benar')}: ${doc.ok.join(', ')}');
      if (!await hasReleaseSigning(root)) {
        if (o.upload) {
          throw PipelineError(trL('Keystore belum diatur — Google Play pasti menolak AAB bertanda debug key. Lihat baris ⚠ di atas.'));
        }
        r.log('⚠ ${trL('android/key.properties tidak ada — AAB bisa tertanda debug key dan ditolak Play Store.')}');
      }
      final v = readVersion(await pubspec().readAsString());
      if (v != null) r.version = v.toString();
      r.log('${trL('Proyek')}  : $root');
      r.log('Package : ${pr.packageName}');
      r.log('${trL('Versi')}   : ${r.version}');
    }),
    PipelineStep(tr('Pasang google-services.json'), (r) async {
      final dst = File(p.join(root, 'android', 'app', 'google-services.json'));
      await File(pr.googleServicesJsonPath).copy(dst.path);
      r.log('✔ ${trL('Disalin ke {0}', [dst.path])}');
    }, enabled: pr.googleServicesJsonPath.isNotEmpty),
    PipelineStep('Git pull', (r) => r.git(['pull', 'origin', pr.branch], cwd: root), enabled: o.gitPull),
    PipelineStep('flutter pub get', (r) => r.flutter(['pub', 'get'], cwd: root)),
    PipelineStep(tr('Cek kelayakan rilis'), (r) async {
      final checker = ReleaseChecker(pr, settings, demoPassword: demoPassword, log: r.log);
      await checker.runAll(android: true, ios: false, track: o.upload ? o.track : '');
      r.log(trL('Hasil: {0} gagal, {1} peringatan, {2} pemeriksaan',
          [checker.failCount, checker.warnCount, checker.results.length]));
      if (checker.failCount > 0) {
        final fails = checker.results.where((c) => c.level == CheckLevel.fail).map((c) => '${c.category}: ${c.title}').toList();
        if (o.upload && !o.askBeforeUpload) {
          throw PipelineError(trL(
              '{0} pemeriksaan gagal — perbaiki dulu sebelum rilis (atau matikan "Cek kelayakan rilis" untuk build tes)',
              [checker.failCount]));
        }
        // Mode cek dulu: catat, lanjut build supaya semua masalah terlihat sekaligus
        r.vars['checkFails'] = fails.join('\n');
        r.log('⚠ ${trL('{0} pemeriksaan gagal — dicatat, build tetap dilanjutkan. Upload hanya bisa setelah kamu setujui.', [checker.failCount])}');
      }
    }, enabled: o.releaseChecks),
    PipelineStep(tr('Integration test login (akun demo)'), (r) async {
      if (!await Directory(p.join(root, 'integration_test')).exists()) {
        r.log(trL('Folder integration_test/ tidak ada, dilewati.'));
        return;
      }
      if (pr.demoUser.isEmpty || demoPassword.isEmpty) {
        throw PipelineError(trL('Akun demo belum diisi di Edit Proyek'));
      }
      await r.flutter(
        ['test', 'integration_test', '--dart-define=TEST_USER=${pr.demoUser}', '--dart-define=TEST_PASS=$demoPassword'],
        cwd: root,
        display: 'flutter test integration_test --dart-define=TEST_USER=${pr.demoUser} --dart-define=TEST_PASS=********',
      );
    }, enabled: o.integrationTest),
    PipelineStep(
      'flutter analyze',
      // Hanya kode aplikasi (lib/). Folder test/ tidak ikut ke AAB — test bawaan template Flutter
      // yang sudah usang (mis. "MyApp isn't a class") tidak boleh menggagalkan rilis.
      (r) async {
        final start = r.logs.length;
        final code = await r.flutter(['analyze', 'lib', '--no-fatal-infos', '--no-fatal-warnings'], cwd: root, allowFail: true);
        final out = r.logs.sublist(start);
        final errors = out.where((l) => l.trimLeft().startsWith('error ')).toList();
        final warns = out.where((l) => l.trimLeft().startsWith('warning ')).length;
        final infos = out.where((l) => l.trimLeft().startsWith('info ')).length;
        r.log('');
        r.log(trL('Ringkasan analyze: {0} error, {1} warning, {2} info (saran gaya kode — tidak menghalangi rilis)', [errors.length, warns, infos]));
        if (errors.isNotEmpty) {
          // Error di file yang TIDAK di-import dari lib/main.dart tidak ikut di-build (file sisa / tidak dipakai).
          final used = await _reachableFromMain(root);
          final fileRe = RegExp(r' - (lib[\\/][^:]+\.dart):\d+:\d+ - ');
          String? fileOf(String l) => fileRe.firstMatch(l)?.group(1)?.replaceAll('\\', '/');
          final real = errors.where((e) {
            final f = fileOf(e);
            return used == null || f == null || used.contains(f);
          }).toList();
          final unusedFiles = errors.map(fileOf).whereType<String>().where((f) => used != null && !used.contains(f)).toSet();
          if (unusedFiles.isNotEmpty) {
            r.log('');
            r.log('⚠ ${trL('{0} file berisi error tapi TIDAK dipakai aplikasi (tidak di-import dari lib/main.dart) — tidak ikut di-build, jadi tidak menghalangi rilis:', [unusedFiles.length])}');
            for (final f in unusedFiles) {
              r.log('   • $f');
            }
            r.log('   ↳ ${trL('Sebaiknya hapus atau pindahkan file sisa ini keluar dari lib/ supaya project rapi.')}');
          }
          if (real.isNotEmpty) {
            r.log('');
            for (final e in real) {
              r.log('✖ ${e.trim()}');
            }
            final ai = AiFixer.instance;
            if (ai.ready && ai.autoApply && !r.vars.containsKey('aiAnalyze')) {
              r.vars['aiAnalyze'] = '1';
              r.log('');
              r.log('🤖 ${trL('AI memperbaiki error kode lalu analyze diulang…')}');
              try {
                final fx = await ai.fix(root: root, task: 'flutter analyze menemukan error di lib/', logs: real, log: r.log);
                if (fx.explanation.isNotEmpty) r.log('   💬 ${fx.explanation}');
                for (final f in fx.changed) {
                  r.log('   ✔ ${trL('diubah AI')}: $f (backup: $f.deployhub.bak)');
                }
                await ai.runCommands(root, fx.commands, settings.flutterCmd, r.log);
                if (fx.ok) {
                  final s2 = r.logs.length;
                  final c2 = await r.flutter(['analyze', 'lib', '--no-fatal-infos', '--no-fatal-warnings'], cwd: root, allowFail: true);
                  final again = r.logs.sublist(s2).where((l) => l.trimLeft().startsWith('error ')).length;
                  if (c2 == 0 || again == 0) {
                    r.log('✔ ${trL('Error kode sudah diperbaiki AI')}');
                    return;
                  }
                }
              } catch (e) {
                r.log('   ✖ AI: $e');
              }
            }
            throw PipelineError(trL('{0} error di kode lib/ — aplikasi tidak bisa di-build. Perbaiki baris ✖ di atas.', [real.length]));
          }
          r.log('✔ ${trL('Tidak ada error di file yang dipakai aplikasi')}');
          return;
        }
        if (code != 0) r.log('ℹ ${trL('flutter analyze keluar dengan kode {0}, tapi tidak ada error — lanjut.', [code])}');
        r.log('✔ ${trL('Tidak ada error di kode')}');
      },
      enabled: o.analyze,
    ),
    PipelineStep('flutter test', (r) async {
      if (!await Directory(p.join(root, 'test')).exists()) {
        r.log(trL('Folder test/ tidak ada, dilewati.'));
        return;
      }
      // Lewati test bawaan template Flutter ("Counter increments smoke test") yang tidak lagi
      // cocok dengan aplikasimu — kalau hanya itu isinya, tidak ada test milikmu yang dijalankan.
      final tests = await Directory(p.join(root, 'test'))
          .list(recursive: true)
          .where((e) => e is File && e.path.endsWith('_test.dart'))
          .cast<File>()
          .toList();
      final own = <File>[];
      for (final t in tests) {
        final c = await t.readAsString();
        if (c.contains('Counter increments smoke test')) {
          r.log('ℹ ${trL('{0}: test bawaan template Flutter (counter) — dilewati, bukan test aplikasimu. Boleh dihapus.', [p.relative(t.path, from: root)])}');
        } else {
          own.add(t);
        }
      }
      if (own.isEmpty) {
        r.log(trL('Tidak ada test milik aplikasi, dilewati.'));
        return;
      }
      await r.flutter(['test', '--coverage', ...own.map((f) => p.relative(f.path, from: root))], cwd: root);
      final cov = await lcovPercent(File(p.join(root, 'coverage', 'lcov.info')));
      if (cov != null) {
        r.vars['coverage'] = cov.toStringAsFixed(1);
        r.log('📊 ${trL('Coverage: {0}% baris kode dites', [cov.toStringAsFixed(1)])}${pr.minCoverage > 0 ? ' (${trL('minimal {0}%', [pr.minCoverage])})' : ''}');
        if (pr.minCoverage > 0 && cov < pr.minCoverage) {
          throw PipelineError(trL('Coverage {0}% di bawah minimal {1}% — tambah test atau turunkan batas di Edit proyek', [cov.toStringAsFixed(1), pr.minCoverage]));
        }
      }
    }, enabled: o.test),
    PipelineStep(tr('Security scan (rahasia, file sensitif, http)'), (r) async {
      final found = await securityScan(root, git: settings.gitCmd);
      for (final f in found) {
        r.log('${f.level == 'fail' ? '✖' : '⚠'} ${f.text}');
      }
      final fails = found.where((f) => f.level == 'fail').length;
      if (found.isEmpty) r.log('✔ ${trL('Tidak ada rahasia atau file sensitif yang bocor')}');
      if (fails > 0) {
        throw PipelineError(trL('{0} temuan keamanan serius — rahasia tidak boleh ada di kode / repo. Perbaiki baris ✖ di atas.', [fails]));
      }
    }, enabled: Integrations.instance.securityScanOn),
    PipelineStep(tr('Scan kerentanan library (OSV)'), (r) async {
      final res = await osvScan(root).then<({int packages, List<Vuln> vulns})?>((v) => v).catchError((Object e) {
        r.log('⚠ ${trL('Database OSV tidak bisa dihubungi ({0}) — scan dilewati', [e])}');
        return null;
      });
      if (res == null) return;
      if (res.vulns.isEmpty) {
        r.log('✔ ${trL('{0} library diperiksa — tidak ada kerentanan yang diketahui', [res.packages])}');
        return;
      }
      r.log(trL('{0} kerentanan di {1} library:', [res.vulns.length, res.packages]));
      for (final v in res.vulns) {
        r.log('${v.serious ? '✖' : '⚠'} ${v.line}');
      }
      final serious = res.vulns.where((v) => v.serious).toList();
      if (serious.isNotEmpty) {
        // tidak langsung gagal: ditahan di langkah Persetujuan upload (bisa diperbaiki / di-override)
        r.vars['vulnFails'] = [
          for (final v in serious) '${v.severity} ${v.package} ${v.version} (${v.id})${v.fixed.isEmpty ? '' : ' → ${v.fixed}'}'
        ].join('\n');
        r.log('→ ${trL('Perbaiki: naikkan versi di pubspec.yaml lalu jalankan "flutter pub upgrade <nama>"')}');
      }
    }, enabled: Integrations.instance.vulnScanOn),
    PipelineStep(tr('Naikkan versi (build number)'), (r) async {
      final content = await pubspec().readAsString();
      final v = readVersion(content) ??
          (throw PipelineError(trL('Baris "version:" tidak ditemukan di pubspec.yaml')));
      if (o.readyBuild) r.vars['pubspecOrig'] = content;
      var next = v.build + 1;
      if (o.upload || o.readyBuild) {
        try {
          final playMax = await PlayService.maxVersionCode(pr.serviceAccountPath, pr.packageName);
          r.log(trL('versionCode tertinggi di Google Play: {0}', [playMax]));
          if (playMax >= next) next = playMax + 1;
        } catch (e) {
          r.log('⚠ ${trL('Gagal cek versionCode di Play ({0}) — pakai nomor lokal.', [e])}');
        }
      }
      final nv = PubVersion(v.name, next);
      await pubspec().writeAsString(writeVersion(content, nv));
      r.version = nv.toString();
      r.log('${trL('Versi')}: $v → $nv');
    }, enabled: o.bumpVersion),
    PipelineStep(tr('Optimasi produksi (R8 + shrink resources)'), (r) async {
      final res = await ensureR8(root);
      r.log(res.changed ? '✔ ${res.message}' : 'ℹ ${res.message}');
      if (res.backupPath.isNotEmpty) r.log(trL('Backup file asli: {0}', [res.backupPath]));
      r.log(trL('Kalau build gagal karena R8, tambahkan aturan -keep di android/app/proguard-rules.pro atau kembalikan dari backup.'));
    }, enabled: o.mode == 'production' && o.applyR8),
    PipelineStep(o.mode == 'production' ? tr('Build AAB produksi (obfuscate + split debug info)') : tr('Build AAB (release)'), (r) async {
      final extra = splitArgs(pr.extraBuildArgs);
      final envFile = File(p.join(root, 'env', '${o.env}.json'));
      if (await envFile.exists() && !extra.any((a) => a.startsWith('--dart-define-from-file'))) {
        extra.add('--dart-define-from-file=env/${o.env}.json');
        r.log('🌐 ${trL('Lingkungan: {0} (env/{0}.json)', [o.env])}');
      } else if (o.env != 'prod') {
        r.log('⚠ ${trL('env/{0}.json tidak ada — build memakai nilai bawaan. Buat lewat menu proyek → "Siapkan dev / staging / prod".', [o.env])}');
      }
      final prodArgs = <String>[
        if (o.mode == 'production' && !extra.contains('--obfuscate')) '--obfuscate',
        if (o.mode == 'production' && !extra.any((a) => a.startsWith('--split-debug-info')))
          '--split-debug-info=build/symbols/${r.version.replaceAll('+', '-')}',
      ];
      // Perbaikan Gradle otomatis (import Kotlin DSL, applicationId, google-services.json)
      final gf = await fixGradle(root, packageName: pr.packageName);
      for (final m in gf.fixed) {
        r.log('🔧 ${trL('Diperbaiki otomatis')}: $m');
      }
      for (final w in gf.warnings) {
        r.log('⚠ $w');
      }
      // Build; kalau gagal karena error yang dikenal → perbaiki otomatis lalu coba lagi (maks. 3 putaran).
      final tried = <String>{};
      var aiRounds = 0;
      for (var attempt = 1;; attempt++) {
        final start = r.logs.length;
        final int code;
        if (Integrations.instance.dockerOn && Integrations.instance.dockerBuild && attempt == 1 && !await ensureTool('docker', r.log)) {
          r.log('⚠ ${trL('Docker tidak siap — build dilanjutkan langsung di PC ini.')}');
          Integrations.instance.dockerBuild = false;
        }
        if (Integrations.instance.dockerOn && Integrations.instance.dockerBuild) {
          // Build di dalam container → environment selalu sama (Flutter + Android SDK + JDK di image)
          final lp = File(p.join(root, 'android', 'local.properties'));
          final lpBak = await lp.exists() ? await lp.readAsString() : null;
          final cmd = ['flutter pub get', 'flutter build appbundle --release ${[...prodArgs, ...extra].join(' ')}'].join(' && ');
          code = await r.sh('docker', ['run', '--rm', '-v', '$root:/app', '-w', '/app', 'ghcr.io/cirruslabs/flutter:stable', 'bash', '-lc', cmd],
              cwd: root, allowFail: true, display: 'docker run … flutter build appbundle (container)');
          if (lpBak != null) await lp.writeAsString(lpBak); // flutter di container menulis path Linux — kembalikan
        } else {
          code = await r.flutter(['build', 'appbundle', '--release', ...prodArgs, ...extra], cwd: root, allowFail: true);
        }
        if (code == 0) break;
        final out = r.logs.sublist(start);
        final fixes = autoFixesFromLog(out, root: root, packageName: pr.packageName, flutterCmd: settings.flutterCmd)
            .where((f) => !tried.contains(f.problem))
            .toList();
        if (fixes.isEmpty || attempt >= 3) {
          final hint = explainGradleError(out);
          if (hint != null) r.log('💡 $hint');
          // Aturan tidak cukup → AI (kalau diaktifkan di Pengaturan)
          final ai = AiFixer.instance;
          if (ai.ready && ai.autoApply && aiRounds < ai.maxRounds) {
            aiRounds++;
            r.log('');
            r.log('🤖 ${trL('Perbaikan otomatis biasa tidak cukup — AI mencoba memperbaiki (putaran {0}/{1})', [aiRounds, ai.maxRounds])}');
            try {
              final fx = await ai.fix(root: root, task: 'flutter build appbundle --release gagal', logs: out, log: r.log);
              if (fx.explanation.isNotEmpty) r.log('   💬 ${fx.explanation}');
              for (final f in fx.changed) {
                r.log('   ✔ ${trL('diubah AI')}: $f (backup: $f.deployhub.bak)');
              }
              await ai.runCommands(root, fx.commands, settings.flutterCmd, r.log);
              if (fx.ok) {
                r.log('');
                continue;
              }
            } catch (e) {
              r.log('   ✖ AI: $e');
            }
          }
          throw PipelineError(trL('flutter build gagal (kode {0})', [code]));
        }
        r.log('');
        r.log('🔧 ${trL('Build gagal karena masalah yang dikenal — diperbaiki otomatis lalu build ulang (percobaan {0}/3):', [attempt + 1])}');
        for (final f in fixes) {
          tried.add(f.problem);
          r.log('   • ${f.problem}');
          try {
            for (final m in await f.run()) {
              r.log('     ✔ $m');
            }
          } catch (e) {
            r.log('     ✖ $e');
          }
        }
        r.log('');
      }
      if (o.mode == 'production') {
        r.log(trL('Simbol debug Dart disimpan di build/symbols/ — simpan untuk membaca stack trace (flutter symbolize).'));
      }
      final aab = await _findNewestAab(root) ??
          (throw PipelineError(trL('File .aab tidak ditemukan setelah build')));
      r.vars['aab'] = aab.path;
      final size = await aab.length();
      r.log('AAB: ${aab.path} (${fmtMb(size)})');
      r.summary = 'AAB ${r.version}';

      final sizes = await Storage.readJson('aab_sizes.json');
      final map = sizes is Map ? Map<String, dynamic>.from(sizes) : <String, dynamic>{};
      final key = '${pr.id}_${o.mode}';
      final prev = (map[key] as num?)?.toInt();
      final checker = ReleaseChecker(pr, settings, demoPassword: '', log: r.log);
      checker.checkAabSize(size, prev);
      final download = await estimateArm64Download(aab);
      final internalSize = (map['${pr.id}_internal'] as num?)?.toInt();
      checker.reportOptimization(
        mode: o.mode,
        aabBytes: size,
        downloadBytes: download,
        internalAabBytes: o.mode == 'production' ? internalSize : null,
      );
      if (download != null) r.summary = 'AAB ${r.version} • ${fmtMb(size)} • ~${fmtMb(download)} download';
      map[key] = size;
      await Storage.writeJson('aab_sizes.json', map);
    }),
    PipelineStep(tr('Upload simbol Crashlytics (stack trace terbaca)'), (r) async {
      if (!await usesCrashlytics(root)) {
        r.log(trL('Crashlytics belum dipasang — menu proyek → "Pasang Crashlytics". Dilewati.'));
        return;
      }
      final appId = await firebaseAndroidAppId(root, pr.packageName);
      final sym = 'build/symbols/${r.version.replaceAll('+', '-')}';
      if (appId == null || !await Directory(p.join(root, sym)).exists()) {
        r.log('⚠ ${trL('App ID Firebase / folder simbol tidak ditemukan — dilewati')}');
        return;
      }
      final code = await r.sh('firebase', ['crashlytics:symbols:upload', '--app=$appId', sym], cwd: root, allowFail: true);
      r.log(code == 0 ? '✔ ${trL('Simbol terupload — crash di Firebase Console terbaca nama fungsi & barisnya')}' : '⚠ ${trL('Upload simbol gagal (login Firebase CLI dulu) — build tetap lanjut')}');
    }, enabled: o.mode == 'production'),
    PipelineStep(tr('Laporan AAB (seperti Play Console)'), (r) async {
      final rep = await analyzeAab(File(r.vars['aab']!), track: o.upload ? o.track : '', minTargetSdk: settings.minTargetSdk, projectRoot: root);
      await saveReport(r.id, rep);
      logReport(rep, r.log);
      r.vars['aabFails'] = rep.findings.where((f) => f.level == 'fail').map((f) => '${f.group}: ${f.title}').join('\n');
      r.vars['r8Lowest'] = '${(rep.r8.lowest ?? -1).round()}';
      if (rep.failCount > 0 && o.upload && !o.askBeforeUpload) {
        throw PipelineError(trL('{0} masalah di AAB yang pasti ditolak Google Play — lihat Laporan AAB', [rep.failCount]));
      }
    }),
    PipelineStep(tr('Simpan artefak rilis'), (r) async {
      final aab = File(r.vars['aab']!);
      final ver = r.version.isEmpty ? 'unknown' : r.version.replaceAll('+', '-');
      final it = Integrations.instance;
      if (it.artifactsOn || o.readyBuild) {
        final dir = Directory(p.join(Storage.dir.path, 'artifacts', pr.packageName.isEmpty ? pr.id : pr.packageName, ver));
        await dir.create(recursive: true);
        await aab.copy(p.join(dir.path, p.basename(aab.path)));
        final map = await findR8Mapping(root);
        if (map != null) await map.copy(p.join(dir.path, 'mapping.txt'));
        final rep = File(reportPath(r.id));
        if (await rep.exists()) await rep.copy(p.join(dir.path, 'aab-report.json'));
        r.vars['artifactDir'] = dir.path;
        r.vars['artifactAab'] = p.join(dir.path, p.basename(aab.path));
        r.log('✔ ${trL('Artefak disimpan')}: ${dir.path}');
      }
      if (it.nexusOn && it.nexusUrl.isNotEmpty) {
        final url = await it.nexusUpload(aab, '${pr.packageName}/$ver/${p.basename(aab.path)}');
        r.log('✔ Nexus/Artifactory: $url');
      }
    }, enabled: Integrations.instance.artifactsOn || Integrations.instance.nexusOn || o.readyBuild),
    PipelineStep(tr('Persetujuan upload'), (r) async {
      final blockers = <String>[
        for (final l in (r.vars['checkFails'] ?? '').split('\n')) if (l.isNotEmpty) trL('Cek kelayakan: {0}', [l]),
        for (final l in (r.vars['aabFails'] ?? '').split('\n')) if (l.isNotEmpty) trL('Laporan AAB: {0}', [l]),
        for (final l in (r.vars['vulnFails'] ?? '').split('\n')) if (l.isNotEmpty) trL('Kerentanan library: {0}', [l]),
      ];
      final info = <String>[];
      var code = int.tryParse(r.version.contains('+') ? r.version.split('+').last : '') ?? 0;
      if (code == 0) {
        final v = readVersion(await pubspec().readAsString());
        if (v != null) {
          code = v.build;
          if (r.version.isEmpty) r.version = v.toString();
        }
      }
      try {
        final pv = await PlayService.versions(pr.serviceAccountPath, pr.packageName);
        if (pv.error.isEmpty) {
          if (code > 0 && code <= pv.maxCode) {
            blockers.add(trL('versionCode {0} sudah dipakai di Google Play (tertinggi {1})', [code, pv.maxCode]));
          } else {
            info.add(trL('Versi {0} — versionCode belum pernah dipakai (tertinggi di Play: {1}) ✔', [r.version, pv.maxCode]));
          }
        } else {
          info.add(trL('Versi di Google Play tidak bisa dicek: {0}', [pv.error]));
        }
      } catch (e) {
        info.add(trL('Versi di Google Play tidak bisa dicek: {0}', [e]));
      }
      final low = int.tryParse(r.vars['r8Lowest'] ?? '') ?? -1;
      if (low >= 0) info.add(low < 50 ? trL('⚠ Optimasi R8 terendah {0}% (di bawah 50%)', [low]) : trL('Optimasi R8 terendah {0}% ✔', [low]));
      info.add(trL('Tujuan: Google Play — {0} ({1})', [o.track, o.releaseStatus]));
      final ok = await r.waitApproval(blockers: blockers, info: info);
      if (!ok) {
        r.log('⏹ ${trL('Tidak diupload. AAB tersimpan di {0}', [r.vars['aab']])}');
        r.summary = '${r.summary} • ${trL('tidak diupload')}';
        r.stopRequested = true;
        return;
      }
      r.log('✔ ${trL('Upload disetujui')}');
    }, enabled: o.upload && o.askBeforeUpload),
    PipelineStep(tr('Upload ke Google Play'), (r) async {
      final code = await PlayService.uploadBundle(
        jsonPath: pr.serviceAccountPath,
        packageName: pr.packageName,
        aab: File(r.vars['aab']!),
        track: o.track,
        releaseStatus: o.releaseStatus,
        releaseNotes: o.releaseNotes,
        fraction: o.track == 'production' && o.rolloutPercent > 0 && o.rolloutPercent < 100 ? o.rolloutPercent / 100 : null,
        log: r.log,
        mapping: o.mode == 'production' ? await findR8Mapping(root) : null,
      );
      r.track = o.track;
      if (PlayService.lastUploadWasDraft) {
        r.vars['playDraft'] = '1';
        r.log('');
        r.log('⚠ ${trL('versionCode {0} masuk ke "{1}" sebagai DRAFT — BELUM dipublikasikan.', [code, o.track])}');
        if (o.releaseStatus == 'draft') {
          r.log('   ${trL('Status rilis dipilih "draft" di dialog Deploy. Pilih "completed" supaya langsung dipublikasikan.')}');
        } else {
          r.log('   ${trL('Penyebab: aplikasi masih berstatus Draf di Play Console (belum pernah dipublikasikan). Aturan Google: lewat API, aplikasi Draf hanya boleh menerima rilis draft — ini bukan error DeployHub.')}');
          r.log('   ${trL('Solusi (SEKALI saja): Play Console → Uji dan rilis → Pengujian internal → rilis draft → Simpan dan publikasikan. Setelah itu upload berikutnya langsung terpublikasi otomatis.')}');
        }
        r.log('   https://play.google.com/console');
        r.summary = 'Google Play ${o.track} • versionCode $code • ⚠ ${trL('draft — klik "Simpan dan publikasikan" di Play Console')}';
      } else {
        r.log('✔ ${trL('versionCode {0} DIPUBLIKASIKAN ke track "{1}"', [code, o.track])}');
        r.summary = 'Google Play ${o.track} • versionCode $code • ${trL('terpublikasi')}';
      }
    }, enabled: o.upload),
    PipelineStep(tr('Sinkron Play Store (listing, gambar, kontak, tester)'), (r) async {
      await needPlay();
      final meta = await loadStoreMeta(pr);
      final groups = pr.testerGroupList;
      if ((meta == null || meta.listings.isEmpty) && groups.isEmpty) {
        r.log(trL('Folder store/ dan Google Group tester belum ada, dilewati.'));
        return;
      }
      await PlayService.syncStore(
        jsonPath: pr.serviceAccountPath,
        packageName: pr.packageName,
        meta: meta ?? StoreMeta(Directory(storeDir(pr))),
        images: o.syncImages,
        testerGroups: groups,
        testerTrack: pr.closedTestTrack,
        log: r.log,
      );
    }, enabled: o.syncStore),
    PipelineStep(tr('Upload Keamanan Data (data_safety.csv)'), (r) async {
      await needPlay();
      final csv = File(p.join(storeDir(pr), 'data_safety.csv'));
      if (!await csv.exists()) {
        r.log(trL('store/data_safety.csv belum ada, dilewati.'));
        return;
      }
      await PlayService.uploadDataSafety(pr.serviceAccountPath, pr.packageName, await csv.readAsString());
      r.log('✔ ${trL('Formulir Keamanan Data diperbarui')}');
    }, enabled: o.syncStore),
    PipelineStep(tr('Git commit, tag & push'), (r) async {
      final tag = 'android-v${r.version.replaceAll('+', '-')}';
      await r.git(['add', 'pubspec.yaml'], cwd: root);
      await r.git(['commit', '-m', 'release(android): ${r.version}'], cwd: root, allowFail: true);
      await r.git(['tag', tag], cwd: root);
      await r.git(['push', 'origin', pr.branch], cwd: root);
      await r.git(['push', 'origin', tag], cwd: root);
      r.vars['tag'] = tag;
    }, enabled: o.gitTag),
    PipelineStep(tr('GitHub Release (lampirkan AAB)'), (r) async {
      final tag = r.vars['tag'] ?? 'android-v${r.version.replaceAll('+', '-')}';
      final url = await GitHubService(githubToken).createReleaseWithAsset(
        owner: pr.githubOwner,
        repo: pr.githubRepo,
        tag: tag,
        name: '${pr.name} Android ${r.version}',
        body: o.releaseNotes,
        target: pr.branch,
        asset: File(r.vars['aab']!),
        assetName: '${pr.name.replaceAll(' ', '_')}-${r.version.replaceAll('+', '-')}.aab',
        log: r.log,
      );
      r.log('✔ Release: $url');
    }, enabled: o.githubRelease),
  ];
}
