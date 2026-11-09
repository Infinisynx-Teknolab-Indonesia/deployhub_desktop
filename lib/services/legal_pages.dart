import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'github_service.dart';
import 'storage.dart';

/// Halaman wajib Google Play dibuat otomatis dari SDK & izin yang dipakai aplikasi:
///  • Kebijakan privasi            → Konten aplikasi → Kebijakan privasi
///  • Cara hapus akun & data        → Keamanan Data → Penghapusan akun (wajib kalau ada login)
///  • Standar keselamatan anak      → wajib untuk aplikasi chat / sosial
/// Di-host gratis di GitHub Pages (repo publik <repo>-legal) → link otomatis terisi di proyek.

/// Data yang dikumpulkan satu SDK / izin.
class DataUse {
  const DataUse(this.source, this.data, this.purpose, {this.shared = false, this.policy = ''});
  final String source; // nama SDK / fitur
  final List<String> data; // jenis data (istilah Keamanan Data Google)
  final String purpose;
  final bool shared; // dikirim ke pihak ketiga
  final String policy; // link kebijakan privasi pihak ketiga
}

const _sdkMap = <String, DataUse>{
  'firebase_analytics': DataUse('Google Analytics for Firebase', ['Interaksi aplikasi', 'ID perangkat atau ID lainnya'], 'Analitik penggunaan aplikasi',
      shared: true, policy: 'https://firebase.google.com/support/privacy'),
  'firebase_messaging': DataUse('Firebase Cloud Messaging', ['ID perangkat atau ID lainnya'], 'Mengirim notifikasi', policy: 'https://firebase.google.com/support/privacy'),
  'firebase_crashlytics': DataUse('Firebase Crashlytics', ['Log error', 'Diagnostik', 'ID perangkat atau ID lainnya'], 'Memperbaiki error aplikasi',
      shared: true, policy: 'https://firebase.google.com/support/privacy'),
  'firebase_auth': DataUse('Firebase Authentication', ['Alamat email', 'Nomor telepon', 'ID pengguna'], 'Login dan pengelolaan akun', policy: 'https://firebase.google.com/support/privacy'),
  'google_sign_in': DataUse('Login dengan Google', ['Nama', 'Alamat email', 'ID pengguna'], 'Login dan pengelolaan akun', policy: 'https://policies.google.com/privacy'),
  'cloud_firestore': DataUse('Cloud Firestore', ['Pesan dalam aplikasi', 'Konten buatan pengguna lainnya'], 'Menyimpan data aplikasi', policy: 'https://firebase.google.com/support/privacy'),
  'firebase_storage': DataUse('Firebase Storage', ['Foto', 'Video', 'File dan dokumen'], 'Menyimpan file yang diunggah pengguna', policy: 'https://firebase.google.com/support/privacy'),
  'google_mobile_ads': DataUse('Google AdMob', ['ID perangkat atau ID lainnya', 'Interaksi aplikasi', 'Perkiraan lokasi'], 'Iklan dan pemasaran',
      shared: true, policy: 'https://policies.google.com/technologies/ads'),
  'livekit_client': DataUse('LiveKit (panggilan suara/video)', ['Rekaman suara atau suara', 'Video'], 'Panggilan suara dan video real-time'),
  'flutter_webrtc': DataUse('WebRTC (panggilan suara/video)', ['Rekaman suara atau suara', 'Video'], 'Panggilan suara dan video real-time'),
  'agora_rtc_engine': DataUse('Agora (panggilan suara/video)', ['Rekaman suara atau suara', 'Video'], 'Panggilan suara dan video real-time',
      shared: true, policy: 'https://www.agora.io/en/privacy-policy/'),
  'geolocator': DataUse('Lokasi perangkat', ['Perkiraan lokasi', 'Lokasi akurat'], 'Fitur berbasis lokasi'),
  'location': DataUse('Lokasi perangkat', ['Perkiraan lokasi', 'Lokasi akurat'], 'Fitur berbasis lokasi'),
  'image_picker': DataUse('Galeri & kamera', ['Foto', 'Video'], 'Mengirim / mengunggah foto dan video'),
  'camera': DataUse('Kamera', ['Foto', 'Video'], 'Mengambil foto / video di aplikasi'),
  'file_picker': DataUse('Pemilih file', ['File dan dokumen'], 'Mengirim / mengunggah file'),
  'record': DataUse('Mikrofon', ['Rekaman suara atau suara'], 'Pesan suara'),
  'flutter_sound': DataUse('Mikrofon', ['Rekaman suara atau suara'], 'Pesan suara'),
  'flutter_contacts': DataUse('Kontak', ['Kontak'], 'Mencari teman dari kontak'),
  'contacts_service': DataUse('Kontak', ['Kontak'], 'Mencari teman dari kontak'),
  'onesignal_flutter': DataUse('OneSignal', ['ID perangkat atau ID lainnya'], 'Mengirim notifikasi', shared: true, policy: 'https://onesignal.com/privacy_policy'),
  'sentry_flutter': DataUse('Sentry', ['Log error', 'Diagnostik'], 'Memperbaiki error aplikasi', shared: true, policy: 'https://sentry.io/privacy/'),
  'purchases_flutter': DataUse('RevenueCat', ['Riwayat pembelian'], 'Langganan / pembelian', shared: true, policy: 'https://www.revenuecat.com/privacy'),
  'in_app_purchase': DataUse('Google Play Billing', ['Riwayat pembelian'], 'Pembelian dalam aplikasi', policy: 'https://policies.google.com/privacy'),
};

const _permMap = <String, DataUse>{
  'ACCESS_FINE_LOCATION': DataUse('Izin lokasi', ['Lokasi akurat'], 'Fitur berbasis lokasi'),
  'ACCESS_COARSE_LOCATION': DataUse('Izin lokasi', ['Perkiraan lokasi'], 'Fitur berbasis lokasi'),
  'RECORD_AUDIO': DataUse('Izin mikrofon', ['Rekaman suara atau suara'], 'Pesan suara / panggilan'),
  'CAMERA': DataUse('Izin kamera', ['Foto', 'Video'], 'Foto / video / panggilan video'),
  'READ_CONTACTS': DataUse('Izin kontak', ['Kontak'], 'Mencari teman dari kontak'),
  'AD_ID': DataUse('ID iklan', ['ID perangkat atau ID lainnya'], 'Iklan dan analitik', shared: true),
};

/// Deteksi data yang dikumpulkan dari pubspec.yaml + AndroidManifest.xml.
Future<List<DataUse>> detectDataUse(Project pr) async {
  final out = <DataUse>[];
  final pub = await File(p.join(pr.localPath, 'pubspec.yaml')).readAsString().catchError((_) => '');
  for (final e in _sdkMap.entries) {
    if (RegExp('^\\s+${e.key}\\s*:', multiLine: true).hasMatch(pub)) out.add(e.value);
  }
  final manifest = await File(p.join(pr.localPath, 'android', 'app', 'src', 'main', 'AndroidManifest.xml')).readAsString().catchError((_) => '');
  final perms = {...RegExp(r'android\.permission\.(\w+)').allMatches(manifest).map((m) => m.group(1)!)};
  final covered = out.expand((d) => d.data).toSet();
  for (final e in _permMap.entries) {
    if (perms.contains(e.key) && !e.value.data.every(covered.contains)) out.add(e.value);
  }
  if (pr.hasLogin) out.insert(0, const DataUse('Akun', ['Nama', 'Alamat email', 'ID pengguna'], 'Membuat dan mengelola akun'));
  if (pr.isSocialApp) out.insert(0, const DataUse('Chat', ['Pesan dalam aplikasi', 'Konten buatan pengguna lainnya'], 'Fitur chat antar pengguna'));
  return out;
}

/// Panduan jawaban formulir Keamanan Data (teks siap ikuti di Play Console).
String dataSafetyGuide(Project pr, List<DataUse> uses) {
  final byType = <String, Set<String>>{};
  final sharedTypes = <String>{};
  for (final u in uses) {
    for (final d in u.data) {
      (byType[d] ??= {}).add(u.purpose);
      if (u.shared) sharedTypes.add(d);
    }
  }
  final b = StringBuffer()
    ..writeln('Apakah aplikasi mengumpulkan / membagikan data pengguna? ${byType.isEmpty ? 'Tidak' : 'Ya'}')
    ..writeln('Semua data dienkripsi saat dikirim (HTTPS)? Ya')
    ..writeln('Pengguna bisa minta data dihapus? ${pr.hasLogin ? 'Ya — link: ${pr.deleteAccountUrl.isEmpty ? '(buat lewat tombol Buat halaman wajib)' : pr.deleteAccountUrl}' : 'Ya (lewat email kontak)'}')
    ..writeln()
    ..writeln('Jenis data yang perlu dicentang:');
  for (final e in byType.entries) {
    b.writeln('• ${e.key} — Dikumpulkan${sharedTypes.contains(e.key) ? ' + Dibagikan' : ''} • Tujuan: ${e.value.join(', ')}');
  }
  b
    ..writeln()
    ..writeln('Setelah selesai di Play Console: Export to CSV → simpan sebagai store/data_safety.csv,')
    ..writeln('berikutnya DeployHub mengupload otomatis setiap deploy.');
  return b.toString();
}

class LegalInfo {
  LegalInfo({required this.appName, required this.developer, required this.email, this.deleteSteps = '', this.retentionDays = 30, this.childContact = ''});
  String appName, developer, email, deleteSteps, childContact;
  int retentionDays;
}

String _esc(String s) => const HtmlEscape().convert(s);

String _page(String title, String body) => '''<!doctype html>
<html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_esc(title)}</title>
<style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:760px;margin:0 auto;padding:24px 16px;line-height:1.6;color:#1b1f24;background:#fff}
h1{font-size:1.6rem}h2{font-size:1.15rem;margin-top:1.6em}table{border-collapse:collapse;width:100%}td,th{border:1px solid #d0d7de;padding:6px 8px;text-align:left;vertical-align:top}
small{color:#57606a}a{color:#0969da}@media(prefers-color-scheme:dark){body{background:#0d1117;color:#e6edf3}td,th{border-color:#30363d}a{color:#4493f8}small{color:#8d96a0}}</style>
</head><body>
$body
<hr><small>Terakhir diperbarui: ${DateTime.now().toIso8601String().substring(0, 10)}</small>
</body></html>
''';

Map<String, String> buildLegalPages(Project pr, LegalInfo i, List<DataUse> uses) {
  final app = _esc(i.appName), dev = _esc(i.developer), mail = _esc(i.email);
  final rows = uses
      .map((u) => '<tr><td>${_esc(u.source)}</td><td>${_esc(u.data.join(', '))}</td><td>${_esc(u.purpose)}</td>'
          '<td>${u.shared ? (u.policy.isEmpty ? 'Ya' : 'Ya — <a href="${_esc(u.policy)}">kebijakan</a>') : 'Tidak'}</td></tr>')
      .join('\n');
  final privacy = _page('Kebijakan Privasi — ${i.appName}', '''
<h1>Kebijakan Privasi $app</h1>
<p>Kebijakan ini menjelaskan data apa yang dikumpulkan aplikasi <b>$app</b> (dikembangkan oleh <b>$dev</b>), untuk apa data itu dipakai, dan hak Anda atas data tersebut.</p>
<h2>1. Data yang kami kumpulkan</h2>
${uses.isEmpty ? '<p>Aplikasi ini tidak mengumpulkan data pribadi.</p>' : '<table><tr><th>Sumber / fitur</th><th>Data</th><th>Tujuan</th><th>Dibagikan ke pihak ketiga</th></tr>\n$rows\n</table>'}
<h2>2. Cara kami menggunakan data</h2>
<p>Data hanya dipakai untuk menjalankan fitur aplikasi, menjaga keamanan akun, memperbaiki error, dan (bila ada) menampilkan iklan. Kami tidak menjual data pribadi Anda.</p>
<h2>3. Keamanan</h2>
<p>Semua data dikirim melalui koneksi terenkripsi (HTTPS/TLS). Akses ke server dibatasi hanya untuk pengelola aplikasi.</p>
<h2>4. Penyimpanan &amp; penghapusan</h2>
<p>Data disimpan selama akun Anda aktif. Setelah akun dihapus, data pribadi dihapus dalam ${i.retentionDays} hari, kecuali yang wajib disimpan menurut hukum.
${pr.hasLogin ? 'Cara menghapus akun: <a href="delete-account.html">halaman penghapusan akun</a>.' : 'Untuk meminta penghapusan data, hubungi kami lewat email di bawah.'}</p>
<h2>5. Anak-anak</h2>
<p>Aplikasi ini ditujukan untuk pengguna berusia 18 tahun ke atas dan tidak ditujukan untuk anak-anak. Kami tidak dengan sengaja mengumpulkan data anak.${pr.isSocialApp ? ' Lihat juga <a href="child-safety.html">standar keselamatan anak</a>.' : ''}</p>
<h2>6. Hak Anda</h2>
<p>Anda berhak meminta salinan, perbaikan, atau penghapusan data pribadi Anda, sesuai UU No. 27 Tahun 2022 tentang Pelindungan Data Pribadi.</p>
<h2>7. Kontak</h2>
<p>$dev — <a href="mailto:$mail">$mail</a></p>
<h2>English summary</h2>
<p>$app collects only the data listed above to operate its features, keep accounts secure, fix crashes${uses.any((u) => u.source.contains('AdMob')) ? ' and show ads' : ''}. Data is encrypted in transit, never sold, and deleted within ${i.retentionDays} days after account deletion. Contact: <a href="mailto:$mail">$mail</a>.</p>
''');
  final steps = i.deleteSteps.trim().isEmpty ? 'Buka aplikasi → Profil / Pengaturan → Hapus akun → konfirmasi.' : i.deleteSteps.trim();
  final delete = _page('Hapus Akun — ${i.appName}', '''
<h1>Menghapus akun &amp; data $app</h1>
<h2>Dari dalam aplikasi</h2>
<p>${_esc(steps).replaceAll('\n', '<br>')}</p>
<h2>Tanpa aplikasi (lewat email)</h2>
<p>Kirim email ke <a href="mailto:$mail?subject=${Uri.encodeComponent('Hapus akun ${i.appName}')}">$mail</a> dengan subjek <b>"Hapus akun ${_esc(i.appName)}"</b> dari email / nomor yang terdaftar. Permintaan diproses maksimal 7 hari kerja.</p>
<h2>Data yang dihapus</h2>
<p>Profil, pesan, foto/file yang Anda unggah, dan data login dihapus permanen dalam ${i.retentionDays} hari. Log transaksi yang wajib disimpan menurut hukum dapat disimpan lebih lama dalam bentuk anonim.</p>
<p><small>Developer: $dev</small></p>
''');
  final child = _page('Standar Keselamatan Anak — ${i.appName}', '''
<h1>Standar Keselamatan Anak $app</h1>
<p><b>$dev</b> menerapkan kebijakan <b>tanpa toleransi</b> terhadap eksploitasi dan pelecehan seksual anak (CSAE) serta materi pelecehan seksual anak (CSAM).</p>
<h2>Larangan</h2>
<p>Dilarang membuat, mengunggah, membagikan, atau meminta konten yang mengeksploitasi atau membahayakan anak, termasuk grooming dan sextortion. Akun yang melanggar diblokir permanen.</p>
<h2>Melapor</h2>
<p>Pengguna dapat melaporkan pesan, konten, atau akun langsung dari dalam aplikasi (menu Laporkan / Blokir) atau lewat email <a href="mailto:$mail">$mail</a>. Laporan ditinjau secepatnya.</p>
<h2>Tindakan</h2>
<p>Konten CSAM dihapus, akun diblokir, dan kasus dilaporkan ke pihak berwenang (Kepolisian RI / Kementerian PPPA) serta organisasi terkait sesuai hukum yang berlaku.</p>
<h2>Kepatuhan hukum</h2>
<p>Kami mematuhi hukum perlindungan anak yang berlaku, termasuk UU No. 35 Tahun 2014 tentang Perlindungan Anak.</p>
<h2>Kontak penanggung jawab keselamatan anak</h2>
<p>${_esc(i.childContact.isEmpty ? i.developer : i.childContact)} — <a href="mailto:$mail">$mail</a></p>
''');
  return {
    'index.html': privacy,
    if (pr.hasLogin) 'delete-account.html': delete,
    if (pr.isSocialApp) 'child-safety.html': child,
  };
}

/// Simpan halaman di folder proyek (store/legal/) + host di GitHub Pages. Mengembalikan URL dasar.
Future<String> publishLegalPages(Project pr, Map<String, String> pages, void Function(String) log) async {
  final dir = Directory(p.join(pr.localPath, 'store', 'legal'));
  await dir.create(recursive: true);
  for (final e in pages.entries) {
    await File(p.join(dir.path, e.key)).writeAsString(e.value);
  }
  log('💾 ${dir.path}');
  final token = await Storage.secret(Secrets.github);
  if (token.isEmpty || pr.githubOwner.isEmpty) throw Exception('Hubungkan GitHub dulu (Pengaturan → GitHub) supaya halaman bisa di-host otomatis');
  final gh = GitHubService(token);
  final repo = '${(pr.githubRepo.isEmpty ? pr.name : pr.githubRepo).toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]+'), '-')}-legal';
  if (await gh.repo(pr.githubOwner, repo) == null) {
    final org = await gh.isOrg(pr.githubOwner) ? pr.githubOwner : '';
    await gh.createRepo(repo, private: false, description: 'Kebijakan privasi & halaman wajib ${pr.name}', org: org);
    log('📁 repo publik ${pr.githubOwner}/$repo dibuat (hanya berisi halaman legal, bukan kode aplikasi)');
  }
  for (final e in pages.entries) {
    await gh.putFile(pr.githubOwner, repo, e.key, e.value, message: 'Perbarui ${e.key} (DeployHub)');
    log('⬆ ${e.key}');
  }
  final url = await gh.enablePages(pr.githubOwner, repo);
  log('🌐 $url (aktif dalam ±1–2 menit)');
  return url.endsWith('/') ? url : '$url/';
}
