import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_typography.dart';
import '../theme/app_elevation.dart';

/// A standardized button for use in all ScreenSync screens.
/// Supports primary, outlined, and text button variants.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.loading = false,
    this.fullWidth = true,
    this.height = 52.0,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final bool loading;
  final bool fullWidth;
  final double height;

  @override
  Widget build(BuildContext context) {
    final isDisabled = onPressed == null || loading;

    Widget child = loading
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : Text(label, style: _labelStyle);

    Widget button;
    switch (variant) {
      case AppButtonVariant.outlined:
        button = OutlinedButton(
          onPressed: isDisabled ? null : onPressed,
          style: OutlinedButton.styleFrom(
            minimumSize: Size(fullWidth ? double.infinity : 0, height),
            side: BorderSide(
              color: isDisabled ? AppColors.textDisabled : AppColors.primary,
              width: 1.5,
            ),
            shape: RoundedRectangleBorder(borderRadius: AppRadius.rLg),
          ),
          child: child,
        );
        break;
      case AppButtonVariant.text:
        button = TextButton(
          onPressed: isDisabled ? null : onPressed,
          style: TextButton.styleFrom(
            minimumSize: Size(fullWidth ? double.infinity : 0, height),
            shape: RoundedRectangleBorder(borderRadius: AppRadius.rLg),
          ),
          child: Text(label, style: AppTypography.bodyPrimary.copyWith(color: AppColors.primary)),
        );
        break;
      default:
        button = ElevatedButton(
          onPressed: isDisabled ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            disabledBackgroundColor: Colors.grey.shade400,
            foregroundColor: Colors.white,
            elevation: AppElevation.button,
            minimumSize: Size(fullWidth ? double.infinity : 0, height),
            shape: RoundedRectangleBorder(borderRadius: AppRadius.rLg),
          ),
          child: child,
        );
    }
    return button;
  }

  TextStyle get _labelStyle {
    switch (variant) {
      case AppButtonVariant.outlined:
        return AppTypography.buttonLabel.copyWith(color: AppColors.primary);
      default:
        return AppTypography.buttonLabel;
    }
  }
}

enum AppButtonVariant { primary, outlined, text }
