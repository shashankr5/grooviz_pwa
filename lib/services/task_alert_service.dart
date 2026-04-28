// services/task_alert_service.dart
//
// Alert service for:
//   • SERVICE TASKS  — a new guest service request arrived (e.g. water bottle,
//                      housekeeping) and needs staff to accept it.
//   • DELIVERY TASKS — a food order is marked READY and room service needs
//                      to pick it up.
//
// Design mirrors OrderAlertService exactly:
//   • Two independent counters: _pendingServiceCount / _pendingDeliveryCount
//   • One shared foreground service (TaskAlertTaskHandler)
//   • Service stays alive as long as EITHER counter > 0
//   • Broadcast streams let the UI refresh its list on new alerts

import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'task_alert_foreground_task.dart';

class TaskAlertService {
  // ── Pending counters ────────────────────────────────────────────────────
  static int _pendingServiceCount  = 0; // unaccepted service tasks
  static int _pendingDeliveryCount = 0; // ready orders not yet picked up

  // ── Broadcast streams — UI subscribes to refresh its list ───────────────
  static final StreamController<void> _newTaskController =
      StreamController.broadcast();
  static final StreamController<void> _newDeliveryController =
      StreamController.broadcast();

  static Stream<void> get onNewTask     => _newTaskController.stream;
  static Stream<void> get onNewDelivery => _newDeliveryController.stream;

  /// Call this (from FCM handler or WebSocket) to notify the UI to reload tasks.
  static void notifyNewTask()     => _newTaskController.add(null);

  /// Call this (from FCM handler or WebSocket) to notify the UI to reload delivery orders.
  static void notifyNewDelivery() => _newDeliveryController.add(null);

  // ════════════════════════════════════════════════════════════════════════
  //  SERVICE TASK API
  //  Call startServiceAlert() when NEW_SERVICE_TASK FCM arrives.
  //  Call stopOneServiceAlert() when the task is accepted (In Progress).
  //  Call resetServiceCount() after _loadTasks() so the count matches reality.
  // ════════════════════════════════════════════════════════════════════════

  static Future<bool> startServiceAlert() async {
    _pendingServiceCount++;
    print('TaskAlertService.startServiceAlert() | serviceCount=$_pendingServiceCount');
    return _ensureRunning(
      notificationTitle: 'New Service Request',
      notificationText:  'Tap to view pending tasks',
    );
  }

  static Future<void> stopOneServiceAlert() async {
    _pendingServiceCount = (_pendingServiceCount - 1).clamp(0, 9999);
    print('TaskAlertService.stopOneServiceAlert() | serviceCount=$_pendingServiceCount');
    await _reevaluate();
  }

  /// Call after _loadTasks() with the authoritative open-task count from the API.
  static void resetServiceCount(int count) {
    _pendingServiceCount = count.clamp(0, 9999);
    print('TaskAlertService.resetServiceCount($count)');
    _reevaluate();
  }

  // ════════════════════════════════════════════════════════════════════════
  //  DELIVERY TASK API
  //  Call startDeliveryAlert() when NEW_DELIVERY_TASK FCM arrives.
  //  Call stopOneDeliveryAlert() when room service accepts or delivers.
  //  Call resetDeliveryCount() after _loadReadyOrders() in DeliveryPage.
  // ════════════════════════════════════════════════════════════════════════

  static Future<bool> startDeliveryAlert() async {
    _pendingDeliveryCount++;
    print('TaskAlertService.startDeliveryAlert() | deliveryCount=$_pendingDeliveryCount');
    return _ensureRunning(
      notificationTitle: 'Order Ready for Delivery',
      notificationText:  'Tap to view delivery queue',
    );
  }

  static Future<void> stopOneDeliveryAlert() async {
    _pendingDeliveryCount = (_pendingDeliveryCount - 1).clamp(0, 9999);
    print('TaskAlertService.stopOneDeliveryAlert() | deliveryCount=$_pendingDeliveryCount');
    await _reevaluate();
  }

  /// Call after _loadReadyOrders() with the authoritative ready-order count.
  static void resetDeliveryCount(int count) {
    _pendingDeliveryCount = count.clamp(0, 9999);
    print('TaskAlertService.resetDeliveryCount($count)');
    _reevaluate();
  }

  // ════════════════════════════════════════════════════════════════════════
  //  FORCE STOP — call on logout / app reset
  // ════════════════════════════════════════════════════════════════════════

  static Future<void> stopAll() async {
    _pendingServiceCount  = 0;
    _pendingDeliveryCount = 0;
    await _stopService();
  }

  // ── Internal ────────────────────────────────────────────────────────────

  static int get _totalPending => _pendingServiceCount + _pendingDeliveryCount;

  static Future<bool> _ensureRunning({
    required String notificationTitle,
    required String notificationText,
  }) async {
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) {
        await FlutterForegroundTask.startService(
          notificationTitle: notificationTitle,
          notificationText:  notificationText,
          callback: taskAlertStartCallback,
        );
        print('TaskAlertService: foreground service started');
      } else {
        print('TaskAlertService: service already running, alert continues');
      }
      return true;
    } catch (e) {
      print('TaskAlertService._ensureRunning error: $e');
      return false;
    }
  }

  /// Stop the service only when BOTH counters are zero.
  static Future<void> _reevaluate() async {
    if (_totalPending == 0) {
      await _stopService();
    } else {
      print(
        'TaskAlertService: alert continues '
        '(service=$_pendingServiceCount, delivery=$_pendingDeliveryCount)',
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