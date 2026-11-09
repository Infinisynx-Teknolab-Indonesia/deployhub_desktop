import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'services/android_pipeline.dart';
import 'services/github_service.dart';
import 'services/ios_pipeline.dart';
import 'services/pipeline.dart';
import 'services/play_auth.dart';
import 'services/quick_upload.dart';
import 'services/ready_builds.dart';
import 'services/storage.dart';
import 'services/hub_client.dart';
import 'services/hub_sync.dart';
import 'services/integrations.dart';
import 'services/tool_env.dart';

final app = AppState();

class AppState extends ChangeNotifier {
  List<Project> projects = [];
  AppSettings settings = AppSettings();
  List<RunRecord> history = [];
  PipelineRun? currentRun;

  bool get isRunning => currentRun?.isRunning ?? false;

  Future<void> load() async {
    final pj = await Storage.readJson('projects.json');
    if (pj is List) {
      projects = pj.map((e) => Project.fromJson(Map<String, dynamic>.from(e))).toList();
    }
    final st = await Storage.readJson('settings.json');
    if (st is Map) settings = AppSettings.fromJson(Map<String, dynamic>.from(st));
    PlayAuth.settings = settings;
    final hs = await Storage.readJson('history.json');
    if (hs is List) {
      history = hs.map((e) => RunRecord.fromJson(Map<String, dynamic>.from(e))).toList();
    }
  }

  Timer? _syncTimer;

  /// Sinkron dua arah dengan DeployHub Server: kirim deploy PC yang tertunda + tarik deploy server.
  Future<void> syncWithServer() async {
    final changed = await HubSync.instance.run(
      history,
      projects.map((e) => e.id).toSet(),
      {for (final p in projects) p.id: p.name},
    );
    if (changed) {
      if (history.length > 300) history = history.sublist(0, 300);
      await Storage.writeJson('history.json', history.map((e) => e.toJson()).toList());
      notifyListeners();
    }
  }

  /// Sinkron saat aplikasi dibuka, lalu tiap 10 menit selama server diaktifkan.
  void startServerSync() {
    _syncTimer?.cancel();
    unawaited(syncWithServer());
    _syncTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      if (Hub.instance.ready) unawaited(syncWithServer());
    });
  }

  Future<void> upsertProject(Project p) async {
    final i = projects.indexWhere((e) => e.id == p.id);
    if (i >= 0) {
      projects[i] = p;
    } else {
      projects.add(p);
    }
    await Storage.writeJson('projects.json', projects.map((e) => e.toJson()).toList());
    notifyListeners();
  }

  Future<void> deleteProject(String id) async {
    projects.removeWhere((e) => e.id == id);
    await Storage.writeJson('projects.json', projects.map((e) => e.toJson()).toList());
    notifyListeners();
  }

  /// Hapus riwayat deploy (beserta file log & laporan AAB-nya).
  Future<void> deleteHistory(Iterable<String> ids) async {
    final set = ids.toSet();
    for (final r in history.where((r) => set.contains(r.id))) {
      for (final path in [r.logPath, r.logPath.replaceAll(RegExp(r'\.log$'), '.aab.json')]) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    history.removeWhere((r) => set.contains(r.id));
    await HubSync.instance.ignore(set);
    await Storage.writeJson('history.json', history.map((e) => e.toJson()).toList());
    notifyListeners();
  }

  Future<void> saveSettings(AppSettings s) async {
    settings = s;
    PlayAuth.settings = s;
    await Storage.writeJson('settings.json', s.toJson());
    notifyListeners();
  }

  RunRecord? lastRun(String projectId, String platform) {
    for (final r in history) {
      if (r.projectId == projectId && r.platform == platform) return r;
    }
    return null;
  }

  Future<void> startAndroid(Project p, AndroidOptions o) async {
    final token = await Storage.secret(Secrets.github);
    final demoPw = await Storage.secret(Secrets.demoPassword(p.id));
    final run = PipelineRun(
      project: p,
      platform: 'android',
      settings: settings,
      steps: androidSteps(p, o, settings, githubToken: token, demoPassword: demoPw),
    );
    run.rerun = ({bool skipChecks = false}) {
      if (skipChecks) o.releaseChecks = false;
      final fresh = projects.where((x) => x.id == p.id).firstOrNull ?? p; // pakai data proyek terbaru
      return startAndroid(fresh, o);
    };
    _start(run);
  }

  Future<void> startIos(Project p, IosOptions o) async {
    final pw = await Storage.secret(Secrets.macPassword);
    final demoPw = await Storage.secret(Secrets.demoPassword(p.id));
    final run = PipelineRun(
      project: p,
      platform: 'ios',
      settings: settings,
      steps: iosSteps(p, o, settings, pw, demoPassword: demoPw),
    );
    run.rerun = ({bool skipChecks = false}) {
      if (skipChecks) o.releaseChecks = false;
      final fresh = projects.where((x) => x.id == p.id).firstOrNull ?? p;
      return startIos(fresh, o);
    };
    _start(run);
  }

  /// Upload file AAB / IPA yang sudah jadi (tanpa build).
  Future<void> startQuickUpload(QuickUploadOptions o) async {
    final pw = await Storage.secret(Secrets.macPassword);
    final run = PipelineRun(
      project: o.project,
      platform: o.isIpa ? 'ios' : 'android',
      settings: settings,
      steps: quickUploadSteps(o, settings, pw),
    );
    run.rerun = ({bool skipChecks = false}) => startQuickUpload(o);
    _start(run);
  }

  void _start(PipelineRun run) {
    _launch(run);
  }

  /// Jalankan pipeline; Future selesai setelah pipeline (dan penyimpanan riwayat) selesai.
  Future<void> _launch(PipelineRun run) {
    currentRun = run;
    notifyListeners();
    run.addListener(notifyListeners);
    return run.execute().whenComplete(() async {
      run.removeListener(notifyListeners);
      history.insert(0, run.toRecord());
      if (history.length > 300) history = history.sublist(0, 300);
      await Storage.writeJson('history.json', history.map((e) => e.toJson()).toList());
      notifyListeners();
      // sinkron ke DeployHub Server (tidak menghalangi pipeline kalau server mati)
      unawaited(HubSync.instance.report(history.first).then((_) => syncWithServer()));
      await _notifyTelegram(run);
      await Integrations.instance.notify(_notifyText(run));
    });
  }

  Future<void> _notifyTelegram(PipelineRun run) async {
    final token = await Storage.secret(Secrets.telegram);
    if (token.isEmpty || settings.telegramChatId.isEmpty) return;
    final icon = switch (run.status) {
      RunStatus.success => '✅',
      RunStatus.cancelled => '⏹',
      _ => '❌',
    };
    final text = '$icon ${run.project.name} (${run.platform.toUpperCase()}) '
        '${runStatusLabel(run.status)}\n'
        'Versi: ${run.version}\n'
        '${run.summary.isEmpty ? '' : '${run.summary}\n'}'
        'Durasi: ${run.elapsed.inMinutes}m ${run.elapsed.inSeconds % 60}d';
    try {
      await Telegram.send(token, settings.telegramChatId, text);
    } catch (_) {}
  }

  /// Teks notifikasi untuk Discord / Slack / Telegram.
  String _notifyText(PipelineRun run) {
    final icon = switch (run.status) {
      RunStatus.success => '✅',
      RunStatus.cancelled => '⏹',
      _ => '❌',
    };
    final failed = run.steps.where((s) => s.status == StepStatus.failed).map((s) => s.title).firstOrNull;
    return '$icon ${run.project.name} (${run.platform.toUpperCase()}) ${runStatusLabel(run.status)}\n'
        'Versi: ${run.version}\n'
        '${run.summary.isEmpty ? '' : '${run.summary}\n'}'
        '${failed == null ? '' : 'Gagal di: $failed\n'}'
        'Durasi: ${run.elapsed.inMinutes}m ${run.elapsed.inSeconds % 60}d';
  }

  // ───────────────────────── Build siap deploy (otomatis saat GitHub update, deploy manual 1 klik)
  bool _readyBusy = false;

  /// Build AAB (dan IPA kalau iOS diatur) tanpa upload → disimpan sebagai "Build siap deploy".
  Future<void> buildReady(Project p, {bool android = true, bool ios = true, String commit = ''}) async {
    if (isRunning || _readyBusy) return;
    _readyBusy = true;
    final made = <String>[];
    try {
      if (android && p.packageName.isNotEmpty) {
        final o = AndroidOptions(
          mode: 'production', // build final: R8 + shrink + obfuscate
          gitPull: p.useGithub && p.hasGithub,
          upload: false,
          bumpVersion: true,
          readyBuild: true,
          askBeforeUpload: false,
          syncStore: false,
          gitTag: false,
          githubRelease: false,
        );
        final token = await Storage.secret(Secrets.github);
        final demoPw = await Storage.secret(Secrets.demoPassword(p.id));
        final run = PipelineRun(project: p, platform: 'android', settings: settings, steps: androidSteps(p, o, settings, githubToken: token, demoPassword: demoPw));
        run.rerun = ({bool skipChecks = false}) => buildReady(p, ios: false, commit: commit);
        try {
          await _launch(run);
        } finally {
          // repo dikembalikan bersih (versi naik hanya di dalam AAB, tidak di-commit)
          final orig = run.vars['pubspecOrig'];
          if (orig != null) await File('${p.localPath}${Platform.pathSeparator}pubspec.yaml').writeAsString(orig);
        }
        final aab = run.vars['artifactAab'] ?? run.vars['aab'];
        if (run.status == RunStatus.success && aab != null) {
          await ReadyBuilds.instance.put(p.id, ReadyBuild(platform: 'android', path: aab, version: run.version, commit: commit, runId: run.id));
          made.add('Android ${run.version}');
        }
      }
      if (ios && p.useIos && p.hasIos) {
        final o = IosOptions(mode: 'appstore', pushFromPc: false, gitPull: true, upload: false, submitReview: false, downloadIpa: true);
        final pw = await Storage.secret(Secrets.macPassword);
        final demoPw = await Storage.secret(Secrets.demoPassword(p.id));
        final run = PipelineRun(project: p, platform: 'ios', settings: settings, steps: iosSteps(p, o, settings, pw, demoPassword: demoPw));
        run.rerun = ({bool skipChecks = false}) => buildReady(p, android: false, commit: commit);
        await _launch(run);
        final ipa = run.vars['ipaLocal'];
        if (run.status == RunStatus.success && ipa != null) {
          await ReadyBuilds.instance.put(p.id, ReadyBuild(platform: 'ios', path: ipa, version: run.version, commit: commit, runId: run.id));
          made.add('iOS ${run.version}');
        }
      }
    } finally {
      _readyBusy = false;
      notifyListeners();
    }
    if (made.isNotEmpty) {
      await Integrations.instance.notify('📦 ${p.name}: build siap deploy — ${made.join(' • ')}'
          '${commit.isEmpty ? '' : ' (commit ${commit.length > 7 ? commit.substring(0, 7) : commit})'}\nBuka DeployHub → Proyek → klik Deploy.');
    }
  }

  /// Upload build siap ke Google Play / App Store Connect (tanpa build ulang).
  Future<void> deployReady(Project p, String platform, {String track = 'internal', String releaseNotes = '', bool submitReview = false}) async {
    final b = ReadyBuilds.instance.get(p.id, platform);
    if (b == null || !b.exists) throw Exception('Build siap tidak ditemukan — build ulang dulu');
    final o = QuickUploadOptions(file: File(b.path), project: p)
      ..track = track
      ..releaseNotes = releaseNotes
      ..submitReview = submitReview
      ..bundleId = p.iosBundleId
      ..fullChecks = true // cek kelayakan + laporan AAB + persetujuan sebelum upload
      ..demoPassword = await Storage.secret(Secrets.demoPassword(p.id))
      ..commit = b.commit
      ..builtAt = b.builtAt;
    if (platform == 'ios') {
      final v = b.version.split('+');
      o
        ..appVersion = v.first
        ..buildNumber = v.length > 1 ? v[1] : '';
    }
    final pw = await Storage.secret(Secrets.macPassword);
    final run = PipelineRun(project: p, platform: platform, settings: settings, steps: quickUploadSteps(o, settings, pw));
    run.rerun = ({bool skipChecks = false}) => deployReady(p, platform, track: track, releaseNotes: releaseNotes, submitReview: submitReview);
    // tidak di-await: layar pipeline langsung tampil
    _launch(run).then((_) async {
      if (run.status == RunStatus.success && run.vars['uploaded'] == '1') {
        await ReadyBuilds.instance.markDeployed(p.id, platform, platform == 'ios' ? 'TestFlight' : track);
        notifyListeners();
      }
    });
  }

  // ───────────────────────── Source trigger: commit baru → pipeline otomatis
  Timer? _trigger;
  final _lastCommit = <String, String>{};
  String triggerStatus = '';

  /// Mulai / hentikan pengecekan commit baru sesuai Pengaturan → DevOps & integrasi.
  void restartAutoTrigger() {
    _trigger?.cancel();
    final it = Integrations.instance;
    if (!it.autoTriggerOn || it.autoTriggerProjects.isEmpty) {
      triggerStatus = '';
      return;
    }
    _checkCommits(); // baseline
    _trigger = Timer.periodic(Duration(minutes: it.autoTriggerMinutes.clamp(1, 120)), (_) => _checkCommits());
  }

  Future<void> _checkCommits() async {
    final it = Integrations.instance;
    for (final id in it.autoTriggerProjects) {
      final p = projects.where((x) => x.id == id).firstOrNull;
      if (p == null || p.localPath.isEmpty) continue;
      try {
        final r = await Process.run(settings.gitCmd, ['ls-remote', 'origin', 'refs/heads/${p.branch}'],
            workingDirectory: p.localPath, runInShell: true, environment: ToolEnv.env());
        final hash = '${r.stdout}'.trim().split(RegExp(r'\s+')).first;
        if (r.exitCode != 0 || hash.length < 7) continue;
        final prev = _lastCommit[id];
        _lastCommit[id] = hash;
        triggerStatus = '${p.name}: ${hash.substring(0, 7)} • ${DateTime.now().toString().substring(11, 16)}';
        if (it.autoTriggerMode == 'ready') {
          // build siap deploy: bandingkan dengan commit build terakhir (tidak hilang walau DeployHub ditutup)
          final last = ReadyBuilds.instance.get(p.id, 'android')?.commit ?? ReadyBuilds.instance.get(p.id, 'ios')?.commit;
          if (last == hash || isRunning || _readyBusy) continue;
          if (last == null && prev == null) continue; // pertama kali: jadikan patokan, build saat ada commit berikutnya
          await it.notify('🔔 Commit baru ${hash.substring(0, 7)} di ${p.name} (${p.branch}) → build AAB${p.useIos && p.hasIos ? ' + IPA' : ''} siap deploy');
          await buildReady(p, commit: hash);
          continue;
        }
        if (prev == null || prev == hash || isRunning) continue;
        // Commit baru → jalankan pipeline
        final cd = it.autoTriggerMode == 'cd';
        await startAndroid(
          p,
          AndroidOptions(
            mode: cd ? 'production' : 'internal',
            track: 'internal',
            gitPull: true,
            upload: cd,
            bumpVersion: cd,
            askBeforeUpload: false, // Continuous Deployment: tanpa persetujuan manual
            syncStore: false,
          ),
        );
        await it.notify('🔔 Commit baru ${hash.substring(0, 7)} di ${p.name} (${p.branch}) → pipeline ${cd ? 'CD (upload ke internal)' : 'CI (cek + build)'} dimulai');
      } catch (_) {}
    }
    notifyListeners();
  }
}
