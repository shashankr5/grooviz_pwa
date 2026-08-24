// services/task_alert_service.dart
//
// CHANGES IN THIS VERSION:
//  • ensureDeliveryRunning() now uses AlertSoundKey.delivery (was .task)
//  • Added _escalationCount + resetEscalationCount()
//  • Added notifyEscalation() – called by WebSocket ESCALATION_ALERT handler
//  • Added ensureEscalationRunning() — plays escalation sound once, no loop
//  • stopAll() also resets _escalationCount

import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'unified_alert_foreground_task.dart';
import 'order_alert_service.dart';

class TaskAlertService {
  TaskAlertService._();

  static int _pendingServiceCount  = 0;
  static int _pendingDeliveryCount = 0;

  static int get totalPending =>
      _pendingServiceCount + _pendingDeliveryCount;

  static int get pendingServiceCount => _pendingServiceCount;
  static int get pendingDeliveryCount => _pendingDeliveryCount;

  static Future<void> reevaluate() => _reevaluate();

  // ── Streams ─────────────────────────────────────────────────────────────
  static final StreamController<void> _newTaskController =
      StreamController.broadcast();
  static final StreamController<void> _newDeliveryController =
      StreamController.broadcast();

  static Stream<void> get onNewTask       => _newTaskController.stream;
  static Stream<void> get onNewDelivery   => _newDeliveryController.stream;

  static void notifyNewTask()     => _newTaskController.add(null);
  static void notifyNewDelivery() => _newDeliveryController.add(null);

  // ── Service task API ─────────────────────────────────────────────────────

  static Future<bool> startServiceAlert()    => ensureServiceRunning();
  static Future<bool> ensureServiceRunning() => _ensureRunning(
        soundName:         AlertSoundKey.task,
        // Service task alerts loop until explicitly accepted/stopped by any device.
        shouldLoop:        true,
        notificationTitle: 'New Service Request',
        notificationText:  'Tap to view pending tasks',
      );

  /// Escalations are urgent one-time alerts. They never join the normal
  /// service/delivery loop and therefore cannot be restarted by a queue refresh.
  static Future<bool> ensureEscalationRunning() => _ensureRunning(
        soundName: AlertSoundKey.escalation,
        shouldLoop: false,
        notificationTitle: 'Escalation Requires Attention',
        notificationText: 'Tap to review the escalated service request',
      );

  /// ACCEPTOR DEVICE ONLY — optimistic decrement.
  static Future<void> stopOneServiceAlert() async {
    _pendingServiceCount = (_pendingServiceCount - 1).clamp(0, 9999);
    print('TaskAlertService.stopOneServiceAlert() | serviceCount=$_pendingServiceCount');
    await _reevaluate();
  }

  /// PRIMARY STOP GATE for service tasks.
  static void resetServiceCount(
    int count, {
    bool reconcileAlert = false,
  }) {
    _pendingServiceCount = count.clamp(0, 9999);
    print('TaskAlertService.resetServiceCount($count)');
    // Reconciliation must always stop a stale alert at zero. It may only
    // start/restart an alert for a real incoming event.
    if (count <= 0 || reconcileAlert) _reevaluate();
    
    // BUGFIX: If there are pending tasks but no alert is running, start the alert
    // This handles the case where app was killed/restarted with pending tasks
    else if (count > 0) {
      _checkAndStartServiceAlertIfNeeded();
    }
  }

  static Future<void> _checkAndStartServiceAlertIfNeeded() async {
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning && _pendingServiceCount > 0) {
        print('TaskAlertService: Starting alert for existing pending tasks ($_pendingServiceCount)');
        await ensureServiceRunning();
      }
    } catch (e) {
      print('TaskAlertService._checkAndStartServiceAlertIfNeeded error: $e');
    }
  }

  // ── Delivery API ─────────────────────────────────────────────────────────
  //
  // CHANGE: now uses AlertSoundKey.delivery ('delivery_notification')
  // instead of AlertSoundKey.task so delivery orders play their own
  // distinct ascending-triad sound.

  static Future<bool> startDeliveryAlert()    => ensureDeliveryRunning();
  static Future<bool> ensureDeliveryRunning() => _ensureRunning(
        soundName:         AlertSoundKey.delivery,   // CHANGED from .task
        // A Ready order remains actionable until Room Service accepts it.
        // _reevaluate() stops this loop when the Ready queue becomes empty.
        shouldLoop:        true,
        notificationTitle: 'Order Ready for Delivery',
        notificationText:  'Tap to view delivery queue',
      );

  /// ACCEPTOR DEVICE ONLY — optimistic decrement.
  static Future<void> stopOneDeliveryAlert() async {
    _pendingDeliveryCount = (_pendingDeliveryCount - 1).clamp(0, 9999);
    print('TaskAlertService.stopOneDeliveryAlert() | deliveryCount=$_pendingDeliveryCount');
    await _reevaluate();
  }

  /// PRIMARY STOP GATE for delivery tasks.
  static void resetDeliveryCount(
    int count, {
    bool reconcileAlert = false,
  }) {
    _pendingDeliveryCount = count.clamp(0, 9999);
    print('TaskAlertService.resetDeliveryCount($count)');
    if (count <= 0 || reconcileAlert) _reevaluate();
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
    required bool   shouldLoop,
    required String notificationTitle,
    required String notificationText,
  }) async {
    return AlertServiceRestartGate.run(
      soundName: soundName,
      operation: () async {
        try {
          // Write sound preference BEFORE starting service so the handler
          // isolate can read it synchronously in onStart().
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(AlertSoundKey.prefKey, soundName);
          await prefs.setString(
            AlertSoundKey.loopKey,
            shouldLoop ? 'true' : 'false',
          );

          final isRunning = await FlutterForegroundTask.isRunningService;
          if (isRunning) {
            await FlutterForegroundTask.restartService();
            print(
              'TaskAlertService: foreground service restarted '
              '(sound=$soundName, loop=$shouldLoop)',
            );
          } else {
            await FlutterForegroundTask.startService(
              notificationTitle: notificationTitle,
              notificationText: notificationText,
              callback: unifiedAlertStartCallback,
            );
            print(
              'TaskAlertService: foreground service started '
              '(sound=$soundName, loop=$shouldLoop)',
            );
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
    // ARCHITECTURE: _reevaluate() is a STOP-ONLY gate.
    // It NEVER restarts the foreground service — restarts are driven exclusively
    // by FCM/WS new-event handlers (NEW_FOOD_ORDER, NEW_SERVICE_TASK, etc.).
    // This eliminates spurious sound replays triggered by:
    //   • pull-to-refresh (_loadDeliveryCounts → resetDeliveryCount(0) → reevaluate)
    //   • home-icon tap (_refreshCurrentTab → _loadTasks → resetServiceCount)
    //   • post-accept reload (_acceptTask → _loadTasks → resetServiceCount)
    //   • cold-launch reconciliation (AlertReloadCoordinator.reloadTasks)
    if (OrderAlertService.pendingOrderCount > 0) return; // Food pending — service still running
    if (totalPending == 0) {
      await _stopService(); // All clear — stop the foreground service
    }
    // totalPending > 0: service already running and looping — nothing to do
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
