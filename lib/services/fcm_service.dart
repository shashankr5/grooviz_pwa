import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FCMService {
  static final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  static StreamSubscription<String>? _refreshSub;
  static Completer<String?>? _pendingTokenCompleter;
  static DateTime? _lastDirectFetchAt;
  static const Duration _directFetchThrottle = Duration(seconds: 15);

  static Future<void> initialize() async {
    try {
      await _fcm.setAutoInitEnabled(true);
      await _fcm.requestPermission(
        alert: true, 
        badge: true, 
        sound: true
      );

      _refreshSub ??= _fcm.onTokenRefresh.listen((token) async {
        if (token.isEmpty) return;
        await _saveToken(token);
        _completePending(token);
      });

      unawaited(probeTokenAvailability(force: true));
    } catch (e) {
      print('FCM initialization error: $e');
    }
  }

  static Future<String?> getCachedFCMToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('fcm_token');
  }

  static Future<String?> getFCMToken({
    Duration timeout = const Duration(minutes: 2),
    bool preferFresh = false,
  }) async {
    return ensureFCMToken(timeout: timeout, preferFresh: preferFresh);
  }

  static Future<String?> ensureFCMToken({
    Duration timeout = const Duration(minutes: 2),
    bool preferFresh = false,
  }) async {
    final cached = await getCachedFCMToken();

    if (!preferFresh && cached != null && cached.isNotEmpty) {
      unawaited(probeTokenAvailability());
      return cached;
    }

    final immediate = await _getTokenDirect(force: true);
    if (immediate != null && immediate.isNotEmpty) {
      await _saveToken(immediate);
      return immediate;
    }

    final pending = _pendingTokenCompleter ??= Completer<String?>();
    unawaited(probeTokenAvailability());

    final token = await pending.future.timeout(timeout, onTimeout: () => null);
    if (token != null && token.isNotEmpty) return token;

    return cached ?? await getCachedFCMToken();
  }

  static Future<void> probeTokenAvailability({bool force = false}) async {
    final token = await _getTokenDirect(force: force);
    if (token != null && token.isNotEmpty) {
      await _saveToken(token);
      _completePending(token);
    }
  }

  static Future<String?> _getTokenDirect({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _lastDirectFetchAt != null &&
        now.difference(_lastDirectFetchAt!) < _directFetchThrottle) {
      return null;
    }

    _lastDirectFetchAt = now;
    return _tryGetTokenOnce();
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

  static void _completePending(String? token) {
    final completer = _pendingTokenCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(token);
    }
    _pendingTokenCompleter = null;
  }

  static Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fcm_token', token);
  }
}