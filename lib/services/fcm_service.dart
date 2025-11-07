// services/fcm_service.dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FCMService {
  static final FirebaseMessaging _fcm = FirebaseMessaging.instance;

  // Initialize FCM and get token
  static Future<void> initialize() async {
    try {
      // Request permissions
      await _fcm.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      // Get initial token
      await _getAndSaveToken();
      
      // Listen for token refresh
      _fcm.onTokenRefresh.listen(_onTokenRefresh);
      
    } catch (e) {
      print('FCM Initialization Error: $e');
    }
  }

  // Get current FCM token
  static Future<String?> getFCMToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('fcm_token');
    } catch (e) {
      print('Error getting FCM token: $e');
      return null;
    }
  }

  // Get and save FCM token
  static Future<void> _getAndSaveToken() async {
    try {
      String? token = await _fcm.getToken();
      if (token != null) {
        await _saveToken(token);
        print('FCM Token: $token');
      }
    } catch (e) {
      print('Error getting FCM token: $e');
    }
  }

  // Save token to storage
  static Future<void> _saveToken(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcm_token', token);
    } catch (e) {
      print('Error saving FCM token: $e');
    }
  }

  // Handle token refresh
  static Future<void> _onTokenRefresh(String newToken) async {
    print('FCM Token Refreshed: $newToken');
    await _saveToken(newToken);
  }
}