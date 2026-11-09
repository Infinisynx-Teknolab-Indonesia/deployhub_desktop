import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../services/pipeline.dart';
import '../theme/dh_theme.dart';
import 'ui.dart';

/// Navigasi antar halaman (sidebar).
final nav = ValueNotifier<String>('dashboard');

/// Logo DeployHub: ubin warna utama + ikon roket (gaya ArsipLogo).
/// Nama aplikasi yang bisa diganti di Pengaturan.
String get appName => ThemeCtl.instance.appName;

/// Teks kecil di bawah nama aplikasi.
String get appTagline => ThemeCtl.instance.tagline.isEmpty ? tr('CI/CD aplikasi Flutter') : ThemeCtl.instance.tagline;

class DhLogo extends StatelessWidget {
  const DhLogo({super.key, this.size = 36});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: YmColors.primaryContainer,
          borderRadius: BorderRadius.circular(size * 0.33),
          boxShadow: shadowSm,
        ),
        child: Icon(Icons.rocket_launch_rounded, color: Colors.white, size: size * 0.55),
      );
}

Color statusColor(String status) => switch (status) {
      'success' => YmColors.success,
      'failed' => YmColors.danger,
      'cancelled' => YmColors.warning,
      _ => YmColors.primary,
    };

IconData statusIcon(String status) => switch (status) {
      'success' => Icons.check_circle_rounded,
      'failed' => Icons.cancel_rounded,
      'cancelled' => Icons.stop_circle_rounded,
      _ => Icons.pending_rounded,
    };

Widget statusChip(String status) => switch (status) {
      'success' => SoftChip.success(tr('Sukses'), icon: Icons.check_rounded),
      'failed' => SoftChip.danger(tr('Gagal'), icon: Icons.close_rounded),
      'cancelled' => SoftChip.warning(tr('Dibatalkan'), icon: Icons.stop_rounded),
      _ => SoftChip.primary(tr('Berjalan'), dot: YmColors.primary),
    };

Widget stepIcon(StepStatus s) => switch (s) {
      StepStatus.pending => Icon(Icons.radio_button_unchecked_rounded, size: 18, color: YmColors.outlineVariant),
      StepStatus.running => SizedBox(
          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: YmColors.primary)),
      StepStatus.success => Icon(Icons.check_circle_rounded, size: 18, color: YmColors.success),
      StepStatus.failed => Icon(Icons.cancel_rounded, size: 18, color: YmColors.danger),
      StepStatus.skipped => Icon(Icons.remove_circle_outline_rounded, size: 18, color: YmColors.outlineVariant),
    };

/// Kolom isian bergaya Arsip PU.
class DhField extends StatelessWidget {
  const DhField(this.controller, this.label,
      {super.key, this.hint, this.icon, this.suffix, this.obscure = false, this.maxLines = 1, this.onChanged, this.keyboard});
  final TextEditingController controller;
  final String label;
  final String? hint;
  final IconData? icon;
  final Widget? suffix;
  final bool obscure;
  final int? maxLines;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboard;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          obscureText: obscure,
          maxLines: obscure ? 1 : maxLines,
          onChanged: onChanged,
          keyboardType: keyboard,
          style: YmTextStyles.chatText.copyWith(fontSize: 13.5),
          decoration: fieldDecoration(label, icon: icon, hint: hint, suffix: suffix),
        ),
      );
}

/// Baris dua kolom isian.
Widget fieldRow(List<Widget> children, {List<int>? flex}) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(flex: flex == null ? 1 : flex[i], child: children[i]),
        ],
      ],
    );

/// Judul kecil kelompok (huruf kapital, renggang) — seperti judul bagian sidebar.
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
        child: Text(text.toUpperCase(), style: YmTextStyles.labelSm.copyWith(color: YmColors.outline, letterSpacing: 0.55)),
      );
}

/// Baris setelan: judul + keterangan di kiri, kontrol di kanan.
class SettingRow extends StatelessWidget {
  const SettingRow({super.key, required this.title, this.subtitle, required this.trailing});
  final String title;
  final String? subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: YmTextStyles.username.copyWith(fontSize: 14)),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(subtitle!, style: YmTextStyles.label.copyWith(fontSize: 12.5, height: 1.5)),
              ],
            ]),
          ),
          const SizedBox(width: 20),
          trailing,
        ]),
      );
}

/// Kotak dialog bergaya Arsip PU: ubin ikon + judul + isi bergulir + tombol.
class DhDialog extends StatelessWidget {
  const DhDialog({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.actions = const [],
    this.width = 640,
    this.height,
    this.subtitle,
    this.headerTrailing,
  });
  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget child;
  final List<Widget> actions;
  final double width;
  final double? height;
  final Widget? headerTrailing;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: height ?? 760),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 16, 14),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: YmColors.primarySoft, borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: YmColors.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: YmTextStyles.headlineMd, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (subtitle != null) Text(subtitle!, style: YmTextStyles.bodySm, maxLines: 2),
                ]),
              ),
              if (headerTrailing != null) headerTrailing!,
              IconButton(
                tooltip: tr('Tutup'),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ]),
          ),
          Divider(height: 1, color: YmColors.line),
          Flexible(
            child: height == null
                ? SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 18, 24, 8), child: child)
                : Padding(padding: const EdgeInsets.fromLTRB(24, 18, 24, 8), child: child),
          ),
          if (actions.isNotEmpty) ...[
            Divider(height: 1, color: YmColors.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
              child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Bagian di dalam dialog: judul kecil berikon + isi.
class DialogSection extends StatelessWidget {
  const DialogSection({super.key, required this.title, required this.icon, required this.children, this.subtitle});
  final String title;
  final String? subtitle;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, size: 18, color: YmColors.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w600))),
          ]),
          if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(subtitle!, style: YmTextStyles.bodySm)),
          const SizedBox(height: 12),
          ...children,
        ]),
      );
}

/// Checkbox baris (gaya daftar Arsip PU).
class CheckRow extends StatelessWidget {
  const CheckRow({super.key, required this.label, required this.value, required this.onChanged, this.sub, this.enabled = true});
  final String label;
  final String? sub;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? () => onChanged(!value) : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Checkbox(value: enabled && value, onChanged: enabled ? (v) => onChanged(v ?? false) : null),
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: YmTextStyles.labelLg),
                    if (sub != null) Text(sub!, style: YmTextStyles.bodySm),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      );
}

/// Banner "Google Play belum terhubung" dengan tombol ke Pengaturan.
/// [ready] = hasil PlayAuth.globalReady() (dihitung di pemanggil).
class PlayConnectBanner extends StatelessWidget {
  const PlayConnectBanner({super.key, required this.ready});
  final Future<bool> ready;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: ready,
      builder: (context, snap) {
        if (snap.data != false) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(bottom: 18),
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          decoration: BoxDecoration(color: YmColors.warningSoft, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Icon(Icons.link_off_rounded, color: YmColors.onWarningSoft),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Google Play belum terhubung'),
                    style: YmTextStyles.labelLg.copyWith(fontWeight: FontWeight.w700, color: YmColors.onWarningSoft)),
                Text(tr('Login dulu supaya DeployHub bisa upload AAB dan mengatur listing di Play Console.'),
                    style: YmTextStyles.bodySm.copyWith(color: YmColors.onWarningSoft)),
              ]),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              style: primaryButtonStyle(),
              onPressed: () => nav.value = 'settings',
              icon: const Icon(Icons.login_rounded),
              label: Text(tr('Login ke Google Play')),
            ),
          ]),
        );
      },
    );
  }
}

/// Kotak kode (perintah / isi file) dengan tombol salin.
class CodeBox extends StatelessWidget {
  const CodeBox(this.code, {super.key, this.label});
  final String code;
  final String? label;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(color: const Color(0xFF0A0F1A), borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(children: [
              Text(label ?? '', style: const TextStyle(fontFamily: kFont, color: Color(0xFF8B95A7), fontSize: 11.5)),
              const Spacer(),
              IconButton(
                tooltip: tr('Salin'),
                icon: const Icon(Icons.copy_rounded, size: 16, color: Color(0xFFB8C0CC)),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  showSnack(context, tr('Disalin'));
                },
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: SelectableText(code,
                style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: ['Menlo', 'monospace'], fontSize: 12.5, height: 1.5, color: Color(0xFFD7DCE3))),
          ),
        ]),
      );
}
