import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_typography.dart';

/// A standardized badge chip for status labels, counters, and tags.
class AppBadge extends StatelessWidget {
  const AppBadge({
    super.key,
    required this.label,
    this.color,
    this.backgroundColor,
    this.icon,
    this.small = false,
  });

  final String label;
  final Color? color;
  final Color? backgroundColor;
  final IconData? icon;
  final bool small;

  /// Creates a status badge using AppColors.statusColor and statusLightColor.
  factory AppBadge.status(String status) {
    return AppBadge(
      label: status,
      color: AppColors.statusColor(status),
      backgroundColor: AppColors.statusLightColor(status),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fgColor = color ?? AppColors.textPrimary;
    final bgColor = backgroundColor ?? AppColors.borderLight;
    final fontSize = small ? 10.0 : 12.0;
    final padding = small
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
        : const EdgeInsets.symmetric(horizontal: 10, vertical: 4);

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: AppRadius.rCircular,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: fontSize + 2, color: fgColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: AppTypography.caption.copyWith(
              color: fgColor,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
