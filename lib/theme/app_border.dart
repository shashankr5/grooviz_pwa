import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppBorder {
  AppBorder._();

  static const double thinWidth = 1.0;
  static const double mediumWidth = 1.5;
  static const double thickWidth = 2.0;

  static const BorderSide sideDefault = BorderSide(
    color: AppColors.border,
    width: thinWidth,
  );

  static const BorderSide sideFocused = BorderSide(
    color: AppColors.primary,
    width: mediumWidth,
  );

  static const BorderSide sideError = BorderSide(
    color: AppColors.error,
    width: thinWidth,
  );

  static Border get light => Border.all(color: AppColors.borderLight);
  static Border get primary => Border.all(color: AppColors.primary);
}
