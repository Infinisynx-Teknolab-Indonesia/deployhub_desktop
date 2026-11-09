import '../core/i18n.dart';
import '../models.dart';
import 'play_console_tasks.dart';
import 'store_metadata.dart';

enum StageState { done, current, locked }

/// Jenis aksi yang ditawarkan di setiap tahap.
enum StageAction {
  editProject,
  settings,
  manual,
  console,
  storeTemplate,
  deployInternal,
  testers,
  deployProduction,
  deployTestflight,
  deployAppStore,
  copyStoreInfo,
  none,
}

class JourneyStage {
  JourneyStage({
    required this.key,
    required this.title,
    required this.description,
    required this.done,
    required this.action,
    this.actionLabel = '',
    this.manual = false,
    this.progress,
    this.progressText = '',
  });
  final String key;
  final String title;
  final String description;
  final bool done;
  final StageAction action;
  final String actionLabel;
  final bool manual; // diselesaikan dengan centang manual (tidak bisa dicek otomatis)
  final double? progress;
  final String progressText;
  StageState state = StageState.locked;
}

/// Perjalanan rilis Google Play dari nol sampai tampil publik.
/// Tahap baru terbuka setelah semua tahap sebelumnya selesai.
Future<List<JourneyStage>> buildJourney(Project pr, List<RunRecord> history, bool playConnected) async {
  bool uploaded(String track) =>
      history.any((r) => r.projectId == pr.id && r.status == 'success' && r.track == track);
  final ct = ClosedTestStatus(pr);
  final tasks = consoleTasks(pr);
  final tasksDone = tasks.where((t) => pr.consoleDone.contains(t.key)).length;
  final meta = await loadStoreMeta(pr);
  final storeReady = meta != null && meta.listings.isNotEmpty;

  // Aplikasi yang sudah live: semua setup awal sudah beres di Play Console,
  // cukup update AAB. Tampilkan satu tahap saja.
  if (pr.alreadyLive) {
    final s = JourneyStage(
      key: 'production',
      title: tr('Rilis update ke publik (production)'),
      description: trL('Aplikasi sudah live di Play Store. Build AAB baru lalu deploy ke track production.'),
      done: uploaded('production'),
      action: StageAction.deployProduction,
      actionLabel: tr('Deploy ke production'),
    );
    s.state = StageState.current;
    return [s];
  }

  final projectReady = pr.localPath.isNotEmpty &&
      pr.packageName.isNotEmpty &&
      pr.privacyPolicyUrl.isNotEmpty &&
      (!pr.hasLogin || (pr.demoUser.isNotEmpty && pr.deleteAccountUrl.isNotEmpty)) &&
      (!pr.isSocialApp || pr.childSafetyUrl.isNotEmpty);

  final stages = <JourneyStage>[
    JourneyStage(
      key: 'project',
      title: tr('Lengkapi data proyek'),
      description: trL('Folder, package, fitur aplikasi, link kebijakan, akun demo (kalau ada login), link CSAE (kalau ada chat).'),
      done: projectReady,
      action: StageAction.editProject,
      actionLabel: tr('Edit proyek'),
    ),
    JourneyStage(
      key: 'connect',
      title: tr('Hubungkan Google Play'),
      description: trL('Login dengan Google atau Service Account di Pengaturan → Akun & koneksi.'),
      done: playConnected || pr.serviceAccountPath.isNotEmpty,
      action: StageAction.settings,
      actionLabel: tr('Buka Pengaturan'),
    ),
    JourneyStage(
      key: 'app_created',
      title: tr('Buat aplikasi di Play Console + upload AAB pertama'),
      description: trL('Sekali saja, manual: Play Console → Buat aplikasi. Upload AAB pertama ke Pengujian internal lewat browser (API Google tidak bisa membuat aplikasi baru). Setelah itu semua upload otomatis dari DeployHub.'),
      done: pr.journeyDone.contains('app_created') || uploaded('internal') || uploaded('alpha') || uploaded('production'),
      action: StageAction.manual,
      actionLabel: tr('Sudah saya lakukan'),
      manual: true,
    ),
    JourneyStage(
      key: 'console',
      title: tr('Isi Konten aplikasi di Play Console'),
      description: trL('Kebijakan privasi, Detail login, Iklan, Rating konten, Audiens, Keamanan Data, dll. Jawaban siap tempel ada di checklist.'),
      done: tasksDone >= tasks.length,
      action: StageAction.console,
      actionLabel: tr('Buka checklist'),
      progress: tasks.isEmpty ? 0 : tasksDone / tasks.length,
      progressText: '$tasksDone/${tasks.length}',
    ),
    JourneyStage(
      key: 'listing',
      title: tr('Siapkan listing Play Store'),
      description: trL('Judul, deskripsi, ikon 512×512, feature graphic 1024×500, minimal 2 screenshot di folder store/. Disinkron otomatis saat deploy.'),
      done: storeReady,
      action: StageAction.storeTemplate,
      actionLabel: tr('Buat template store/'),
    ),
    JourneyStage(
      key: 'internal',
      title: tr('Uji internal'),
      description: trL('Deploy ke track internal. Dalam beberapa menit bisa diinstall tester internal lewat Play Store (tidak tampil publik).'),
      done: uploaded('internal') || uploaded('alpha') || uploaded('production'),
      action: StageAction.deployInternal,
      actionLabel: tr('Deploy ke internal'),
    ),
  ];

  if (pr.isPersonalAccount) {
    stages.addAll([
      JourneyStage(
        key: 'recruit',
        title: tr('Rekrut minimal 12 tester'),
        description: trL('Buat Google Group, masukkan email tester, pasang grup di track Pengujian tertutup (alpha), lalu kirim link undangan. Tester harus klik "Jadi penguji" (opt-in).'),
        done: pr.testerGroupList.isNotEmpty && pr.testerCount >= ClosedTestStatus.minTesters,
        action: StageAction.testers,
        actionLabel: tr('Atur tester & undangan'),
        progress: pr.testerCount / ClosedTestStatus.minTesters,
        progressText: '${pr.testerCount}/${ClosedTestStatus.minTesters}',
      ),
      JourneyStage(
        key: 'closed_test',
        title: tr('Pengujian tertutup 14 hari'),
        description: trL('Deploy ke track alpha, lalu 12 tester harus tetap ikut selama 14 hari berturut-turut. Tester yang keluar lalu masuk lagi mengulang hitungan.'),
        done: uploaded('alpha') && ct.started && ct.daysOk && ct.testersOk,
        action: StageAction.testers,
        actionLabel: tr('Atur tanggal mulai'),
        progress: ct.days / ClosedTestStatus.minDays,
        progressText: ct.started ? trL('Hari ke-{0} dari {1}', [ct.days.clamp(0, 999), ClosedTestStatus.minDays]) : trL('Belum mulai'),
      ),
      JourneyStage(
        key: 'prod_access',
        title: tr('Ajukan akses produksi'),
        description: trL('Play Console → Dasbor → Ajukan akses produksi. Jawab pertanyaan tentang tester, masukan mereka, dan perubahan yang kamu buat. Tunggu persetujuan Google (biasanya beberapa hari).'),
        done: pr.journeyDone.contains('prod_access'),
        action: StageAction.manual,
        actionLabel: tr('Akses produksi sudah disetujui'),
        manual: true,
      ),
    ]);
  }

  stages.add(JourneyStage(
    key: 'production',
    title: tr('Rilis ke publik (production)'),
    description: trL('Deploy ke track production. Google mereview beberapa jam sampai beberapa hari, setelah lolos aplikasi tampil di Play Store untuk semua orang.'),
    done: uploaded('production'),
    action: StageAction.deployProduction,
    actionLabel: tr('Deploy ke production'),
  ));

  _lock(stages);
  return stages;
}

void _lock(List<JourneyStage> stages) {
  var blocked = false;
  for (final s in stages) {
    if (blocked) {
      s.state = StageState.locked;
    } else if (s.done) {
      s.state = StageState.done;
    } else {
      s.state = StageState.current;
      blocked = true;
    }
  }
}

/// Perjalanan rilis App Store (iOS) dari nol sampai tampil publik.
List<JourneyStage> buildIosJourney(Project pr, List<RunRecord> history, AppSettings s) {
  bool shipped(String track) =>
      history.any((r) => r.projectId == pr.id && r.platform == 'ios' && r.status == 'success' && r.track == track);
  final projectReady = pr.useIos &&
      pr.macProjectPath.isNotEmpty &&
      pr.iosBundleId.isNotEmpty &&
      pr.privacyPolicyUrl.isNotEmpty &&
      (!pr.hasLogin || pr.demoUser.isNotEmpty);
  final keyReady = (pr.ascKeyId.isNotEmpty || s.ascKeyId.isNotEmpty) &&
      (pr.ascIssuerId.isNotEmpty || s.ascIssuerId.isNotEmpty) &&
      s.ascP8Path.isNotEmpty;

  final stages = <JourneyStage>[
    JourneyStage(
      key: 'ios_project',
      title: tr('Lengkapi data proyek iOS'),
      description: trL('Aktifkan "Rilis juga ke iPhone", isi folder project di MacBook, Bundle ID, link kebijakan privasi, dan akun demo (kalau ada login).'),
      done: projectReady,
      action: StageAction.editProject,
      actionLabel: tr('Edit proyek'),
    ),
    JourneyStage(
      key: 'ios_key',
      title: tr('Akun Apple Developer + API key App Store Connect'),
      description: trL('Butuh keanggotaan Apple Developer Program (berbayar per tahun). App Store Connect → Users and Access → Integrations → App Store Connect API → buat key (akses App Manager), download .p8, isi Key ID, Issuer ID, dan file .p8 di Pengaturan.'),
      done: keyReady,
      action: StageAction.settings,
      actionLabel: tr('Buka Pengaturan'),
    ),
    JourneyStage(
      key: 'ios_mac',
      title: tr('Hubungkan MacBook'),
      description: trL('Di Mac: System Settings → General → Sharing → Remote Login aktif. Pasang Xcode, Flutter, CocoaPods (dan fastlane untuk kirim review otomatis). Lalu isi host, user, password di Pengaturan dan klik "Tes SSH MacBook".'),
      done: s.macHost.isNotEmpty && s.macUser.isNotEmpty,
      action: StageAction.settings,
      actionLabel: tr('Buka Pengaturan'),
    ),
    JourneyStage(
      key: 'ios_app_created',
      title: tr('Daftarkan Bundle ID + buat aplikasi di App Store Connect'),
      description: trL('Sekali saja, manual: developer.apple.com → Identifiers → daftarkan Bundle ID ({0}). Lalu App Store Connect → Apps → + → New App, pilih Bundle ID tersebut.', [pr.iosBundleId.isEmpty ? '-' : pr.iosBundleId]),
      done: pr.journeyDone.contains('ios_app_created') || shipped('testflight') || shipped('appstore'),
      action: StageAction.manual,
      actionLabel: tr('Sudah saya lakukan'),
      manual: true,
    ),
    JourneyStage(
      key: 'ios_signing',
      title: tr('Atur signing di Xcode (sekali)'),
      description: trL('Di MacBook buka ios/Runner.xcworkspace → Runner → Signing & Capabilities → centang "Automatically manage signing" dan pilih Team. Login Apple ID di Xcode → Settings → Accounts.'),
      done: pr.journeyDone.contains('ios_signing') || shipped('testflight') || shipped('appstore'),
      action: StageAction.manual,
      actionLabel: tr('Sudah saya lakukan'),
      manual: true,
    ),
    JourneyStage(
      key: 'ios_testflight',
      title: tr('Upload ke TestFlight'),
      description: trL('Deploy mode TestFlight. Build diproses Apple 5–30 menit lalu muncul di App Store Connect → TestFlight.'),
      done: shipped('testflight') || shipped('appstore'),
      action: StageAction.deployTestflight,
      actionLabel: tr('Deploy ke TestFlight'),
    ),
    JourneyStage(
      key: 'ios_tested',
      title: tr('Uji lewat TestFlight'),
      description: trL('App Store Connect → TestFlight → Internal Testing → tambahkan tester (maks 100, langsung tanpa review). Tester install aplikasi TestFlight di iPhone lalu install aplikasimu. Untuk tester luar (External) perlu Beta App Review.'),
      done: pr.journeyDone.contains('ios_tested') || shipped('appstore'),
      action: StageAction.manual,
      actionLabel: tr('Sudah diuji'),
      manual: true,
    ),
    JourneyStage(
      key: 'ios_store_info',
      title: tr('Isi informasi App Store'),
      description: trL('App Store Connect → aplikasi → versi: screenshot iPhone 6.7" / 6.5", deskripsi, kata kunci, URL support & kebijakan privasi, App Privacy, Age Rating, dan App Review Information (akun demo + catatan untuk reviewer).'),
      done: pr.journeyDone.contains('ios_store_info') || shipped('appstore'),
      action: StageAction.copyStoreInfo,
      actionLabel: tr('Salin akun demo & link'),
      manual: true,
    ),
    JourneyStage(
      key: 'ios_review',
      title: tr('Kirim untuk review App Store'),
      description: trL('Deploy mode App Store: IPA produksi diupload dan otomatis dikirim untuk review (butuh fastlane di MacBook). Apple biasanya mereview 1–2 hari.'),
      done: shipped('appstore'),
      action: StageAction.deployAppStore,
      actionLabel: tr('Deploy ke App Store'),
    ),
    JourneyStage(
      key: 'ios_released',
      title: tr('Disetujui & rilis ke publik'),
      description: trL('Setelah status "Pending Developer Release", klik "Release This Version" di App Store Connect. Aplikasi tampil di App Store untuk semua orang (biasanya dalam 24 jam).'),
      done: pr.journeyDone.contains('ios_released'),
      action: StageAction.manual,
      actionLabel: tr('Sudah tampil di App Store'),
      manual: true,
    ),
  ];
  _lock(stages);
  return stages;
}

/// Pesan undangan tester siap kirim (WhatsApp / Telegram / email).
String testerInvite(Project pr) {
  final groups = pr.testerGroupList;
  final group = groups.isEmpty ? '' : groups.first;
  final groupName = group.contains('@') ? group.split('@').first : group;
  return [
    trL('Halo! Bantu saya uji aplikasi {0} sebelum rilis di Play Store 🙏', [pr.name]),
    '',
    if (group.isNotEmpty) trL('1. Gabung grup tester: {0}', ['https://groups.google.com/g/$groupName']),
    trL('{0}. Buka link ini dari HP Android (akun Google yang sama), klik "Jadi penguji":',
        [group.isNotEmpty ? '2' : '1']),
    '   https://play.google.com/apps/testing/${pr.packageName}',
    trL('{0}. Install dari Play Store:', [group.isNotEmpty ? '3' : '2']),
    '   https://play.google.com/store/apps/details?id=${pr.packageName}',
    '',
    trL('Mohon tetap terdaftar sebagai penguji minimal 14 hari dan buka aplikasinya sesekali. Terima kasih!'),
  ].join('\n');
}
