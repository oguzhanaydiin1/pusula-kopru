import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// OA Labs tasarım sistemi, oalabs.dev site.css ile birebir. Koyu ve açık tema (açık: aynı tonların
/// krem zeminli hâli, Terazi ve OA Radyo ile aynı). [koyu] uygulama açılırken ve tema değişince ayarlanır.
class OA {
  OA._();
  static bool koyu = true;
  static Color _r(int d, int l) => Color(koyu ? d : l);
  static Color get bg => _r(0xFF0D0F16, 0xFFF6F3EC);
  static Color get bg2 => _r(0xFF11131C, 0xFFEFEBE2);
  static Color get surface => _r(0xFF151824, 0xFFFFFFFF);
  static Color get surface2 => _r(0xFF1C2030, 0xFFF0ECE3);
  static Color get line => _r(0xFF1E2232, 0xFFE7E1D5);
  static Color get border => _r(0xFF262B3D, 0xFFE3DDD0);
  static Color get border2 => _r(0xFF2A2F43, 0xFFD6CFBF);
  static Color get text => _r(0xFFEEEAE2, 0xFF1A1710);
  static Color get text2 => _r(0xFFB7BACA, 0xFF4A4336);
  static Color get muted => _r(0xFF9EA2B3, 0xFF6B6457);
  static Color get faint => _r(0xFF7E8296, 0xFF8F8878);
  static Color get amber => _r(0xFFF2A541, 0xFFE0901F);
  static Color get amberHi => _r(0xFFF7BF6E, 0xFFC97A12);
  static const amberInk = Color(0xFF14110A);
  static Color get green => _r(0xFF5BC48C, 0xFF2E9D63);
  static Color get blue => _r(0xFF6EA8FE, 0xFF3B7DDB);
  static Color get danger => _r(0xFFF08A7E, 0xFFD2553F);
}

/// Tema tercihi: 'dark' | 'light' | 'system'. Sistem seçiliyse işletim sisteminin açık/koyu ayarına uyar.
class ThemePref {
  static String mode = 'dark';
  static void apply(String m, Brightness platform) {
    mode = const ['dark', 'light', 'system'].contains(m) ? m : 'dark';
    OA.koyu = mode == 'system' ? platform == Brightness.dark : mode == 'dark';
  }
}

/// Başlık fontu: Bricolage Grotesque 800, sıkı harf aralığı.
TextStyle oaDisplay(double size, {Color? color}) => GoogleFonts.bricolageGrotesque(
      fontSize: size,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.02 * size,
      height: 1.1,
      color: color ?? OA.text,
    );

/// Gövde fontu: DM Sans.
TextStyle oaBody(double size, {Color? color, FontWeight weight = FontWeight.w400, double? height}) =>
    GoogleFonts.dmSans(fontSize: size, color: color ?? OA.text, fontWeight: weight, height: height);

ThemeData buildTheme() {
  final base = OA.koyu ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
  final text = GoogleFonts.dmSansTextTheme(base.textTheme).apply(bodyColor: OA.text, displayColor: OA.text);
  return base.copyWith(
    scaffoldBackgroundColor: OA.bg,
    canvasColor: OA.bg,
    textTheme: text,
    colorScheme: (OA.koyu ? ColorScheme.dark : ColorScheme.light)(
      primary: OA.amber,
      onPrimary: OA.amberInk,
      secondary: OA.amber,
      onSecondary: OA.amberInk,
      surface: OA.surface,
      onSurface: OA.text,
      surfaceContainer: OA.surface,
      surfaceContainerHigh: OA.surface2,
      outline: OA.border2,
      outlineVariant: OA.border,
      error: OA.danger,
      onError: OA.amberInk,
    ),
    dividerColor: OA.line,
    dividerTheme: DividerThemeData(color: OA.line, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: OA.amber,
        foregroundColor: OA.amberInk,
        minimumSize: const Size(44, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        shape: const StadiumBorder(),
        textStyle: GoogleFonts.dmSans(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: OA.text,
        minimumSize: const Size(44, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        side: BorderSide(color: OA.border2),
        shape: const StadiumBorder(),
        textStyle: GoogleFonts.dmSans(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: OA.amber,
        minimumSize: const Size(44, 44),
        shape: const StadiumBorder(),
        textStyle: GoogleFonts.dmSans(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: OA.bg,
      hintStyle: GoogleFonts.dmSans(color: OA.faint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: OA.border2)),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: OA.border2)),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: OA.amber)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: OA.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: BorderSide(color: OA.border)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: OA.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: OA.koyu ? OA.text : const Color(0xFF1A1710),
      contentTextStyle: GoogleFonts.dmSans(color: OA.koyu ? OA.bg : const Color(0xFFF6F3EC), fontSize: 15),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? OA.amberInk : OA.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? OA.amber : OA.surface2),
      trackOutlineColor: WidgetStateProperty.all(OA.border2),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: OA.amber, linearTrackColor: OA.surface2),
    focusColor: OA.amber.withValues(alpha: 0.2),
  );
}
