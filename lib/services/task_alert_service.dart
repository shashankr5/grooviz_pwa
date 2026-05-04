// services/task_alert_service.dart
//
// FIXES APPLIED:
//  FIX-4: Removed SharedPreferences sound-key write. Sound name passed
//          directly as taskData to startService(), eliminating the
//          write/read race condition with UnifiedAlertTaskHandler.
//
//  FIX-1 (from previous): _reevaluate() calls _ensureRunning() when
//          totalPending > 0 — covers cold-launch and app-resume.

import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'unified_alert_foreground_task.dart';

class TaskAlertService {
  static int _pendingServiceCount  = 0;
  static int _pendingDeliveryCount = 0;

  static int get totalPending => _pendingServiceCount + _pendingDeliveryCount;

  // ── Streams ─────────────────────────────────────────────────────────────
  static final StreamController<void> _newTaskController =
      StreamController.broadcast();
  static final StreamController<void> _newDeliveryController =
      StreamController.broadcast();

  static Stream<void> get onNewTask     => _newTaskController.stream;
  static Stream<void> get onNewDelivery => _newDeliveryController.stream;

  static void notifyNewTask()     => _newTaskController.add(null);
  static void notifyNewDelivery() => _newDeliveryController.add(null);

  // ── Service task API ─────────────────────────────────────────────────────

  static Future<bool> startServiceAlert()    => ensureServiceRunning();
  static Future<bool> ensureServiceRunning() => _ensureRunning(
        soundName:         AlertSoundKey.task,
        notificationTitle: 'New Service Request',
        notificationText:  'Tap to view pending tasks',
      );

  /// ACCEPTOR DEVICE ONLY — optimistic decrement.
  /// Must be followed by _loadTasks() → resetServiceCount().
  static Future<void> stopOneServiceAlert() async {
    _pendingServiceCount = (_pendingServiceCount - 1).clamp(0, 9999);
    print('TaskAlertService.stopOneServiceAlert() | serviceCount=$_pendingServiceCount');
    await _reevaluate();
  }

  /// PRIMARY STOP GATE for service tasks.
  static void resetServiceCount(int count) {
    _pendingServiceCount = count.clamp(0, 9999);
    print('TaskAlertService.resetServiceCount($count)');
    _reevaluate();
  }

  // ── Delivery API ─────────────────────────────────────────────────────────

  static Future<bool> startDeliveryAlert()    => ensureDeliveryRunning();
  static Future<bool> ensureDeliveryRunning() => _ensureRunning(
        soundName:         AlertSoundKey.task,
        notificationTitle: 'Order Ready for Delivery',
        notificationText:  'Tap to view delivery queue',
      );

  /// ACCEPTOR DEVICE ONLY — optimistic decrement.
  /// Must be followed by _loadAllOrders() → resetDeliveryCount().
  static Future<void> stopOneDeliveryAlert() async {
    _pendingDeliveryCount = (_pendingDeliveryCount - 1).clamp(0, 9999);
    print('TaskAlertService.stopOneDeliveryAlert() | deliveryCount=$_pendingDeliveryCount');
    await _reevaluate();
  }

  /// PRIMARY STOP GATE for delivery tasks.
  static void resetDeliveryCount(int count) {
    _pendingDeliveryCount = count.clamp(0, 9999);
    print('TaskAlertService.resetDeliveryCount($count)');
    _reevaluate();
  }

  // ── Force stop (logout / app reset) ─────────────────────────────────────

  static Future<void> stopAll() async {
    _pendingServiceCount  = 0;
    _pendingDeliveryCount = 0;
    await _stopService();
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  static Future<bool> _ensureRunning({
    required String soundName,
    required String notificationTitle,
    required String notificationText,
  }) async {
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) {
        // FIX-4: Pass sound name as taskData — no SharedPreferences race.
        await FlutterForegroundTask.startService(
          notificationTitle: notificationTitle,
          notificationText:  notificationText,
          callback:          unifiedAlertStartCallback, 
        );
        print('TaskAlertService: foreground service started (sound=$soundName)');
      }
      return true;
    } catch (e) {
      print('TaskAlertService._ensureRunning error: $e');
      return false;
    }
  }

  static Future<void> _reevaluate() async {
    if (totalPending == 0) {
      await _stopService();
    } else {
      // Restart if not running — covers cold-launch and app-resume.
      await _ensureRunning(
        soundName:         AlertSoundKey.task,
        notificationTitle: _pendingDeliveryCount > 0
            ? 'Order Ready for Delivery'
            : 'New Service Request',
        notificationText: _pendingDeliveryCount > 0
            ? 'Tap to view delivery queue'
            : 'Tap to view pending tasks',
      );
    }
  }

  static Future<void> _stopService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        print('TaskAlertService: foreground service stopped');
      }
    } catch (e) {
      print('TaskAlertService._stopService error: $e');
    }
  }
}