// services/task_alert_service.dart
//
// Task alert service managing service tasks, deliveries, and escalations
// Provides unified interface for all task-related alert sounds

import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'unified_alert_foreground_task.dart';
import 'order_alert_service.dart';

class TaskAlertService {
  static int _serviceTaskCount = 0;
  static int _deliveryCount = 0;
  static bool _escalationActive = false;

  static final StreamController<void> _newTaskController = StreamController.broadcast();
  static final StreamController<void> _newDeliveryController = StreamController.broadcast();

  static Stream<void> get onNewTask => _newTaskController.stream;
  static Stream<void> get onNewDelivery => _newDeliveryController.stream;

  static void notifyNewTask() => _newTaskController.add(null);
  static void notifyNewDelivery() => _newDeliveryController.add(null);

  static int get totalPending => _serviceTaskCount + _deliveryCount;
  static int get serviceTaskCount => _serviceTaskCount;
  static int get deliveryCount => _deliveryCount;
  static bool get escalationActive => _escalationActive;

  // ── Public API ──────────────────────────────────────────────────────────

  static Future<bool> ensureServiceRunning() => _ensureRunning(
        soundName: AlertSoundKey.task,
        notificationTitle: 'Service Request',
        notificationText: 'Waiting for assignment...',
      );

  static Future<bool> ensureDeliveryRunning() => _ensureRunning(
        soundName: AlertSoundKey.delivery,
        notificationTitle: 'Delivery Ready',
        notificationText: 'Order ready for delivery...',
      );

  static Future<bool> ensureEscalationRunning() => _ensureRunning(
        soundName: AlertSoundKey.escalation,
        notificationTitle: 'Escalation Alert',
        notificationText: 'SLA breach requires attention...',
      );

  /// Stop one delivery alert optimistically
  static Future<void> stopOneDeliveryAlert() async {
    _deliveryCount = (_deliveryCount - 1).clamp(0, 9999);
    print('TaskAlertService.stopOneDeliveryAlert() | deliveryCount=$_deliveryCount');
    await _reevaluate();
  }

  /// Stop one service alert optimistically
  static Future<void> stopOneServiceAlert() async {
    _serviceTaskCount = (_serviceTaskCount - 1).clamp(0, 9999);
    print('TaskAlertService.stopOneServiceAlert() | serviceCount=$_serviceTaskCount');
    await _reevaluate();
  }

  /// Stop escalation alerts
  static Future<void> stopEscalation() async {
    _escalationActive = false;
    print('TaskAlertService.stopEscalation() | escalation=false');
    await _reevaluate();
  }

  /// Stop all task-related alerts
  static Future<void> stopAll() async {
    _serviceTaskCount = 0;
    _deliveryCount = 0;
    _escalationActive = false;
    print('TaskAlertService.stopAll() | all counts reset');
    await _reevaluate();
  }

  /// Reset service task count from server data
  static void resetServiceCount(int count, {bool reconcileAlert = false}) {
    _serviceTaskCount = count.clamp(0, 9999);
    print('TaskAlertService.resetServiceCount($count)');
    if (count <= 0 || reconcileAlert) _reevaluate();
  }

  /// Reset delivery count from server data
  static void resetDeliveryCount(int count, {bool reconcileAlert = false}) {
    _deliveryCount = count.clamp(0, 9999);
    print('TaskAlertService.resetDeliveryCount($count)');
    if (count <= 0 || reconcileAlert) _reevaluate();
  }

  /// Set escalation status from server data
  static void setEscalationActive(bool active, {bool reconcileAlert = false}) {
    _escalationActive = active;
    print('TaskAlertService.setEscalationActive($active)');
    if (!active || reconcileAlert) _reevaluate();
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
          await prefs.setString(AlertSoundKey.loopKey, 'true');

          final isRunning = await FlutterForegroundTask.isRunningService;
          if (isRunning) {
            await FlutterForegroundTask.restartService();
            print('TaskAlertService: foreground service restarted (sound=$soundName)');
          } else {
            await FlutterForegroundTask.startService(
              notificationTitle: notificationTitle,
              notificationText: notificationText,
              callback: unifiedAlertStartCallback,
            );
            print('TaskAlertService: foreground service started (sound=$soundName)');
          }
          return true;
        } catch (e) {
          print('TaskAlertService._ensureRunning error: $e');
          return false;
        }
      },
    );
  }

  static Future<void> _reevaluate() async {
    // Stop service only if no pending items remain
    if (_serviceTaskCount > 0) return;
    if (_deliveryCount > 0) return;
    if (_escalationActive) return;
    if (OrderAlertService.pendingOrderCount > 0) return;
    
    await _stopService();
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