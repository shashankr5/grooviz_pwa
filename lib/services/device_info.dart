// services/device_info.dart
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../constants/storage_keys.dart';

class DeviceInfo {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  static final Uuid _uuid = Uuid();

  static Future<Map<String, dynamic>> getDeviceInfo() async {
    return {
      "installation_id": await _getInstallationId(),
      "device_identifier": await _getDeviceIdentifier(),
      "device_type": Platform.isAndroid ? "android" : "ios",
      "device_model": await _getDeviceModel(),
      "os_version": await _getOSVersion(),
      "app_version": await _getAppVersion(),
    };
  }

  /// Persistent install ID
  static Future<String> _getInstallationId() async {
    final prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString(StorageKeys.installationId);

    if (id == null || id.isEmpty) {
      id = _uuid.v4();       
      await prefs.setString(StorageKeys.installationId, id);
    }

    return id; 
  }

  /// Guaranteed non-null device identifier
  static Future<String> _getDeviceIdentifier() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(StorageKeys.deviceIdentifier);
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      if (Platform.isAndroid) {
        final android = await _deviceInfo.androidInfo;
        final id = (android.id.isNotEmpty == true) ? android.id : "android_${_uuid.v4()}";
        await prefs.setString(StorageKeys.deviceIdentifier, id);  // SAVE HERE
        return id;
      } else {
        final ios = await _deviceInfo.iosInfo;
        final id = (ios.identifierForVendor?.isNotEmpty == true)
            ? ios.identifierForVendor!
            : "ios_${_uuid.v4()}";
        await prefs.setString(StorageKeys.deviceIdentifier, id);  // SAVE HERE
        return id;
      }
    } catch (e) {
      final fallback = "device_${_uuid.v4()}";
      await prefs.setString(StorageKeys.deviceIdentifier, fallback);
      return fallback;
    }
  }

  static Future<String> _getDeviceModel() async {
    try {
      if (Platform.isAndroid) {
        final android = await _deviceInfo.androidInfo;
        return "${android.manufacturer} ${android.model}";
      } else {
        final ios = await _deviceInfo.iosInfo;
        return ios.utsname.machine;
      }
    } catch (e) {
      return "Unknown Device";
    }
  }

  static Future<String> _getOSVersion() async {
    try {
      if (Platform.isAndroid) {
        final android = await _deviceInfo.androidInfo;
        return "Android ${android.version.release}";
      } else {
        final ios = await _deviceInfo.iosInfo;
        return "iOS ${ios.systemVersion}";
      }
    } catch (e) {
      return "Unknown OS";
    }
  }

  static Future<String> _getAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (e) {
      return "1.0.0";
    }
  }
}