// services/fcm_service.dart
import 'dart:io';
import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fcm_background.dart';


class FCMService {
  static final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  static StreamSubscription<String>? _refreshSub;

  static Future<void> initialize() async {
    try {
      await _fcm.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      _refreshSub ??= _fcm.onTokenRefresh.listen((token) async {
        await _saveToken(token);
      });

      final token = await _tryGetTokenOnce();
      if (token != null && token.isNotEmpty) {
        await _saveToken(token);
      }
    } catch (e) {
      print('FCM initialization error: $e');
    }
  }

  static Future<String?> getCachedFCMToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('fcm_token');
  }

  static Future<String?> getFCMToken({
    Duration timeout = const Duration(seconds: 20),
    bool preferFresh = false,
  }) async {
    return ensureFCMToken(
      timeout: timeout,
      preferFresh: preferFresh,
      );
  }

  static Future<String?> ensureFCMToken({
    Duration timeout = const Duration(seconds: 20),
    bool preferFresh = false,
  }) async {
    final cached = await getCachedFCMToken();
    if (cached != null && cached.isNotEmpty) return cached;
    if (!preferFresh && cached != null && cached.isNotEmpty) {
      unawaited(_refreshTokenInBackground());
      return cached;
    }

    final immediate = await _tryGetTokenOnce();
    if (immediate != null && immediate.isNotEmpty) {
      await _saveToken(immediate);
      return immediate;
    }

    final completer = Completer<String?>();

    late final StreamSubscription<String> sub;
    sub = _fcm.onTokenRefresh.listen((token) async {
      if (token.isNotEmpty && !completer.isCompleted) {
        await _saveToken(token);
        completer.complete(token);
      }
    });

    try {
      final deadline = DateTime.now().add(timeout);
      var delay = const Duration(seconds: 2);

      while (DateTime.now().isBefore(deadline)) {
        final token = await _tryGetTokenOnce();
        if (token != null && token.isNotEmpty) {
          await _saveToken(token);
          if (!completer.isCompleted) completer.complete(token);
          break;
        }

        await Future.delayed(delay);
        if (delay < const Duration(seconds: 5)) {
          delay += const Duration(seconds: 1);
        }
      }

      if (!completer.isCompleted) {
        completer.complete(await getCachedFCMToken());

      if (!completer.isCompleted && cached != null && cached.isNotEmpty) {
        completer.complete(cached);
      } else if (!completer.isCompleted) {
          completer.complete(await getCachedFCMToken());
        }
      }

      return await completer.future.timeout(
        timeout + const Duration(seconds: 1),
        onTimeout: () => null,
      );
    } finally {
      await sub.cancel();
    }
  }

  static Future<String?> _tryGetTokenOnce() async {
    try {
      if (Platform.isIOS) {
        await _fcm.getAPNSToken();
      }
      final token = await _fcm.getToken();
      return (token != null && token.isNotEmpty) ? token : null;
    } catch (e) {
      print('FCM token fetch failed (will retry automatically): $e');
      return null;
    }
  }

  static Future<void> _refreshTokenInBackground() async {
    final token = await _tryGetTokenOnce();
    if (token != null && token.isNotEmpty) {
      await _saveToken(token);
    }
  }

  static Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fcm_token', token);
  }
}