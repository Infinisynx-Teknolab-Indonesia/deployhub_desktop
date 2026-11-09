import 'dart:io';

import 'package:path/path.dart' as p;

import 'keystore_tool.dart';

/// Hasil deteksi otomatis dari folder project Flutter.
class ScanResult {
  String name = '';
  String packageName = '';
  String githubOwner = '';
  String githubRepo = '';
  String iosBundleId = '';
  bool hasLogin = false;
  bool hasGoogleLogin = false;
  bool usesFirebase = false;
  bool hasAds = false;
  bool hasChat = false;
  bool hasIosFolder = false;
  bool hasGoogleServicesJson = false;
  bool hasIosPlist = false; // ios/Runner/GoogleService-Info.plist
  bool hasFirebaseOptions = false; // lib/firebase_options.dart (FlutterFire)
  bool hasKeyProperties = false;
  bool hasReleaseSigning = false; // key.properties + build.gradle memakainya
  final List<String> evidence = []; // alasan singkat, untuk ditampilkan
}

/// Baca pubspec, kode lib/, gradle, dan .git/config untuk menebak fitur aplikasi.
Future<ScanResult> scanProject(String root) async {
  final r = ScanResult();
  if (root.isEmpty || !await Directory(root).exists()) return r;

  String pubspec = '';
  final pub = File(p.join(root, 'pubspec.yaml'));
  if (await pub.exists()) {
    pubspec = await pub.readAsString();
    r.name = RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(pubspec)?.group(1) ?? '';
  }
  final deps = RegExp(r'^\s{2}([a-z0-9_]+):', multiLine: true).allMatches(pubspec).map((m) => m.group(1)!).toSet();

  final buf = StringBuffer();
  final lib = Directory(p.join(root, 'lib'));
  if (await lib.exists()) {
    await for (final e in lib.list(recursive: true)) {
      if (e is File && e.path.endsWith('.dart')) {
        try {
          buf.writeln(await e.readAsString());
        } catch (_) {}
      }
    }
  }
  final code = buf.toString();

  r.hasGoogleLogin = deps.contains('google_sign_in') || RegExp(r'GoogleAuthProvider|GoogleSignIn\(').hasMatch(code);
  r.hasLogin = r.hasGoogleLogin ||
      deps.contains('firebase_auth') ||
      deps.contains('sign_in_with_apple') ||
      RegExp(r'''signInWith\w+|class\s+\w*(Login|SignIn|Masuk)\w*|['"/]login['"/]|auth/login|obscureText:\s*true''').hasMatch(code);
  if (r.hasGoogleLogin) {
    r.evidence.add('google_sign_in');
  } else if (r.hasLogin) {
    r.evidence.add('login');
  }

  final fb = deps.where((d) => d.startsWith('firebase_')).toList();
  r.usesFirebase = fb.isNotEmpty || r.hasGoogleLogin;
  if (fb.isNotEmpty) r.evidence.add(fb.take(3).join(', '));

  r.hasAds = deps.contains('google_mobile_ads') || deps.any((d) => d.contains('admob')) || deps.contains('unity_ads_plugin');
  if (r.hasAds) r.evidence.add('google_mobile_ads');

  final chatDeps = deps.where((d) => const [
        'web_socket_channel', 'socket_io_client', 'livekit_client', 'stream_chat_flutter', 'flutter_chat_ui',
        'agora_rtc_engine', 'firebase_messaging', 'signalr_netcore', 'dash_chat_2',
      ].contains(d));
  r.hasChat = chatDeps.isNotEmpty || RegExp(r'class\s+\w*(Chat|Message|Pesan|Room)\w*').hasMatch(code);
  if (r.hasChat) r.evidence.add(chatDeps.isNotEmpty ? chatDeps.first : 'chat');

  r.hasIosFolder = await Directory(p.join(root, 'ios')).exists();
  final pbx = File(p.join(root, 'ios', 'Runner.xcodeproj', 'project.pbxproj'));
  if (await pbx.exists()) {
    for (final m in RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = "?([^;"]+)"?;').allMatches(await pbx.readAsString())) {
      if (!m.group(1)!.contains('RunnerTests')) {
        r.iosBundleId = m.group(1)!;
        break;
      }
    }
  }
  r.hasGoogleServicesJson = await File(p.join(root, 'android', 'app', 'google-services.json')).exists();
  r.hasIosPlist = await File(p.join(root, 'ios', 'Runner', 'GoogleService-Info.plist')).exists();
  r.hasFirebaseOptions = await File(p.join(root, 'lib', 'firebase_options.dart')).exists();
  r.hasKeyProperties = await File(p.join(root, 'android', 'key.properties')).exists();
  r.hasReleaseSigning = await hasReleaseSigning(root);

  for (final g in ['build.gradle.kts', 'build.gradle']) {
    final f = File(p.join(root, 'android', 'app', g));
    if (await f.exists()) {
      r.packageName = RegExp(r'''applicationId\s*=?\s*["']([^"']+)["']''').firstMatch(await f.readAsString())?.group(1) ?? '';
      break;
    }
  }
  final git = File(p.join(root, '.git', 'config'));
  if (await git.exists()) {
    final m = RegExp(r'github\.com[:/]([^/\s]+)/([^\s]+?)(?:\.git)?\s*$', multiLine: true).firstMatch(await git.readAsString());
    if (m != null) {
      r.githubOwner = m.group(1)!;
      r.githubRepo = m.group(2)!;
    }
  }
  return r;
}
