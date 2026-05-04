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
import 'unified_alert_foreground_task.dart';
import 'task_alert_service.dart';

class OrderAlertService {
  static int _pendingOrderCount = 0;

  static final StreamController<void> _newOrderController =
      StreamController.broadcast();

  static Stream<void> get onNewOrder => _newOrderController.stream;
  static void notifyNewOrder() => _newOrderController.add(null);

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
  static void resetCount(int pendingCount) {
    _pendingOrderCount = pendingCount.clamp(0, 9999);
    print('OrderAlertService.resetCount($pendingCount)');
    _reevaluate();
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  static int get _totalPending =>
      _pendingOrderCount + TaskAlertService.totalPending;

  static Future<bool> _ensureRunning({
    required String soundName,
    required String notificationTitle,
    required String notificationText,
  }) async {
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) {
        // FIX-4: Pass sound name as taskData — read synchronously by handler.
        // No SharedPreferences write needed, no race condition possible.
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
  }

  static Future<void> _reevaluate() async {
    if (_totalPending == 0) {
      await _stopService();
    } else {
      // Restart if not running — covers cold-launch and app-resume with
      // pending orders (FIX-1 from previous review).
      await _ensureRunning(
        soundName:         AlertSoundKey.food,
        notificationTitle: 'New Order',
        notificationText:  'Waiting for acceptance...',
      );
    }
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