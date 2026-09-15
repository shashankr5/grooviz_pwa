import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppGradients {
  AppGradients._();

  static const LinearGradient primary = LinearGradient(
    colors: [AppColors.primary, AppColors.primaryDark],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient accent = LinearGradient(
    colors: [AppColors.accent, AppColors.primary],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static final LinearGradient overlay = LinearGradient(
    colors: [Colors.transparent, Colors.black.withOpacity(0.4)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}
