import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../models.dart';
import '../services/android_pipeline.dart';
import '../services/ios_pipeline.dart';
import '../state.dart';
import '../services/project_scan.dart';
import '../services/storage.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';
import 'deploy_dialogs.dart' show tracks, trackLabel, AndroidDeployDialog, IosDeployDialog;
import 'detect_help_dialog.dart';
import 'firebase_setup_dialog.dart';

/// Form proyek bertahap: setiap langkah satu topik, bagian yang tidak relevan
/// disembunyikan sesuai jawaban "Fitur aplikasi".
class ProjectEditor extends StatefulWidget {
  const ProjectEditor({super.key, required this.project});
  final Project project;

  @override
  State<ProjectEditor> createState() => _ProjectEditorState();
}

class _Step {
  const _Step(this.id, this.icon, this.title, this.complete);
  final String id;
  final IconData icon;
  final String title;
  final bool complete;
}

class _ProjectEditorState extends State<ProjectEditor> {
  late final Project pr = widget.project;
  late final c = <String, TextEditingController>{
    'name': TextEditingController(text: pr.name),
    'localPath': TextEditingController(text: pr.localPath),
    'branch': TextEditingController(text: pr.branch),
    'packageName': TextEditingController(text: pr.packageName),
    'serviceAccountPath': TextEditingController(text: pr.serviceAccountPath),
    'extraBuildArgs': TextEditingController(text: pr.extraBuildArgs),
    'minCoverage': TextEditingController(text: pr.minCoverage == 0 ? '' : '${pr.minCoverage}'),
    'playSigningSha1': TextEditingController(text: pr.playSigningSha1),
    'maxAabMb': TextEditingController(text: '${pr.maxAabMb}'),
    'githubOwner': TextEditingController(text: pr.githubOwner),
    'githubRepo': TextEditingController(text: pr.githubRepo),
    'macProjectPath': TextEditingController(text: pr.macProjectPath),
    'iosExportOptions': TextEditingController(text: pr.iosExportOptions),
    'ascKeyId': TextEditingController(text: pr.ascKeyId),
    'ascIssuerId': TextEditingController(text: pr.ascIssuerId),
    'iosBundleId': TextEditingController(text: pr.iosBundleId),
    'googleServicesJsonPath': TextEditingController(text: pr.googleServicesJsonPath),
    'googleServiceInfoPlistPath': TextEditingController(text: pr.googleServiceInfoPlistPath),
    'privacyPolicyUrl': TextEditingController(text: pr.privacyPolicyUrl),
    'deleteAccountUrl': TextEditingController(text: pr.deleteAccountUrl),
    'childSafetyUrl': TextEditingController(text: pr.childSafetyUrl),
    'demoUser': TextEditingController(text: pr.demoUser),
    'demoPassword': TextEditingController(),
    'loginTestUrl': TextEditingController(text: pr.loginTestUrl),
    'loginUserField': TextEditingController(text: pr.loginUserField),
  };
  late String track = tracks.contains(pr.defaultTrack) ? pr.defaultTrack : 'internal';
  late bool hasLogin = pr.hasLogin;
  late bool isSocial = pr.isSocialApp;
  late bool usesFirebase = pr.usesFirebase;
  late bool hasAds = pr.hasAds;
  late bool useGithub = pr.useGithub;
  late bool useIos = pr.useIos;
  late bool alreadyLive = pr.alreadyLive;
  bool showPw = false;
  ScanResult? scan;
  bool scanning = false;
  String step = 'folder';

  @override
  void initState() {
    super.initState();
    Storage.secret(Secrets.demoPassword(pr.id)).then((v) {
      if (mounted) setState(() => c['demoPassword']!.text = v);
    });
    if (pr.localPath.isNotEmpty) _scan(applyFlags: false);
  }

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  String v(String k) => c[k]!.text.trim();

  /// Deteksi dari kode. [applyFlags] = isi jawaban Ya/Tidak sesuai hasil deteksi.
  Future<void> _scan({bool applyFlags = true}) async {
    if (v('localPath').isEmpty) return;
    setState(() => scanning = true);
    final r = await scanProject(v('localPath'));
    if (!mounted) return;
    setState(() {
      scan = r;
      scanning = false;
      if (c['name']!.text.isEmpty && r.name.isNotEmpty) c['name']!.text = r.name;
      if (c['packageName']!.text.isEmpty && r.packageName.isNotEmpty) c['packageName']!.text = r.packageName;
      if (c['iosBundleId']!.text.isEmpty && r.iosBundleId.isNotEmpty) c['iosBundleId']!.text = r.iosBundleId;
      if (c['githubOwner']!.text.isEmpty && r.githubOwner.isNotEmpty) {
        c['githubOwner']!.text = r.githubOwner;
        c['githubRepo']!.text = r.githubRepo;
      }
      if (applyFlags) {
        hasLogin = r.hasLogin;
        isSocial = r.hasChat;
        usesFirebase = r.usesFirebase;
        hasAds = r.hasAds;
        useGithub = r.githubOwner.isNotEmpty;
        useIos = r.hasIosFolder && useIos;
      }
    });
    if (applyFlags) showSnack(context, tr('Jawaban diisi otomatis dari kode — silakan periksa lagi'));
  }

  Future<void> _pickFolder() async {
    final d = await FilePicker.platform.getDirectoryPath(dialogTitle: tr('Pilih folder project Flutter'));
    if (d == null) return;
    c['localPath']!.text = d;
    await _scan();
  }

  Widget _pick(String key, String title, List<String> ext) => IconButton(
        tooltip: tr('Pilih file'),
        icon: const Icon(Icons.file_open_outlined),
        onPressed: () async {
          final r = await FilePicker.platform.pickFiles(dialogTitle: title, type: FileType.custom, allowedExtensions: ext);
          final path = r?.files.single.path;
          if (path != null) setState(() => c[key]!.text = path);
        },
      );

  DhField _f(String key, String label, {String? hint, IconData? icon, Widget? suffix, bool obscure = false}) =>
      DhField(c[key]!, label, hint: hint, icon: icon, suffix: suffix, obscure: obscure, onChanged: (_) => setState(() {}));

  List<_Step> get _steps => [
        _Step('folder', Icons.folder_outlined, tr('Folder & nama'), v('localPath').isNotEmpty && v('name').isNotEmpty),
        _Step('features', Icons.tune_rounded, tr('Fitur aplikasi'), true),
        if (!alreadyLive)
          _Step(
              'links',
              Icons.shield_outlined,
              tr('Kebijakan & link'),
              v('privacyPolicyUrl').isNotEmpty &&
                  (!hasLogin || v('deleteAccountUrl').isNotEmpty) &&
                  (!isSocial || v('childSafetyUrl').isNotEmpty)),
        if (hasLogin && !alreadyLive)
          _Step('login', Icons.person_outline_rounded, tr('Akun demo reviewer'),
              v('demoUser').isNotEmpty && c['demoPassword']!.text.isNotEmpty),
        _Step('android', Icons.android_rounded, 'Google Play', v('packageName').isNotEmpty),
        if (usesFirebase)
          _Step('firebase', Icons.local_fire_department_outlined, 'Firebase', !firebaseConfigMissing),
        if (useGithub) _Step('github', Icons.hub_outlined, 'GitHub', v('githubOwner').isNotEmpty && v('githubRepo').isNotEmpty),
        if (useIos) _Step('ios', Icons.apple, 'iOS', v('macProjectPath').isNotEmpty && v('iosBundleId').isNotEmpty),
        _Step('summary', Icons.fact_check_outlined, tr('Ringkasan'), true),
      ];

  /// Simpan proyek, lalu buka dialog build (tanpa upload) di atas editor.
  Future<void> _buildNow({required bool ios}) async {
    final np = await _collect();
    if (np == null || !mounted) return;
    if (app.isRunning) {
      showSnack(context, tr('Masih ada pipeline yang berjalan. Tunggu selesai dulu.'), error: true);
      return;
    }
    if (ios && !np.hasIos) {
      setState(() => step = 'ios');
      showSnack(context, tr('Isi dulu folder project di MacBook dan Bundle ID di langkah iOS.'), error: true);
      return;
    }
    await app.upsertProject(np);
    if (!mounted) return;
    if (ios) {
      final o = await showDialog<IosOptions>(context: context, builder: (_) => IosDeployDialog(project: np, buildOnly: true));
      if (o == null || !mounted) return;
      await app.startIos(np, o);
    } else {
      final o = await showDialog<AndroidOptions>(context: context, builder: (_) => AndroidDeployDialog(project: np, buildOnly: true));
      if (o == null || !mounted) return;
      await app.startAndroid(np, o);
    }
    if (!mounted) return;
    Navigator.pop(context, np);
    nav.value = 'pipeline';
  }

  Future<void> _save() async {
    final np = await _collect();
    if (np != null && mounted) Navigator.pop(context, np);
  }

  Future<Project?> _collect() async {
    if (v('name').isEmpty || v('localPath').isEmpty) {
      setState(() => step = 'folder');
      showSnack(context, tr('Nama dan folder project wajib diisi'), error: true);
      return null;
    }
    await Storage.setSecret(Secrets.demoPassword(pr.id), c['demoPassword']!.text);
    if (!mounted) return null;
    return (
      Project(
        id: pr.id,
        name: v('name'),
        localPath: v('localPath'),
        branch: v('branch').isEmpty ? 'main' : v('branch'),
        packageName: v('packageName'),
        serviceAccountPath: v('serviceAccountPath'),
        defaultTrack: track,
        extraBuildArgs: v('extraBuildArgs'),
        minCoverage: (int.tryParse(v('minCoverage')) ?? 0).clamp(0, 100).toInt(),
        playSigningSha1: v('playSigningSha1'),
        maxAabMb: int.tryParse(v('maxAabMb')) ?? 150,
        githubOwner: v('githubOwner'),
        githubRepo: v('githubRepo'),
        macProjectPath: v('macProjectPath'),
        iosExportOptions: v('iosExportOptions'),
        ascKeyId: v('ascKeyId'),
        ascIssuerId: v('ascIssuerId'),
        iosBundleId: v('iosBundleId'),
        googleServicesJsonPath: usesFirebase ? v('googleServicesJsonPath') : '',
        googleServiceInfoPlistPath: usesFirebase ? v('googleServiceInfoPlistPath') : '',
        privacyPolicyUrl: v('privacyPolicyUrl'),
        deleteAccountUrl: v('deleteAccountUrl'),
        childSafetyUrl: v('childSafetyUrl'),
        isSocialApp: isSocial,
        demoUser: v('demoUser'),
        loginTestUrl: v('loginTestUrl'),
        loginUserField: v('loginUserField').isEmpty ? 'username' : v('loginUserField'),
        hasLogin: hasLogin,
        usesFirebase: usesFirebase,
        hasAds: hasAds,
        useGithub: useGithub,
        useIos: useIos,
        isPersonalAccount: pr.isPersonalAccount,
        testerGroups: pr.testerGroups,
        closedTestTrack: pr.closedTestTrack,
        closedTestStart: pr.closedTestStart,
        testerCount: pr.testerCount,
        consoleAnswers: pr.consoleAnswers,
        consoleDone: pr.consoleDone,
        journeyDone: pr.journeyDone,
        alreadyLive: alreadyLive,
      )
    );
  }

  // ───────────────────────── pertanyaan Ya / Tidak
  Widget _yesNo({
    required String question,
    required String sub,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool? detected,
    IconData icon = Icons.help_outline_rounded,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: YmColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: value ? YmColors.primary.withOpacity(0.45) : YmColors.line),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: value ? YmColors.primarySoft : YmColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 19, color: value ? YmColors.primary : YmColors.outline),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(question, style: YmTextStyles.username.copyWith(fontSize: 14)),
            const SizedBox(height: 2),
            Text(sub, style: YmTextStyles.bodySm),
            if (detected != null) ...[
              const SizedBox(height: 6),
              detected == value
                  ? SoftChip.success(tr('Sesuai hasil deteksi kode'), icon: Icons.auto_awesome_outlined)
                  : SoftChip.warning(
                      detected ? tr('Kode terdeteksi: Ya — yakin Tidak?') : tr('Tidak terdeteksi di kode'),
                      icon: Icons.auto_awesome_outlined),
            ],
          ]),
        ),
        const SizedBox(width: 12),
        QuickChip(label: tr('Ya'), selected: value, onTap: () => setState(() => onChanged(true))),
        const SizedBox(width: 6),
        QuickChip(label: tr('Tidak'), selected: !value, onTap: () => setState(() => onChanged(false))),
      ]),
    );
  }

  Widget _intro(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Text(text, style: YmTextStyles.bodyMd),
      );

  Widget _packageWarning() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: YmColors.dangerSoft, borderRadius: BorderRadius.circular(10)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.block_rounded, color: YmColors.onDangerSoft, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tr('Package "com.example..." DITOLAK Google Play dan tidak bisa diganti setelah upload pertama. Ganti dulu sebelum membuat AAB, misalnya com.batamchitchat.app: ubah applicationId (dan namespace) di android/app/build.gradle, lalu daftarkan ulang di Firebase.'),
              style: YmTextStyles.bodySm.copyWith(color: YmColors.onDangerSoft, fontWeight: FontWeight.w600),
            ),
          ),
        ]),
      );

  /// Panduan lengkap langkah Firebase: urutan yang benar + tombol aksi.
  Widget _firebaseGuide() {
    final cfgOk = !firebaseConfigMissing;
    final shaOk = v('playSigningSha1').isNotEmpty;
    final hasFolder = v('localPath').isNotEmpty;
    Widget row(int n, bool done, String title, String body, {List<Widget> actions = const []}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              radius: 13,
              backgroundColor: done ? YmColors.successSoft : YmColors.primarySoft,
              child: done
                  ? Icon(Icons.check_rounded, size: 16, color: YmColors.onSuccessSoft)
                  : Text('$n', style: YmTextStyles.labelSm.copyWith(color: YmColors.primary, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(body, style: YmTextStyles.bodySm),
                if (actions.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Wrap(spacing: 8, runSpacing: 8, children: actions)),
              ]),
            ),
          ]),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.route_rounded, size: 18, color: YmColors.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('Urutan yang benar (ikuti dari atas)'), style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 4),
        Text(
          tr('Firebase adalah layanan Google untuk login, chat, notifikasi, dll. Aplikasimu butuh file konfigurasi supaya tahu project Firebase mana yang dipakai. Tanpa file itu build gagal atau aplikasi langsung crash saat dibuka.'),
          style: YmTextStyles.bodySm,
        ),
        const SizedBox(height: 12),
        row(1, cfgOk, tr('Buat file konfigurasi Firebase'),
            tr('Klik "Siapkan Firebase". DeployHub membuat google-services.json, GoogleService-Info.plist dan firebase_options.dart, lalu mendaftarkan SHA-1 kunci upload (keystore) kamu. Login Google sudah jalan di HP-mu sendiri setelah ini.'),
            actions: [
              OutlinedButton.icon(
                style: outlineButtonStyle(),
                onPressed: hasFolder ? _openFirebaseSetup : null,
                icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                label: Text(tr('Siapkan Firebase')),
              ),
            ]),
        row(2, false, tr('Buat file AAB / IPA dulu'),
            tr('Build aplikasi tanpa upload untuk memastikan semuanya lolos (signing, Firebase, R8). Hasilnya: build/app/outputs/bundle/release/app-release.aab di folder project. IPA dibuat di MacBook lalu disalin ke PC.'),
            actions: [
              OutlinedButton.icon(
                style: outlineButtonStyle(),
                onPressed: hasFolder ? () => _buildNow(ios: false) : null,
                icon: const Icon(Icons.android_rounded, size: 18),
                label: Text(tr('Buat AAB sekarang')),
              ),
              if (useIos)
                OutlinedButton.icon(
                  style: outlineButtonStyle(),
                  onPressed: hasFolder ? () => _buildNow(ios: true) : null,
                  icon: const Icon(Icons.apple, size: 18),
                  label: Text(tr('Buat IPA sekarang')),
                ),
            ]),
        row(3, shaOk, tr('Upload AAB pertama ke Pengujian internal'),
            tr('Dari halaman Proyek: "Deploy ke Play Store" → Internal, atau menu ⋮ → "Upload file AAB / IPA langsung" untuk file dari langkah 2. Saat upload pertama Google membuat kunci penandatanganan (App signing key) untuk aplikasimu.')),
        row(4, shaOk, tr('Ambil SHA-1 App signing dari Play Console'),
            tr('Play Console → Uji dan rilis → Integritas aplikasi → Penandatanganan aplikasi Play → salin SHA-1 di kotak "Sertifikat kunci penandatanganan aplikasi". Tempel di kolom SHA-1 di bawah.'),
            actions: [
              TextButton.icon(
                onPressed: () => showDialog(context: context, builder: (_) => const Sha1HelpDialog()),
                icon: const Icon(Icons.help_outline_rounded, size: 18),
                label: Text(tr('Lihat langkah lengkap')),
              ),
            ]),
        row(5, false, tr('Daftarkan SHA-1 itu ke Firebase'),
            tr('Buka "Siapkan Firebase" lagi → langkah 5 "Daftarkan SHA-1". Setelah itu Login Google juga jalan di aplikasi yang diinstall dari Play Store. iOS tidak butuh SHA-1.')),
      ]),
    );
  }

  // ───────────────────────── isi tiap langkah
  Widget _content() {
    final s = scan;
    switch (step) {
      case 'folder':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _yesNo(
            icon: Icons.rocket_launch_outlined,
            question: tr('Aplikasi ini sudah live di Play Store?'),
            sub: tr('Ya → tidak perlu isi kebijakan, CSAE, akun demo, atau listing lagi. DeployHub hanya membuat AAB, mengoptimalkan, dan mengupload update.'),
            value: alreadyLive,
            onChanged: (x) => alreadyLive = x,
          ),
          _intro(tr('Pilih folder project Flutter di PC. Nama, package, repo GitHub, dan fitur aplikasi dideteksi otomatis dari kode.')),
          _f('localPath', tr('Folder project di PC'),
              icon: Icons.folder_open_outlined,
              hint: r'D:\projects\batamchitchat',
              suffix: IconButton(tooltip: tr('Pilih folder'), icon: const Icon(Icons.drive_folder_upload_outlined), onPressed: _pickFolder)),
          fieldRow([
            _f('name', tr('Nama proyek (sama dengan nama di Play Store)'), icon: Icons.label_outline_rounded, hint: 'Batam ChitChat'),
            _f('branch', 'Branch', icon: Icons.call_split_rounded, hint: 'main'),
          ], flex: [3, 1]),
          _f('packageName', 'Package name', icon: Icons.inventory_2_outlined, hint: 'com.batamchitchat.app'),
          if (v('packageName').startsWith('com.example')) _packageWarning(),
          if (scanning) const LinearProgressIndicator(),
          if (s != null && !scanning)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Terdeteksi dari kode'), style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                LayoutBuilder(builder: (context, cs) {
                  final w = (cs.maxWidth - 8) / 2;
                  return Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final (item, on) in [
                      (DetectItem.signing, s.hasReleaseSigning),
                      (DetectItem.login, s.hasLogin),
                      (DetectItem.googleLogin, s.hasGoogleLogin),
                      (DetectItem.chat, s.hasChat),
                      (DetectItem.firebase, s.usesFirebase),
                      (DetectItem.ads, s.hasAds),
                      (DetectItem.ios, s.hasIosFolder),
                      (DetectItem.github, s.githubOwner.isNotEmpty),
                    ])
                      SizedBox(width: w, child: _det(item, on)),
                  ]);
                }),
                const SizedBox(height: 10),
                Row(children: [
                  Icon(Icons.touch_app_outlined, size: 16, color: YmColors.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      tr('Klik salah satu baris di atas untuk penjelasan, apa yang harus diisi, dan cara memperbaikinya.'),
                      style: YmTextStyles.bodySm,
                    ),
                  ),
                ]),
                if (firebaseConfigMissing) ...[
                  const SizedBox(height: 10),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: _openFirebaseSetup,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: YmColors.warningSoft, borderRadius: BorderRadius.circular(10)),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.local_fire_department_outlined, size: 18, color: YmColors.onWarningSoft),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(tr('Konfigurasi Firebase belum ada'),
                                style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700, color: YmColors.onWarningSoft)),
                            Text(
                              tr('Kode memakai Firebase, tapi android/app/google-services.json{0} tidak ada. Build akan gagal atau aplikasi crash. Klik untuk membuatnya otomatis atau lihat langkah manual.',
                                  [useIos && s.hasIosFolder && !s.hasIosPlist ? ' / GoogleService-Info.plist' : '']),
                              style: YmTextStyles.bodySm.copyWith(color: YmColors.onWarningSoft),
                            ),
                          ]),
                        ),
                        Icon(Icons.chevron_right_rounded, color: YmColors.onWarningSoft),
                      ]),
                    ),
                  ),
                ],
                if (!s.hasReleaseSigning) ...[
                  const SizedBox(height: 10),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _openDetect(DetectItem.signing, false),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: YmColors.warningSoft, borderRadius: BorderRadius.circular(10)),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.warning_amber_rounded, size: 18, color: YmColors.onWarningSoft),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(tr('Keystore belum diatur'),
                                style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700, color: YmColors.onWarningSoft)),
                            Text(
                              tr('Tanpa keystore, AAB ditandatangani dengan debug key dan Google Play akan menolaknya. Build saja tetap jalan. Klik untuk membuat keystore otomatis.'),
                              style: YmTextStyles.bodySm.copyWith(color: YmColors.onWarningSoft),
                            ),
                          ]),
                        ),
                        Icon(Icons.chevron_right_rounded, color: YmColors.onWarningSoft),
                      ]),
                    ),
                  ),
                ],
              ]),
            ),
        ]);
      case 'features':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: _intro(tr('Jawab sesuai aplikasimu. Jawaban menentukan isian dan pemeriksaan apa yang wajib.'))),
            OutlinedButton.icon(
              style: outlineButtonStyle(),
              onPressed: v('localPath').isEmpty || scanning ? null : () => _scan(),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: Text(tr('Isi otomatis dari kode')),
            ),
          ]),
          _yesNo(
            icon: Icons.login_rounded,
            question: tr('Aplikasi punya login / akun?'),
            sub: tr('Ya → wajib akun demo untuk reviewer Google/Apple dan link hapus akun.'),
            value: hasLogin,
            detected: s?.hasLogin,
            onChanged: (x) => hasLogin = x,
          ),
          _yesNo(
            icon: Icons.forum_outlined,
            question: tr('Ada fitur chat / sosial / komunitas?'),
            sub: tr('Ya → wajib halaman standar perlindungan anak (CSAE) dan fitur lapor di aplikasi.'),
            value: isSocial,
            detected: s?.hasChat,
            onChanged: (x) => isSocial = x,
          ),
          _yesNo(
            icon: Icons.local_fire_department_outlined,
            question: tr('Pakai Firebase atau Login Google?'),
            sub: tr('Ya → dicek google-services.json, package, dan SHA-1 (penyebab umum Login Google gagal di Play Store).'),
            value: usesFirebase,
            detected: s?.usesFirebase,
            onChanged: (x) => usesFirebase = x,
          ),
          _yesNo(
            icon: Icons.campaign_outlined,
            question: tr('Ada iklan (AdMob)?'),
            sub: tr('Menentukan jawaban "Iklan" di Play Console.'),
            value: hasAds,
            detected: s?.hasAds,
            onChanged: (x) => hasAds = x,
          ),
          _yesNo(
            icon: Icons.apple,
            question: tr('Rilis juga ke iPhone (App Store)?'),
            sub: tr('Ya → build iOS di MacBook lewat SSH dan upload ke TestFlight.'),
            value: useIos,
            detected: s?.hasIosFolder,
            onChanged: (x) => useIos = x,
          ),
          _yesNo(
            icon: Icons.hub_outlined,
            question: tr('Pakai GitHub?'),
            sub: tr('Ya → git tag, GitHub Release dengan file AAB, dan GitHub Actions.'),
            value: useGithub,
            detected: s == null ? null : s.githubOwner.isNotEmpty,
            onChanged: (x) => useGithub = x,
          ),
        ]);
      case 'links':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _intro(tr('Link ini wajib bisa dibuka publik. DeployHub mengecek setiap link sebelum rilis.')),
          _f('privacyPolicyUrl', alreadyLive ? tr('Link kebijakan privasi (opsional)') : tr('Link kebijakan privasi (wajib)'), icon: Icons.privacy_tip_outlined, hint: 'https://batamchitchat.com/privacy'),
          if (hasLogin)
            _f('deleteAccountUrl', tr('Link hapus akun (wajib karena ada login)'),
                icon: Icons.person_remove_outlined, hint: 'https://batamchitchat.com/hapus-akun'),
          if (isSocial)
            _f('childSafetyUrl', tr('Link standar perlindungan anak / CSAE (wajib karena ada chat)'),
                icon: Icons.child_care_outlined, hint: 'https://batamchitchat.com/child-safety'),
          if (!hasLogin && !isSocial)
            Text(tr('Link hapus akun dan CSAE tidak diperlukan karena aplikasi tidak punya login maupun chat.'),
                style: YmTextStyles.bodySm),
        ]);
      case 'login':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _intro(tr('Reviewer Google & Apple login memakai akun ini. Pastikan tidak perlu OTP / verifikasi email.')),
          fieldRow([
            _f('demoUser', tr('Username / email akun demo'), icon: Icons.alternate_email_rounded),
            DhField(c['demoPassword']!, tr('Password akun demo'),
                icon: Icons.password_rounded,
                obscure: !showPw,
                onChanged: (_) => setState(() {}),
                suffix: IconButton(
                  icon: Icon(showPw ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => setState(() => showPw = !showPw),
                )),
          ]),
          fieldRow([
            _f('loginTestUrl', tr('URL tes login API (opsional)'), icon: Icons.link_rounded, hint: 'https://api.batamchitchat.com/auth/login'),
            _f('loginUserField', tr('Field user'), hint: 'username'),
          ], flex: [3, 1]),
          Text(tr('Kalau URL tes diisi, akun demo dicoba login ke server sebelum setiap rilis. Password disimpan aman di Windows Credential Manager.'),
              style: YmTextStyles.bodySm),
        ]);
      case 'android':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _intro(tr('Login Google Play diatur sekali di Pengaturan. Isi Service Account di sini hanya kalau proyek ini memakai akun berbeda.')),
          _f('packageName', 'Package name', icon: Icons.inventory_2_outlined, hint: 'com.batamchitchat.app'),
          if (v('packageName').startsWith('com.example')) _packageWarning(),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DropdownButtonFormField<String>(
              value: track,
              isExpanded: true,
              decoration: fieldDecoration(tr('Track default saat deploy')),
              items: [for (final t in tracks) DropdownMenuItem(value: t, child: Text(trackLabel(t)))],
              onChanged: (x) => setState(() => track = x!),
            ),
          ),
          _f('serviceAccountPath', tr('Service Account JSON khusus proyek ini (opsional)'),
              icon: Icons.key_outlined, suffix: _pick('serviceAccountPath', 'Service Account JSON', ['json'])),
          fieldRow([
            _f('extraBuildArgs', tr('Argumen build tambahan'), icon: Icons.terminal_rounded, hint: '--obfuscate --split-debug-info=build/symbols'),
            _f('maxAabMb', tr('Batas ukuran AAB (MB)'), hint: '150'),
            _f('minCoverage', tr('Coverage test minimal (%)'), hint: tr('0 = tidak dicek')),
          ], flex: [3, 1, 1]),
        ]);
      case 'firebase':
        final sc = scan;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: firebaseConfigMissing ? YmColors.warningSoft : YmColors.successSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(firebaseConfigMissing ? Icons.warning_amber_rounded : Icons.check_circle_rounded,
                  color: firebaseConfigMissing ? YmColors.onWarningSoft : YmColors.onSuccessSoft),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    firebaseConfigMissing ? tr('Konfigurasi Firebase belum ada') : tr('Konfigurasi Firebase ada'),
                    style: YmTextStyles.labelLg.copyWith(
                        fontWeight: FontWeight.w700, color: firebaseConfigMissing ? YmColors.onWarningSoft : YmColors.onSuccessSoft),
                  ),
                  Text(
                    [
                      'google-services.json: ${(sc?.hasGoogleServicesJson ?? false) || v('googleServicesJsonPath').isNotEmpty ? '✔' : '✖'}',
                      if (useIos) 'GoogleService-Info.plist: ${(sc?.hasIosPlist ?? false) || v('googleServiceInfoPlistPath').isNotEmpty ? '✔' : '✖'}',
                      'firebase_options.dart: ${(sc?.hasFirebaseOptions ?? false) ? '✔' : '✖'}',
                    ].join('   '),
                    style: YmTextStyles.bodySm.copyWith(color: firebaseConfigMissing ? YmColors.onWarningSoft : YmColors.onSuccessSoft),
                  ),
                ]),
              ),
              ElevatedButton.icon(
                style: primaryButtonStyle(),
                onPressed: v('localPath').isEmpty ? null : _openFirebaseSetup,
                icon: const Icon(Icons.auto_fix_high_rounded),
                label: Text(firebaseConfigMissing ? tr('Siapkan Firebase') : tr('SHA-1 & Login Google')),
              ),
            ]),
          ),
          _firebaseGuide(),
          GroupLabel(tr('Lokasi file (opsional)')),
          _intro(tr('Biarkan kosong kalau file sudah ada di folder project (status di atas ✔). Pilih file hanya kalau file itu sengaja tidak disimpan di git / di folder lain. Saat build, DeployHub menyalinnya ke tempat yang benar.')),
          _f('googleServicesJsonPath', tr('google-services.json (Android) — tujuan: android/app/'),
              icon: Icons.description_outlined, suffix: _pick('googleServicesJsonPath', 'google-services.json', ['json'])),
          if (useIos)
            _f('googleServiceInfoPlistPath', tr('GoogleService-Info.plist (iOS) — tujuan: ios/Runner/'),
                icon: Icons.description_outlined, suffix: _pick('googleServiceInfoPlistPath', 'GoogleService-Info.plist', ['plist'])),
          GroupLabel(tr('SHA-1 dari Google Play (diisi setelah upload pertama)')),
          _f('playSigningSha1', tr('SHA-1 App signing key (dari Play Console)'),
              icon: Icons.fingerprint_rounded,
              hint: 'AB:CD:EF:...',
              suffix: IconButton(
                tooltip: tr('Cara mengambil SHA-1'),
                icon: const Icon(Icons.help_outline_rounded),
                onPressed: () => showDialog(context: context, builder: (_) => const Sha1HelpDialog()),
              )),
          InkWell(
            onTap: () => showDialog(context: context, builder: (_) => const Sha1HelpDialog()),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(Icons.help_outline_rounded, size: 16, color: YmColors.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(tr('Di mana ambilnya? Klik untuk langkah-langkahnya. Boleh dikosongkan dulu kalau belum pernah upload AAB.'),
                      style: YmTextStyles.bodySm.copyWith(color: YmColors.primary, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ),
        ]);
      case 'github':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _intro(tr('Token GitHub diatur sekali di Pengaturan.')),
          fieldRow([
            _f('githubOwner', tr('Owner / organisasi'), icon: Icons.business_outlined),
            _f('githubRepo', tr('Nama repo'), icon: Icons.source_outlined),
          ]),
        ]);
      case 'ios':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _intro(tr('Build iOS berjalan di MacBook. API key App Store Connect diatur di Pengaturan; isi di sini hanya kalau berbeda.')),
          _f('macProjectPath', tr('Folder project di MacBook'), icon: Icons.laptop_mac_rounded, hint: '~/projects/batamchitchat'),
          _f('iosBundleId', 'Bundle ID', icon: Icons.inventory_2_outlined, hint: 'com.batamchitchat.app'),
          _f('iosExportOptions', tr('ExportOptions.plist (opsional, relatif ke project)'), hint: 'ios/ExportOptions.plist'),
          fieldRow([
            _f('ascKeyId', 'App Store Connect Key ID'),
            _f('ascIssuerId', 'Issuer ID'),
          ]),
        ]);
      default:
        return _summary();
    }
  }

  Future<void> _openDetect(DetectItem item, bool detected) async {
    final res = await showDialog<String>(
      context: context,
      builder: (_) => DetectHelpDialog(item: item, detected: detected, root: v('localPath')),
    );
    if (res == null || !mounted) return;
    if (res == 'rescan') {
      await _scan(applyFlags: false);
      if (item == DetectItem.github && mounted && v('githubOwner').isNotEmpty) setState(() => useGithub = true);
      return;
    }
    // pindah ke langkah yang harus diisi; aktifkan jawaban terkait supaya langkahnya muncul
    setState(() {
      switch (item) {
        case DetectItem.login:
          hasLogin = true;
        case DetectItem.googleLogin:
        case DetectItem.firebase:
          usesFirebase = true;
        case DetectItem.chat:
          isSocial = true;
        case DetectItem.ads:
          hasAds = true;
        case DetectItem.ios:
          useIos = true;
        case DetectItem.github:
          useGithub = true;
        case DetectItem.signing:
          break;
      }
      step = res;
    });
  }

  /// Paket Firebase dipakai tapi file konfigurasinya belum ada (dan tidak dipilih manual).
  bool get firebaseConfigMissing {
    final s = scan;
    if (s == null || !(s.usesFirebase || usesFirebase)) return false;
    final android = s.hasGoogleServicesJson || v('googleServicesJsonPath').isNotEmpty;
    final ios = !useIos || !s.hasIosFolder || s.hasIosPlist || v('googleServiceInfoPlistPath').isNotEmpty;
    return !(android && ios);
  }

  Future<void> _openFirebaseSetup() async {
    final res = await showDialog<String>(
      context: context,
      builder: (_) => FirebaseSetupDialog(
        root: v('localPath'),
        packageName: v('packageName'),
        iosBundleId: v('iosBundleId'),
        useIos: useIos,
        playSigningSha1: v('playSigningSha1'),
        googleLogin: scan?.hasGoogleLogin ?? false,
      ),
    );
    if (res == 'rescan' && mounted) await _scan(applyFlags: false);
  }

  /// Satu baris hasil deteksi — tombol penuh (klik di mana saja untuk penjelasan).
  Widget _det(DetectItem item, bool on) {
    final configMissing = item == DetectItem.firebase && firebaseConfigMissing;
    final fix = (!on && detectNeedsFix(item)) || configMissing;
    final (Color bg, Color fg, IconData icon, String status) = configMissing
        ? (YmColors.warningSoft, YmColors.onWarningSoft, Icons.warning_amber_rounded, tr('Dipakai, tapi konfigurasi belum ada'))
        : on
            ? (YmColors.successSoft, YmColors.onSuccessSoft, Icons.check_circle_rounded, tr('Terdeteksi'))
            : fix
                ? (YmColors.warningSoft, YmColors.onWarningSoft, Icons.warning_amber_rounded, tr('Perlu diperbaiki'))
                : (YmColors.surface, YmColors.textMuted, Icons.remove_circle_outline_rounded, tr('Tidak terdeteksi'));
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => configMissing ? _openFirebaseSetup() : _openDetect(item, on),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? Colors.transparent : (fix ? YmColors.warning.withOpacity(0.4) : YmColors.line)),
          ),
          child: Row(children: [
            Icon(icon, size: 20, color: on ? YmColors.success : (fix ? YmColors.warning : YmColors.outline)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(detectLabel(item), maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w600, color: on || fix ? fg : YmColors.textDark)),
                Text(status, style: YmTextStyles.labelSm.copyWith(color: fg)),
              ]),
            ),
            Text(fix ? tr('Perbaiki') : tr('Lihat cara'),
                style: YmTextStyles.labelMd.copyWith(color: fix ? fg : YmColors.primary, fontWeight: FontWeight.w600)),
            Icon(Icons.chevron_right_rounded, size: 18, color: fix ? fg : YmColors.primary),
          ]),
        ),
      ),
    );
  }

  Widget _summary() {
    final rows = <(bool, String, String)>[
      (!alreadyLive, tr('Kebijakan privasi'), v('privacyPolicyUrl').isEmpty ? tr('Belum diisi') : v('privacyPolicyUrl')),
      (hasLogin && !alreadyLive, tr('Akun demo reviewer'), v('demoUser').isEmpty ? tr('Belum diisi') : v('demoUser')),
      (hasLogin && !alreadyLive, tr('Link hapus akun'), v('deleteAccountUrl').isEmpty ? tr('Belum diisi') : v('deleteAccountUrl')),
      (isSocial && !alreadyLive, tr('Standar perlindungan anak (CSAE)'), v('childSafetyUrl').isEmpty ? tr('Belum diisi') : v('childSafetyUrl')),
      (usesFirebase, tr('Firebase & SHA-1'), v('playSigningSha1').isEmpty ? tr('SHA-1 App signing belum diisi') : 'OK'),
      (useIos, 'iOS / TestFlight', v('macProjectPath').isEmpty ? tr('Folder MacBook belum diisi') : v('macProjectPath')),
      (useGithub, 'GitHub', v('githubOwner').isEmpty ? tr('Belum diisi') : '${v('githubOwner')}/${v('githubRepo')}'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _intro(tr('Ini yang akan dicek DeployHub sebelum setiap rilis untuk proyek ini.')),
      for (final (on, title, detail) in rows)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Icon(
              !on ? Icons.remove_circle_outline_rounded : (detail.contains(tr('Belum')) ? Icons.warning_amber_rounded : Icons.check_circle_rounded),
              color: !on ? YmColors.outline : (detail.contains(tr('Belum')) ? YmColors.warning : YmColors.success),
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: YmTextStyles.username)),
            Flexible(
              child: Text(on ? detail : tr('Tidak berlaku'),
                  style: YmTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end),
            ),
          ]),
        ),
      const SizedBox(height: 8),
      Text(tr('Isian di Play Console yang tidak ada API-nya (Iklan, Rating konten, dll.) ada di menu ⋮ → Checklist Play Console.'),
          style: YmTextStyles.bodySm),
      const SizedBox(height: 16),
      _buildPanel(),
    ]);
  }

  /// Panel "buat file dulu" — build AAB / IPA tanpa upload.
  Widget _buildPanel() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: YmColors.primarySoft, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.inventory_2_outlined, color: YmColors.onPrimaryFixed),
            const SizedBox(width: 8),
            Expanded(
              child: Text(tr('Buat file AAB / IPA sekarang (tanpa upload)'),
                  style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700, color: YmColors.onPrimaryFixed)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            tr('Proyek disimpan, lalu DeployHub menjalankan pub get → analyze → test → flutter build appbundle --release. Hasil: build/app/outputs/bundle/release/app-release.aab, lengkap dengan laporan AAB (perangkat, R8, yang kurang). Tidak ada yang dikirim ke Google Play / Apple.'),
            style: YmTextStyles.bodySm.copyWith(color: YmColors.onPrimaryFixed),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ElevatedButton.icon(
              style: primaryButtonStyle(),
              onPressed: v('localPath').isEmpty ? null : () => _buildNow(ios: false),
              icon: const Icon(Icons.android_rounded),
              label: Text(tr('Buat AAB sekarang')),
            ),
            if (useIos)
              OutlinedButton.icon(
                style: outlineButtonStyle(),
                onPressed: v('localPath').isEmpty ? null : () => _buildNow(ios: true),
                icon: const Icon(Icons.apple),
                label: Text(tr('Buat IPA sekarang')),
              ),
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final steps = _steps;
    if (!steps.any((x) => x.id == step)) step = 'features';
    final i = steps.indexWhere((x) => x.id == step);
    return DhDialog(
      title: pr.name.isEmpty ? tr('Tambah proyek') : tr('Edit {0}', [pr.name]),
      subtitle: tr('Langkah {0} dari {1}: {2}', [i + 1, steps.length, steps[i].title]),
      icon: Icons.folder_copy_outlined,
      width: 980,
      height: 680,
      actions: [
        OutlinedButton(style: outlineButtonStyle(), onPressed: () => Navigator.pop(context), child: Text(tr('Batal'))),
        if (i > 0)
          OutlinedButton.icon(
            style: outlineButtonStyle(),
            onPressed: () => setState(() => step = steps[i - 1].id),
            icon: const Icon(Icons.arrow_back_rounded),
            label: Text(tr('Kembali')),
          ),
        if (i < steps.length - 1)
          OutlinedButton.icon(
            style: outlineButtonStyle(),
            onPressed: () => setState(() => step = steps[i + 1].id),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(tr('Berikutnya')),
          ),
        OutlinedButton.icon(
          style: outlineButtonStyle(),
          onPressed: v('localPath').isEmpty ? null : () => _buildNow(ios: false),
          icon: const Icon(Icons.inventory_2_outlined),
          label: Text(tr('Simpan & buat AAB')),
        ),
        ElevatedButton.icon(style: primaryButtonStyle(), onPressed: _save, icon: const Icon(Icons.save_outlined), label: Text(tr('Simpan'))),
      ],
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 230,
          child: ListView(children: [
            for (var k = 0; k < steps.length; k++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() => step = steps[k].id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: steps[k].id == step ? YmColors.surfaceHigh : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(children: [
                      Container(
                        width: 24,
                        height: 24,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: steps[k].id == step ? YmColors.primary : YmColors.surfaceContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Text('${k + 1}',
                            style: YmTextStyles.labelSm.copyWith(color: steps[k].id == step ? YmColors.onPrimary : YmColors.textMuted)),
                      ),
                      const SizedBox(width: 10),
                      Icon(steps[k].icon, size: 18, color: steps[k].id == step ? YmColors.primary : YmColors.outline),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(steps[k].title,
                            style: YmTextStyles.labelMd.copyWith(
                                color: steps[k].id == step ? YmColors.primary : YmColors.textDark,
                                fontWeight: steps[k].id == step ? FontWeight.w600 : FontWeight.w500)),
                      ),
                      Icon(steps[k].complete ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                          size: 16, color: steps[k].complete ? YmColors.success : YmColors.warning),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 20),
        VerticalDivider(width: 1, color: YmColors.line),
        const SizedBox(width: 20),
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.only(bottom: 12), child: _content())),
      ]),
    );
  }
}


/// Popup: cara mengambil SHA-1 App signing key dari Play Console.
class Sha1HelpDialog extends StatelessWidget {
  const Sha1HelpDialog({super.key});

  Widget _step(int n, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: YmColors.primarySoft,
            child: Text('$n', style: YmTextStyles.labelSm.copyWith(color: YmColors.primary, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(body, style: YmTextStyles.bodySm),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return DhDialog(
      title: tr('Cara mengambil SHA-1 App signing key'),
      icon: Icons.fingerprint_rounded,
      width: 620,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Tutup'))),
        ElevatedButton.icon(
          style: primaryButtonStyle(),
          onPressed: () => launchUrl(Uri.parse('https://play.google.com/console'), mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_new_rounded),
          label: Text(tr('Buka Play Console')),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(color: YmColors.warningSoft, borderRadius: BorderRadius.circular(10)),
          child: Text(
            tr('Penting: SHA-1 ini baru muncul SETELAH kamu upload AAB pertama ke Play Console (misalnya ke Pengujian internal). Kalau belum pernah upload, kosongkan dulu, deploy dulu, lalu kembali ke sini.'),
            style: YmTextStyles.bodySm.copyWith(color: YmColors.onWarningSoft, fontWeight: FontWeight.w600),
          ),
        ),
        _step(1, tr('Buka Play Console'), tr('play.google.com/console → klik aplikasi kamu (mis. batamchitchat).')),
        _step(2, tr('Menu kiri: "Uji dan rilis"'), tr('Klik "Uji dan rilis" supaya submenunya terbuka, lalu gulir ke bawah sampai bagian "Penyiapan aplikasi" / "Setup".')),
        _step(3, tr('Klik "Integritas aplikasi"'), tr('Di halaman Integritas aplikasi, klik tab / tombol "Penandatanganan aplikasi Play" (App signing). Kadang ada tombol "Setelan" di kartu Penandatanganan aplikasi Play.')),
        _step(4, tr('Salin SHA-1 di "Sertifikat kunci penandatanganan aplikasi"'),
            tr('Ada dua kotak: "Sertifikat kunci penandatanganan aplikasi" (App signing key) dan "Sertifikat kunci upload" (Upload key). Salin baris "Sidik jari sertifikat SHA-1" dari kotak PERTAMA.')),
        _step(5, tr('Tempel di DeployHub'), tr('Tempel di kolom SHA-1 lalu Simpan. Lewat "Siapkan Firebase" langkah 5, SHA-1 ini otomatis didaftarkan ke Firebase.')),
        const SizedBox(height: 4),
        Text(tr('Contoh bentuknya:'), style: YmTextStyles.labelMd),
        const SizedBox(height: 6),
        const CodeBox('A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:90:A1:B2:C3:D4', label: 'SHA-1'),
        Text(
          tr('Kenapa perlu? Google menandatangani ulang aplikasimu dengan kunci miliknya. Kalau SHA-1 kunci itu tidak didaftarkan di Firebase, Login Google gagal (error 10) di aplikasi yang diinstall dari Play Store, padahal di debug lancar. SHA-1 kunci upload kamu sudah dibaca otomatis dari keystore.'),
          style: YmTextStyles.bodySm,
        ),
      ]),
    );
  }
}
