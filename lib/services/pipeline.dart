import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/i18n.dart';
import '../models.dart';
import '../utils.dart';
import 'mac_service.dart';
import 'storage.dart';
import 'tool_env.dart';

enum StepStatus { pending, running, success, failed, skipped }

enum RunStatus { running, success, failed, cancelled }

String runStatusLabel(RunStatus s) => switch (s) {
      RunStatus.running => tr('Berjalan'),
      RunStatus.success => tr('Sukses'),
      RunStatus.failed => tr('Gagal'),
      RunStatus.cancelled => tr('Dibatalkan'),
    };

class PipelineError implements Exception {
  final String message;
  PipelineError(this.message);
  @override
  String toString() => message;
}

class PipelineStep {
  final String title;
  final bool enabled;
  final Future<void> Function(PipelineRun run) action;
  StepStatus status = StepStatus.pending;
  Duration? duration;

  PipelineStep(this.title, this.action, {this.enabled = true});
}

class PipelineRun extends ChangeNotifier {
  PipelineRun({
    required this.project,
    required this.platform,
    required this.steps,
    required this.settings,
  }) : id = DateTime.now().millisecondsSinceEpoch.toString();

  final String id;
  final Project project;
  final String platform; // android | ios
  final List<PipelineStep> steps;
  final AppSettings settings;

  final List<String> logs = [];
  final DateTime startedAt = DateTime.now();
  DateTime? finishedAt;
  RunStatus status = RunStatus.running;
  String version = '';
  String summary = '';
  String track = ''; // diisi setelah upload ke Google Play berhasil

  /// Persetujuan upload: pipeline berhenti sejenak setelah semua cek & build selesai.
  Completer<bool>? _approval;
  List<String> approvalBlockers = []; // masalah yang membuat Google Play menolak / review gagal
  List<String> approvalInfo = []; // ringkasan (versi, ukuran, optimasi)
  bool get awaitingApproval => _approval != null && !_approval!.isCompleted;

  /// Tunggu pengguna klik "Upload sekarang" (true) atau "Jangan upload" (false).
  Future<bool> waitApproval({required List<String> blockers, required List<String> info}) {
    approvalBlockers = blockers;
    approvalInfo = info;
    _approval = Completer<bool>();
    log('⏸ ${trL('Menunggu persetujuan upload — klik "Upload sekarang" atau "Jangan upload" di atas log.')}');
    notifyListeners();
    return _approval!.future;
  }

  /// Ganti daftar masalah (setelah diperbaiki dari panel persetujuan → "Cek ulang").
  void updateBlockers(List<String> blockers) {
    approvalBlockers = blockers;
    notifyListeners();
  }

  void approve(bool ok) {
    if (awaitingApproval) _approval!.complete(ok);
    notifyListeners();
  }

  /// true = selesai lebih awal sebagai sukses (mis. pengguna memilih "Jangan upload").
  bool stopRequested = false;

  /// Jalankan ulang pipeline yang sama (opsional tanpa "Cek kelayakan rilis").
  Future<void> Function({bool skipChecks})? rerun;

  /// Data yang dibagi antar langkah (mis. path AAB, nama tag).
  final Map<String, String> vars = {};

  SSHClient? ssh;
  Process? _proc;
  bool _cancelled = false;
  IOSink? _sink;
  Timer? _notifyTimer;

  String get logPath => p.join(Storage.logsDir, '$id.log');
  Duration get elapsed => (finishedAt ?? DateTime.now()).difference(startedAt);
  bool get isRunning => status == RunStatus.running;

  void log(String line) {
    logs.add(line);
    _sink?.writeln(line);
    _notifyTimer ??= Timer(const Duration(milliseconds: 120), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  void _checkCancel() {
    if (_cancelled) throw PipelineError(trL('Dibatalkan oleh pengguna'));
  }

  Future<void> execute() async {
    _sink = File(logPath).openWrite();
    log('▶ ${project.name} — deploy ${platform.toUpperCase()} • ${fmtTime(startedAt)}');

    for (final step in steps) {
      if (!step.enabled) {
        step.status = StepStatus.skipped;
        continue;
      }
      if (_cancelled) break;
      step.status = StepStatus.running;
      notifyListeners();
      log('');
      log('━━━ ${step.title}');
      final sw = Stopwatch()..start();
      try {
        await step.action(this);
        step.status = StepStatus.success;
      } catch (e) {
        step.status = StepStatus.failed;
        log('✖ $e');
        status = _cancelled ? RunStatus.cancelled : RunStatus.failed;
      }
      step.duration = sw.elapsed;
      notifyListeners();
      if (status != RunStatus.running || stopRequested) break;
    }

    for (final s in steps) {
      if (s.status == StepStatus.pending) s.status = StepStatus.skipped;
    }
    if (status == RunStatus.running) {
      status = _cancelled ? RunStatus.cancelled : RunStatus.success;
    }
    finishedAt = DateTime.now();
    ssh?.close();
    ssh = null;

    log('');
    log(status == RunStatus.success
        ? '✔ ${trL('Pipeline sukses dalam {0}', [fmtDuration(elapsed)])}'
        : '✖ ${trL('Pipeline berhenti ({0}) setelah {1}', [status.name, fmtDuration(elapsed)])}');

    final sink = _sink;
    _sink = null;
    await sink?.flush();
    await sink?.close();
    _notifyTimer?.cancel();
    _notifyTimer = null;
    notifyListeners();
  }

  Future<void> cancel() async {
    if (!isRunning || _cancelled) return;
    _cancelled = true;
    if (awaitingApproval) _approval!.complete(false);
    log('⏹ ${trL('Membatalkan pipeline...')}');
    final proc = _proc;
    if (proc != null) {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '${proc.pid}', '/T', '/F']);
      } else {
        proc.kill();
      }
    }
    ssh?.close();
    notifyListeners();
  }

  /// Jalankan perintah lokal di PC, output masuk ke log.
  Future<int> sh(String exe, List<String> args,
      {required String cwd, bool allowFail = false, String? display}) async {
    _checkCancel();
    log('\$ ${display ?? '$exe ${args.join(' ')}'}');
    final proc = await Process.start(exe, args,
        workingDirectory: cwd, runInShell: true, environment: ToolEnv.env());
    _proc = proc;
    const dec = Utf8Decoder(allowMalformed: true);
    final a = proc.stdout.transform(dec).transform(const LineSplitter()).forEach(log);
    final b = proc.stderr.transform(dec).transform(const LineSplitter()).forEach(log);
    final code = await proc.exitCode;
    await Future.wait([a, b]);
    _proc = null;
    _checkCancel();
    if (code != 0 && !allowFail) {
      throw PipelineError(trL('"{0}" gagal (kode {1})', ['$exe ${args.isEmpty ? '' : args.first}', code]));
    }
    return code;
  }

  Future<int> flutter(List<String> args,
          {required String cwd, bool allowFail = false, String? display}) =>
      sh(settings.flutterCmd, args, cwd: cwd, allowFail: allowFail, display: display);

  Future<int> git(List<String> args, {required String cwd, bool allowFail = false}) =>
      sh(settings.gitCmd, args, cwd: cwd, allowFail: allowFail);

  /// Jalankan perintah di MacBook lewat SSH.
  /// [display] dipakai untuk log bila perintah berisi rahasia.
  Future<void> mac(String cmd,
      {bool inProject = true, bool allowFail = false, String? display}) async {
    _checkCancel();
    final client = ssh ?? (throw PipelineError(trL('Belum terhubung ke MacBook')));
    log('mac\$ ${display ?? cmd}');
    final code = await MacService.run(
      client,
      MacService.wrap(cmd, cwd: inProject ? project.macProjectPath : ''),
      log,
    );
    _checkCancel();
    if (code != 0 && !allowFail) {
      throw PipelineError(trL('Perintah di MacBook gagal (kode {0})', [code]));
    }
  }

  /// Jalankan perintah di MacBook dan kembalikan output-nya (juga ditulis ke log).
  Future<String> macOut(String cmd, {bool inProject = true}) async {
    _checkCancel();
    final client = ssh ?? (throw PipelineError(trL('Belum terhubung ke MacBook')));
    log('mac\$ $cmd');
    final lines = <String>[];
    final code = await MacService.run(client, MacService.wrap(cmd, cwd: inProject ? project.macProjectPath : ''), (l) {
      lines.add(l);
      log(l);
    });
    _checkCancel();
    if (code != 0) throw PipelineError(trL('Perintah di MacBook gagal (kode {0})', [code]));
    return lines.join('\n').trim();
  }

  RunRecord toRecord() => RunRecord(
        id: id,
        projectId: project.id,
        projectName: project.name,
        platform: platform,
        status: status.name,
        version: version,
        summary: summary,
        track: track,
        startedAt: startedAt,
        finishedAt: finishedAt ?? DateTime.now(),
        logPath: logPath,
      );
}
