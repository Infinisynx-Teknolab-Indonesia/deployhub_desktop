import '../core/i18n.dart';
import '../models.dart';

/// Tugas "Konten aplikasi" di Play Console yang TIDAK punya API.
/// DeployHub menyiapkan jawaban siap tempel + checklist.
class ConsoleTask {
  ConsoleTask(this.key, this.title, this.where, this.suggestion, {this.auto = ''});
  final String key;
  final String title;
  final String where; // lokasi di Play Console
  final String suggestion; // jawaban bawaan (satu bahasa, siap tempel)
  final String auto; // kalau diisi: bagian ini sudah diotomatisasi DeployHub
}

List<ConsoleTask> consoleTasks(Project pr) {
  final yes = trL('Ya'), no = trL('Tidak');
  final demo = pr.demoUser.isEmpty
      ? trL('Semua fitur bisa dipakai tanpa login')
      : '${trL('Semua atau sebagian fitur dibatasi (perlu login)')}\n'
          '${trL('Nama')}: ${trL('Akun demo reviewer')}\n'
          'Username: ${pr.demoUser}\n'
          'Password: ${trL('(salin dari tombol "Salin info" di Cek Kelayakan Rilis)')}\n'
          '${trL('Catatan: akun ini tidak memerlukan OTP / verifikasi email.')}';
  return [
    ConsoleTask('privacy', tr('Kebijakan privasi'), tr('Konten aplikasi → Kebijakan privasi'),
        pr.privacyPolicyUrl.isEmpty ? trL('(isi link kebijakan privasi di Edit Proyek)') : pr.privacyPolicyUrl),
    ConsoleTask('app_access', tr('Detail login'), tr('Konten aplikasi → Detail login'), demo),
    ConsoleTask('ads', tr('Iklan'), tr('Konten aplikasi → Iklan'),
        pr.hasAds ? trL('Ya, aplikasi saya berisi iklan (Google AdMob)') : trL('Tidak, aplikasi saya tidak berisi iklan')),
    ConsoleTask(
        'content_rating',
        tr('Rating konten'),
        tr('Konten aplikasi → Rating konten (kuesioner IARC)'),
        '${trL('Kategori: Sosial & komunikasi')}\n'
            '${trL('Kekerasan, seksual, bahasa kasar, narkoba, judi')}: $no\n'
            '${trL('Pengguna bisa berinteraksi/berkomunikasi')}: ${pr.isSocialApp ? yes : no}\n'
            '${trL('Pengguna bisa berbagi konten buatan sendiri')}: ${pr.isSocialApp ? yes : no}\n'
            '${trL('Berbagi lokasi dengan pengguna lain')}: $no\n'
            '${trL('Pembelian barang digital')}: $no'),
    ConsoleTask('target_audience', tr('Audiens target'), tr('Konten aplikasi → Audiens target dan konten'),
        trL('Usia 18 tahun ke atas\nAplikasi tidak menarik bagi anak-anak: Ya')),
    ConsoleTask('data_safety', tr('Keamanan Data'), tr('Konten aplikasi → Keamanan Data'),
        trL('Isi sekali, lalu Export to CSV → simpan sebagai store/data_safety.csv'),
        auto: trL('Setelah ada store/data_safety.csv, DeployHub mengupload otomatis tiap deploy')),
    ConsoleTask('government', tr('Aplikasi pemerintah'), tr('Konten aplikasi → Aplikasi pemerintah'),
        trL('Tidak, aplikasi ini tidak dikembangkan oleh atau atas nama pemerintah')),
    ConsoleTask('financial', tr('Fitur keuangan'), tr('Konten aplikasi → Fitur keuangan'),
        trL('Aplikasi saya tidak menyediakan fitur keuangan apa pun')),
    ConsoleTask('health', tr('Kesehatan'), tr('Konten aplikasi → Kesehatan'),
        trL('Aplikasi saya tidak memiliki fitur kesehatan')),
    ConsoleTask('category', tr('Kategori & detail kontak'), tr('Kehadiran di toko → Setelan toko'),
        '${trL('Jenis: Aplikasi')}\n${trL('Kategori')}: ${pr.isSocialApp ? trL('Komunikasi (atau Sosial)') : '...'}',
        auto: trL('Email/website/telepon kontak disinkron otomatis dari store/details.json')),
    if (pr.isSocialApp)
      ConsoleTask(
          'child_safety',
          tr('Standar keselamatan anak'),
          tr('Konten aplikasi → Standar keselamatan anak'),
          '${trL('Link standar CSAE')}: ${pr.childSafetyUrl.isEmpty ? trL('(isi di Edit Proyek)') : pr.childSafetyUrl}\n'
              '${trL('Mekanisme lapor di aplikasi')}: $yes\n'
              '${trL('Kepatuhan hukum perlindungan anak')}: $yes\n'
              '${trL('Kontak penanggung jawab CSAM: (nama) – (email) – (telepon)')}'),
    ConsoleTask('listing', tr('Listing Play Store'), tr('Kehadiran di toko → Listingan Play Store utama'),
        trL('Teks & gambar dari folder store/android/<bahasa>/'),
        auto: trL('Disinkron otomatis tiap deploy (judul, deskripsi, ikon, feature graphic, screenshot)')),
  ];
}

/// Ringkasan pengujian tertutup untuk akun pribadi (12 tester, 14 hari).
class ClosedTestStatus {
  ClosedTestStatus(this.pr);
  final Project pr;
  static const minTesters = 12;
  static const minDays = 14;

  int get days => pr.closedTestDays ?? 0;
  bool get started => pr.closedTestDays != null;
  bool get testersOk => pr.testerCount >= minTesters;
  bool get daysOk => days >= minDays;
  bool get ready => !pr.isPersonalAccount || (started && testersOk && daysOk);
  int get daysLeft => (minDays - days).clamp(0, minDays).toInt();

  String describe() {
    if (!pr.isPersonalAccount) return trL('Akun organisasi — tidak wajib pengujian tertutup');
    if (!started) return trL('Pengujian tertutup belum dimulai');
    final base = trL('Hari ke-{0} dari {1}, {2}/{3} tester', [days, minDays, pr.testerCount, minTesters]);
    return ready
        ? '$base — ${trL('siap ajukan akses produksi')}'
        : '$base — ${trL('sisa {0} hari', [daysLeft])}';
  }
}
