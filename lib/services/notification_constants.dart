import 'package:flutter/material.dart';

/// Fixed notification IDs — one per department.
/// Using fixed IDs means Android REPLACES the existing notification
/// rather than stacking a new one. Staff see max 5 tray entries total.
class NotifId {
  static const int foodOrder    = 1001;
  static const int delivery     = 1002;
  static const int serviceTask  = 1003;
  static const int escalation   = 1004;
  static const int session      = 1005;
  static const int groupSummary = 1000; // Android group summary
}

/// Notification group key — all ScreenSync alerts collapse under one umbrella
class NotifGroup {
  static const String key = 'screensync_operational_alerts';
}

/// Accent colors per department (Android left-strip color)
class NotifColor {
  static const int foodOrder   = 0xFFFF6B35; // Amber-orange
  static const int delivery    = 0xFF2196F3; // Blue
  static const int serviceTask = 0xFF4CAF50; // Green
  static const int escalation  = 0xFFF44336; // Red
  static const int session     = 0xFF9C27B0; // Purple
}

/// Monochrome icon drawables (place in android/app/src/main/res/drawable/)
class NotifIcon {
  static const String food       = '@drawable/ic_notif_food';
  static const String delivery   = '@drawable/ic_notif_delivery';
  static const String task       = '@drawable/ic_notif_task';
  static const String escalation = '@drawable/ic_notif_escalation';
  static const String fallback   = '@drawable/ic_notif_default';
}

/// Channel IDs (must match what's registered in notification_handler init)
class NotifChannel {
  static const String foodOrder   = 'high_importance_channel';
  static const String delivery    = 'delivery_alert_channel';
  static const String task        = 'task_alert_channel';
  static const String escalation  = 'escalation_alert_channel';
  static const String foreground  = 'order_alert_service';
}
