# DeployHub — CI/CD desktop untuk aplikasi Flutter

Tampilan mengikuti **Arsip Dokumen PU**: top bar, sidebar, panel, huruf Inter + Plus Jakarta Sans, 6 tema warna (Indigo, Biru PU, Zamrud, Grafit, Konstruksi, Malam). Bahasa: **Indonesia**, **English**, atau **Bilingual** (label pendek "English / Indonesia", teks panjang dua baris). Atur di Pengaturan → Tampilan & bahasa.

Aplikasi Flutter (Windows) untuk build dan deploy aplikasi kamu (mis. Batam ChitChat) langsung dari PC:

- **Android** → build `.aab` di PC → upload otomatis ke **Google Play** (internal/alpha/beta/production)
- **iOS** → PC menyuruh **MacBook** lewat SSH: `git pull` → `pod install` → `flutter build ipa` → upload ke **TestFlight**
- **GitHub** → lihat & jalankan GitHub Actions, buat tag, buat Release dengan lampiran `.aab`
- **Cek Kelayakan Rilis** → akun demo + tes login, link kebijakan & perlindungan anak, Firebase/Login Google (SHA-1), targetSdk, ukuran aplikasi
- **Sinkron Play Store otomatis** → listing per bahasa, ikon, feature graphic, screenshot, detail kontak, Keamanan Data, tester Google Group
- **Checklist Play Console** (bagian tanpa API) dengan jawaban siap tempel + pelacak pengujian tertutup 12 tester / 14 hari
- Log langsung (real-time), riwayat deploy, notifikasi Telegram

```
PC Windows (DeployHub)
 ├─ flutter build appbundle ──► Google Play Developer API
 ├─ git push / GitHub API ────► GitHub (tag, release, Actions)
 └─ SSH ──► MacBook ──► flutter build ipa ──► App Store Connect / TestFlight
```

---

## 0. Cara kerja DevOps (untuk pemula)

```
 Kamu (VS Code)                GitHub                     VPS / cloud
 ───────────────  git push  ─────────────  SSH deploy  ─────────────────────────
 kode aplikasi  ───────────▶  repo        ───────────▶  git pull → docker compose
                              │                          build → container jalan
                              ▼ CI (GitHub Actions /     ▲          │
                                Jenkins / GitLab)        │          ▼ health check
                              analyze → test → build     │    gagal? rollback otomatis
                                                         │
 DeployHub (PC kamu) ── mengatur semuanya: tombol deploy, backup, monitoring, self-healing
```

- **Git/GitHub** = tempat kode. Setiap `push` memicu pipeline.
- **CI (Continuous Integration)** = mesin yang otomatis cek kode: analyze, test, build. Bisa GitHub Actions (gratis, paling mudah), GitLab CI, atau Jenkins (server CI milik sendiri). Cukup pilih **satu** — saran: GitHub Actions.
- **Docker** = membungkus aplikasi + semua kebutuhannya jadi "container", jadi jalan sama persis di PC dan di server. `docker-compose.yml` = daftar container (API + database).
- **CD (Continuous Deployment)** = setelah CI lulus, versi baru otomatis dipasang ke server.
- **VPS** = komputer sewaan di internet (DigitalOcean, AWS, GCP, IDCloudHost…). **Terraform** = membuat VPS dari kode, **Ansible** = menyiapkan isinya.
- **Monitoring** = Prometheus mengukur, Grafana menampilkan grafik, alert ke Telegram kalau ada masalah.

**Alur dari nol untuk backend (mis. FJBBatam API):**
1. Pengaturan → DevOps → *Docker untuk backend* → commit & push file Docker-nya.
2. Infrastructure as Code → buat VPS (atau *Tambah server* kalau sudah punya VPS).
3. Kartu server → *Setup server* → *1. Siapkan project di server* → isi `.env` di server.
4. *Deploy sekarang* → *2. Domain & HTTPS* → *Pasang monitoring*.
5. *3. CD via GitHub Actions* → mulai sekarang cukup `git push`.
6. Nyalakan Backup harian, Pantau kesehatan, Self-healing, Rollback otomatis.

Untuk aplikasi Android: DevOps → *File CI* (GitHub Actions) + *Pasang secret signing di GitHub*; upload ke Play Store tetap lewat pipeline DeployHub (dengan persetujuan).

Hasil tes semua fitur server: lihat **TESTING.md**.

## 1. Menjalankan DeployHub

Butuh Flutter SDK + Visual Studio (workload "Desktop development with C++") di PC.

```bat
cd deployhub
flutter create --platforms=windows --project-name deployhub .
flutter pub get
flutter run -d windows
```

`flutter create .` hanya menambah folder `windows/` yang belum ada, file di `lib/` tidak ditimpa.

Untuk versi .exe: `flutter build windows` → hasilnya di `build\windows\x64\runner\Release\`.

---

## 2. Setup Google Play (sekali saja)

1. Buka **Google Cloud Console** → buat/pilih project → aktifkan **Google Play Android Developer API**.
2. **IAM & Admin → Service Accounts** → buat service account → tab **Keys** → *Add key* → JSON. Simpan file JSON-nya.
3. Buka **Play Console → Users and permissions** → *Invite new user* → masukkan email service account (…@….iam.gserviceaccount.com) → beri izin untuk aplikasi kamu: *Release to testing tracks* (dan *Release to production* kalau perlu).
4. Di DeployHub: **Tambah Proyek** → pilih file JSON tadi.

Catatan penting:
- **AAB pertama harus diupload manual** di Play Console. API tidak bisa membuat aplikasi baru.
- Kalau aplikasi belum pernah dipublikasikan sama sekali, pakai status rilis **draft**.
- Pastikan `android/key.properties` + keystore sudah ada di project, supaya AAB ditandatangani dengan upload key, bukan debug key.
- Izin service account kadang butuh beberapa jam sampai aktif.

---

## 2b. Pengaturan → Akun & koneksi

Semua akun diatur sekali di **Pengaturan**, lalu dipakai semua proyek:

| Koneksi | Pilihan |
|---|---|
| **Google Play** | **Login dengan Google** (OAuth Desktop — akun Google pemilik Play Console, login lewat browser) **atau** **Service Account JSON** (standar CI/CD tanpa browser). Tombol "Tes Google Play" mencoba akses ke package kamu. Proyek boleh punya Service Account sendiri di Edit Proyek. |
| **GitHub** | Personal Access Token (fine-grained: Contents & Actions = Read and write). "Tes GitHub" menampilkan username. |
| **App Store Connect** | Key ID, Issuer ID, file `AuthKey_XXXX.p8`. File .p8 diupload otomatis ke MacBook saat deploy iOS. |
| **MacBook (SSH)** | Host/IP, user, password (juga untuk unlock keychain), private key opsional. |
| **Telegram** | Bot token + chat ID untuk notifikasi. |

Google tidak menyediakan login username/password untuk API Play Console, jadi "login Google Play" memakai jalur resmi OAuth.

### Menyiapkan "Login dengan Google"
1. Google Cloud Console → pilih/buat project → **APIs & Services → Library** → aktifkan **Google Play Android Developer API**.
2. **OAuth consent screen** → External → isi nama aplikasi, tambahkan email kamu sebagai *test user*.
3. **Credentials → Create credentials → OAuth client ID → Desktop app** → salin Client ID & Client Secret.
4. DeployHub → Pengaturan → Google Play → **Login dengan Google** → isi Client ID & Secret → klik **Login dengan Google** → browser terbuka → pilih akun pemilik Play Console → izinkan.
5. Token disimpan di Windows Credential Manager dan diperbarui otomatis.

---

## 3. Setup GitHub

Buat **Fine-grained Personal Access Token** (GitHub → Settings → Developer settings):
- Repository access: pilih repo kamu (mis. `Infinisynx-Teknolab-Indonesia/...`)
- Permissions: **Contents: Read and write** (release), **Actions: Read and write** (jalankan workflow), Metadata: Read

Untuk repo organisasi, owner organisasi mungkin perlu menyetujui token tersebut.

Tombol **Jalankan** di halaman GitHub hanya bekerja untuk workflow yang punya trigger:
```yaml
on:
  workflow_dispatch:
```

Push/tag dari DeployHub memakai `git` di PC, jadi pastikan `git push` di folder project sudah bisa jalan tanpa ditanya password (Git Credential Manager atau SSH key).

---

## 4. Setup MacBook (untuk iOS)

Di MacBook:
1. **System Settings → General → Sharing → Remote Login** → aktifkan (SSH).
2. Install Xcode, Flutter, CocoaPods. Tes di Terminal: `flutter doctor`.
3. Buka Xcode → **Settings → Accounts** → login Apple ID developer. Di `ios/Runner.xcworkspace` aktifkan *Automatically manage signing* dan pilih Team.
4. Clone repo project ke Mac, mis. `~/projects/batamchitchat`, lalu jalankan `flutter build ipa` sekali manual untuk memastikan signing beres.
5. Buat **App Store Connect API Key** (App Store Connect → Users and Access → Integrations → App Store Connect API) → download `AuthKey_XXXXXX.p8` → taruh di Mac:
   ```bash
   mkdir -p ~/.appstoreconnect/private_keys
   mv ~/Downloads/AuthKey_XXXXXX.p8 ~/.appstoreconnect/private_keys/
   ```
   Isi **Key ID** dan **Issuer ID** di Edit Proyek.

Di DeployHub → **Pengaturan → MacBook**: isi IP Mac (lihat di System Settings → Wi-Fi → Details), username, password, lalu klik **Tes SSH MacBook**. Hasilnya harus menampilkan versi macOS, Xcode, Flutter, CocoaPods.

Tips:
- PC dan Mac di jaringan yang sama. Kalau di luar rumah, pakai **Tailscale** (gratis) lalu isi IP Tailscale Mac.
- Lebih aman pakai SSH key: `ssh-keygen -t ed25519` di PC, salin isi `.pub` ke `~/.ssh/authorized_keys` di Mac, lalu pilih file private key di Pengaturan.
- Langkah **Unlock keychain** perlu password Mac. Tanpa ini, codesign lewat SSH sering gagal dengan `errSecInternalComponent`.
- Kalau ingin ExportOptions sendiri, buat `ios/ExportOptions.plist` (method `app-store-connect`) dan isi path-nya di Edit Proyek.
- Upload memakai `xcrun altool --upload-app`. Kalau Apple mengubah tool ini di versi Xcode kamu, alternatifnya aplikasi **Transporter** atau `fastlane pilot`.

---

## 5. Alur deploy

**Android** (urutan langkah, bisa dicentang/tidak):
1. Cek konfigurasi
2. Git pull
3. `flutter pub get`
4. `flutter analyze`
5. `flutter test`
6. Naikkan build number (otomatis dicocokkan dengan versionCode tertinggi di Play, jadi tidak kena error "version code already used")
7. `flutter build appbundle --release`
8. Upload ke Google Play + catatan rilis
9. Git commit, tag `android-v1.2.3-45`, push
10. GitHub Release + lampiran `.aab`

**iOS**:
1. Push kode dari PC ke GitHub
2. SSH ke MacBook
3. Git pull di Mac
4. `flutter pub get` + `pod install`
5. Unlock keychain
6. `flutter build ipa --release`
7. Upload ke TestFlight

Tips: jalankan **Deploy Android** dulu (build number naik + commit + push), lalu **Deploy iOS**, supaya Android dan iOS memakai versi yang sama.

---

## 5b. Cek Kelayakan Rilis

Berjalan otomatis sebelum build (langkah "Cek kelayakan rilis"), atau manual lewat tombol **Cek Kelayakan Rilis** di kartu proyek. Kalau ada yang **gagal (✖)**, deploy dihentikan supaya tidak ditolak reviewer. **Peringatan (⚠)** tidak menghentikan deploy.

| Kategori | Yang dicek |
|---|---|
| Versi & SDK | `version:` di pubspec, **targetSdk ≥ 36** (wajib Google Play untuk app baru & update sejak 31 Agustus 2026; angka bisa diubah di Pengaturan) |
| Login & akun demo | Deteksi otomatis apakah aplikasi punya login. Kalau ada: **akun demo wajib diisi**, akun dites login ke API kamu (URL tes login), link hapus akun wajib & bisa dibuka, fitur hapus akun di dalam aplikasi |
| Kebijakan & perlindungan anak | Link kebijakan privasi bisa dibuka. Untuk aplikasi chat/sosial: **link standar perlindungan anak (CSAE)** wajib, bisa dibuka publik, dan menyebut nama aplikasi; fitur lapor di dalam aplikasi; (iOS) fitur blokir user |
| Firebase & Login Google | `google-services.json` ada & package cocok, **SHA-1 upload key** (dibaca otomatis dari keystore via keytool) dan **SHA-1 App signing Google Play** terdaftar di Firebase, web client ID ada. iOS: `GoogleService-Info.plist`, bundle ID cocok, `REVERSED_CLIENT_ID` ada di Info.plist, Sign in with Apple |
| Ukuran & hemat | Aset > 1 MB, obfuscate + split-debug-info, jumlah `print()`, ukuran AAB vs batas, kenaikan ukuran dibanding build sebelumnya (> 10% = peringatan) |

Tombol **"Salin info untuk Play Console"** menyalin akun demo + semua link, tinggal tempel di:
- Play Console → App content → **App access** (akun demo), **Data safety → Account deletion** (link hapus akun), **Child safety standards** (link CSAE + kontak penanggung jawab)
- App Store Connect → App Review Information → **Sign-in required**

### Kenapa SHA-1 App signing penting
Kalau aplikasi memakai Play App Signing, Google menandatangani ulang aplikasi dengan key milik Google. Login Google yang lancar saat debug bisa **gagal (error 10) di versi dari Play Store** kalau SHA-1 App signing belum didaftarkan di Firebase. Ambil di Play Console → Test and release → App integrity → App signing, isi di Edit Proyek, tambahkan juga di Firebase, lalu download ulang `google-services.json`.

### Firebase tidak ikut di git
Kalau `google-services.json` / `GoogleService-Info.plist` sengaja tidak di-commit, pilih file-nya di Edit Proyek. Saat deploy, DeployHub menyalinnya ke `android/app/` dan mengupload plist ke MacBook (SFTP) sebelum build.

### Integration test login
Centang "Integration test login" di dialog deploy. Contoh tesnya ada di `contoh/integration_test/login_test.dart`; salin ke project aplikasi dan sesuaikan Key widget-nya. Butuh HP/emulator yang tersambung ke PC.

---

## 5c. Pipeline lengkap & sinkron Play Store

Urutan langkah Deploy Android sekarang:

1. Cek konfigurasi → pasang google-services.json → git pull → `flutter pub get`
2. **Cek kelayakan rilis** (termasuk listing, checklist Play Console, pengujian tertutup)
3. Integration test login → `flutter analyze` → `flutter test`
4. Naikkan build number → build AAB → cek ukuran
5. Upload AAB ke track
6. **Sinkron Play Store**: listing + gambar + detail kontak + tester Google Group
7. **Upload Keamanan Data** dari `store/data_safety.csv`
8. Git tag & push → GitHub Release → notifikasi Telegram

### Yang otomatis vs manual

| Bagian Play Console | Cara |
|---|---|
| Upload AAB, track, catatan rilis | ⚡ Otomatis (API) |
| Listing: judul, deskripsi, ikon, feature graphic, screenshot (per bahasa) | ⚡ Otomatis dari `store/android/<bahasa>/` |
| Email / website / telepon kontak, bahasa default | ⚡ Otomatis dari `store/details.json` |
| Keamanan Data | ⚡ Otomatis dari `store/data_safety.csv` (isi sekali di Play Console → Export to CSV) |
| Tester pengujian tertutup | ⚡ Otomatis via Google Group |
| Kebijakan privasi, Detail login, Iklan, Rating konten, Audiens target, Aplikasi pemerintah, Fitur keuangan, Kesehatan, Kategori, Standar keselamatan anak | ✋ Manual sekali — tidak ada API dari Google. DeployHub menyiapkan jawaban siap tempel di **Checklist Play Console** |
| Pengajuan akses produksi (akun pribadi) | ✋ Manual setelah 12 tester × 14 hari |

### Mulai pakai
1. Kartu proyek → menu ⋮ → **Buat template store/** → isi teks di `store/android/id-ID/` dan taruh gambar di `images/`. Commit folder ini ke git.
2. Kartu proyek → menu ⋮ → **Checklist Play Console** → salin tiap jawaban ke Play Console, centang yang sudah diisi. Isi juga Google Group tester, tanggal mulai, dan jumlah tester.
3. Deploy ke track **alpha** selama pengujian tertutup. Deploy ke **production** otomatis diblokir oleh Cek Kelayakan Rilis sampai checklist lengkap dan (untuk akun pribadi) 12 tester × 14 hari terpenuhi.

Catatan: perubahan listing yang dikirim lewat API ikut direview Google seperti biasa.

---

## 5d. Mode build: Internal vs Produksi

Di dialog Deploy Android pilih dulu modenya:

| | **Internal (uji cepat)** | **Produksi (optimal)** |
|---|---|---|
| Track | internal | alpha / beta / production |
| R8 + shrinkResources | tidak diubah | diaktifkan otomatis di `android/app/build.gradle(.kts)` (backup `.deployhub.bak`, `proguard-rules.pro` aman untuk Flutter dibuat) |
| Dart | release biasa | `--obfuscate --split-debug-info=build/symbols/<versi>` |
| Mapping R8 | — | diupload ke Play sebagai deobfuscation file (crash report tetap terbaca) |
| Laporan ukuran | ukuran AAB + perkiraan download | + perbandingan dengan build internal terakhir, target ≥50% |

Tentang target 50%: build release Flutter sudah memakai R8 secara bawaan, jadi tambahan obfuscate + shrink resources biasanya mengecilkan **file AAB** sekitar 5–20%. Yang biasanya turun lebih dari 50% adalah **ukuran download di HP**, karena Google Play hanya mengirim library untuk satu jenis CPU (arm64) dan tidak mengirim debug symbols. DeployHub menampilkan kedua angka itu apa adanya, dan memberi peringatan kalau download belum turun 50% dibanding AAB internal.

Kalau build produksi gagal karena R8 (biasanya "Missing class ..."), tambahkan aturan `-keep` atau `-dontwarn` untuk class itu di `android/app/proguard-rules.pro`, atau kembalikan `build.gradle` dari file backup.

---

## 5e. Deploy ke App Store (iOS)

Di kartu proyek ada dua tombol besar: **Deploy ke Play Store** dan **Deploy ke App Store**. Dialog App Store juga punya dua mode:

| | **TestFlight (uji)** | **App Store (produksi)** |
|---|---|---|
| Build | `flutter build ipa --release` | + `--obfuscate --split-debug-info` |
| Build number | otomatis (tanggal-jam, selalu unik) atau manual | sama |
| Upload | `xcrun altool` ke App Store Connect → muncul di TestFlight 5–30 menit | sama |
| Review | — | otomatis dikirim untuk review lewat `fastlane deliver` (dicoba ulang tiap 2 menit sampai Apple selesai memproses build) |
| IPA | disalin ke `build/ios_from_mac/` di PC | sama |

Yang perlu ada di MacBook: Xcode, Flutter, CocoaPods, Remote Login aktif, dan **fastlane** (`brew install fastlane`) kalau ingin kirim review otomatis. API key `.p8` dan file JSON untuk fastlane dipasang otomatis oleh DeployHub ke `~/.appstoreconnect/`.

**Perjalanan Rilis** sekarang punya tab **Google Play** dan **App Store**. Tab App Store berisi 10 tahap: data proyek iOS → API key → MacBook → daftarkan Bundle ID & buat aplikasi → signing Xcode → TestFlight → uji → info App Store → kirim review → rilis.

---

## 5f. Upload file AAB / IPA langsung (tanpa build)

Tombol **"Upload file AAB / IPA"** ada di Dasbor, halaman Proyek, dan menu ⋮ kartu proyek. Pilih file yang sudah jadi:

- **.aab → Google Play**: DeployHub membaca package name, versionName/versionCode, dan tanda tangan dari dalam file. Kalau ditandatangani **debug key** atau belum ditandatangani, upload diblokir (Google pasti menolak). Pilih track + status + catatan rilis, lalu upload.
- **.ipa → App Store**: pilih kartu "App Store" di atas. File dikirim ke MacBook lewat SFTP, diupload dengan `xcrun altool` ke TestFlight, dan (opsional) otomatis dikirim untuk review App Store lewat fastlane. Bundle ID dan versi dibaca dari Info.plist di dalam IPA.

Proyek tidak wajib dipilih. Kalau dipilih (atau package-nya cocok dengan proyek), hasilnya masuk ke riwayat proyek itu.

---

## 5g. Laporan AAB (seperti Play Console)

Setiap kali AAB dibuat atau dipilih untuk diupload, DeployHub menganalisa isinya, langsung dari file, tanpa tool tambahan:

| Bagian | Yang dicek |
|---|---|
| Aplikasi | package, versi, **targetSdk** (ditolak kalau di bawah batas Google Play) |
| Perangkat yang didukung | Android minimal, jenis CPU (wajib arm64-v8a, peringatan kalau tanpa armeabi-v7a), fitur hardware, **halaman memori 16 KB** (ELF `.so` 64-bit; wajib untuk update yang target Android 15+ sejak 1 Nov 2025) |
| Optimasi | **R8 aktif?** (mapping ada di AAB), **simbol debug native** (Play Console memberi peringatan kalau tidak ada), perkiraan ukuran download per CPU |
| Izin & deklarasi | izin yang butuh formulir di Play Console (SMS, lokasi latar belakang, foto & video, foreground service, dll.), AD_ID |
| Rilis | perkiraan waktu tunggu per track |

Temuan merah (✖) memblokir upload karena Google pasti menolak. Laporan bisa dibuka dari dialog Upload file, halaman Pipeline, dan ikon di Riwayat. Jumlah persis perangkat yang didukung hanya ada di Play Console → App bundle explorer, karena Google tidak menyediakan API untuk itu.

## 5h. Hubungkan App Store Connect

Apple tidak memakai login Apple ID untuk alat otomatis. Yang resmi adalah **API key (.p8)**. Pengaturan → App Store Connect → ikuti 4 langkah → **Hubungkan**. DeployHub langsung memanggil App Store Connect API dari PC (token JWT ES256) untuk menampilkan daftar aplikasi, status build, dan status review. Build dan upload IPA tetap lewat MacBook.

---

## 5i. Siapkan Firebase (otomatis)

Kalau kode memakai paket Firebase tapi `android/app/google-services.json` (atau `ios/Runner/GoogleService-Info.plist`) belum ada, baris Firebase di form proyek berwarna **oranye** dan muncul kotak "Konfigurasi Firebase belum ada". Klik kotak itu (atau tombol **Siapkan Firebase** di langkah Firebase):

**Otomatis**, memakai alat resmi Google:
1. Pasang alat: Firebase CLI (`npm install -g firebase-tools`, butuh Node.js) + FlutterFire CLI (`flutter pub global activate flutterfire_cli`).
2. Login Firebase: jendela terminal `firebase login` terbuka, lalu login lewat browser.
3. Pilih project Firebase yang ada, atau buat project baru.
4. **Buat konfigurasi**: `flutterfire configure`, yang mendaftarkan aplikasi Android (dan iOS) lalu membuat `google-services.json`, `GoogleService-Info.plist`, dan `lib/firebase_options.dart`.
5. **Daftarkan SHA-1**: SHA-1 upload key (dibaca dari keystore) + SHA-1 App signing (dari Play Console) didaftarkan lewat CLI, lalu `google-services.json` diunduh ulang.
6. Aktifkan Login Google di Firebase Console (manual, tidak ada perintah CLI).

**Manual**: langkah demi langkah di Firebase Console, lengkap dengan lokasi file dan SHA-1 kamu.

---

## 5j. Full screen & system tray (sama seperti Arsip PU)

- Aplikasi mulai **full screen**. Arahkan mouse ke tepi paling atas layar → title bar turun
  (tombol keluar full screen, minimize, maximize, tutup). **F11** = full screen / keluar.
- Tombol **X** menyembunyikan DeployHub ke **system tray** (pojok kanan bawah taskbar).
  Pipeline tetap berjalan; tooltip ikon menampilkan "Deploy X berjalan".
- Ikon tray: klik kiri = buka, klik kanan = Buka / Pipeline berjalan / Riwayat / Proyek / Keluar.
- Ikon .exe: `windows/runner/resources/app_icon.ico` (ikut di zip) — `flutter clean` lalu build ulang.

## 5k. Menjalankan DeployHub di MacBook

DeployHub juga bisa dijalankan / dibuat installer di macOS (`flutter build macos`).
- `macos/Runner/*.entitlements` (ikut di zip): **App Sandbox mati** — wajib, karena DeployHub
  menjalankan flutter, git, xcodebuild, pod, firebase. Salin ke folder `macos/Runner/` project.
- PATH: aplikasi Mac yang dibuka dari Finder tidak membaca `~/.zshrc`. DeployHub membaca PATH
  login shell saat mulai + menambah Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`),
  `~/.pub-cache/bin`, `~/.npm-global/bin`, nvm/volta.
- Siapkan Firebase di Mac: Node.js lewat **Homebrew** (`brew install node`), atau Firebase CLI
  **tanpa Node.js** lewat installer resmi (`curl -sL https://firebase.tools | bash`, Terminal
  meminta password Mac). FlutterFire via `flutter pub global activate flutterfire_cli`.
- Password/token: Keychain macOS; kalau Keychain menolak (aplikasi belum ditandatangani),
  disimpan di `secrets.json` (chmod 600) di folder data aplikasi.
- Build iOS dari DeployHub yang jalan di Mac yang sama: Pengaturan → MacBook, host `localhost`
  (System Settings → General → Sharing → Remote Login aktif).

## 5l. Optimasi R8 sebelum upload (seperti App bundle explorer)

Saat AAB dipilih (Upload file langsung) atau selesai di-build, DeployHub menampilkan:
Platform asal, API level, SDK target, OpenGL ES, tata letak layar, 16 KB, **persentase
pengoptimalan / obfuscation / penyusutan**, **Konfigurasi R8** (mode penuh, penyingkatan
resource, penyingkatan resource yang dioptimalkan, kemas ulang kelas), total DEX, dan
"Tindakan direkomendasikan" (edge-to-edge, API layar penuh lama, gambar bitmap besar, R8).
- Obfuscation: dari mapping R8 di dalam AAB. Penyusutan: dari `usage.txt` build yang sama.
  Pengoptimalan: perkiraan (angka persis dihitung Google setelah upload).
- Kalau ada yang **< 50%**, tombol Upload terkunci sampai dicentang "Tetap upload".
- Mode Produksi kini juga menulis `android.enableR8.fullMode=true` dan
  `android.r8.optimizedResourceShrinking=true` di `android/gradle.properties`.

## 5m. Perbaikan file project otomatis

Sebelum setiap build (langkah "Cek konfigurasi") dan lewat menu ⋮ → "Periksa & perbaiki file project":
- **Keystore / key.properties**: storeFile salah path → dicari & dibetulkan; keyPassword kosong → = storePassword;
  keyAlias salah → alias yang ada di keystore; password salah → peringatan. Keystore + key.properties belum ada
  dan aplikasi belum pernah diupload → keystore BARU dibuat (password acak di Credential Manager).
  key.properties hilang tapi password pernah disimpan DeployHub → dibuat ulang.
- **local.properties**: flutter.sdk / sdk.dir salah → dibuat ulang dari Flutter & Android SDK yang terdeteksi.
- **pubspec.yaml**: tanpa version / build number → ditambahkan; aset yang filenya tidak ada → dinonaktifkan.
- **Gradle**: import Kotlin DSL, applicationId, compileSdk plugin lama, namespace plugin lama, kotlin.incremental
  (beda drive), JVM target, minSdk, versi Kotlin, memori Gradle, lisensi SDK, cache terkunci.
- **AndroidManifest**: izin INTERNET; peringatan AdMob APPLICATION_ID.
- Build gagal karena error yang dikenal → diperbaiki otomatis lalu build ulang (maks. 3 putaran).
Semua file yang diubah dibackup ke *.deployhub.bak.

## 5n. DevOps & integrasi (Pengaturan)

Semua alat bisa **diaktifkan / dimatikan** sendiri di Pengaturan → DevOps & integrasi, dipasang otomatis (winget di Windows, Homebrew di Mac), dan dites dari sana.

| Tahap CI/CD | Di DeployHub |
|---|---|
| 1. Source | git pull otomatis, pemicu commit baru (cek branch tiap N menit), file CI untuk push/PR: GitHub Actions, `.gitlab-ci.yml`, `Jenkinsfile`, `bitbucket-pipelines.yml` |
| 2. Build | `flutter pub get`, build AAB/IPA, perbaikan Gradle otomatis, opsi build di Docker |
| 3. Test | `flutter analyze` (lint), unit test, integration test, cek kelayakan rilis, laporan AAB/R8, **security scan** |
| 4. Release / Staging | arsip artefak per versi (AAB + mapping + laporan), Nexus / Artifactory, GitHub Release |
| 5. Deploy | Persetujuan sebelum upload = *Continuous Delivery*; pemicu mode CD / matikan "tanya dulu" = *Continuous Deployment*. Track internal / alpha / beta / produksi, TestFlight / App Store |
| Notifikasi | Telegram, Discord, Slack |

Jenkins bisa dipasang otomatis sebagai container Docker (`http://localhost:8080`). Tekton & ArgoCD khusus untuk cluster Kubernetes (aplikasi server), tidak dipakai untuk rilis aplikasi mobile ke Play Store / App Store.

## 5o. Tombol "Optimalkan" di Laporan AAB (v1.14)

Setiap "Tindakan direkomendasikan" punya tombol **Optimalkan** (atau **Optimalkan semua**). Semua file yang diubah dibackup ke `*.deployhub.bak`, lalu tinggal **Jalankan ulang**.

| Peringatan Play Console | Yang dikerjakan tombol |
|---|---|
| Layar penuh (edge-to-edge) | MainActivity → `FlutterFragmentActivity` + `enableEdgeToEdge()`, dependensi `androidx.activity` |
| API layar penuh usang | `flutter pub upgrade` + edge-to-edge (sisa dari engine Flutter aman diabaikan) |
| Gambar bitmap > 300 KB | Perkecil resolusi (ikon/logo 512 px) + kompres ulang, nama file tetap |
| R8 < 50% / Kemas ulang kelas | Mode penuh, shrinkResources, optimizedResourceShrinking, `-repackageclasses` |
| Simbol debug native | `ndk { debugSymbolLevel = "SYMBOL_TABLE" }` |
| Halaman memori 16 KB | `flutter pub upgrade` |

## 5p. AI perbaikan otomatis

Pengaturan → AI perbaikan otomatis (on/off). Preset: Prakash AI (`http://localhost:5088/v1`), LM Studio, Ollama, llama.cpp, OpenAI, Claude API.
Kalau perbaikan berbasis aturan tidak cukup, log error + file terkait dikirim ke AI, file hasil perbaikan ditulis (backup `*.deployhub.bak`) lalu build/analyze diulang.
`key.properties`, keystore, `google-services.json`, `.env`, service account **tidak pernah** dikirim; password di file disamarkan.

## 5q. Server & infrastruktur

Pengaturan → Otomatisasi Deployment & Infrastruktur (on/off). Per server (SSH): deploy (`git pull` → `docker compose up -d --build`), backup DB terjadwal + salinan ke PC, restore, health check (HTTP + RAM/disk/container) dengan alert Telegram/Discord/Slack, deploy otomatis saat commit baru, dan ekspor skrip **Python Fabric** yang setara:

```
D:\python3.12\python.exe -m pip install fabric requests
set SERVER_PASSWORD=...
D:\python3.12\python.exe deploy_vps.py deploy
```

## 5r. Infrastructure as Code, monitoring & self-healing (v1.15)

**Terraform** (Pengaturan → Infrastructure as Code): pilih DigitalOcean / AWS / GCP → *Plan* → setujui → *Apply*. VPS Ubuntu 24.04 dibuat dengan cloud-init (Docker, ufw, fail2ban), SSH key dibuat otomatis, dan server langsung masuk ke daftar *Server & infrastruktur*. File `.tf` ada di folder `infra/<nama>` (bisa diedit / di-commit). *Destroy* menghapus server.

**Ansible / setup server**: tombol *Setup server (SSH)* (bash) atau *Setup (Ansible)* (playbook `setup.yml` dijalankan lewat container `alpine/ansible`). *Playbook Ansible (semua server)* menulis `inventory.ini` + `setup.yml`.

**Monitoring**: *Pasang monitoring* memasang Prometheus + Grafana (port 3000) + Loki/Promtail (log, alternatif ELK) + node-exporter + cAdvisor dengan aturan alert (disk, RAM, CPU, target mati, container restart terus). Alert yang aktif ikut terbaca di health check DeployHub → Telegram/Discord/Slack.

**Self-healing** (per server): container mati → dinyalakan, aplikasi tidak menjawab → `docker compose restart`, disk ≥ 90% → bersihkan image/cache/log lama. **Rollback otomatis**: deploy / health check gagal → `git reset --hard <commit sebelumnya>` + deploy ulang. **AI diagnosis**: log container dikirim ke AI; perintah perbaikan hanya dijalankan kalau diizinkan dan selalu disaring (hapus data, volume, reboot, firewall, SSH, git push, curl|sh → ditolak).

**Runbook**: *Buat runbook* menulis `infra/RUNBOOK.md` (server, deploy, rollback, backup/restore, penanganan insiden).

## 5s. Pasang alat otomatis (v1.16)

Tidak perlu memasang manual. Setiap fitur yang butuh alat memanggil `ensureTool()`: kalau belum ada → dipasang otomatis (winget di Windows, Homebrew di Mac), PATH dibaca ulang, lalu dicek lagi.

| Fitur | Alat yang dipasang otomatis |
|---|---|
| Build AAB di Docker, Jenkins, Ansible, Unduh image Flutter | Docker Desktop (+ WSL2 di Windows), lalu Docker Desktop dinyalakan dan ditunggu sampai siap |
| Terraform plan / apply / destroy | Terraform |
| Pengaturan → Alat di PC | tombol per alat + **Pasang semua yang belum ada** |

Catatan Windows: jendela izin administrator (UAC) muncul sekali — klik Yes. Setelah WSL2 pertama kali dipasang, Windows biasanya minta restart.

## 5t. Build siap deploy + halaman wajib Play (v1.19)

**Auto-build saat GitHub update, deploy manual 1 klik**
1. Kartu proyek → *Build siap deploy* → nyalakan **Auto-build saat GitHub update**.
2. Setiap ada commit baru di branch proyek, DeployHub menjalankan `git pull` → build **AAB produksi** (R8, versionCode = tertinggi di Play + 1) → (kalau iOS diatur) build **IPA** di MacBook. `pubspec.yaml` dikembalikan seperti semula, jadi repo tetap bersih. Notifikasi "build siap" dikirim ke Telegram/Discord/Slack.
3. Klik **Deploy** → pilih track → pipeline: periksa file & tanda tangan → cek versionCode di Play → **Laporan AAB** → **Cek kelayakan rilis** → **panel persetujuan** (semua masalah tampil) → upload. Build yang ditolak tetap tersimpan.

**Halaman wajib**: ⋮ → *Buat kebijakan privasi & halaman wajib* — kebijakan privasi, hapus akun (kalau ada login), standar keselamatan anak (aplikasi chat) dibuat dari SDK & izin yang terdeteksi, di-host di GitHub Pages (repo publik terpisah `<repo>-legal`), link otomatis terisi di proyek. Juga berisi **panduan jawaban Keamanan Data**.

## 5u. Tombol "Perbaiki" di panel persetujuan (v1.20)

Setiap baris merah punya tombol **Perbaiki**:
- *Listing Play Store / Email kontak* → form listing: judul, deskripsi (bisa ditulis AI), email/website/telepon, ikon 512 (dari ikon aplikasi), feature graphic 1024x500 (dibuat otomatis dari ikon + nama), screenshot HP (ukuran & rasio disesuaikan otomatis). Disimpan di `store/` dan disinkron tiap deploy.
- *SHA-1 di Firebase* → SHA-1 upload key dibaca dari keystore + SHA-1 App signing (tempel dari Play Console) → didaftarkan ke Firebase lewat Firebase CLI → google-services.json diunduh ulang.
- Lainnya → Edit proyek.
Setelah diperbaiki, daftar merah dicek ulang otomatis (tombol **Cek ulang**) tanpa build ulang.

## 5v. DevOps lengkap (v1.22)

| Kekurangan sebelumnya | Sekarang |
|---|---|
| Pipeline bergantung pada PC | **DeployHub Server** (folder terpisah `deployhub-server`, Python FastAPI): jalan di PC (`run.py`, Eclipse) atau VPS (Docker/Portainer). Build setiap push (webhook GitHub + polling), antrean job, artefak, deploy ke Play, dashboard web untuk HP. DeployHub desktop = panel kontrol (Pengaturan → DeployHub Server). |
| Tidak ada test | Menu proyek → **Buat test dasar + coverage**. Pipeline menjalankan `flutter test --coverage` dan menampilkan %, dengan batas minimal per proyek (Edit proyek → Coverage test minimal). |
| Tidak ada crash monitoring | Menu proyek → **Pasang Crashlytics** (dependency, plugin Gradle, `main.dart`); simbol obfuscate diupload otomatis setiap build produksi. **Rollout & crash**: crash rate & ANR dari Play Developer Reporting API, dibandingkan dengan ambang Google (1.09% / 0.47%). |
| Tidak ada staged rollout / rollback | Deploy production: pilih 5/10/20/50/100% pengguna. **Rollout & crash**: naikkan %, **Hentikan** (halt), Lanjutkan, 100%. Server: naik otomatis tiap `min_hours` kalau crash/ANR aman, halt otomatis kalau melewati ambang. |
| Tidak ada dev/staging/prod | Menu proyek → **Siapkan dev / staging / prod** → `env/*.json` + `lib/config/env.dart` + `.vscode/launch.json`. Dialog Deploy: pilih lingkungan → `--dart-define-from-file=env/<env>.json`. |

## 6. Penyimpanan data

- Proyek, pengaturan, tema & bahasa, riwayat: `%APPDATA%\com.example\deployhub\` (folder AppSupport aplikasi)
- Log tiap deploy: subfolder `logs\`
- Token GitHub, login Google Play, password Mac, token Telegram, password akun demo: **Windows Credential Manager** (tidak disimpan sebagai teks biasa)

## 7. Struktur kode

```
lib/
  main.dart                    shell: top bar + sidebar (gaya Arsip PU)
  theme/dh_theme.dart          tema warna, huruf, tombol (dari Arsip PU)
  core/i18n.dart, i18n_en.dart bahasa Indonesia / English / Bilingual
  widgets/                     Panel, PageHeader, StatCard, dialog, dll.
  state.dart                   state aplikasi (proyek, riwayat, run aktif)
  models.dart                  Project, AppSettings, RunRecord
  services/
    pipeline.dart              mesin pipeline: langkah, log, cancel, perintah lokal & SSH
    android_pipeline.dart      langkah-langkah deploy Android
    ios_pipeline.dart          langkah-langkah deploy iOS
    play_service.dart          Google Play Developer API
    play_auth.dart             login Google (OAuth) / Service Account
    github_service.dart        GitHub REST API + Telegram
    mac_service.dart           SSH ke MacBook (dartssh2)
    release_checks.dart        cek kelayakan rilis
    store_metadata.dart        baca/validasi folder store/ + template
    play_console_tasks.dart    checklist Play Console + status pengujian tertutup
    version.dart               baca/tulis versi pubspec.yaml
    storage.dart               file JSON + secure storage
  screens/                     Proyek, Pipeline, GitHub, Riwayat, Pengaturan
```
