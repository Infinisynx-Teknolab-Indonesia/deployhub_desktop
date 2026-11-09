import 'dart:io';

import 'storage.dart';

/// "Build siap deploy": AAB / IPA yang sudah di-build otomatis (mis. setiap GitHub di-update)
/// dan tinggal diupload dengan sekali klik "Deploy".
class ReadyBuild {
  ReadyBuild({
    required this.platform,
    required this.path,
    required this.version,
    this.commit = '',
    DateTime? builtAt,
    this.runId = '',
    this.deployedTrack = '',
    this.deployedAt,
  }) : builtAt = builtAt ?? DateTime.now();

  final String platform; // android | ios
  final String path; // file .aab / .ipa di PC
  final String version; // 1.0.0+8
  final String commit; // commit GitHub yang di-build
  final DateTime builtAt;
  final String runId;
  String deployedTrack; // kosong = belum dideploy
  DateTime? deployedAt;

  bool get deployed => deployedTrack.isNotEmpty;
  bool get exists => File(path).existsSync();
  String get shortCommit => commit.length > 7 ? commit.substring(0, 7) : commit;

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'path': path,
        'version': version,
        'commit': commit,
        'builtAt': builtAt.toIso8601String(),
        'runId': runId,
        'deployedTrack': deployedTrack,
        'deployedAt': deployedAt?.toIso8601String(),
      };

  factory ReadyBuild.fromJson(Map<String, dynamic> j) => ReadyBuild(
        platform: j['platform'] ?? 'android',
        path: j['path'] ?? '',
        version: j['version'] ?? '',
        commit: j['commit'] ?? '',
        builtAt: DateTime.tryParse(j['builtAt'] ?? '') ?? DateTime.now(),
        runId: j['runId'] ?? '',
        deployedTrack: j['deployedTrack'] ?? '',
        deployedAt: DateTime.tryParse(j['deployedAt'] ?? ''),
      );
}

class ReadyBuilds {
  ReadyBuilds._();
  static final ReadyBuilds instance = ReadyBuilds._();

  /// projectId → platform → build terbaru
  final Map<String, Map<String, ReadyBuild>> _m = {};

  Future<void> load() async {
    final j = await Storage.readJson('ready_builds.json');
    if (j is! Map) return;
    j.forEach((pid, v) {
      if (v is Map) {
        _m['$pid'] = {for (final e in v.entries) '${e.key}': ReadyBuild.fromJson(Map<String, dynamic>.from(e.value))};
      }
    });
  }

  Future<void> _save() => Storage.writeJson('ready_builds.json', {
        for (final e in _m.entries) e.key: {for (final b in e.value.entries) b.key: b.value.toJson()},
      });

  ReadyBuild? get(String projectId, String platform) => _m[projectId]?[platform];

  Future<void> put(String projectId, ReadyBuild b) async {
    (_m[projectId] ??= {})[b.platform] = b;
    await _save();
  }

  Future<void> markDeployed(String projectId, String platform, String track) async {
    final b = get(projectId, platform);
    if (b == null) return;
    b
      ..deployedTrack = track
      ..deployedAt = DateTime.now();
    await _save();
  }
}
