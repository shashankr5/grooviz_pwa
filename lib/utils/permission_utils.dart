import 'package:permission_handler/permission_handler.dart';

class PermissionUtils {
  PermissionUtils._();

  /// Checks if notification permission is granted.
  static Future<bool> isNotificationGranted() async {
    return Permission.notification.isGranted;
  }

  /// Request a list of permissions, returns mapping of status.
  static Future<Map<Permission, PermissionStatus>> requestPermissions(List<Permission> permissions) async {
    return permissions.request();
  }

  /// Open application OS settings screen.
  static Future<bool> openSettings() async {
    return openAppSettings();
  }
}
