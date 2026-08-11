import 'package:flutter/material.dart';

/// SitePhoto brand palette — matches the desktop app's engineering blue.
class AppColors {
  static const primary = Color(0xFF1976D2);
  static const primaryDark = Color(0xFF143B50);
  static const accent = Color(0xFF29758A);
  static const sepLine = Color(0xFF1976D2);
  static const sepLineLight = Color(0xFF90CAF9);
  static const sepPillBg = Color(0xFFE3F2FD);
  static const sepPillText = Color(0xFF1565C0);
  static const bg = Color(0xFFF5F7F8);
  static const cardBg = Colors.white;
  static const numberBadge = Color(0xFFD32F2F);
  static const textPrimary = Color(0xFF143B50);
  static const textSecondary = Color(0xFF6B7D84);
  static const success = Color(0xFF2E7D32);
  static const warning = Color(0xFFE65100);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorSchemeSeed: AppColors.primary,
    scaffoldBackgroundColor: AppColors.bg,
    fontFamily: 'NotoSansTC',
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.primary,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: AppColors.cardBg,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.primary,
      foregroundColor: Colors.white,
    ),
  );
}
