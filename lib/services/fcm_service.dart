import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/storage_keys.dart';

class FCMService {
  FCMService._();

  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  static Future<String> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp().timeout(const Duration(seconds: 4));
      }

      try {
        await _messaging.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        ).timeout(const Duration(seconds: 4));
      } catch (permError) {
        print('FCM permission request warning: $permError');
      }

      final token = await _messaging.getToken().timeout(const Duration(seconds: 5));
      if (token != null && token.trim().isNotEmpty) {
        await prefs.setString(StorageKeys.fcmToken, token.trim());
        await prefs.remove(StorageKeys.fcmNeedsReregistration);
        return token.trim();
      }
    } catch (error) {
      print('FCM token registration failed: $error');
    }

    // Fallback 1: Return cached FCM token if previously saved
    final cachedToken = prefs.getString(StorageKeys.fcmToken);
    if (cachedToken != null && cachedToken.trim().isNotEmpty) {
      return cachedToken.trim();
    }

    // Fallback 2: Generate a resilient fallback token linked to installation ID
    final installationId = prefs.getString(StorageKeys.installationId) ?? 'device';
    final fallbackToken = 'fallback_token_$installationId';
    await prefs.setString(StorageKeys.fcmToken, fallbackToken);
    await prefs.setBool(StorageKeys.fcmNeedsReregistration, true);
    return fallbackToken;
  }

  static Future<void> handleTokenRefresh(String token) async {
    if (token.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.fcmToken, token);
    await prefs.setBool(StorageKeys.fcmNeedsReregistration, true);
  }

  static Future<void> deregisterToken() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      await _messaging.deleteToken();
    } catch (error) {
      print('FCM token deregistration failed: $error');
    } finally {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(StorageKeys.fcmToken);
      await prefs.setBool(StorageKeys.fcmNeedsReregistration, true);
    }
  }
}
