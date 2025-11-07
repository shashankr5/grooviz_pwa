// services/device_info_service.dart
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class DeviceInfoService {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  static final Uuid _uuid = Uuid();

  // Get all device information
  static Future<Map<String, dynamic>> getDeviceInfo() async {
    return {
      'installation_id': await _getInstallationId(),
      'device_identifier': await _getDeviceIdentifier(),
      'device_type': Platform.isAndroid ? 'android' : 'ios',
      'device_model': await _getDeviceModel(),
      'os_version': await _getOSVersion(),
      'app_version': await _getAppVersion(),
    };
  }

  // Get installation ID (generated once per install)
  static Future<String> _getInstallationId() async {
    final prefs = await SharedPreferences.getInstance();
    var installationId = prefs.getString('installation_id');
    
    if (installationId == null) {
      installationId = _uuid.v4();
      await prefs.setString('installation_id', installationId);
    }
    
    return installationId;
  }

  // Get device identifier
  static Future<String> _getDeviceIdentifier() async {
    try {
      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfo.androidInfo;
        return androidInfo.id;
      } else {
        final iosInfo = await _deviceInfo.iosInfo;
        return iosInfo.identifierForVendor ?? 'unknown_ios';
      }
    } catch (e) {
      return 'unknown_device_${_uuid.v4()}';
    }
  }

  // Get device model
  static Future<String> _getDeviceModel() async {
    try {
      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfo.androidInfo;
        return '${androidInfo.manufacturer} ${androidInfo.model}';
      } else {
        final iosInfo = await _deviceInfo.iosInfo;
        return iosInfo.utsname.machine;
      }
    } catch (e) {
      return 'Unknown';
    }
  }

  // Get OS version
  static Future<String> _getOSVersion() async {
    try {
      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfo.androidInfo;
        return 'Android ${androidInfo.version.release}';
      } else {
        final iosInfo = await _deviceInfo.iosInfo;
        return 'iOS ${iosInfo.systemVersion}';
      }
    } catch (e) {
      return 'Unknown';
    }
  }

  // Get app version
  static Future<String> _getAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      return packageInfo.version;
    } catch (e) {
      return '1.0.0';
    }
  }
}
