import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../services/keystore_tool.dart';
import '../state.dart';
import '../theme/dh_theme.dart';
import '../widgets/dh_widgets.dart';
import '../widgets/ui.dart';
import 'github_connect.dart';

/// Item hasil deteksi kode yang punya penjelasan.
enum DetectItem { login, googleLogin, chat, firebase, ads, ios, github, signing }

String detectLabel(DetectItem i) => switch (i) {
      DetectItem.login => tr('Login'),
      DetectItem.googleLogin => tr('Login Google'),
      DetectItem.chat => tr('Chat / sosial'),
      DetectItem.firebase => 'Firebase',
      DetectItem.ads => tr('Iklan'),
      DetectItem.ios => tr('Folder iOS'),
      DetectItem.github => 'GitHub',
      DetectItem.signing => tr('Keystore (signing release)'),
    };

/// Langkah form yang harus diisi kalau item ini terdeteksi: (label tombol, id langkah).
List<(String, String)> detectTargets(DetectItem i) => switch (i) {
      DetectItem.login => [(tr('Isi akun demo reviewer'), 'login'), (tr('Isi link hapus akun'), 'links')],
      DetectItem.googleLogin => [(tr('Isi SHA-1 App signing'), 'firebase')],
      DetectItem.chat => [(tr('Isi link CSAE'), 'links')],
      DetectItem.firebase => [(tr('Isi file Firebase & SHA-1'), 'firebase')],
      DetectItem.ads => [(tr('Cek jawaban "Ada iklan"'), 'features')],
      DetectItem.ios => [(tr('Isi folder MacBook & Bundle ID'), 'ios')],
      DetectItem.github => [(tr('Cek owner & repo'), 'github')],
      DetectItem.signing => const [],
    };

/// Penting untuk upload? (abu-abu yang perlu diperbaiki ditandai oranye)
bool detectNeedsFix(DetectItem i) => i == DetectItem.signing;

/// Popup penjelasan & cara memperbaiki satu item deteksi.
class DetectHelpDialog extends StatefulWidget {
  const DetectHelpDialog({super.key, required this.item, required this.detected, required this.root});
  final DetectItem item;
  final bool detected;
  final String root; // folder project di PC

  @override
  State<DetectHelpDialog> createState() => _DetectHelpDialogState();
}

class _DetectHelpDialogState extends State<DetectHelpDialog> {
  final pw = TextEditingController();
  final pw2 = TextEditingController();
  final name = TextEditingController();
  final org = TextEditingController();
  bool busy = false;
  List<String>? result;
  bool resultOk = false;

  @override
  void dispose() {
    for (final c in [pw, pw2, name, org]) {
      c.dispose();
    }
    super.dispose();
  }

  String get root => widget.root.isEmpty ? r'D:\path\project' : widget.root;

  Widget _p(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: YmTextStyles.bodyMd.copyWith(color: YmColors.textDark)),
      );

  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 7), child: Icon(Icons.circle, size: 6, color: YmColors.primary)),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: YmTextStyles.bodyMd.copyWith(color: YmColors.textDark))),
        ]),
      );

  Widget _note(String text, {bool warn = false}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: warn ? YmColors.warningSoft : YmColors.surfaceAlt, borderRadius: BorderRadius.circular(10)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(warn ? Icons.warning_amber_rounded : Icons.lightbulb_outline_rounded,
              size: 18, color: warn ? YmColors.onWarningSoft : YmColors.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: YmTextStyles.bodySm.copyWith(color: warn ? YmColors.onWarningSoft : YmColors.textDark, height: 1.5))),
        ]),
      );

  Future<void> _createKeystore() async {
    if (pw.text.length < 6) {
      showSnack(context, tr('Password minimal 6 karakter'), error: true);
      return;
    }
    if (pw.text != pw2.text) {
      showSnack(context, tr('Password tidak sama'), error: true);
      return;
    }
    if (pw.text.contains(RegExp(r'[\s"=\\]'))) {
      showSnack(context, tr('Password jangan memakai spasi, tanda kutip, = atau \\'), error: true);
      return;
    }
    setState(() => busy = true);
    final r = await createUploadKeystore(
      root: widget.root,
      keytool: app.settings.keytoolCmd,
      password: pw.text,
      name: name.text.trim().isEmpty ? 'Developer' : name.text.trim(),
      organization: org.text.trim().isEmpty ? 'Developer' : org.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      busy = false;
      result = r.log;
      resultOk = r.ok;
    });
  }

  List<Widget> _content() {
    final d = widget.detected;
    switch (widget.item) {
      case DetectItem.signing:
        if (d) {
          return [
            _p(tr('Build release sudah ditandatangani dengan upload key dari android/key.properties. AAB siap diterima Google Play.')),
            _note(tr('Cadangkan file upload-keystore.jks dan password-nya di tempat aman (Google Drive / flashdisk). Kalau hilang, kamu harus minta reset upload key ke Google.'), warn: true),
          ];
        }
        return [
          _p(tr('Tanpa keystore, AAB ditandatangani dengan debug key, dan Google Play akan menolaknya saat upload.')),
          _bullet(tr('Build saja (tanpa upload) tetap bisa jalan.')),
          _bullet(tr('Untuk upload ke Google Play kamu perlu keystore. Cukup dibuat sekali per aplikasi.')),
          const SizedBox(height: 8),
          GroupLabel(tr('Cara 1 — Buat otomatis (disarankan)')),
          _p(tr('DeployHub membuat upload-keystore.jks, android/key.properties, mengatur signing release di build.gradle (dengan backup), dan menambahkannya ke .gitignore.')),
          fieldRow([
            DhField(pw, tr('Password keystore'), obscure: true, icon: Icons.password_rounded),
            DhField(pw2, tr('Ulangi password'), obscure: true, icon: Icons.password_rounded),
          ]),
          fieldRow([
            DhField(name, tr('Nama kamu'), icon: Icons.person_outline_rounded, hint: 'Budi'),
            DhField(org, tr('Organisasi / toko'), icon: Icons.business_outlined, hint: 'Batam ChitChat'),
          ]),
          Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton.icon(
              style: primaryButtonStyle(),
              onPressed: busy || widget.root.isEmpty ? null : _createKeystore,
              icon: busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.key_rounded),
              label: Text(tr('Buat keystore otomatis')),
            ),
          ),
          if (result != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: resultOk ? YmColors.successSoft : YmColors.dangerSoft, borderRadius: BorderRadius.circular(10)),
              child: SelectableText(result!.join('\n'),
                  style: YmTextStyles.bodySm.copyWith(
                      fontFamily: 'Consolas', color: resultOk ? YmColors.onSuccessSoft : YmColors.onDangerSoft)),
            ),
            if (!resultOk)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(tr('Kalau keytool tidak ditemukan, isi path lengkapnya di Pengaturan → Tools di PC.'), style: YmTextStyles.bodySm),
              ),
          ],
          const SizedBox(height: 12),
          _note(tr('Simpan password dan cadangkan upload-keystore.jks. Kalau hilang, kamu harus minta reset upload key ke Google.'), warn: true),
          const SizedBox(height: 4),
          GroupLabel(tr('Cara 2 — Manual')),
          _p(tr('1. Buat keystore (PowerShell):')),
          CodeBox(
            'cd $root\\android\n'
            'keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload',
            label: 'PowerShell',
          ),
          _p(tr('Kalau keytool tidak dikenali, pakai path lengkap:')),
          const CodeBox('"C:\\Program Files\\Android\\Android Studio\\jbr\\bin\\keytool.exe"', label: 'keytool'),
          _p(tr('2. Buat file android\\key.properties:')),
          const CodeBox(
            'storePassword=PASSWORD_KAMU\nkeyPassword=PASSWORD_KAMU\nkeyAlias=upload\nstoreFile=../upload-keystore.jks',
            label: 'key.properties',
          ),
          _p(tr('3. Di android/app/build.gradle(.kts): baca key.properties, tambahkan signingConfigs release, dan ganti signingConfig release dari debug ke release (lihat panduan resmi Flutter).')),
          TextButton.icon(
            onPressed: () => launchUrl(Uri.parse('https://docs.flutter.dev/deployment/android#sign-the-app')),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text(tr('Panduan resmi Flutter: Sign the app')),
          ),
          _p(tr('4. Tambahkan key.properties dan *.jks ke .gitignore supaya tidak ikut ke GitHub.')),
        ];
      case DetectItem.github:
        if (d) return [_p(tr('Folder project sudah terhubung ke repo GitHub. Tag, release, dan GitHub Actions bisa dipakai.'))];
        return [
          _p(tr('Folder ini belum terhubung ke repo GitHub. Ini tidak wajib — deploy ke Play Store dan App Store tetap jalan tanpa GitHub.')),
          _p(tr('Tapi untuk deploy iOS, MacBook menarik kode dari GitHub, jadi sebaiknya dihubungkan.')),
          GroupLabel(tr('Hubungkan sekarang')),
          GitHubConnectPanel(
            root: root,
            onConnected: (owner, repo) => setState(() {
              resultOk = true;
              result = [tr('Terhubung ke {0}/{1}. Klik Tutup — owner & repo terisi otomatis.', [owner, repo])];
            }),
          ),
          if (resultOk && result != null) _note(result!.first),
        ];
      case DetectItem.ios:
        if (d) return [_p(tr('Project punya folder ios/, jadi bisa dibuild untuk iPhone di MacBook.'))];
        return [
          _p(tr('Project belum punya folder ios/. Kalau hanya rilis Android, abaikan saja.')),
          _p(tr('Untuk menambahkan dukungan iPhone, jalankan di folder project:')),
          CodeBox('cd $root\nflutter create --platforms=ios .', label: 'PowerShell'),
          _p(tr('Lalu commit & push, dan atur signing di Xcode (MacBook) sekali.')),
        ];
      case DetectItem.login:
        return d
            ? [
                _p(tr('Terdeteksi halaman login. Konsekuensinya:')),
                _bullet(tr('Wajib akun demo untuk reviewer Google & Apple (tanpa OTP).')),
                _bullet(tr('Wajib link web untuk hapus akun dan fitur hapus akun di dalam aplikasi.')),
              ]
            : [_p(tr('Tidak terdeteksi login. Kalau aplikasimu memang tanpa akun, tidak perlu akun demo maupun link hapus akun.'))];
      case DetectItem.googleLogin:
        return d
            ? [
                _p(tr('Terdeteksi Login Google. Penyebab paling umum gagal di versi Play Store adalah SHA-1 yang belum didaftarkan:')),
                _bullet(tr('Daftarkan SHA-1 upload key DAN SHA-1 App signing (Play Console → Integritas aplikasi) di Firebase.')),
                _bullet(tr('Download ulang google-services.json setelah menambah SHA-1.')),
                _bullet(tr('Untuk iOS, App Store mewajibkan Sign in with Apple juga.')),
              ]
            : [_p(tr('Tidak memakai Login Google. Tidak ada yang perlu diatur.'))];
      case DetectItem.chat:
        return d
            ? [
                _p(tr('Terdeteksi fitur chat. Google Play mewajibkan untuk aplikasi chat / sosial:')),
                _bullet(tr('Halaman web standar perlindungan anak (CSAE) yang menyebut nama aplikasi.')),
                _bullet(tr('Cara melapor dari dalam aplikasi.')),
                _bullet(tr('Kontak penanggung jawab di Play Console. Untuk App Store juga fitur blokir user.')),
              ]
            : [_p(tr('Tidak terdeteksi fitur chat. Standar perlindungan anak (CSAE) tidak wajib.'))];
      case DetectItem.firebase:
        return d
            ? [
                _p(tr('Terdeteksi Firebase. Pastikan:')),
                _bullet(tr('android/app/google-services.json ada dan package-nya sama.')),
                _bullet(tr('Untuk iOS: ios/Runner/GoogleService-Info.plist ada.')),
                _bullet(tr('Kalau file tidak di-commit ke git, pilih filenya di langkah Firebase.')),
              ]
            : [_p(tr('Tidak memakai Firebase. Tidak ada yang perlu diatur.'))];
      case DetectItem.ads:
        return d
            ? [
                _p(tr('Terdeteksi iklan (AdMob). Konsekuensinya:')),
                _bullet(tr('Jawab "Ya" di Play Console → Konten aplikasi → Iklan.')),
                _bullet(tr('Isi Keamanan Data: data perangkat / ID iklan dikumpulkan.')),
                _bullet(tr('Pastikan AdMob App ID asli (bukan ID tes) dipakai di build produksi.')),
              ]
            : [_p(tr('Tidak terdeteksi iklan. Jawab "Tidak" di Play Console → Iklan.'))];
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.detected;
    final needFix = !d && detectNeedsFix(widget.item);
    return DhDialog(
      title: detectLabel(widget.item),
      subtitle: d ? tr('Terdeteksi di project') : tr('Tidak terdeteksi di project'),
      icon: d ? Icons.check_circle_outline_rounded : (needFix ? Icons.warning_amber_rounded : Icons.info_outline_rounded),
      width: 720,
      actions: [
        ElevatedButton(
          style: primaryButtonStyle(),
          onPressed: () => Navigator.pop(context, resultOk ? 'rescan' : null),
          child: Text(tr('Tutup')),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ..._content(),
        if (d && detectTargets(widget.item).isNotEmpty) ...[
          const SizedBox(height: 6),
          GroupLabel(tr('Yang harus diisi')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (label, step) in detectTargets(widget.item))
              ElevatedButton.icon(
                style: primaryButtonStyle(),
                onPressed: () => Navigator.pop(context, step),
                icon: const Icon(Icons.arrow_forward_rounded),
                label: Text(label),
              ),
          ]),
        ],
      ]),
    );
  }
}
