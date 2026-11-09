import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../utils.dart';

class GitHubError implements Exception {
  final int status;
  final String message;
  GitHubError(this.status, this.message);
  @override
  String toString() => 'GitHub $status: $message';
}

class GitHubService {
  GitHubService(this.token);
  final String token;
  static const _api = 'https://api.github.com';

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  String _msg(String body) {
    try {
      return (jsonDecode(body) as Map)['message']?.toString() ?? body;
    } catch (_) {
      return body;
    }
  }

  Future<dynamic> _req(String method, String path, {Object? body}) async {
    final uri = Uri.parse('$_api$path');
    final r = switch (method) {
      'POST' => await http.post(uri,
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: body == null ? null : jsonEncode(body)),
      'PATCH' => await http.patch(uri,
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: body == null ? null : jsonEncode(body)),
      'PUT' => await http.put(uri,
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: body == null ? null : jsonEncode(body)),
      _ => await http.get(uri, headers: _headers),
    };
    if (r.statusCode >= 300) throw GitHubError(r.statusCode, _msg(r.body));
    if (r.body.isEmpty) return null;
    return jsonDecode(r.body);
  }

  /// Deploy key (SSH, read-only) — server bisa git clone / pull repo private tanpa menyimpan token.
  Future<void> addDeployKey(String owner, String repo, String title, String publicKey, {bool readOnly = true}) async {
    try {
      await _req('POST', '/repos/$owner/$repo/keys', body: {'title': title, 'key': publicKey.trim(), 'read_only': readOnly});
    } on GitHubError catch (e) {
      if (e.status == 422 && e.message.contains('already')) return; // key sudah terdaftar
      rethrow;
    }
  }

  /// Webhook push → DeployHub Server (dibuat sekali; kalau URL sama sudah ada, diperbarui).
  Future<void> upsertWebhook(String owner, String repo, String url, String secret, {List<String> events = const ['push', 'pull_request']}) async {
    final hooks = (await _req('GET', '/repos/$owner/$repo/hooks') as List).cast<Map>();
    final existing = hooks.where((h) => h['config']?['url'] == url).firstOrNull;
    final body = {
      'name': 'web',
      'active': true,
      'events': events,
      'config': {'url': url, 'content_type': 'json', 'secret': secret, 'insecure_ssl': '0'},
    };
    if (existing != null) {
      await _req('PATCH', '/repos/$owner/$repo/hooks/${existing['id']}', body: body);
    } else {
      await _req('POST', '/repos/$owner/$repo/hooks', body: body);
    }
  }

  /// true kalau [owner] adalah organisasi (bukan akun pribadi).
  Future<bool> isOrg(String owner) async => (await _req('GET', '/users/$owner') as Map)['type'] == 'Organization';

  /// Repo ada? (null = tidak ada)
  Future<Map<String, dynamic>?> repo(String owner, String name) async {
    try {
      return Map<String, dynamic>.from(await _req('GET', '/repos/$owner/$name'));
    } on GitHubError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// Buat / perbarui satu file lewat Contents API.
  Future<void> putFile(String owner, String repo, String path, String content, {String message = 'update', String branch = 'main'}) async {
    String? sha;
    try {
      sha = (await _req('GET', '/repos/$owner/$repo/contents/$path?ref=$branch') as Map)['sha'] as String?;
    } on GitHubError catch (e) {
      if (e.status != 404) rethrow;
    }
    await _req('PUT', '/repos/$owner/$repo/contents/$path', body: {
      'message': message,
      'content': base64Encode(utf8.encode(content)),
      'branch': branch,
      if (sha != null) 'sha': sha,
    });
  }

  /// Aktifkan GitHub Pages (branch main, folder root). Mengembalikan URL situs.
  Future<String> enablePages(String owner, String repo, {String branch = 'main'}) async {
    try {
      await _req('POST', '/repos/$owner/$repo/pages', body: {
        'source': {'branch': branch, 'path': '/'},
      });
    } on GitHubError catch (e) {
      if (e.status != 409) rethrow; // 409 = Pages sudah aktif
    }
    final info = await _req('GET', '/repos/$owner/$repo/pages') as Map;
    return '${info['html_url'] ?? 'https://${owner.toLowerCase()}.github.io/$repo/'}';
  }

  /// Semua repo yang bisa diakses token (milik sendiri, kolaborator, organisasi), terbaru dulu.
  Future<List<Map<String, dynamic>>> repos() async {
    final out = <Map<String, dynamic>>[];
    for (var page = 1; page <= 5; page++) {
      final r = await _req('GET',
          '/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member&page=$page');
      final list = (r as List).cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      out.addAll(list);
      if (list.length < 100) break;
    }
    return out;
  }

  /// Buat repo baru di akun sendiri (atau di organisasi kalau [org] diisi).
  Future<Map<String, dynamic>> createRepo(String name, {bool private = true, String description = '', String org = ''}) async =>
      Map<String, dynamic>.from(await _req('POST', org.isEmpty ? '/user/repos' : '/orgs/$org/repos', body: {
        'name': name,
        'private': private,
        'description': description,
        'auto_init': false,
      }) as Map);

  Future<String> currentUser() async =>
      ((await _req('GET', '/user')) as Map)['login'].toString();

  Future<List<Map<String, dynamic>>> workflows(String owner, String repo) async {
    final r = await _req('GET', '/repos/$owner/$repo/actions/workflows') as Map;
    return (r['workflows'] as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> runs(String owner, String repo) async {
    final r = await _req('GET', '/repos/$owner/$repo/actions/runs?per_page=20')
        as Map;
    return (r['workflow_runs'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> dispatch(
      String owner, String repo, int workflowId, String ref) async {
    await _req('POST',
        '/repos/$owner/$repo/actions/workflows/$workflowId/dispatches',
        body: {'ref': ref});
  }

  /// Buat GitHub Release dan lampirkan file (mis. .aab). Mengembalikan URL release.
  Future<String> createReleaseWithAsset({
    required String owner,
    required String repo,
    required String tag,
    required String name,
    required String body,
    required String target,
    required File asset,
    required String assetName,
    void Function(String)? log,
  }) async {
    log?.call('Membuat release $tag di $owner/$repo...');
    final rel = await _req('POST', '/repos/$owner/$repo/releases', body: {
      'tag_name': tag,
      'name': name,
      'body': body,
      'target_commitish': target,
    }) as Map<String, dynamic>;

    final uploadUrl = (rel['upload_url'] as String).split('{').first;
    final bytes = await asset.readAsBytes();
    log?.call('Mengupload $assetName (${fmtMb(bytes.length)})...');
    final r = await http.post(
      Uri.parse('$uploadUrl?name=${Uri.encodeQueryComponent(assetName)}'),
      headers: {..._headers, 'Content-Type': 'application/octet-stream'},
      body: bytes,
    );
    if (r.statusCode >= 300) throw GitHubError(r.statusCode, _msg(r.body));
    return rel['html_url'] as String;
  }
}

class Telegram {
  static Future<void> send(String token, String chatId, String text) async {
    final r = await http.post(
      Uri.parse('https://api.telegram.org/bot$token/sendMessage'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'chat_id': chatId, 'text': text}),
    );
    if (r.statusCode >= 300) throw Exception('Telegram: ${r.body}');
  }
}
