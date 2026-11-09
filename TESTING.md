# Hasil tes DeployHub v1.17 (sandbox)

Sandbox: Ubuntu 24.04 + Docker 29 + OpenSSH sebagai "VPS tiruan". Perintah yang dites diambil **langsung dari kode Dart DeployHub** (bukan ditulis ulang), dijalankan lewat SSH dengan cara yang sama seperti DeployHub (`bash -lc '…'`).
Backend contoh: API Python + MariaDB di Docker Compose, repo git, user `deploy` (non-root + sudo) seperti di AWS/GCP.

| # | Yang dites | Hasil | Bug yang ditemukan & sudah diperbaiki |
|---|---|---|---|
| 1 | Health probe (load, RAM, disk, container) | ✅ | — |
| 2 | Deploy pertama (git pull → compose build → up) | ✅ HTTP 200 | — |
| 3 | Backup MySQL → data dirusak → restore | ✅ data kembali utuh | — |
| 4 | Self-healing: container API dimatikan | ✅ terdeteksi, dinyalakan, HTTP 200; volume DB aman | — |
| 5 | Rollback: versi rusak (health 500) | ✅ kembali ke versi baik | Setelah rollback, deploy otomatis mencoba commit rusak lagi → commit rusak kini dicatat & dilewati |
| 6 | Setup server (bash) sebagai user sudo | ✅ Docker, ufw, update otomatis, swap | Skrip berhenti total kalau 1 layanan gagal → kini ada fallback |
| 7 | Playbook Ansible (2× jalan) | ✅ failed=0, run ke-2 changed=0 (idempotent) | VPS minimal tanpa python3-apt → dipasang otomatis; layanan hanya di host systemd |
| 8 | Konfigurasi monitoring (promtool, compose config, YAML) | ✅ valid | — |
| 8b | Prometheus asli + aturan alert DeployHub | ✅ alert `TargetMati` terbaca di health check | Rumus disk beda dengan `df` (alert ±5% terlalu cepat) → disamakan |
| 9 | Skrip Python Fabric: health / deploy / backup | ✅ | `D:\python` di docstring = escape tidak valid; traceback membingungkan; **health dicek sebelum aplikasi siap → versi baik bisa di-rollback** → kini dicoba ulang ±60 dtk (juga di DeployHub) |
| 10 | File CI: actionlint + shellcheck + YAML | ✅ 0 masalah | Test template Flutter bikin CI selalu merah; build release gagal tanpa keystore → kini dilewati / pakai GitHub Secrets / APK debug |
| 10b | CD ke VPS lewat GitHub Actions: sukses / health gagal / build gagal | ✅ ketiganya benar | **Build gagal dilaporkan "sukses"** (`a && b` tidak memicu `set -e`) dan titik rollback rusak → diperbaiki |
| 11 | Siapkan project di server (clone, .env 600, run ulang → pull) | ✅ | — |
| 12 | Deploy key di server (idempoten) | ✅ | — |
| 13 | Caddyfile (caddy validate + fmt + reverse proxy jalan) | ✅ | indentasi → format resmi |
| 14 | Docker backend FastAPI: build, HEALTHCHECK, user non-root, port 127.0.0.1, hadolint | ✅ healthy | compose gagal kalau `.env` belum ada → `.env` opsional |
| 15 | Terraform DO/AWS/GCP + cloud-init (parser HCL & YAML) | ✅ valid | — |
| 16 | gh secret (nilai lewat stdin, tidak terlihat di daftar proses) | ✅ | — |
| 17 | 62 file Dart diparse (tree-sitter) | ✅ 0 error sintaks | — |

## Yang TIDAK bisa dites di sandbox (diblokir / butuh akun)
- **Compile Flutter/Dart** (SDK diblokir) → hanya cek sintaks. Jalankan `flutter pub get` + `flutter run -d windows`; kirim error kalau ada.
- Pull image Docker Hub (prometheus, grafana, caddy, mysql) → konfigurasi divalidasi dengan alat resminya, tidak dijalankan sebagai container.
- `terraform apply` ke cloud sungguhan, GitHub API (deploy key, secrets), Jenkins, Docker Desktop di Windows, panggilan AI, sertifikat HTTPS (butuh domain publik).
