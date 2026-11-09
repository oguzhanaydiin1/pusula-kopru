import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// OA Labs tasarım sistemi (koyu tema), oalabs.dev site.css ile birebir.
class OA {
  OA._();
  static const bg = Color(0xFF0D0F16);
  static const bg2 = Color(0xFF11131C);
  static const surface = Color(0xFF151824);
  static const surface2 = Color(0xFF1C2030);
  static const line = Color(0xFF1E2232);
  static const border = Color(0xFF262B3D);
  static const border2 = Color(0xFF2A2F43);
  static const text = Color(0xFFEEEAE2);
  static const text2 = Color(0xFFB7BACA);
  static const muted = Color(0xFF9EA2B3);
  static const faint = Color(0xFF7E8296);
  static const amber = Color(0xFFF2A541);
  static const amberHi = Color(0xFFF7BF6E);
  static const amberInk = Color(0xFF14110A);
  static const green = Color(0xFF5BC48C);
  static const blue = Color(0xFF6EA8FE);
  static const danger = Color(0xFFF08A7E);
}

/// Başlık fontu: Bricolage Grotesque 800, sıkı harf aralığı.
TextStyle oaDisplay(double size, {Color color = OA.text}) => GoogleFonts.bricolageGrotesque(
      fontSize: size,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.02 * size,
      height: 1.1,
      color: color,
    );

/// Gövde fontu: DM Sans.
TextStyle oaBody(double size, {Color color = OA.text, FontWeight weight = FontWeight.w400, double? height}) =>
    GoogleFonts.dmSans(fontSize: size, color: color, fontWeight: weight, height: height);

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final text = GoogleFonts.dmSansTextTheme(base.textTheme).apply(bodyColor: OA.text, displayColor: OA.text);
  return base.copyWith(
    scaffoldBackgroundColor: OA.bg,
    canvasColor: OA.bg,
    textTheme: text,
    colorScheme: const ColorScheme.dark(
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
    dividerTheme: const DividerThemeData(color: OA.line, thickness: 1, space: 1),
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
        side: const BorderSide(color: OA.border2),
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
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: OA.border2)),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: OA.border2)),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: OA.amber)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: OA.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: OA.border)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: OA.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: OA.text,
      contentTextStyle: GoogleFonts.dmSans(color: OA.bg, fontSize: 15),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? OA.amberInk : OA.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? OA.amber : OA.surface2),
      trackOutlineColor: WidgetStateProperty.all(OA.border2),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: OA.amber, linearTrackColor: OA.surface2),
    focusColor: OA.amber.withValues(alpha: 0.2),
  );
}
