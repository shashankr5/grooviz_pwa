import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // ── Brand / Primary ───────────────────────────────────────────
  static const primary      = Color(0xFF4C3BCF);
  static const primaryDark  = Color(0xFF3A2BA8);
  static const primaryLight = Color(0xFFEEECFB);

  // Legacy accent support (from old file)
  static const accent       = Color(0xFF1E88E5);
  static const _accent      = Color(0xFF5C6BC0);

  // ── Semantic Colors ───────────────────────────────────────────
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

  // ── Background / Surface ──────────────────────────────────────
  static const bg           = Color(0xFFF3F4F8);
  static const bgLight      = Color(0xFFF3F4F8); // unified

  static const surface      = Colors.white;
  static const surfaceAlt   = Color(0xFFF8F9FA);

  // ── Text ──────────────────────────────────────────────────────
  static const textPrimary   = Color(0xFF1E293B);
  static const textSecondary = Color(0xFF64748B);
  static const textDisabled  = Color(0xFFADB5BD);
  static const textOnDark    = Colors.white;

  // ── Borders ───────────────────────────────────────────────────
  static const border       = Color(0xFFE5E7EB);
  static const borderLight  = Color(0xFFF1F5F9);

  // ── Shadows / Overlay ─────────────────────────────────────────
  static Color shadow        = Colors.black.withOpacity(0.06);
  static Color shadowMedium  = Colors.black.withOpacity(0.10);
  static Color overlay       = Colors.black.withOpacity(0.5);

  // ── Secondary (kept for compatibility)
  static const secondary = success;

  // ── Status Helpers (VERY useful across app) ───────────────────
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