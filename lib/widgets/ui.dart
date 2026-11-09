import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../core/i18n.dart';
import '../theme/dh_theme.dart';

// Komponen tampilan bersama — gaya sama dengan Arsip Dokumen PU.

class Reveal extends StatefulWidget {
  final Widget child;
  final int index;
  final Offset offset;
  const Reveal({super.key, required this.child, this.index = 0, this.offset = const Offset(0, 0.06)});

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  late final Animation<double> _a = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (reduceMotion(context)) {
      _c.value = 1;
      return;
    }
    final delay = Duration(milliseconds: 40 * math.min(widget.index, 10));
    Future.delayed(delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _a,
        child: SlideTransition(position: Tween(begin: widget.offset, end: Offset.zero).animate(_a), child: widget.child),
      );
}

class CountUp extends StatelessWidget {
  final num value;
  final TextStyle style;
  final String Function(num v)? format;
  const CountUp({super.key, required this.value, required this.style, this.format});

  static String dots(num v) {
    final s = v.round().abs().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
      b.write(s[i]);
    }
    return '${v < 0 ? '-' : ''}$b';
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.toDouble()),
      duration: motion(context, const Duration(milliseconds: 900)),
      curve: Curves.easeOutCubic,
      builder: (_, v, __) => Text((format ?? dots)(v), style: style),
    );
  }
}

class HoverCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final double radius;

  /// Latar gradasi (mis. kartu "perlu ditinjau": from-tertiary-fixed/20 via-transparent).
  final Gradient? gradient;

  /// Warna latar saat disorot (versi web: hover:bg-surface-container).
  final Color? hoverColor;

  /// Bayangan khusus (null = shadow-sm / hover:shadow-md).
  final List<BoxShadow>? baseShadowOverride;
  final List<BoxShadow>? hoverShadowOverride;
  const HoverCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.borderColor,
    this.radius = 12,
    this.gradient,
    this.hoverColor,
    this.baseShadowOverride,
    this.hoverShadowOverride,
  });

  @override
  State<HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<HoverCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: w.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: w.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: motion(context, const Duration(milliseconds: 200)),
          curve: kMotionCurve,
          transform: Matrix4.translationValues(0, _hover && w.onTap != null && !reduceMotion(context) ? -1 : 0, 0),
          padding: w.padding,
          decoration: BoxDecoration(
            color: _hover && w.hoverColor != null ? w.hoverColor : (w.color ?? YmColors.surface),
            gradient: w.gradient,
            borderRadius: BorderRadius.circular(w.radius),
            border: w.borderColor != null
                ? Border.all(color: w.borderColor!)
                : (YmColors.isDark ? Border.all(color: _hover ? YmColors.primary.withOpacity(0.5) : YmColors.line) : null),
            boxShadow: _hover ? (w.hoverShadowOverride ?? hoverShadow) : (w.baseShadowOverride ?? softShadow),
          ),
          child: Material(type: MaterialType.transparency, child: w.child),
        ),
      ),
    );
  }
}

class SoftChip extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color? fg;
  final Color? bg;
  final bool pill;
  final bool bold;

  /// Titik bulat kecil di depan teks (versi web: w-1.5 h-1.5 rounded-full).
  final Color? dot;
  const SoftChip(this.text, {super.key, this.icon, this.fg, this.bg, this.pill = false, this.bold = false, this.dot});

  /// Chip status hijau / biru / oranye / merah (warna persis versi web).
  factory SoftChip.success(String t, {IconData? icon, Color? dot}) =>
      SoftChip(t, icon: icon, dot: dot, fg: YmColors.onSuccessSoft, bg: YmColors.successContainer.withOpacity(0.5), pill: true, bold: true);
  factory SoftChip.successStrong(String t, {IconData? icon, Color? dot}) =>
      SoftChip(t, icon: icon, dot: dot, fg: YmColors.onSuccessContainer, bg: YmColors.successContainer, pill: true, bold: true);
  factory SoftChip.primary(String t, {IconData? icon, Color? dot}) =>
      SoftChip(t, icon: icon, dot: dot, fg: YmColors.onPrimaryFixed, bg: YmColors.primaryFixed, pill: true, bold: true);
  factory SoftChip.warning(String t, {IconData? icon, Color? dot}) =>
      SoftChip(t, icon: icon, dot: dot, fg: YmColors.onWarningSoft, bg: YmColors.warningSoft, pill: true, bold: true);
  factory SoftChip.danger(String t, {IconData? icon, Color? dot}) =>
      SoftChip(t, icon: icon, dot: dot, fg: YmColors.onDangerSoft, bg: YmColors.dangerSoft, pill: true, bold: true);
  factory SoftChip.neutral(String t, {IconData? icon}) => SoftChip(t, icon: icon, fg: YmColors.textMuted, bg: YmColors.surfaceContainerHigh, pill: true);

  @override
  Widget build(BuildContext context) {
    final f = fg ?? YmColors.textMuted;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: pill ? 10 : 8, vertical: 2),
      decoration: BoxDecoration(color: bg ?? YmColors.surfaceContainer, borderRadius: BorderRadius.circular(pill ? 999 : 6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[Container(width: 6, height: 6, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)), const SizedBox(width: 6)],
          if (icon != null) ...[Icon(icon, size: 14, color: f), const SizedBox(width: 4)],
          Flexible(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: YmTextStyles.labelSm.copyWith(color: f, fontWeight: bold ? FontWeight.w600 : FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

class PageHeader extends StatelessWidget {
  final List<String> crumbs;
  final String title;
  final String? subtitle;
  final Widget? badge;
  final List<Widget> actions;
  final IconData? overlineIcon;
  final String? overline;

  /// true = pemisah jejak berupa ikon › (versi web halaman kategori).
  final bool chevrons;

  const PageHeader({
    super.key,
    this.crumbs = const [],
    required this.title,
    this.subtitle,
    this.badge,
    this.actions = const [],
    this.overline,
    this.overlineIcon,
    this.chevrons = false,
  });

  @override
  Widget build(BuildContext context) {
    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (crumbs.isNotEmpty || badge != null)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              for (var i = 0; i < crumbs.length; i++) ...[
                if (i > 0)
                  chevrons
                      ? Icon(Icons.chevron_right_rounded, size: 16, color: YmColors.outlineVariant)
                      : Text('/', style: YmTextStyles.labelSm.copyWith(color: YmColors.outlineVariant)),
                Text(
                  crumbs[i],
                  style: YmTextStyles.labelMd.copyWith(
                    color: i == crumbs.length - 1 ? YmColors.textDark : (chevrons ? YmColors.textMuted : YmColors.outline),
                    fontWeight: i == crumbs.length - 1 ? (chevrons ? FontWeight.w600 : FontWeight.w500) : FontWeight.w500,
                  ),
                ),
              ],
              if (badge != null) badge!,
            ],
          ),
        if (overline != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(overlineIcon ?? Icons.verified_outlined, size: 18, color: YmColors.primary),
              const SizedBox(width: 4),
              Text(overline!.toUpperCase(), style: YmTextStyles.labelSm.copyWith(color: YmColors.primary, letterSpacing: 0.55)),
            ]),
          ),
        Padding(
          padding: EdgeInsets.only(top: crumbs.isNotEmpty ? 4 : 0),
          child: Text(title, style: YmTextStyles.display),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 768),
            child: Text(subtitle!, style: YmTextStyles.bodyMd),
          ),
        ],
      ],
    );
    if (actions.isEmpty) return left;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: left),
        const SizedBox(width: 16),
        Flexible(
          child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8, children: actions),
        ),
      ],
    );
  }
}

class ProgressBar extends StatelessWidget {
  final double value; // 0..1
  final Color? color;
  final double height;
  const ProgressBar({super.key, required this.value, this.color, this.height = 6});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: Container(
        height: height,
        color: YmColors.surfaceContainerHigh,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: value.clamp(0.0, 1.0).toDouble()),
          duration: motion(context, const Duration(milliseconds: 900)),
          curve: Curves.easeOutCubic,
          builder: (_, v, __) => FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: v,
            child: Container(decoration: BoxDecoration(color: color ?? YmColors.primary, borderRadius: BorderRadius.circular(height))),
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Reveal(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(20)),
                child: Icon(icon, size: 30, color: YmColors.primary),
              ),
              const SizedBox(height: 16),
              Text(title, textAlign: TextAlign.center, style: YmTextStyles.sectionTitle),
              const SizedBox(height: 6),
              SizedBox(width: 420, child: Text(message, textAlign: TextAlign.center, style: YmTextStyles.label.copyWith(fontSize: 13, height: 1.55))),
              if (action != null) ...[const SizedBox(height: 18), action!],
            ],
          ),
        ),
      ),
    );
  }
}

class PageBody extends StatelessWidget {
  final Widget child;
  final bool scroll;
  final double maxWidth;
  const PageBody({super.key, required this.child, this.scroll = true, this.maxWidth = double.infinity});

  @override
  Widget build(BuildContext context) {
    const pad = EdgeInsets.all(24);
    final inner = maxWidth == double.infinity
        ? child
        : Align(alignment: Alignment.topLeft, child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child));
    return scroll ? SingleChildScrollView(padding: pad, child: inner) : Padding(padding: pad, child: inner);
  }
}

enum ChipTone { normal, warning, success, danger }

class QuickChip extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final ChipTone tone;
  const QuickChip({super.key, required this.label, required this.selected, required this.onTap, this.icon, this.tone = ChipTone.normal});

  @override
  State<QuickChip> createState() => _QuickChipState();
}

class _QuickChipState extends State<QuickChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final (Color bg, Color fg, Color iconColor) = w.selected
        ? (YmColors.primary, YmColors.onPrimary, YmColors.onPrimary)
        : switch (w.tone) {
            ChipTone.warning => (YmColors.warningSoft, YmColors.onWarningSoft, YmColors.warning),
            ChipTone.success => (YmColors.successContainer.withOpacity(0.4), YmColors.onSuccessSoft, YmColors.success),
            ChipTone.danger => (YmColors.dangerSoft, YmColors.onDangerSoft, YmColors.danger),
            ChipTone.normal => (_hover ? YmColors.surfaceContainer : YmColors.surfaceAlt, YmColors.textMuted, YmColors.textMuted),
          };
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: w.onTap,
        child: AnimatedContainer(
          duration: motion(context, const Duration(milliseconds: 150)),
          curve: kMotionCurve,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999), boxShadow: w.selected ? shadowSm : null),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (w.tone == ChipTone.success && !w.selected) ...[
              Container(width: 8, height: 8, decoration: BoxDecoration(color: YmColors.success, shape: BoxShape.circle)),
              const SizedBox(width: 6),
            ],
            if (w.icon != null) ...[Icon(w.icon, size: 15, color: iconColor), const SizedBox(width: 6)],
            Text(w.label, style: YmTextStyles.labelMd.copyWith(color: fg)),
          ]),
        ),
      ),
    );
  }
}

class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final String? title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final Widget? titleBadge;

  /// Warna ubin ikon judul (mis. merah muda untuk "perlu tindakan").
  final Color? iconBg;
  final Color? iconFg;

  /// true = panel mengisi tinggi yang tersedia (child boleh ListView/Expanded).
  final bool expand;

  /// Warna latar lain (mis. kartu peringatan).
  final Color? color;
  final double radius;

  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.titleBadge,
    this.iconBg,
    this.iconFg,
    this.expand = false,
    this.color,
    this.radius = 12,
  });

  @override
  Widget build(BuildContext context) {
    // Panel tanpa padding (isi daftar menempel tepi): judul tetap diberi jarak 24.
    final pad = padding.resolve(TextDirection.ltr);
    final headPad = pad.left < 12 ? EdgeInsets.fromLTRB(24 - pad.left, (20 - pad.top).clamp(0, 20).toDouble(), 24 - pad.right, 16) : const EdgeInsets.only(bottom: 16);
    final head = title == null
        ? null
        : Padding(
            padding: headPad,
            child: Row(
              children: [
                if (icon != null) ...[
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: iconBg ?? YmColors.surfaceContainer, borderRadius: BorderRadius.circular(8)),
                    child: Icon(icon, size: 20, color: iconFg ?? YmColors.primary),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Flexible(child: Text(title!, maxLines: 1, overflow: TextOverflow.ellipsis, style: YmTextStyles.headlineMd)),
                        if (titleBadge != null) ...[const SizedBox(width: 8), titleBadge!],
                      ]),
                      if (subtitle != null) Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: YmTextStyles.bodySm),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              ],
            ),
          );
    final body = Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: padding,
        child: head == null
            ? child
            : Column(
                mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [head, if (expand) Expanded(child: child) else child],
              ),
      ),
    );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color ?? YmColors.surface,
        borderRadius: BorderRadius.circular(radius),
        border: YmColors.isDark ? Border.all(color: YmColors.line) : null,
        boxShadow: shadowSm,
      ),
      child: body,
    );
  }
}

InputDecoration fieldDecoration(String label, {IconData? icon, String? hint, Widget? suffix}) => InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      prefixIcon: icon == null ? null : Icon(icon, size: 18, color: YmColors.outline),
      suffixIcon: suffix,
      filled: true,
      fillColor: YmColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: TextStyle(color: YmColors.textMuted, fontSize: 13),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: YmColors.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: YmColors.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: YmColors.primary, width: 1.6)),
    );

InputDecoration searchDecoration(String hint, {Widget? suffix}) => InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: YmColors.surfaceAlt,
      hoverColor: Colors.transparent,
      prefixIcon: Padding(padding: const EdgeInsets.only(left: 14, right: 8), child: Icon(Icons.search_rounded, size: 20, color: YmColors.outline)),
      prefixIconConstraints: const BoxConstraints(minWidth: 44),
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
      hintStyle: TextStyle(fontFamily: kFont, color: YmColors.outline, fontSize: 14, height: 22 / 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: YmColors.primary.withOpacity(0.2), width: 2)),
    );

ButtonStyle primaryButtonStyle({Color? color}) {
  final c = color ?? YmColors.primary;
  final isPrimary = color == null || color == YmColors.primary;
  final fg = isPrimary ? YmColors.onPrimary : Colors.white;
  return ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith((s) {
      if (s.contains(WidgetState.disabled)) return YmColors.surfaceContainer;
      if (s.contains(WidgetState.hovered)) return isPrimary ? YmColors.primaryContainer : Color.lerp(c, Colors.white, 0.12);
      return c;
    }),
    foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? YmColors.outline : fg),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? 0 : (s.contains(WidgetState.hovered) ? 4 : 2)),
    shadowColor: WidgetStatePropertyAll(c.withOpacity(0.45)),
    minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: kFont, fontWeight: FontWeight.w500, fontSize: 14, height: 20 / 14)),
    iconSize: const WidgetStatePropertyAll(18),
    animationDuration: const Duration(milliseconds: 150),
  );
}

ButtonStyle outlineButtonStyle() => ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? YmColors.surfaceContainer : YmColors.surface),
      foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? YmColors.outline : YmColors.textDark),
      iconColor: WidgetStatePropertyAll(YmColors.outline),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      side: WidgetStatePropertyAll(YmColors.isDark ? BorderSide(color: YmColors.line) : BorderSide.none),
      elevation: const WidgetStatePropertyAll(1),
      shadowColor: const WidgetStatePropertyAll(Color(0x33000000)),
      minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: kFont, fontWeight: FontWeight.w500, fontSize: 14, height: 20 / 14)),
      iconSize: const WidgetStatePropertyAll(18),
    );

ButtonStyle softButtonStyle({Color? fg, Color? bg, Color? hover}) => ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered) ? (hover ?? (bg == null ? YmColors.surfaceContainer : Color.lerp(bg, Colors.white, 0.12))) : (bg ?? YmColors.surfaceAlt)),
      foregroundColor: WidgetStatePropertyAll(fg ?? YmColors.textDark),
      iconColor: WidgetStatePropertyAll(fg ?? YmColors.textDark),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: kFont, fontWeight: FontWeight.w600, fontSize: 11, height: 14 / 11, letterSpacing: 0.22)),
      iconSize: const WidgetStatePropertyAll(16),
    );

void showSnack(BuildContext context, String text, {bool error = false}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Row(children: [
      Icon(error ? Icons.error_outline_rounded : Icons.check_circle_rounded, color: error ? const Color(0xFFFFB4AB) : const Color(0xFF82F5C1), size: 20),
      const SizedBox(width: 12),
      Expanded(child: Text(text, style: const TextStyle(fontFamily: kFont, color: Colors.white, fontSize: 13, height: 1.4))),
    ]),
    backgroundColor: error ? const Color(0xFF7A1F1A) : const Color(0xFF213145),
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    width: 560,
    duration: Duration(seconds: error ? 6 : 3),
  ));
}

Future<bool> confirmDialog(BuildContext context, {required String title, required String message, String? ok, bool danger = false}) async {
  final r = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: tr('Tutup'),
    barrierColor: const Color(0x590B1C30),
    transitionDuration: motion(context, const Duration(milliseconds: 220)),
    transitionBuilder: (c, a, _, child) {
      final curved = CurvedAnimation(parent: a, curve: Curves.easeOutBack, reverseCurve: Curves.easeInCubic);
      return FadeTransition(opacity: a, child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(curved), child: child));
    },
    pageBuilder: (c, _, __) => AlertDialog(
      icon: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: danger ? YmColors.dangerSoft : YmColors.primarySoft, borderRadius: BorderRadius.circular(12)),
        child: Icon(danger ? Icons.warning_amber_rounded : Icons.help_outline_rounded, color: danger ? YmColors.danger : YmColors.primary),
      ),
      title: Text(title),
      content: SizedBox(width: 420, child: Text(message, textAlign: TextAlign.center, style: YmTextStyles.chatText.copyWith(color: YmColors.textMuted))),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        OutlinedButton(style: outlineButtonStyle(), onPressed: () => Navigator.pop(c, false), child: Text(tr('Batal'))),
        ElevatedButton(
          style: primaryButtonStyle(color: danger ? YmColors.danger : null),
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok ?? tr('Ya')),
        ),
      ],
    ),
  );
  return r ?? false;
}

class PulseDot extends StatefulWidget {
  final Color color;
  final bool pulse;
  final double size;
  const PulseDot({super.key, required this.color, this.pulse = true, this.size = 8});

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant PulseDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.pulse && !reduceMotion(context)) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s * 2,
      height: s * 2,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final t = Curves.easeOut.transform(_c.value);
          return Stack(alignment: Alignment.center, children: [
            if (widget.pulse)
              // animate-ping: membesar sampai 2x sambil memudar dari 75%
              Container(
                width: s * (1 + t),
                height: s * (1 + t),
                decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color.withOpacity(0.75 * (1 - t))),
              ),
            Container(width: s, height: s, decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color)),
          ]);
        },
      ),
    );
  }
}


class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final num? number; // kalau diisi, angka menghitung naik
  final String? unit;
  final Color? unitColor;
  final IconData icon;
  final Color color; // warna ikon
  final Color? tileBg; // latar ubin ikon (bawaan: surface-container)
  final Color? numberColor;
  final String? sub;
  final Widget? chip;
  final Widget? footer;
  final VoidCallback? onTap;

  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.number,
    this.unit,
    this.unitColor,
    this.tileBg,
    this.numberColor,
    this.sub,
    this.chip,
    this.footer,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final numStyle = YmTextStyles.display.copyWith(color: numberColor ?? YmColors.textDark);
    return HoverCard(
      onTap: onTap,
      padding: const EdgeInsets.all(24),
      radius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: tileBg ?? YmColors.surfaceContainer, borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: color, size: 22),
              ),
              const Spacer(),
              if (chip != null) chip!,
            ],
          ),
          const SizedBox(height: 16),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: YmTextStyles.labelMd.copyWith(color: YmColors.textMuted)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              if (number != null) CountUp(value: number!, style: numStyle) else Flexible(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: numStyle)),
              if (unit != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(unit!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: YmTextStyles.labelSm.copyWith(color: unitColor ?? YmColors.outline, fontWeight: unitColor == null ? FontWeight.w600 : FontWeight.w600)),
                ),
              ],
            ],
          ),
          if (sub != null) ...[
            const SizedBox(height: 8),
            Text(sub!, style: YmTextStyles.bodySm, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          if (footer != null) ...[const SizedBox(height: 24), footer!],
        ],
      ),
    );
  }
}

class FilterDropdown<T> extends StatelessWidget {
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final double width;
  final IconData? icon;
  final double height;

  const FilterDropdown({super.key, required this.value, required this.items, required this.onChanged, this.width = 200, this.icon, this.height = 44});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.only(left: 12, right: 8),
      decoration: BoxDecoration(color: YmColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          if (icon != null) ...[Icon(icon, size: 16, color: YmColors.outline), const SizedBox(width: 6)],
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                items: items,
                onChanged: onChanged,
                isExpanded: true,
                focusColor: Colors.transparent,
                dropdownColor: YmColors.surface,
                style: YmTextStyles.labelMd,
                icon: Icon(Icons.expand_more_rounded, size: 16, color: YmColors.outline),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
