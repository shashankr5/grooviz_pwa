import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FCM acquisition states — exposed so UI can react.
enum FCMStatus { idle, acquiring, ready, failed }

class FCMService {
  static final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  static StreamSubscription<String>? _refreshSub;
  static Completer<String?>? _tokenCompleter;

  static bool _retryLoopActive = false;
  static bool _cancelLoop = false;

  // Status stream — LoginScreen listens to this to show progress.
  static final _statusController =
      StreamController<FCMStatus>.broadcast();
  static Stream<FCMStatus> get statusStream => _statusController.stream;
  static FCMStatus _currentStatus = FCMStatus.idle;

  static const String _keyFcmToken = 'fcm_token';
  static const String _keyStoredVersion = 'fcm_stored_app_version';
  static const String _keyNeedsReregistration = 'fcm_needs_reregistration';

  // ─── PUBLIC ENTRY POINT ───────────────────────────────────────────────────

  /// Call once from main() before runApp(), or from app init.
  static Future<void> initialize() async {
    try {
      await _fcm.setAutoInitEnabled(true);
      await _fcm.requestPermission(alert: true, badge: true, sound: true);

      _tokenCompleter ??= Completer<String?>();

      // onTokenRefresh is the fastest possible path when GPS recovers.
      // It fires automatically without any polling on our side.
      _refreshSub ??= _fcm.onTokenRefresh.listen((token) async {
        if (token.isEmpty) return;
        _log('onTokenRefresh → GPS recovered instantly');
        await _saveToken(token);
        _cancelLoop = true;
        await _clearFlag();
        _emitStatus(FCMStatus.ready);
        _complete(token);
      });

      await _handleStartup();
    } catch (e) {
      _log('initialize error: $e');
    }
  }

  // ─── CALLED BEFORE EVERY LOGIN ────────────────────────────────────────────

  /// Returns a token or null within [timeout].
  /// The LOGIN button should wait on this — it shows progress via [statusStream].
  ///
  /// Timeout of 30s is the UX upper bound. GPS always recovers within this
  /// window on a device with any network; if it doesn't, the user likely
  /// has no connectivity at all.
  static Future<String?> ensureFCMToken({
    Duration timeout = const Duration(seconds: 30),
    bool preferFresh = false,
  }) async {
    final cached = await getCachedFCMToken();
    final needsRereg = await _getFlag();

    // ── Fast path ─────────────────────────────────────────────────────────
    if (!preferFresh && !needsRereg && cached != null && cached.isNotEmpty) {
      _emitStatus(FCMStatus.ready);
      return cached;
    }
    _emitStatus(FCMStatus.acquiring);

    // ── Direct attempt — works on many devices immediately ────────────────
    // Try getToken() BEFORE deleteToken(). On a significant fraction of
    // reinstalls, GPS is already connected and getToken() succeeds instantly.
    final direct = await _tryGetTokenOnce();
    if (direct != null) {
      _log('ensureFCMToken: direct getToken() succeeded');
      await _saveToken(direct);
      await _clearFlag();
      _emitStatus(FCMStatus.ready);
      _complete(direct);
      return direct;
    }

    // ── GPS not ready — start/ensure loop is running ──────────────────────
    _tokenCompleter ??= Completer<String?>();
    _startRetryLoopIfNeeded();

    _log('ensureFCMToken: waiting up to ${timeout.inSeconds}s for GPS');

    final token = await _tokenCompleter!.future
        .timeout(timeout, onTimeout: () => null);

    if (token != null && token.isNotEmpty) {
      _emitStatus(FCMStatus.ready);
      return token;
    }

    // Race condition guard: onTokenRefresh may have saved just before timeout.
    final fallback = await getCachedFCMToken();
    if (fallback != null && fallback.isNotEmpty) {
      _emitStatus(FCMStatus.ready);
      return fallback;
    }

    _emitStatus(FCMStatus.failed);
    return null;
  }

  static Future<String?> getCachedFCMToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyFcmToken);
  }

  static FCMStatus get currentStatus => _currentStatus;

  // ─── STARTUP STATE MACHINE ────────────────────────────────────────────────

  static Future<void> _handleStartup() async {
    final prefs = await SharedPreferences.getInstance();
    final info = await PackageInfo.fromPlatform();
    final currentVersion = '${info.version}+${info.buildNumber}';
    final storedVersion = prefs.getString(_keyStoredVersion);
    final needsRereg = prefs.getBool(_keyNeedsReregistration) ?? false;
    final cached = await getCachedFCMToken();

    _log('Startup  ver=$currentVersion  stored=$storedVersion  '
        'needsRereg=$needsRereg  token=${cached != null ? "present" : "null"}');

    // ── Healthy ────────────────────────────────────────────────────────────
    if (cached != null &&
        cached.isNotEmpty &&
        !needsRereg &&
        storedVersion == currentVersion) {
      _log('Healthy — no acquisition needed');
      _emitStatus(FCMStatus.ready);
      _complete(cached);
      return;
    }

    // ── Version change / reinstall ─────────────────────────────────────────
    if (storedVersion != currentVersion) {
      _log('Version change: $storedVersion → $currentVersion');
      await prefs.remove(_keyFcmToken);
      await prefs.setBool(_keyNeedsReregistration, true);
      await prefs.setString(_keyStoredVersion, currentVersion);
    }

    _emitStatus(FCMStatus.acquiring);

    // All non-healthy paths: start acquisition immediately.
    _startRetryLoopIfNeeded();
  }

  // ─── GPS PROBE RETRY LOOP ─────────────────────────────────────────────────
  //
  // Acquisition strategy (fastest-first):
  //
  //  Phase 1 — Burst (attempts 1-4, no delay / 1s / 1s / 2s):
  //    Try getToken() directly first — works on many devices immediately.
  //    If that fails, try deleteToken() as a GPS connectivity probe, then
  //    getToken() again. Short gaps so we catch GPS the moment it's ready.
  //
  //  Phase 2 — Exponential backoff (attempt 5+):
  //    5s → 10s → 20s → 40s → … → max 5 min.
  //    At this point GPS is genuinely unreachable (no connectivity).
  //    onTokenRefresh will fire as soon as it reconnects.
  //
  // We intentionally try getToken() BEFORE deleteToken() on every burst
  // iteration — on many Android devices after reinstall, GPS is already
  // connected and getToken() works without any cleanup round-trip.

  static void _startRetryLoopIfNeeded() {
    if (_retryLoopActive) {
      _log('Retry loop already running');
      return;
    }
    _cancelLoop = false;
    _log('Starting acquisition loop');
    unawaited(_retryLoop());
  }

  static Future<void> _retryLoop() async {
    _retryLoopActive = true;

    // Burst delays: attempt 1 = 0s, 2 = 1s, 3 = 1s, 4 = 2s, then exponential.
    const burstDelays = [0, 1, 1, 2];

    try {
      int attempt = 0;

      while (!_cancelLoop) {
        // Check if onTokenRefresh or another path already got a token.
        final existing = await getCachedFCMToken();
        if (existing != null && existing.isNotEmpty) {
          _log('Loop: token found externally — done');
          await _clearFlag();
          _emitStatus(FCMStatus.ready);
          _complete(existing);
          return;
        }

        // Delay before this attempt.
        if (attempt < burstDelays.length) {
          final d = burstDelays[attempt];
          if (d > 0) {
            _log('Loop: burst delay ${d}s before attempt ${attempt + 1}');
            await _cancelableSleep(d);
            if (_cancelLoop) break;
          }
        } else {
          // Exponential backoff after burst phase.
          final delaySec = min(300, (5 * pow(2, attempt - burstDelays.length)).toInt());
          _log('Loop: backoff ${delaySec}s before attempt ${attempt + 1}');
          await _cancelableSleep(delaySec);
          if (_cancelLoop) break;
        }

        attempt++;
        _log('Loop: attempt $attempt');

        // ── Step 1: try getToken() directly ──────────────────────────────
        // Skip deleteToken() if GPS is already connected — this is faster.
        final directToken = await _tryGetTokenOnce();
        if (directToken != null) {
          _log('Loop: getToken() succeeded on attempt $attempt (no delete needed)');
          await _saveToken(directToken);
          await _clearFlag();
          _emitStatus(FCMStatus.ready);
          _complete(directToken);
          return;
        }

        // ── Step 2: try deleteToken() as GPS readiness probe ─────────────
        _log('Loop: attempt $attempt — getToken() not ready, trying deleteToken()');
        try {
          await _fcm.deleteToken();
          _log('Loop: deleteToken() succeeded — GPS server connection confirmed');

          // Brief settle: GPS just finished a server round-trip.
          await _cancelableSleep(2);
          if (_cancelLoop) break;

          final token = await _tryGetTokenOnce();
          if (token != null) {
            _log('Loop: fresh token obtained after deleteToken on attempt $attempt');
            await _saveToken(token);
            await _clearFlag();
            _emitStatus(FCMStatus.ready);
            _complete(token);
            return;
          }

          // deleteToken() succeeded but getToken() returned null.
          // Firebase will fire onTokenRefresh within a few seconds — stay in loop.
          _log('Loop: deleteToken OK, getToken pending — onTokenRefresh will fire');

        } catch (e) {
          _log('Loop: attempt $attempt — GPS not ready ($e)');
        }
      }
    } finally {
      _retryLoopActive = false;
      _log('Loop: stopped (cancel=$_cancelLoop)');
    }
  }

  // ─── SINGLE ATTEMPT ──────────────────────────────────────────────────────

  static Future<String?> _tryGetTokenOnce() async {
    try {
      if (Platform.isIOS) {
        final apns = await _fcm.getAPNSToken();
        if (apns == null || apns.isEmpty) return null;
      }
      final token = await _fcm.getToken();
      return (token != null && token.isNotEmpty) ? token : null;
    } catch (e) {
      _log('getToken() failed: $e');
      return null;
    }
  }

  // ─── HELPERS ─────────────────────────────────────────────────────────────

  /// Sleeps for [seconds] but checks _cancelLoop every second.
  static Future<void> _cancelableSleep(int seconds) async {
    for (int i = 0; i < seconds; i++) {
      if (_cancelLoop) return;
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  static void _emitStatus(FCMStatus status) {
    _currentStatus = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  static void _complete(String? token) {
    if (_tokenCompleter != null && !_tokenCompleter!.isCompleted) {
      _tokenCompleter!.complete(token);
    }
    _tokenCompleter = null;
  }

  static Future<bool> _getFlag() async =>
      (await SharedPreferences.getInstance())
          .getBool(_keyNeedsReregistration) ?? false;

  static Future<void> _clearFlag() async =>
      (await SharedPreferences.getInstance())
          .remove(_keyNeedsReregistration);

  static Future<void> _saveToken(String token) async =>
      (await SharedPreferences.getInstance())
          .setString(_keyFcmToken, token);

  static void _log(String msg) => print('[FCMService] $msg');
}
