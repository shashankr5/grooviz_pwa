import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

class NotificationPermissionManager {
  static Future<void> requestSafely() async {
    if (!Platform.isAndroid) return;

    // Check current permission status
    final status = await Permission.notification.status;

    // If already granted, do nothing
    if (status.isGranted) {
      return;
    }

    // If permanently denied, open settings
    if (status.isPermanentlyDenied) {
      await openAppSettings();
      return;
    }

    // If denied (but not permanently), request permission
    if (status.isDenied) {
      await Permission.notification.request();
    }
  }
}
