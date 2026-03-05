import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

class NotificationPermissionManager {
  static Future<void> requestSafely() async {
    if (!Platform.isAndroid) return;

    // ✅ Check Android API level - POST_NOTIFICATIONS only exists on API 33+
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final apiLevel = androidInfo.version.sdkInt;

    // Only POST_NOTIFICATIONS permission is needed for API 33+
    // On API 32 and below, no runtime permission is needed
    if (apiLevel < 33) {
      return;
    }

    try {
      // Check current permission status for POST_NOTIFICATIONS
      final status = await Permission.notification.status;

      print('📱 Notification permission status: $status (API level: $apiLevel)');

      // If already granted, do nothing
      if (status.isGranted) {
        return;
      }

      // If denied (not permanently), request permission
      if (status.isDenied) {
        final result = await Permission.notification.request();
        print('📱 Notification permission result: $result');
        return;
      }

      // If permanently denied, only show settings if user explicitly denied (not first time)
      // Don't automatically open settings on first app launch
      if (status.isPermanentlyDenied) {
        print('📱 Notification permission permanently denied - user must enable in settings');
        // Do NOT call openAppSettings() automatically - let the app work without it
        // Users can enable it manually if they want
      }
    } catch (e) {
      print('❌ Error requesting notification permission: $e');
      // Silently fail - app should work without notification permission
    }
  }

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
