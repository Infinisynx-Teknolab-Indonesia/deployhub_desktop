import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'integrations.dart';
import 'server_ops.dart';
import 'storage.dart';
import 'tool_env.dart';

/// Infrastructure as Code + provisioning + monitoring.
///
///  • Terraform: buat / ubah / hapus VPS di DigitalOcean, AWS EC2, Google Cloud (plan → setujui → apply)
///  • Ansible: playbook setup server (Docker, firewall, fail2ban, update otomatis, swap) — jalan lewat Docker
///  • Provision lewat SSH: langkah yang sama tanpa Ansible (bash)
///  • Monitoring: Prometheus + Grafana + Loki (log) + node-exporter + cAdvisor + aturan alert
///  • Runbook: dokumentasi infrastruktur (Markdown) dibuat otomatis
class InfraProject {
  InfraProject({required this.id, this.name = '', this.provider = 'digitalocean', this.region = '', this.size = '', this.gcpProject = '', this.sshUser = ''});
  final String id;
  String name, provider, region, size, gcpProject, sshUser;

  String get dir => p.join(Storage.dir.path, 'infra', id);

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'provider': provider, 'region': region, 'size': size, 'gcpProject': gcpProject, 'sshUser': sshUser};
  factory InfraProject.fromJson(Map<String, dynamic> j) => InfraProject(
        id: j['id'],
        name: j['name'] ?? '',
        provider: j['provider'] ?? 'digitalocean',
        region: j['region'] ?? '',
        size: j['size'] ?? '',
        gcpProject: j['gcpProject'] ?? '',
        sshUser: j['sshUser'] ?? '',
      );
}

/// Nilai bawaan per provider: (region, ukuran, user SSH, label).
const providerDefaults = <String, (String, String, String, String)>{
  'digitalocean': ('sgp1', 's-1vcpu-2gb', 'root', 'DigitalOcean (Droplet)'),
  'aws': ('ap-southeast-1', 't3.small', 'ubuntu', 'AWS (EC2)'),
  'gcp': ('asia-southeast2', 'e2-small', 'ubuntu', 'Google Cloud (Compute Engine)'),
};

class Infra {
  Infra._();
  static final Infra instance = Infra._();

  List<InfraProject> projects = [];

  static const kDoToken = 'infra_do_token';
  static const kAwsKey = 'infra_aws_key';
  static const kAwsSecret = 'infra_aws_secret';
  static const kGcpJson = 'infra_gcp_json_path';

  Future<void> load() async {
    final j = await Storage.readJson('infra.json');
    if (j is Map) projects = [for (final x in (j['projects'] as List? ?? const [])) InfraProject.fromJson(Map<String, dynamic>.from(x))];
  }

  Future<void> save() => Storage.writeJson('infra.json', {'projects': projects.map((e) => e.toJson()).toList()});

  // ───────────────────────── SSH key untuk server baru
  String get keyPath => p.join(Storage.dir.path, 'infra', 'id_ed25519');

  Future<String> ensureSshKey(void Function(String) log) async {
    if (await File(keyPath).exists()) return keyPath;
    await Directory(p.dirname(keyPath)).create(recursive: true);
    final r = await Process.run('ssh-keygen', ['-t', 'ed25519', '-N', '', '-C', 'deployhub', '-f', keyPath], environment: ToolEnv.env());
    if (r.exitCode != 0) throw Exception('ssh-keygen gagal: ${r.stderr}');
    log('🔑 SSH key baru: $keyPath (.pub dipasang ke server baru)');
    return keyPath;
  }

  // ───────────────────────── Terraform
  Future<void> writeTerraform(InfraProject x) async {
    final d = Directory(x.dir);
    await d.create(recursive: true);
    final key = await ensureSshKey((_) {});
    final main = switch (x.provider) { 'aws' => _tfAws, 'gcp' => _tfGcp, _ => _tfDo };
    final mainFile = File(p.join(d.path, 'main.tf'));
    if (!await mainFile.exists()) await mainFile.writeAsString(main); // jangan timpa hasil edit pengguna
    await File(p.join(d.path, 'cloud-init.yaml')).writeAsString(cloudInit(x.provider == 'digitalocean' ? 'root' : 'ubuntu'));
    final pub = '$key.pub'.replaceAll('\\', '/');
    await File(p.join(d.path, 'terraform.tfvars')).writeAsString([
      'name           = "${x.name}"',
      'region         = "${x.region}"',
      'size           = "${x.size}"',
      'ssh_public_key = "$pub"',
      if (x.provider == 'gcp') 'project        = "${x.gcpProject}"',
    ].join('\n'));
    await File(p.join(d.path, '.gitignore')).writeAsString('.terraform/\n*.tfstate\n*.tfstate.backup\n');
  }

  Future<Map<String, String>> _tfEnv(InfraProject x) async {
    final env = {...ToolEnv.env(), 'TF_IN_AUTOMATION': '1', 'TF_INPUT': '0'};
    switch (x.provider) {
      case 'digitalocean':
        env['DIGITALOCEAN_TOKEN'] = await Storage.secret(kDoToken);
      case 'aws':
        env['AWS_ACCESS_KEY_ID'] = await Storage.secret(kAwsKey);
        env['AWS_SECRET_ACCESS_KEY'] = await Storage.secret(kAwsSecret);
      case 'gcp':
        env['GOOGLE_APPLICATION_CREDENTIALS'] = await Storage.secret(kGcpJson);
    }
    return env;
  }

  /// Jalankan terraform <args> di folder proyek, output di-stream ke [log].
  Future<int> terraform(InfraProject x, List<String> args, void Function(String) log) async {
    if (!await ensureTool('terraform', log)) return 1; // belum ada → dipasang otomatis
    await writeTerraform(x);
    log('\$ terraform ${args.join(' ')}');
    // opsi harus sebelum argumen posisi (mis. file plan)
    final proc = await Process.start('terraform', [args.first, '-no-color', ...args.skip(1)],
        workingDirectory: x.dir, runInShell: true, environment: await _tfEnv(x));
    const dec = Utf8Decoder(allowMalformed: true);
    final a = proc.stdout.transform(dec).transform(const LineSplitter()).forEach(log);
    final b = proc.stderr.transform(dec).transform(const LineSplitter()).forEach(log);
    final code = await proc.exitCode;
    await Future.wait([a, b]);
    return code;
  }

  Future<int> plan(InfraProject x, void Function(String) log) async {
    if (!await Directory(p.join(x.dir, '.terraform')).exists()) {
      final c = await terraform(x, ['init', '-upgrade'], log);
      if (c != 0) return c;
    }
    return terraform(x, ['plan', '-out=tfplan'], log);
  }

  Future<int> apply(InfraProject x, void Function(String) log) => terraform(x, ['apply', 'tfplan'], log);

  Future<int> destroy(InfraProject x, void Function(String) log) => terraform(x, ['destroy', '-auto-approve'], log);

  /// IP server dari `terraform output`.
  Future<String?> outputIp(InfraProject x) async {
    final r = await Process.run('terraform', ['output', '-raw', 'ip'], workingDirectory: x.dir, runInShell: true, environment: await _tfEnv(x));
    final ip = '${r.stdout}'.trim();
    return r.exitCode == 0 && RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(ip) ? ip : null;
  }

  /// Daftarkan VPS hasil Terraform ke Server & infrastruktur (deploy, backup, monitoring).
  Future<ServerTarget> addAsServer(InfraProject x, String ip) async {
    final ops = ServerOps.instance;
    final existing = ops.servers.where((s) => s.host == ip).firstOrNull;
    if (existing != null) return existing;
    final s = ServerTarget(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: x.name,
      host: ip,
      user: x.sshUser.isEmpty ? providerDefaults[x.provider]!.$3 : x.sshUser,
      keyPath: keyPath,
      workdir: '/opt/${x.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}',
      healthOn: true,
      provider: x.provider,
    );
    ops.servers.add(s);
    ops.on = true;
    await ops.save();
    ops.restart();
    return s;
  }

  // ───────────────────────── Provision (setup server baru)
  /// Setup lewat SSH tanpa Ansible: Docker, firewall, fail2ban, update keamanan otomatis, swap, zona waktu.
  static const provisionScript = r'''set -e
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo -n"
export DEBIAN_FRONTEND=noninteractive
echo "== paket dasar =="
$SUDO apt-get update -q
$SUDO apt-get install -yq ca-certificates curl git ufw fail2ban unattended-upgrades htop python3
echo "== Docker =="
if ! command -v docker >/dev/null; then curl -fsSL https://get.docker.com | $SUDO sh; fi
$SUDO systemctl enable --now docker 2>/dev/null || $SUDO service docker start 2>/dev/null || true
[ "$(id -u)" -ne 0 ] && $SUDO usermod -aG docker "$USER" || true
echo "== firewall (22, 80, 443, 3000 Grafana) =="
$SUDO ufw allow OpenSSH; $SUDO ufw allow 80/tcp; $SUDO ufw allow 443/tcp; $SUDO ufw allow 3000/tcp
$SUDO ufw --force enable || echo "⚠ ufw tidak bisa diaktifkan (VPS tanpa iptables?) — pakai firewall dari panel cloud"
echo "== fail2ban (blokir brute-force SSH) =="
$SUDO systemctl enable --now fail2ban 2>/dev/null || $SUDO service fail2ban start 2>/dev/null || echo "⚠ fail2ban belum aktif"
echo "== update keamanan otomatis =="
echo 'APT::Periodic::Update-Package-Lists "1"; APT::Periodic::Unattended-Upgrade "1";' | $SUDO tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
echo "== swap 2 GB (kalau belum ada) =="
if ! swapon --show 2>/dev/null | grep -q .; then $SUDO fallocate -l 2G /swapfile && $SUDO chmod 600 /swapfile && $SUDO mkswap /swapfile && $SUDO swapon /swapfile && echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab || echo "⚠ swap tidak didukung di VPS ini"; fi
$SUDO timedatectl set-timezone Asia/Jakarta 2>/dev/null || $SUDO ln -sf /usr/share/zoneinfo/Asia/Jakarta /etc/localtime || true
mkdir -p ~/backups
echo "== selesai =="; docker --version; free -m | head -2; df -h / | tail -1''';

  Future<int> provisionSsh(ServerTarget s, void Function(String) log) => ServerOps.instance.exec(s, provisionScript, log, inWorkdir: false);

  /// Tulis inventory + playbook Ansible ke folder infra/ansible.
  Future<String> writeAnsible(List<ServerTarget> servers) async {
    final d = Directory(p.join(Storage.dir.path, 'infra', 'ansible'));
    await d.create(recursive: true);
    final inv = StringBuffer('[servers]\n');
    for (final s in servers) {
      final key = s.keyPath.isEmpty ? '' : ' ansible_ssh_private_key_file=/keys/${p.basename(s.keyPath)}';
      inv.writeln('${s.name.replaceAll(RegExp(r'\s+'), '_')} ansible_host=${s.host} ansible_port=${s.port} ansible_user=${s.user}$key');
    }
    inv.writeln('\n[servers:vars]\nansible_ssh_common_args=-o StrictHostKeyChecking=accept-new\nansible_python_interpreter=/usr/bin/python3');
    await File(p.join(d.path, 'inventory.ini')).writeAsString(inv.toString());
    await File(p.join(d.path, 'setup.yml')).writeAsString(_playbook);
    return d.path;
  }

  /// Jalankan playbook lewat Docker (Ansible tidak jalan langsung di Windows).
  Future<int> runAnsible(List<ServerTarget> servers, void Function(String) log, {bool check = false}) async {
    if (!await ensureTool('docker', log)) return 1; // Ansible jalan di container
    final dir = await writeAnsible(servers);
    final keyDirs = servers.where((s) => s.keyPath.isNotEmpty).map((s) => p.dirname(s.keyPath)).toSet();
    if (keyDirs.length > 1) log('⚠ Key SSH ada di beberapa folder — hanya ${keyDirs.first} yang dipasang ke container.');
    final pw = servers.length == 1 ? await Storage.secret(servers.first.secretKey) : '';
    final args = [
      'run', '--rm',
      '-v', '$dir:/work',
      if (keyDirs.isNotEmpty) ...['-v', '${keyDirs.first}:/keys:ro'],
      '-w', '/work',
      'alpine/ansible',
      'sh', '-c',
      // key di-copy dengan izin 600 (ssh menolak key yang terbuka dari mount Windows)
      'mkdir -p /tmp/k && cp /keys/* /tmp/k/ 2>/dev/null; chmod 600 /tmp/k/* 2>/dev/null; '
          "sed 's#/keys/#/tmp/k/#g' inventory.ini > /tmp/inventory.ini; "
          'ansible-playbook -i /tmp/inventory.ini setup.yml${check ? ' --check' : ''}${pw.isNotEmpty && servers.first.keyPath.isEmpty ? ' -e ansible_password=\$DH_PW -e ansible_become_password=\$DH_PW' : ''}',
    ];
    log('\$ docker run alpine/ansible ansible-playbook -i inventory.ini setup.yml${check ? ' --check' : ''}');
    final proc = await Process.start('docker', [if (pw.isNotEmpty) ...['run', '-e', 'DH_PW'] else 'run', ...args.sublist(1)],
        runInShell: true, environment: {...ToolEnv.env(), if (pw.isNotEmpty) 'DH_PW': pw});
    const dec = Utf8Decoder(allowMalformed: true);
    final a = proc.stdout.transform(dec).transform(const LineSplitter()).forEach(log);
    final b = proc.stderr.transform(dec).transform(const LineSplitter()).forEach(log);
    final code = await proc.exitCode;
    await Future.wait([a, b]);
    return code;
  }

  // ───────────────────────── Monitoring (Prometheus + Grafana + Loki)
  Future<String> installMonitoring(ServerTarget s, void Function(String) log) async {
    var pw = await Storage.secret('grafana_pw_${s.id}');
    if (pw.isEmpty) {
      final r = Random.secure();
      pw = List.generate(16, (_) => 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'[r.nextInt(56)]).join();
      await Storage.setSecret('grafana_pw_${s.id}', pw);
    }
    String file(String name, String content) => "cat > ~/monitoring/$name <<'DHEOF'\n$content\nDHEOF";
    final script = [
      'set -e',
      'mkdir -p ~/monitoring/grafana/provisioning/datasources',
      file('docker-compose.yml', _monCompose),
      file('prometheus.yml', _promConfig),
      file('alerts.yml', _promAlerts),
      file('promtail.yml', _promtail),
      file('grafana/provisioning/datasources/ds.yml', _grafanaDs),
      "printf 'GF_SECURITY_ADMIN_PASSWORD=%s\\n' '$pw' > ~/monitoring/.env && chmod 600 ~/monitoring/.env",
      'cd ~/monitoring && docker compose pull -q && docker compose up -d',
      'docker compose ps',
    ].join('\n');
    final code = await ServerOps.instance.exec(s, script, log, inWorkdir: false);
    if (code != 0) throw Exception('Gagal memasang monitoring (kode $code)');
    s.monitoringOn = true;
    await ServerOps.instance.save();
    return pw;
  }

  String grafanaUrl(ServerTarget s) => 'http://${s.host}:3000';

  // ───────────────────────── Runbook (dokumentasi)
  Future<String> writeRunbook() async {
    final ops = ServerOps.instance;
    final b = StringBuffer()
      ..writeln('# Runbook infrastruktur')
      ..writeln()
      ..writeln('Dibuat otomatis oleh DeployHub — ${DateTime.now().toString().substring(0, 16)}')
      ..writeln()
      ..writeln('## Ringkasan')
      ..writeln()
      ..writeln('| Server | Host | Folder | Deploy otomatis | Backup harian | Self-healing | Monitoring |')
      ..writeln('|---|---|---|---|---|---|---|');
    String y(bool v) => v ? '✅' : '—';
    for (final s in ops.servers) {
      b.writeln('| ${s.name} | `${s.user}@${s.host}:${s.port}` | `${s.workdir}` | ${y(s.autoDeploy)} | ${s.backupDaily ? '✅ jam ${s.backupHour}:00, simpan ${s.backupKeepDays} hari' : '—'} | ${y(s.selfHeal)} | ${s.monitoringOn ? '[Grafana](${grafanaUrl(s)})' : '—'} |');
    }
    for (final s in ops.servers) {
      b
        ..writeln()
        ..writeln('## ${s.name}')
        ..writeln()
        ..writeln('- Host: `${s.host}` (user `${s.user}`, port ${s.port})${s.provider.isEmpty ? '' : ' — dibuat dengan Terraform (${s.provider})'}')
        ..writeln('- Folder project: `${s.workdir}`, branch `${s.branch}`')
        ..writeln('- Health check: ${s.healthUrl.isEmpty ? '(SSH saja)' : s.healthUrl} tiap ${s.healthMinutes} menit')
        ..writeln()
        ..writeln('### Deploy')
        ..writeln('```bash')
        ..writeln('cd ${s.workdir}')
        ..writeln(s.deployCmd.replaceAll('{branch}', s.branch))
        ..writeln('```')
        ..writeln('Rollback: ${s.autoRollback ? 'otomatis ke commit sebelumnya kalau deploy / health check gagal' : 'manual'} — `git reset --hard <commit>` lalu ulangi perintah deploy.')
        ..writeln()
        ..writeln('### Backup & restore')
        ..writeln('```bash')
        ..writeln(s.backupCmd.isEmpty ? '# belum diatur' : s.backupCmd)
        ..writeln(s.restoreCmd.isEmpty ? '# restore belum diatur' : s.restoreCmd.replaceAll('{file}', '~/backups/<file>'))
        ..writeln('```')
        ..writeln()
        ..writeln('### Penanganan insiden')
        ..writeln('1. Cek: `docker ps -a`, `docker compose logs --tail 100`, `df -h /`, `free -m`.')
        ..writeln('2. Container mati → `docker compose up -d` (DeployHub melakukannya otomatis kalau self-healing aktif).')
        ..writeln('3. Disk penuh → `docker image prune -af && docker builder prune -af`.')
        ..writeln('4. Versi baru bermasalah → rollback ke commit sebelumnya.')
        ..writeln('5. Data rusak → restore backup terbaru (salinan juga ada di PC: DeployHub/backups/${s.name}).');
    }
    if (projects.isNotEmpty) {
      b
        ..writeln()
        ..writeln('## Infrastructure as Code (Terraform)')
        ..writeln();
      for (final x in projects) {
        b.writeln('- **${x.name}** — ${providerDefaults[x.provider]?.$4 ?? x.provider}, region `${x.region}`, ukuran `${x.size}` — folder `${x.dir}`');
      }
    }
    final f = File(p.join(Storage.dir.path, 'infra', 'RUNBOOK.md'));
    await f.parent.create(recursive: true);
    await f.writeAsString(b.toString());
    return f.path;
  }
}

// ═════════════════════════════════════════════ template
String cloudInit(String user) => '''#cloud-config
package_update: true
package_upgrade: true
packages: [ca-certificates, curl, git, ufw, fail2ban, unattended-upgrades, python3]
runcmd:
  - curl -fsSL https://get.docker.com | sh
  - systemctl enable --now docker
  - ${user == 'root' ? 'true' : 'usermod -aG docker $user'}
  - ufw allow OpenSSH
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - ufw allow 3000/tcp
  - ufw --force enable
  - systemctl enable --now fail2ban
  - timedatectl set-timezone Asia/Jakarta
  - mkdir -p /opt
''';

const _tfVars = r'''
variable "name" { type = string }
variable "region" { type = string }
variable "size" { type = string }
variable "ssh_public_key" { type = string }
''';

const _tfDo = r'''# DigitalOcean Droplet — token dari environment DIGITALOCEAN_TOKEN (diisi DeployHub)
terraform {
  required_providers {
    digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.0" }
  }
}
''' +
    _tfVars +
    r'''
provider "digitalocean" {}

resource "digitalocean_ssh_key" "key" {
  name       = "${var.name}-deployhub"
  public_key = file(var.ssh_public_key)
}

resource "digitalocean_droplet" "vm" {
  name      = var.name
  region    = var.region
  size      = var.size
  image     = "ubuntu-24-04-x64"
  ssh_keys  = [digitalocean_ssh_key.key.id]
  user_data = file("${path.module}/cloud-init.yaml")
  tags      = ["deployhub"]
}

resource "digitalocean_firewall" "fw" {
  name        = "${var.name}-fw"
  droplet_ids = [digitalocean_droplet.vm.id]
  dynamic "inbound_rule" {
    for_each = ["22", "80", "443", "3000"]
    content {
      protocol         = "tcp"
      port_range       = inbound_rule.value
      source_addresses = ["0.0.0.0/0", "::/0"]
    }
  }
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

output "ip" { value = digitalocean_droplet.vm.ipv4_address }
''';

const _tfAws = r'''# AWS EC2 — kredensial dari environment AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (diisi DeployHub)
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}
''' +
    _tfVars +
    r'''
provider "aws" { region = var.region }

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_key_pair" "key" {
  key_name   = "${var.name}-deployhub"
  public_key = file(var.ssh_public_key)
}

resource "aws_security_group" "sg" {
  name = "${var.name}-sg"
  dynamic "ingress" {
    for_each = [22, 80, 443, 3000]
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "vm" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.size
  key_name               = aws_key_pair.key.key_name
  vpc_security_group_ids = [aws_security_group.sg.id]
  user_data              = file("${path.module}/cloud-init.yaml")
  root_block_device { volume_size = 30 }
  tags = { Name = var.name, ManagedBy = "deployhub" }
}

resource "aws_eip" "ip" { instance = aws_instance.vm.id }

output "ip" { value = aws_eip.ip.public_ip }
''';

const _tfGcp = r'''# Google Cloud Compute Engine — kredensial dari GOOGLE_APPLICATION_CREDENTIALS (file JSON service account)
terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}
''' +
    _tfVars +
    r'''
variable "project" { type = string }

provider "google" {
  project = var.project
  region  = var.region
}

resource "google_compute_firewall" "web" {
  name          = "${var.name}-web"
  network       = "default"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.name}"]
  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443", "3000"]
  }
}

resource "google_compute_instance" "vm" {
  name         = var.name
  machine_type = var.size
  zone         = "${var.region}-a"
  tags         = ["${var.name}"]
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 30
    }
  }
  network_interface {
    network = "default"
    access_config {}
  }
  metadata = {
    ssh-keys  = "ubuntu:${file(var.ssh_public_key)}"
    user-data = file("${path.module}/cloud-init.yaml")
  }
  labels = { managed-by = "deployhub" }
}

output "ip" { value = google_compute_instance.vm.network_interface[0].access_config[0].nat_ip }
''';

const _playbook = r'''# Setup server — dibuat DeployHub. Jalankan: ansible-playbook -i inventory.ini setup.yml
- name: Setup server untuk deploy aplikasi (Docker, firewall, keamanan)
  hosts: servers
  become: true
  gather_facts: false
  vars:
    timezone: Asia/Jakarta
    open_ports: [80, 443, 3000]
  pre_tasks:
    - name: Python & python3-apt (image VPS minimal sering belum punya)
      ansible.builtin.raw: |
        command -v python3 >/dev/null && python3 -c 'import apt' 2>/dev/null || (apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -yq python3 python3-apt)
      changed_when: false

    - name: Kumpulkan info server
      ansible.builtin.setup:

  tasks:
    - name: Paket dasar
      ansible.builtin.apt:
        name: [ca-certificates, curl, git, ufw, fail2ban, unattended-upgrades, htop, python3]
        state: present
        update_cache: true

    - name: Cek Docker
      ansible.builtin.command: docker --version
      register: docker_check
      changed_when: false
      failed_when: false

    - name: Pasang Docker (skrip resmi)
      ansible.builtin.shell: curl -fsSL https://get.docker.com | sh
      when: docker_check.rc != 0

    - name: Docker aktif saat boot
      ansible.builtin.service:
        name: docker
        state: started
        enabled: true
      when: ansible_service_mgr == 'systemd'

    - name: User masuk grup docker
      ansible.builtin.user:
        name: "{{ ansible_user }}"
        groups: docker
        append: true
      when: ansible_user != 'root'

    - name: Firewall — izinkan SSH
      community.general.ufw:
        rule: allow
        name: OpenSSH

    - name: Firewall — port web & Grafana
      community.general.ufw:
        rule: allow
        port: "{{ item }}"
        proto: tcp
      loop: "{{ open_ports }}"

    - name: Firewall aktif
      community.general.ufw:
        state: enabled

    - name: fail2ban aktif (blokir brute-force SSH)
      ansible.builtin.service:
        name: fail2ban
        state: started
        enabled: true
      when: ansible_service_mgr == 'systemd'

    - name: Update keamanan otomatis
      ansible.builtin.copy:
        dest: /etc/apt/apt.conf.d/20auto-upgrades
        content: |
          APT::Periodic::Update-Package-Lists "1";
          APT::Periodic::Unattended-Upgrade "1";

    - name: Cek swap
      ansible.builtin.command: swapon --show
      register: swap
      changed_when: false

    - name: Buat swap 2 GB
      ansible.builtin.shell: |
        fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
      when: swap.stdout == ""

    - name: Zona waktu
      community.general.timezone:
        name: "{{ timezone }}"

    - name: Folder backup
      ansible.builtin.file:
        path: "~{{ ansible_user }}/backups"
        state: directory
      become: false
''';

const _monCompose = r'''# Monitoring — dibuat DeployHub. Grafana: http://<ip>:3000 (admin / password di .env)
services:
  prometheus:
    image: prom/prometheus:latest
    restart: unless-stopped
    command: ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.retention.time=15d"]
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./alerts.yml:/etc/prometheus/alerts.yml:ro
      - prometheus:/prometheus
    ports: ["127.0.0.1:9090:9090"]
  node-exporter:
    image: prom/node-exporter:latest
    restart: unless-stopped
    pid: host
    command: ["--path.rootfs=/host"]
    volumes: ["/:/host:ro,rslave"]
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    restart: unless-stopped
    privileged: true
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
  loki:
    image: grafana/loki:latest
    restart: unless-stopped
    command: ["-config.file=/etc/loki/local-config.yaml"]
    volumes: [loki:/loki]
  promtail:
    image: grafana/promtail:latest
    restart: unless-stopped
    command: ["-config.file=/etc/promtail/promtail.yml"]
    volumes:
      - ./promtail.yml:/etc/promtail/promtail.yml:ro
      - /var/log:/var/log:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
  grafana:
    image: grafana/grafana:latest
    restart: unless-stopped
    env_file: .env
    environment:
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    ports: ["3000:3000"]
volumes:
  prometheus: {}
  loki: {}
  grafana: {}''';

const _promConfig = r'''global:
  scrape_interval: 30s
  evaluation_interval: 30s
rule_files: [/etc/prometheus/alerts.yml]
scrape_configs:
  - job_name: prometheus
    static_configs: [{targets: ["localhost:9090"]}]
  - job_name: node
    static_configs: [{targets: ["node-exporter:9100"]}]
  - job_name: cadvisor
    static_configs: [{targets: ["cadvisor:8080"]}]''';

const _promAlerts = r'''groups:
  - name: deployhub
    rules:
      - alert: TargetMati
        expr: up == 0
        for: 2m
      - alert: DiskHampirPenuh
        # sama dengan "Use%" di df: terpakai / (terpakai + sisa untuk user)
        expr: (node_filesystem_size_bytes{mountpoint="/"} - node_filesystem_free_bytes{mountpoint="/"}) / (node_filesystem_size_bytes{mountpoint="/"} - node_filesystem_free_bytes{mountpoint="/"} + node_filesystem_avail_bytes{mountpoint="/"}) > 0.9
        for: 5m
      - alert: RamTinggi
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.92
        for: 10m
      - alert: CpuTinggi
        expr: 100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
        for: 15m
      - alert: ContainerRestartTerus
        expr: changes(container_start_time_seconds{name!=""}[15m]) > 3
        for: 1m''';

const _promtail = r'''server: {http_listen_port: 9080, grpc_listen_port: 0}
positions: {filename: /tmp/positions.yaml}
clients: [{url: "http://loki:3100/loki/api/v1/push"}]
scrape_configs:
  - job_name: docker
    docker_sd_configs: [{host: "unix:///var/run/docker.sock", refresh_interval: 15s}]
    relabel_configs:
      - source_labels: ["__meta_docker_container_name"]
        regex: "/(.*)"
        target_label: container
  - job_name: system
    static_configs:
      - targets: [localhost]
        labels: {job: varlogs, __path__: /var/log/*log}''';

const _grafanaDs = r'''apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100''';
