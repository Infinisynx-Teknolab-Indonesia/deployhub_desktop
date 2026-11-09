class Project {
  String id;
  String name;
  String localPath; // folder project Flutter di PC
  String branch;

  // Android / Google Play
  String packageName;
  String serviceAccountPath;
  String defaultTrack;
  String extraBuildArgs;
  String playSigningSha1; // SHA-1 "App signing key" dari Play Console
  int maxAabMb;

  // GitHub
  String githubOwner;
  String githubRepo;

  // iOS / MacBook
  String macProjectPath; // folder project di MacBook, mis. ~/projects/batamchitchat
  String iosExportOptions; // relatif ke project di Mac, mis. ios/ExportOptions.plist
  String ascKeyId; // App Store Connect API Key ID
  String ascIssuerId; // App Store Connect Issuer ID
  String iosBundleId; // mis. com.batamchitchat.app (dari Xcode)

  // Firebase (opsional, kalau file tidak ikut di git)
  String googleServicesJsonPath;
  String googleServiceInfoPlistPath;

  // Kebijakan & review store
  String privacyPolicyUrl;
  String deleteAccountUrl;
  String childSafetyUrl;
  bool isSocialApp; // chat / sosial / dating → wajib standar perlindungan anak
  String demoUser; // password disimpan di secure storage
  String loginTestUrl; // opsional: endpoint login API untuk dites
  String loginUserField; // nama field user di body JSON (username / email)

  // Jawaban "fitur aplikasi" (menentukan bagian & pemeriksaan yang berlaku)
  bool hasLogin; // aplikasi punya login → wajib akun demo & link hapus akun
  bool usesFirebase; // Firebase / Login Google → cek google-services.json & SHA-1
  bool hasAds; // AdMob / iklan → jawaban "Iklan" di Play Console
  bool useGithub; // tag, release, GitHub Actions
  bool useIos; // rilis juga ke App Store (build di MacBook)

  // Play Console: pengujian tertutup & checklist konten aplikasi
  bool isPersonalAccount; // akun developer pribadi (wajib 12 tester / 14 hari)
  String testerGroups; // Google Group, dipisah koma
  String closedTestTrack; // track pengujian tertutup, default alpha
  String closedTestStart; // tanggal ISO mulai pengujian tertutup
  int testerCount; // jumlah tester yang sudah ikut
  int minCoverage; // % minimal baris kode yang dites (0 = tidak dicek)
  Map<String, String> consoleAnswers; // jawaban siap tempel per tugas
  List<String> consoleDone; // tugas Play Console yang sudah diisi
  List<String> journeyDone; // tahap manual Perjalanan Rilis yang sudah dicentang
  bool alreadyLive; // aplikasi sudah live di Play Store → cukup update AAB, lewati setup awal

  Project({
    required this.id,
    this.name = '',
    this.localPath = '',
    this.branch = 'main',
    this.packageName = '',
    this.serviceAccountPath = '',
    this.defaultTrack = 'internal',
    this.extraBuildArgs = '',
    this.playSigningSha1 = '',
    this.maxAabMb = 150,
    this.githubOwner = '',
    this.githubRepo = '',
    this.macProjectPath = '',
    this.iosExportOptions = '',
    this.ascKeyId = '',
    this.ascIssuerId = '',
    this.iosBundleId = '',
    this.googleServicesJsonPath = '',
    this.googleServiceInfoPlistPath = '',
    this.privacyPolicyUrl = '',
    this.deleteAccountUrl = '',
    this.childSafetyUrl = '',
    this.isSocialApp = false,
    this.demoUser = '',
    this.loginTestUrl = '',
    this.loginUserField = 'username',
    this.hasLogin = false,
    this.usesFirebase = false,
    this.hasAds = false,
    this.useGithub = false,
    this.useIos = false,
    this.isPersonalAccount = true,
    this.testerGroups = '',
    this.closedTestTrack = 'alpha',
    this.closedTestStart = '',
    this.testerCount = 0,
    this.minCoverage = 0,
    Map<String, String>? consoleAnswers,
    List<String>? consoleDone,
    List<String>? journeyDone,
    this.alreadyLive = false,
  })  : consoleAnswers = consoleAnswers ?? {},
        consoleDone = consoleDone ?? [],
        journeyDone = journeyDone ?? [];

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] as String,
        name: j['name'] ?? '',
        localPath: j['localPath'] ?? '',
        branch: j['branch'] ?? 'main',
        packageName: j['packageName'] ?? '',
        serviceAccountPath: j['serviceAccountPath'] ?? '',
        defaultTrack: j['defaultTrack'] ?? 'internal',
        extraBuildArgs: j['extraBuildArgs'] ?? '',
        playSigningSha1: j['playSigningSha1'] ?? '',
        maxAabMb: (j['maxAabMb'] as num?)?.toInt() ?? 150,
        githubOwner: j['githubOwner'] ?? '',
        githubRepo: j['githubRepo'] ?? '',
        macProjectPath: j['macProjectPath'] ?? '',
        iosExportOptions: j['iosExportOptions'] ?? '',
        ascKeyId: j['ascKeyId'] ?? '',
        ascIssuerId: j['ascIssuerId'] ?? '',
        iosBundleId: j['iosBundleId'] ?? '',
        googleServicesJsonPath: j['googleServicesJsonPath'] ?? '',
        googleServiceInfoPlistPath: j['googleServiceInfoPlistPath'] ?? '',
        privacyPolicyUrl: j['privacyPolicyUrl'] ?? '',
        deleteAccountUrl: j['deleteAccountUrl'] ?? '',
        childSafetyUrl: j['childSafetyUrl'] ?? '',
        isSocialApp: j['isSocialApp'] == true,
        demoUser: j['demoUser'] ?? '',
        loginTestUrl: j['loginTestUrl'] ?? '',
        loginUserField: j['loginUserField'] ?? 'username',
        // proyek lama (belum ada jawaban) → disimpulkan dari isian yang sudah ada
        hasLogin: j['hasLogin'] ?? ((j['demoUser'] ?? '') != ''),
        usesFirebase: j['usesFirebase'] ??
            ((j['googleServicesJsonPath'] ?? '') != '' || (j['playSigningSha1'] ?? '') != ''),
        hasAds: j['hasAds'] ?? false,
        useGithub: j['useGithub'] ?? ((j['githubOwner'] ?? '') != '' && (j['githubRepo'] ?? '') != ''),
        useIos: j['useIos'] ?? ((j['macProjectPath'] ?? '') != ''),
        isPersonalAccount: j['isPersonalAccount'] != false,
        testerGroups: j['testerGroups'] ?? '',
        closedTestTrack: j['closedTestTrack'] ?? 'alpha',
        closedTestStart: j['closedTestStart'] ?? '',
        testerCount: (j['testerCount'] as num?)?.toInt() ?? 0,
        minCoverage: (j['minCoverage'] as num?)?.toInt() ?? 0,
        consoleAnswers: Map<String, String>.from(j['consoleAnswers'] ?? const {}),
        consoleDone: List<String>.from(j['consoleDone'] ?? const []),
        journeyDone: List<String>.from(j['journeyDone'] ?? const []),
        alreadyLive: j['alreadyLive'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'localPath': localPath,
        'branch': branch,
        'packageName': packageName,
        'serviceAccountPath': serviceAccountPath,
        'defaultTrack': defaultTrack,
        'extraBuildArgs': extraBuildArgs,
        'playSigningSha1': playSigningSha1,
        'maxAabMb': maxAabMb,
        'githubOwner': githubOwner,
        'githubRepo': githubRepo,
        'macProjectPath': macProjectPath,
        'iosExportOptions': iosExportOptions,
        'ascKeyId': ascKeyId,
        'ascIssuerId': ascIssuerId,
        'iosBundleId': iosBundleId,
        'googleServicesJsonPath': googleServicesJsonPath,
        'googleServiceInfoPlistPath': googleServiceInfoPlistPath,
        'privacyPolicyUrl': privacyPolicyUrl,
        'deleteAccountUrl': deleteAccountUrl,
        'childSafetyUrl': childSafetyUrl,
        'isSocialApp': isSocialApp,
        'demoUser': demoUser,
        'loginTestUrl': loginTestUrl,
        'loginUserField': loginUserField,
        'hasLogin': hasLogin,
        'usesFirebase': usesFirebase,
        'hasAds': hasAds,
        'useGithub': useGithub,
        'useIos': useIos,
        'isPersonalAccount': isPersonalAccount,
        'testerGroups': testerGroups,
        'closedTestTrack': closedTestTrack,
        'closedTestStart': closedTestStart,
        'testerCount': testerCount,
        'minCoverage': minCoverage,
        'consoleAnswers': consoleAnswers,
        'consoleDone': consoleDone,
        'journeyDone': journeyDone,
        'alreadyLive': alreadyLive,
      };

  bool get hasGithub => useGithub && githubOwner.isNotEmpty && githubRepo.isNotEmpty;
  bool get hasIos => useIos && macProjectPath.isNotEmpty;

  List<String> get testerGroupList => testerGroups
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  /// Hari berjalan sejak pengujian tertutup dimulai (null kalau belum mulai).
  int? get closedTestDays {
    final d = DateTime.tryParse(closedTestStart);
    if (d == null) return null;
    return DateTime.now().difference(d).inDays;
  }
}

class AppSettings {
  String macHost;
  int macPort;
  String macUser;
  String macKeyPath;
  String telegramChatId;
  String flutterCmd;
  String gitCmd;
  String keytoolCmd;
  int minTargetSdk;

  // Google Play: 'oauth' (login Google) atau 'service' (Service Account JSON)
  String playAuthMode;
  String playServiceAccountPath;
  String playOAuthClientId;
  String playOAuthEmail;
  String playTestPackage;

  // App Store Connect (bawaan untuk semua proyek)
  String ascKeyId;
  String ascIssuerId;
  String ascP8Path;
  String ascVerifiedTeam; // diisi setelah tes koneksi App Store Connect berhasil (mis. "3 aplikasi")

  String githubUser;

  AppSettings({
    this.macHost = '',
    this.macPort = 22,
    this.macUser = '',
    this.macKeyPath = '',
    this.telegramChatId = '',
    this.flutterCmd = 'flutter',
    this.gitCmd = 'git',
    this.keytoolCmd = 'keytool',
    this.minTargetSdk = 36,
    this.playAuthMode = 'oauth',
    this.playServiceAccountPath = '',
    this.playOAuthClientId = '',
    this.playOAuthEmail = '',
    this.playTestPackage = '',
    this.ascKeyId = '',
    this.ascIssuerId = '',
    this.ascP8Path = '',
    this.ascVerifiedTeam = '',
    this.githubUser = '',
  });

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        macHost: j['macHost'] ?? '',
        macPort: (j['macPort'] as num?)?.toInt() ?? 22,
        macUser: j['macUser'] ?? '',
        macKeyPath: j['macKeyPath'] ?? '',
        telegramChatId: j['telegramChatId'] ?? '',
        flutterCmd: j['flutterCmd'] ?? 'flutter',
        gitCmd: j['gitCmd'] ?? 'git',
        keytoolCmd: j['keytoolCmd'] ?? 'keytool',
        minTargetSdk: (j['minTargetSdk'] as num?)?.toInt() ?? 36,
        // bawaan: Login dengan Google; Service Account hanya kalau dipilih DAN file-nya sudah diisi
        playAuthMode: j['playAuthMode'] == 'service' && (j['playServiceAccountPath'] ?? '') != '' ? 'service' : 'oauth',
        playServiceAccountPath: j['playServiceAccountPath'] ?? '',
        playOAuthClientId: j['playOAuthClientId'] ?? '',
        playOAuthEmail: j['playOAuthEmail'] ?? '',
        playTestPackage: j['playTestPackage'] ?? '',
        ascKeyId: j['ascKeyId'] ?? '',
        ascIssuerId: j['ascIssuerId'] ?? '',
        ascP8Path: j['ascP8Path'] ?? '',
        ascVerifiedTeam: j['ascVerifiedTeam'] ?? '',
        githubUser: j['githubUser'] ?? '',
      );

  Map<String, dynamic> toJson() => {
        'macHost': macHost,
        'macPort': macPort,
        'macUser': macUser,
        'macKeyPath': macKeyPath,
        'telegramChatId': telegramChatId,
        'flutterCmd': flutterCmd,
        'gitCmd': gitCmd,
        'keytoolCmd': keytoolCmd,
        'minTargetSdk': minTargetSdk,
        'playAuthMode': playAuthMode,
        'playServiceAccountPath': playServiceAccountPath,
        'playOAuthClientId': playOAuthClientId,
        'playOAuthEmail': playOAuthEmail,
        'playTestPackage': playTestPackage,
        'ascKeyId': ascKeyId,
        'ascIssuerId': ascIssuerId,
        'ascP8Path': ascP8Path,
        'ascVerifiedTeam': ascVerifiedTeam,
        'githubUser': githubUser,
      };

  AppSettings copy() => AppSettings.fromJson(toJson());
}

class RunRecord {
  final String id;
  final String projectId;
  final String projectName;
  final String platform; // android | ios
  final String status; // success | failed | cancelled
  final String version;
  final String summary;
  final String track; // track Google Play yang berhasil diupload ('' kalau tidak upload)
  final DateTime startedAt;
  final DateTime finishedAt;
  final String logPath;

  RunRecord({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.platform,
    required this.status,
    required this.version,
    required this.summary,
    this.track = '',
    required this.startedAt,
    required this.finishedAt,
    required this.logPath,
  });

  factory RunRecord.fromJson(Map<String, dynamic> j) => RunRecord(
        id: j['id'] ?? '',
        projectId: j['projectId'] ?? '',
        projectName: j['projectName'] ?? '',
        platform: j['platform'] ?? '',
        status: j['status'] ?? '',
        version: j['version'] ?? '',
        summary: j['summary'] ?? '',
        track: j['track'] ?? '',
        startedAt: DateTime.tryParse(j['startedAt'] ?? '') ?? DateTime.now(),
        finishedAt: DateTime.tryParse(j['finishedAt'] ?? '') ?? DateTime.now(),
        logPath: j['logPath'] ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'projectName': projectName,
        'platform': platform,
        'status': status,
        'version': version,
        'summary': summary,
        'track': track,
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt.toIso8601String(),
        'logPath': logPath,
      };
}

/// Kunci untuk data rahasia (disimpan di Windows Credential Manager).
class Secrets {
  static const github = 'github_token';
  static const macPassword = 'mac_password';
  static const telegram = 'telegram_bot_token';
  static const playOAuthSecret = 'play_oauth_secret';
  static const playOAuthCreds = 'play_oauth_credentials';
  static String demoPassword(String projectId) => 'demo_pw_$projectId';
}
