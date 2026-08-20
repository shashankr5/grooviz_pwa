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
  static int _escalationCount      = 0;

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
  static final StreamController<int>  _escalationController =
      StreamController.broadcast();               // emits badge count

  static Stream<void> get onNewTask       => _newTaskController.stream;
  static Stream<void> get onNewDelivery   => _newDeliveryController.stream;
  static Stream<int>  get onEscalation    => _escalationController.stream;

  static void notifyNewTask()     => _newTaskController.add(null);
  static void notifyNewDelivery() => _newDeliveryController.add(null);

  // ── Service task API ─────────────────────────────────────────────────────

  static Future<bool> startServiceAlert()    => ensureServiceRunning();
  static Future<bool> ensureServiceRunning() => _ensureRunning(
        soundName:         AlertSoundKey.task,
        shouldLoop:        false,
        notificationTitle: 'New Service Request',
        notificationText:  'Tap to view pending tasks',
      );

  /// ACCEPTOR DEVICE ONLY — optimistic decrement.
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
  //
  // CHANGE: now uses AlertSoundKey.delivery ('delivery_notification')
  // instead of AlertSoundKey.task so delivery orders play their own
  // distinct ascending-triad sound.

  static Future<bool> startDeliveryAlert()    => ensureDeliveryRunning();
  static Future<bool> ensureDeliveryRunning() => _ensureRunning(
        soundName:         AlertSoundKey.delivery,   // CHANGED from .task
        shouldLoop:        false,
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
  static void resetDeliveryCount(int count) {
    _pendingDeliveryCount = count.clamp(0, 9999);
    print('TaskAlertService.resetDeliveryCount($count)');
    _reevaluate();
  }

  // ── Escalation API ───────────────────────────────────────────────────────
  //
  // NEW: plays escalation_notification.wav exactly ONCE to the escalation
  // recipient. Does NOT loop. Service stays alive as a silent watcher so
  // subsequent FCMs can trigger more plays if needed.

  static Future<bool> ensureEscalationRunning() => _ensureRunning(
        soundName:         AlertSoundKey.escalation,
        shouldLoop:        false,                  // play once, no loop
        notificationTitle: 'Task Escalated',
        notificationText:  'A task requires your attention',
      );

  /// Called when the server reports a new escalation badge count.
  static void resetEscalationCount(int count) {
    _escalationCount = count.clamp(0, 9999);
    print('TaskAlertService.resetEscalationCount($count)');
    _escalationController.add(_escalationCount);
  }

  // ── NEW: Called by WebSocket ESCALATION_ALERT handler ────────────────────
  //
  // Emits the server-provided badge_count on the onEscalation stream so
  // HomePage and TasksPage update their badge counts and escalated task
  // lists in real time without a manual reload.
  static void notifyEscalation(int badgeCount) {
    _escalationCount = badgeCount.clamp(0, 9999);
    if (!_escalationController.isClosed) {
      _escalationController.add(badgeCount);
    }
    print('TaskAlertService.notifyEscalation($badgeCount)');
  }

  static int get escalationCount => _escalationCount;

  // ── Force stop (logout / app reset) ─────────────────────────────────────

  static Future<void> stopAll() async {
    _pendingServiceCount  = 0;
    _pendingDeliveryCount = 0;
    _escalationCount      = 0;
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
    // If OrderAlertService has pending food orders, food orders take priority
    if (OrderAlertService.pendingOrderCount > 0) {
      await OrderAlertService.ensureRunning();
      return;
    }

    if (totalPending == 0) {
      await _stopService();
    } else {
      // Restart if not running — covers cold-launch and app-resume.
      await _ensureRunning(
        soundName:         _pendingDeliveryCount > 0
            ? AlertSoundKey.delivery
            : AlertSoundKey.task,
        shouldLoop:        true,
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
