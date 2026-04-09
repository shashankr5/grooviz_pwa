// notification_permission_manager.dart
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class NotificationPermissionManager {

  /// 🔥 Unified permission request (Android 13+ safe)
  static Future<void> requestAllNotificationPermissions() async {
    if (!Platform.isAndroid) return;

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final apiLevel = androidInfo.version.sdkInt;

    try {
      // ✅ STEP 1: POST_NOTIFICATIONS (Android 13+)
      if (apiLevel >= 33) {
        final status = await Permission.notification.status;

        print('📱 Notification permission status: $status');

        if (status.isDenied) {
          final result = await Permission.notification.request();
          print('📱 Notification permission result: $result');
        } else if (status.isPermanentlyDenied) {
          print('⚠️ Notification permanently denied');
        }
      }

      // ✅ STEP 2: Foreground service notification permission
      final fgStatus = await FlutterForegroundTask.checkNotificationPermission();

      print('🔔 FG Service permission status: $fgStatus');

      if (fgStatus != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

    } catch (e) {
      print('❌ Permission request failed: $e');
    }
  }

  /// Optional helper (open settings if needed)
  static Future<bool> openSettingsIfPermanentlyDenied() async {
    if (!Platform.isAndroid) return false;

    try {
      final status = await Permission.notification.status;
      if (!status.isPermanentlyDenied) return false;
      return openAppSettings();
    } catch (_) {
      return false;
    }
  }
}