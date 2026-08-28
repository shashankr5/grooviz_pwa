// services/order_alert_service.dart
//
// FIXES APPLIED:
//  FIX-4: Removed SharedPreferences sound-key write. Sound name is now
//          passed directly as taskData to startService(), read synchronously
//          by UnifiedAlertTaskHandler.onStart() via FlutterForegroundTask.getData().
//          This eliminates the write/read race that could play the wrong sound.
//
//  FIX-1 (from previous): _reevaluate() calls _ensureRunning() when count > 0
//          so cold-launch and app-resume with pending orders restart the alert.

import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'unified_alert_foreground_task.dart';
import 'task_alert_service.dart';

class OrderAlertService {
  static int _pendingOrderCount = 0;

  static final StreamController<void> _newOrderController =
      StreamController.broadcast();

  static Stream<void> get onNewOrder => _newOrderController.stream;
  static void notifyNewOrder() => _newOrderController.add(null);

  static int get pendingOrderCount => _pendingOrderCount;

  // ── Public API ──────────────────────────────────────────────────────────

  static Future<bool> start() => ensureRunning();

  static Future<bool> ensureRunning() => _ensureRunning(
        soundName:         AlertSoundKey.food,
        notificationTitle: 'New Order',
        notificationText:  'Waiting for acceptance...',
      );

  /// ACCEPTOR DEVICE ONLY — optimistic decrement.
  /// Must always be followed by _loadFoodOrders() → resetCount().
  static Future<void> stopOne() async {
    _pendingOrderCount = (_pendingOrderCount - 1).clamp(0, 9999);
    print('OrderAlertService.stopOne() | pendingCount=$_pendingOrderCount');
    await _reevaluate();
  }

  /// Force-stop (logout / ORDER_DELIVERED).
  static Future<void> stop() async {
    _pendingOrderCount = 0;
    await _reevaluate();
  }

  /// PRIMARY STOP GATE. Called by _loadFoodOrders() and AlertReloadCoordinator.
  /// Only reliable cross-device stop mechanism.
  static void resetCount(
    int pendingCount, {
    bool reconcileAlert = false,
  }) {
    _pendingOrderCount = pendingCount.clamp(0, 9999);
    print('OrderAlertService.resetCount($pendingCount)');
    // Page bootstrap/refresh updates counts silently. A zero count must still
    // stop a stale foreground alert immediately.
    if (pendingCount <= 0 || reconcileAlert) _reevaluate();
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  static Future<bool> _ensureRunning({
    required String soundName,
    required String notificationTitle,
    required String notificationText,
  }) async {
    return AlertServiceRestartGate.run(
      soundName: soundName,
      operation: () async {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(AlertSoundKey.prefKey, soundName);
          // Food orders loop until explicitly accepted/stopped.
          await prefs.setString(AlertSoundKey.loopKey, 'true');

          final isRunning = await FlutterForegroundTask.isRunningService;
          if (isRunning) {
            await FlutterForegroundTask.restartService();
            print('OrderAlertService: foreground service restarted (sound=$soundName)');
          } else {
            await FlutterForegroundTask.startService(
              notificationTitle: notificationTitle,
              notificationText:  notificationText,
              callback:          unifiedAlertStartCallback,
            );
            print('OrderAlertService: foreground service started (sound=$soundName)');
          }
          return true;
        } catch (e) {
          print('OrderAlertService._ensureRunning error: $e');
          return false;
        }
      },
    );
  }

  static Future<void> _reevaluate() async {
    // ARCHITECTURE: _reevaluate() is a STOP-ONLY gate.
    // It NEVER restarts the foreground service — restarts are driven exclusively
    // by FCM/WS new-event handlers (NEW_FOOD_ORDER, NEW_SERVICE_TASK, etc.).
    // This eliminates spurious sound replays from page loads, tab taps, and
    // pull-to-refresh cycles.
    if (_pendingOrderCount > 0) return; // Food still pending — service keeps running
    if (TaskAlertService.totalPending > 0) return; // Task/delivery pending — keep service alive
    await _stopService(); // All clear — stop foreground service
  }

  static Future<void> _stopService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        print('OrderAlertService: foreground service stopped');
      }
    } catch (e) {
      print('OrderAlertService._stopService error: $e');
    }
  }
}