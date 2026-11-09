import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'storage.dart';
import 'tool_env.dart';

/// AI perbaikan otomatis (opsional, Pengaturan → AI perbaikan otomatis).
///
/// - **Nonaktif**: DeployHub hanya memakai perbaikan berbasis aturan (gradle_fixer, project_doctor).
/// - **Aktif**: kalau aturan tidak menemukan solusi, log error + file yang terkait dikirim ke AI
///   (Prakash AI / LM Studio / Ollama / OpenAI / Claude). AI membalas isi file yang sudah
///   diperbaiki → DeployHub membackup file lama (*.deployhub.bak), menulis yang baru, lalu
///   build / analyze diulang.
///
/// File rahasia TIDAK PERNAH dikirim ke AI: key.properties, keystore (.jks/.keystore),
/// google-services.json, GoogleService-Info.plist, .env, file service account, *.p8.
class AiFixer {
  AiFixer._();
  static final AiFixer instance = AiFixer._();

  bool on = false;
  /// openai = API kompatibel OpenAI (Prakash AI, LM Studio, llama.cpp, vLLM, OpenAI)
  /// ollama = Ollama /api/chat • anthropic = Claude API
  String provider = 'openai';
  String url = 'http://localhost:5088/v1';
  String model = '';
  bool autoApply = true; // terapkan perbaikan tanpa bertanya (di dalam pipeline)
  int maxRounds = 2; // putaran perbaikan AI per langkah
  bool deep = true; // kirim lebih banyak file & konteks

  static const kKey = 'ai_api_key';

  Future<void> load() async {
    final j = await Storage.readJson('ai.json');
    if (j is! Map) return;
    on = j['on'] == true;
    provider = j['provider'] ?? provider;
    url = j['url'] ?? url;
    model = j['model'] ?? '';
    autoApply = j['autoApply'] != false;
    maxRounds = (j['maxRounds'] as num?)?.toInt() ?? 2;
    deep = j['deep'] != false;
  }

  Future<void> save() => Storage.writeJson('ai.json', {
        'on': on,
        'provider': provider,
        'url': url,
        'model': model,
        'autoApply': autoApply,
        'maxRounds': maxRounds,
        'deep': deep,
      });

  bool get ready => on && model.trim().isNotEmpty && url.trim().isNotEmpty;

  String get _base => url.trim().replaceAll(RegExp(r'/+$'), '');

  // ───────────────────────── panggilan model
  Future<String> chat(String system, String user, {int maxTokens = 16000}) async {
    final key = await Storage.secret(kKey);
    final timeout = const Duration(minutes: 10); // model lokal bisa lambat
    switch (provider) {
      case 'ollama':
        final r = await http
            .post(Uri.parse('$_base/api/chat'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'model': model,
                  'stream': false,
                  'options': {'temperature': 0.1, 'num_ctx': deep ? 32768 : 16384},
                  'messages': [
                    {'role': 'system', 'content': system},
                    {'role': 'user', 'content': user},
                  ],
                }))
            .timeout(timeout);
        if (r.statusCode >= 300) throw Exception('Ollama HTTP ${r.statusCode}: ${_short(r.body)}');
        return '${jsonDecode(utf8.decode(r.bodyBytes))['message']['content']}';
      case 'anthropic':
        final base = _base.isEmpty || _base.contains('localhost') ? 'https://api.anthropic.com' : _base;
        final r = await http
            .post(Uri.parse('$base/v1/messages'),
                headers: {'Content-Type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01'},
                body: jsonEncode({
                  'model': model,
                  'max_tokens': maxTokens,
                  'temperature': 0.1,
                  'system': system,
                  'messages': [
                    {'role': 'user', 'content': user},
                  ],
                }))
            .timeout(timeout);
        if (r.statusCode >= 300) throw Exception('Claude API HTTP ${r.statusCode}: ${_short(r.body)}');
        final content = jsonDecode(utf8.decode(r.bodyBytes))['content'] as List;
        return content.where((c) => c['type'] == 'text').map((c) => c['text']).join();
      default:
        final r = await http
            .post(Uri.parse('$_base/chat/completions'),
                headers: {'Content-Type': 'application/json', if (key.isNotEmpty) 'Authorization': 'Bearer $key'},
                body: jsonEncode({
                  'model': model,
                  'temperature': 0.1,
                  'max_tokens': maxTokens,
                  'stream': false,
                  'messages': [
                    {'role': 'system', 'content': system},
                    {'role': 'user', 'content': user},
                  ],
                }))
            .timeout(timeout);
        if (r.statusCode >= 300) throw Exception('AI HTTP ${r.statusCode}: ${_short(r.body)}');
        return '${jsonDecode(utf8.decode(r.bodyBytes))['choices'][0]['message']['content']}';
    }
  }

  /// Daftar model yang tersedia di server AI.
  Future<List<String>> models() async {
    final key = await Storage.secret(kKey);
    if (provider == 'ollama') {
      final r = await http.get(Uri.parse('$_base/api/tags')).timeout(const Duration(seconds: 15));
      return [for (final m in jsonDecode(r.body)['models'] as List) '${m['name']}'];
    }
    if (provider == 'anthropic') {
      final r = await http.get(Uri.parse('https://api.anthropic.com/v1/models'),
          headers: {'x-api-key': key, 'anthropic-version': '2023-06-01'}).timeout(const Duration(seconds: 15));
      if (r.statusCode >= 300) throw Exception('Claude API HTTP ${r.statusCode}');
      return [for (final m in jsonDecode(r.body)['data'] as List) '${m['id']}'];
    }
    final r = await http.get(Uri.parse('$_base/models'), headers: {if (key.isNotEmpty) 'Authorization': 'Bearer $key'}).timeout(const Duration(seconds: 15));
    if (r.statusCode >= 300) throw Exception('AI HTTP ${r.statusCode}: ${_short(r.body)}');
    return [for (final m in jsonDecode(r.body)['data'] as List) '${m['id']}'];
  }

  Future<String> test() async {
    final t = DateTime.now();
    final a = await chat('Jawab singkat.', 'Balas hanya dengan kata: OK', maxTokens: 20);
    return 'AI ($model) menjawab "${a.trim()}" dalam ${DateTime.now().difference(t).inSeconds} detik';
  }

  // ───────────────────────── perbaikan
  static final _secretFile = RegExp(
      r'(key\.properties|\.jks|\.keystore|google-services\.json|GoogleService-Info\.plist|(^|[\\/])\.env|service[-_]?account.*\.json|\.p8|\.p12|\.pem)$',
      caseSensitive: false);

  /// Path file di dalam project yang disebut di log (lib/x.dart:12:3, android/app/build.gradle.kts:20 …).
  static Set<String> filesFromLog(String root, List<String> logs) {
    final out = <String>{};
    final re = RegExp(r'([A-Za-z]:)?[\w\-./\\ ]*?((lib|test|android|ios|integration_test)[\\/][\w\-./\\]+\.(dart|kts|gradle|kt|java|xml|properties|yaml|pro))');
    for (final l in logs) {
      for (final m in re.allMatches(l)) {
        final rel = m.group(2)!.replaceAll('\\', '/');
        if (!_secretFile.hasMatch(rel) && File(p.join(root, rel)).existsSync()) out.add(rel);
      }
    }
    return out;
  }

  /// Minta AI memperbaiki error. Mengembalikan daftar file yang diubah (kosong = AI tidak bisa).
  Future<AiFixResult> fix({
    required String root,
    required String task, // mis. "flutter build appbundle gagal"
    required List<String> logs,
    Set<String> extraFiles = const {},
    void Function(String)? log,
  }) async {
    final res = AiFixResult();
    final files = <String>{
      ...filesFromLog(root, logs),
      ...extraFiles,
      'pubspec.yaml',
      if (logs.any((l) => l.contains('gradle') || l.contains('Gradle') || l.contains('Kotlin') || l.contains('AGP'))) ...[
        for (final f in [
          'android/app/build.gradle.kts', 'android/app/build.gradle', 'android/settings.gradle.kts', 'android/settings.gradle',
          'android/build.gradle.kts', 'android/build.gradle', 'android/gradle.properties', 'android/gradle/wrapper/gradle-wrapper.properties',
          if (deep) 'android/app/src/main/AndroidManifest.xml',
        ])
          if (File(p.join(root, f)).existsSync()) f,
      ],
    }.where((f) => !_secretFile.hasMatch(f)).take(deep ? 14 : 7).toList();

    // Potong log: bagian yang berisi error + ekornya
    final errIdx = <int>[];
    for (var i = 0; i < logs.length; i++) {
      if (RegExp(r'error|Error|FAILURE|failed|Exception|e: ', caseSensitive: true).hasMatch(logs[i])) errIdx.add(i);
    }
    final keep = <int>{};
    for (final i in errIdx.take(60)) {
      for (var k = i - 2; k <= i + 6; k++) {
        if (k >= 0 && k < logs.length) keep.add(k);
      }
    }
    for (var k = logs.length - 40; k < logs.length; k++) {
      if (k >= 0) keep.add(k);
    }
    final logText = (keep.toList()..sort()).map((i) => logs[i]).join('\n');
    final logCut = logText.length > (deep ? 24000 : 10000) ? logText.substring(logText.length - (deep ? 24000 : 10000)) : logText;

    final buf = StringBuffer()
      ..writeln('TUGAS: $task. Perbaiki penyebab error di bawah supaya perintah berhasil.')
      ..writeln()
      ..writeln('=== LOG ERROR ===')
      ..writeln(_mask(logCut))
      ..writeln();
    final limit = deep ? 60000 : 25000;
    var total = 0;
    for (final f in files) {
      var c = await File(p.join(root, f)).readAsString().catchError((_) => '');
      if (c.isEmpty) continue;
      if (c.length > 40000) c = c.substring(0, 40000);
      if (total + c.length > limit) break;
      total += c.length;
      buf
        ..writeln('=== FILE: $f ===')
        ..writeln(_mask(c))
        ..writeln();
    }
    log?.call('🤖 AI ($model) menganalisis ${files.length} file + log error…');

    const system = '''Kamu adalah ahli Flutter, Dart, Gradle (AGP 8/9, Kotlin DSL) dan Android/iOS build.
Tugasmu memperbaiki error build / analyze / test pada project Flutter dengan perubahan sekecil mungkin.
Aturan:
- Ubah HANYA file yang diberikan (atau buat file baru bila benar-benar perlu) di dalam project.
- Jangan pernah mengubah key.properties, keystore, signingConfig password, applicationId, atau versi aplikasi.
- Jangan menghapus fitur aplikasi; perbaiki kodenya.
- Kirim isi file LENGKAP setelah diperbaiki (bukan potongan / diff).
- Perintah yang boleh disarankan: "flutter pub get", "flutter pub upgrade", "flutter clean", "dart fix --apply".
Balas HANYA JSON valid tanpa teks lain, format:
{"explanation":"penjelasan singkat bahasa Indonesia","files":[{"path":"relatif/dari/root","content":"isi lengkap"}],"commands":["flutter pub get"]}
Kalau tidak bisa diperbaiki dengan mengubah file, balas files kosong dan jelaskan di explanation.''';

    final answer = await chat(system, buf.toString());
    final j = _parseJson(answer);
    if (j == null) {
      res.explanation = 'Jawaban AI bukan JSON yang valid: ${_short(answer)}';
      return res;
    }
    res.explanation = '${j['explanation'] ?? ''}';
    for (final f in (j['files'] as List? ?? const [])) {
      final rel = '${f['path'] ?? ''}'.replaceAll('\\', '/').replaceAll(RegExp(r'^\./'), '');
      final content = '${f['content'] ?? ''}';
      if (rel.isEmpty || content.trim().isEmpty) continue;
      final full = p.normalize(p.join(root, rel));
      if (!p.isWithin(root, full) || _secretFile.hasMatch(rel) || rel.contains('..')) {
        log?.call('   ⛔ ditolak (di luar project / file rahasia): $rel');
        continue;
      }
      if (content.contains('•••')) {
        log?.call('   ⛔ ditolak (berisi nilai rahasia yang disamarkan): $rel');
        continue;
      }
      final file = File(full);
      if (await file.exists()) {
        final old = await file.readAsString();
        if (old == content) continue;
        await file.copy('$full.deployhub.bak');
      } else {
        await file.parent.create(recursive: true);
      }
      await file.writeAsString(content);
      res.changed.add(rel);
    }
    for (final c in (j['commands'] as List? ?? const [])) {
      final cmd = '$c'.trim();
      if (RegExp(r'^(flutter pub get|flutter pub upgrade|flutter clean|dart fix --apply)$').hasMatch(cmd)) res.commands.add(cmd);
    }
    return res;
  }

  /// Jalankan perintah aman yang disarankan AI.
  Future<void> runCommands(String root, List<String> cmds, String flutterCmd, void Function(String) log) async {
    for (final c in cmds) {
      final parts = c.split(' ');
      final exe = parts.first == 'flutter' ? flutterCmd : parts.first;
      log('   \$ $c');
      final r = await Process.run(exe, parts.sublist(1), workingDirectory: root, runInShell: true, environment: ToolEnv.env());
      if (r.exitCode != 0) log('     ✖ ${_short('${r.stderr}${r.stdout}')}');
    }
  }

  /// Diagnosis masalah server (log container, status, disk) → penjelasan + perintah perbaikan.
  /// Perintah TIDAK dijalankan di sini — ServerOps menyaring perintah berbahaya dulu.
  Future<AiFixResult> diagnoseServer(String serverName, String context) async {
    const system = """Kamu adalah engineer DevOps / SRE senior (Linux Ubuntu, Docker, Docker Compose, Nginx, MySQL, PostgreSQL, FastAPI, Node).
Tugasmu: diagnosis kenapa server bermasalah dari data di bawah dan berikan perintah shell perbaikan yang AMAN.
Aturan:
- Maksimal 5 perintah, satu baris per perintah, non-interaktif.
- DILARANG: menghapus data/volume/database, rm -rf di luar /tmp, reboot/shutdown, mengubah firewall/SSH/password, git push, curl|sh.
- Utamakan: docker compose up -d, docker restart <nama>, docker compose logs, membersihkan image/cache, systemctl restart <layanan>.
Balas HANYA JSON: {"explanation":"diagnosis singkat bahasa Indonesia","commands":["..."]}""";
    final answer = await chat(system, 'SERVER: $serverName\n\n${_mask(context)}', maxTokens: 4000);
    final res = AiFixResult();
    final j = _parseJson(answer);
    if (j == null) {
      res.explanation = _short(answer);
      return res;
    }
    res.explanation = '${j['explanation'] ?? ''}';
    for (final c in (j['commands'] as List? ?? const []).take(5)) {
      final t = '$c'.trim();
      if (t.isNotEmpty) res.commands.add(t);
    }
    return res;
  }

  // Samarkan password / token yang mungkin ada di file sebelum dikirim ke AI.
  static String _mask(String s) => s
      .replaceAllMapped(RegExp(r'((?:store|key)Password\s*[=:]\s*)\S+', caseSensitive: false), (m) => '${m[1]}•••')
      .replaceAllMapped(RegExp(r'((?:password|passwd|secret|token|api[_-]?key)\s*[=:]\s*["\x27])[^"\x27]{4,}(["\x27])', caseSensitive: false),
          (m) => '${m[1]}•••${m[2]}')
      .replaceAll(RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----'), '•••PRIVATE KEY•••');

  static Map<String, dynamic>? _parseJson(String s) {
    var t = s.trim();
    // buang blok <think>…</think> (Qwen / DeepSeek) dan pagar ```json
    t = t.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(t);
    if (fence != null) t = fence.group(1)!.trim();
    final a = t.indexOf('{'), b = t.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(t.substring(a, b + 1)));
    } catch (_) {
      return null;
    }
  }

  static String _short(String s) => s.length > 300 ? '${s.substring(0, 300)}…' : s;
}

class AiFixResult {
  String explanation = '';
  final changed = <String>[];
  final commands = <String>[];
  bool get ok => changed.isNotEmpty || commands.isNotEmpty;
}
