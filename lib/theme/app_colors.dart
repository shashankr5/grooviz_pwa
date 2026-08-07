import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Brand / Primary
  static const primary      = Color(0xFF052D50);
  static const primaryDark  = Color(0xFF1E4262);
  static const primaryLight = Color(0xFFEBEFF1);

  // Secondary / Accent
  static const secondary    = Color(0xFF10B981);
  static const accent       = Color(0xFF1E4262);

  // Semantic Colors
  static const success      = Color(0xFF10B981);
  static const successLight = Color(0xFFD1FAE5);

  static const warning      = Color(0xFFF59E0B);
  static const warningLight = Color(0xFFFEF3C7);

  static const error        = Color(0xFFEF4444);
  static const errorLight   = Color(0xFFFEE2E2);

  static const info         = Color(0xFF3B82F6);
  static const infoLight    = Color(0xFFDBEAFE);

  static const orange       = Color(0xFFF97316);
  static const orangeLight  = Color(0xFFFFEDD5);

  static const teal         = Color(0xFF14B8A6);
  static const tealLight    = Color(0xFFCCFBF1);

  // Background / Surface
  static const bg           = Color(0xFFEBEFF1);
  static const bgLight      = Color(0xFFEBEFF1);
  static const surface      = Colors.white;
  static const surfaceAlt   = Color(0xFFF4F6F8);

  // Text Colors
  static const textPrimary   = Color(0xFF052D50);
  static const textSecondary = Color(0xFF4A6580);
  static const textDisabled  = Color(0xFFADB5BD);
  static const textOnDark    = Colors.white;

  // Borders
  static const border       = Color(0xFFD6DDE3);
  static const borderLight  = Color(0xFFEBEFF1);

  // Shadows / Overlay
  static Color get shadow       => Colors.black.withOpacity(0.06);
  static Color get shadowMedium => Colors.black.withOpacity(0.10);
  static Color get overlay      => Colors.black.withOpacity(0.5);

  static Color statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'open':        return info;
      case 'in progress': return orange;
      case 'closed':      return success;
      case 'pending':     return warning;
      case 'preparing':   return info;
      case 'ready':       return success;
      case 'delivered':   return teal;
      case 'cancelled':   return error;
      default:            return textDisabled;
    }
  }

  static Color statusLightColor(String status) {
    switch (status.toLowerCase()) {
      case 'open':        return infoLight;
      case 'in progress': return orangeLight;
      case 'closed':      return successLight;
      case 'pending':     return warningLight;
      case 'preparing':   return infoLight;
      case 'ready':       return successLight;
      case 'delivered':   return tealLight;
      case 'cancelled':   return errorLight;
      default:            return borderLight;
    }
  }
}
