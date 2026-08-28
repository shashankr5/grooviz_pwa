// services/alert_state_manager.dart
//
// SINGLE SOURCE OF TRUTH for all alert state and audio management.
//
// Architecture:
//   FCM/WS events → AlertStateManager → UnifiedAlertTaskHandler
//
// Priority chain: Escalation(4) > Food(3) > Service Task(2) > Delivery(1)
// When a higher-priority alert arrives → sendDataToTask switches sound in-place.
// When the top alert is dismissed → next in chain takes over automatically.

import 'dart:async';
import 'dart:convert';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'unified_alert_foreground_task.dart';
import 'notification_constants.dart';

/// All active alert types ranked by priority.
/// Higher priority wins audio when multiple are active simultaneously.
enum AlertType {
  delivery(1, AlertSoundKey.delivery, NotifId.delivery, 'Delivery Alert', 'Awaiting pickup'),
  serviceTask(2, AlertSoundKey.task, NotifId.serviceTask, 'Service Task', 'Awaiting assignment'),
  foodOrder(3, AlertSoundKey.food, NotifId.foodOrder, 'Food Order', 'Awaiting acceptance'),
  escalation(4, AlertSoundKey.escalation, NotifId.escalation, 'Escalation', 'SLA breach - act now');

  const AlertType(this.priority, this.soundKey, this.notifId, this.title, this.body);
  final int priority;
  final String soundKey;
  final int notifId;
  final String title;
  final String body;
}

class AlertStateManager {
  AlertStateManager._();

  // ── State ────────────────────────────────────────────────────────────────
  static int _foodOrderCount = 0;
  static int _serviceTaskCount = 0;
  static int _deliveryCount = 0;
  static bool _escalationActive = false;
  static AlertType? _currentlyPlaying;

  // ── Getters ──────────────────────────────────────────────────────────────
  static int get foodOrderCount => _foodOrderCount;
  static int get serviceTaskCount => _serviceTaskCount;
  static int get deliveryCount => _deliveryCount;
  static bool get escalationActive => _escalationActive;
  static int get totalPending =>
      _foodOrderCount +
      _serviceTaskCount +
      _deliveryCount +
      (_escalationActive ? 1 : 0);

  // ── UI Streams ───────────────────────────────────────────────────────────
  static final _foodController = StreamController<void>.broadcast();
  static final _taskController = StreamController<void>.broadcast();
  static final _deliveryController = StreamController<void>.broadcast();

  static Stream<void> get onNewFoodOrder => _foodController.stream;
  static Stream<void> get onNewTask => _taskController.stream;
  static Stream<void> get onNewDelivery => _deliveryController.stream;

  static void notifyNewFoodOrder() => _foodController.add(null);
  static void notifyNewTask() => _taskController.add(null);
  static void notifyNewDelivery() => _deliveryController.add(null);

  // ── Setters (batch updates — debounced) ──────────────────────────────────
  static Timer? _syncDebounce;
  static const _syncDelay = Duration(milliseconds: 400);

  static Future<void> setFoodOrderCount(int count, {bool immediate = false}) async {
    _foodOrderCount = count.clamp(0, 9999);
    print('AlertStateManager.setFoodOrderCount($count) immediate=$immediate');
    if (immediate) {
      await _sync();
    } else {
      _scheduleSync();
    }
  }

  static Future<void> setServiceTaskCount(int count, {bool immediate = false}) async {
    _serviceTaskCount = count.clamp(0, 9999);
    print('AlertStateManager.setServiceTaskCount($count) immediate=$immediate');
    if (immediate) {
      await _sync();
    } else {
      _scheduleSync();
    }
  }

  static Future<void> setDeliveryCount(int count, {bool immediate = false}) async {
    _deliveryCount = count.clamp(0, 9999);
    print('AlertStateManager.setDeliveryCount($count) immediate=$immediate');
    if (immediate) {
      await _sync();
    } else {
      _scheduleSync();
    }
  }

  static Future<void> setEscalationActive(bool active, {bool immediate = false}) async {
    _escalationActive = active;
    print('AlertStateManager.setEscalationActive($active) immediate=$immediate');
    if (immediate) {
      await _sync();
    } else {
      _scheduleSync();
    }
  }
  
  /// Force immediate synchronization. Use when the caller needs to ensure
  /// the alert state is applied before returning (e.g., FCM background handler).
  static Future<void> flushSync() async {
    _syncDebounce?.cancel();
    _syncDebounce = null;
    await _sync();
  }

  // ── Increment helpers (for new alerts) ───────────────────────────────────
  static void incrementFoodOrder() {
    _foodOrderCount = (_foodOrderCount + 1).clamp(0, 9999);
    print('AlertStateManager.incrementFoodOrder() -> $_foodOrderCount');
    _scheduleSync();
  }

  static void incrementServiceTask() {
    _serviceTaskCount = (_serviceTaskCount + 1).clamp(0, 9999);
    print('AlertStateManager.incrementServiceTask() -> $_serviceTaskCount');
    _scheduleSync();
  }

  static void incrementDelivery() {
    _deliveryCount = (_deliveryCount + 1).clamp(0, 9999);
    print('AlertStateManager.incrementDelivery() -> $_deliveryCount');
    _scheduleSync();
  }

  // ── Dismissals (immediate — no debounce) ─────────────────────────────────
  static Future<void> dismissFoodOrder() async {
    _foodOrderCount = (_foodOrderCount - 1).clamp(0, 9999);
    print('AlertStateManager.dismissFoodOrder() -> $_foodOrderCount');
    await _sync();
  }

  static Future<void> dismissServiceTask() async {
    _serviceTaskCount = (_serviceTaskCount - 1).clamp(0, 9999);
    print('AlertStateManager.dismissServiceTask() -> $_serviceTaskCount');
    await _sync();
  }

  static Future<void> dismissDelivery() async {
    _deliveryCount = (_deliveryCount - 1).clamp(0, 9999);
    print('AlertStateManager.dismissDelivery() -> $_deliveryCount');
    await _sync();
  }

  static Future<void> dismissEscalation() async {
    _escalationActive = false;
    print('AlertStateManager.dismissEscalation()');
    await _sync();
  }

  static Future<void> dismissAll() async {
    _foodOrderCount = 0;
    _serviceTaskCount = 0;
    _deliveryCount = 0;
    _escalationActive = false;
    print('AlertStateManager.dismissAll()');
    await _sync();
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  static void _scheduleSync() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(_syncDelay, _sync);
  }

  static Future<void> _sync() async {
    _syncDebounce?.cancel();
    _syncDebounce = null;

    final target = _highestPriority();

    if (target == null) {
      _currentlyPlaying = null;
      await _stopService();
      await _clearAllNotifications();
      print('AlertStateManager._sync: all clear - service stopped');
      return;
    }

    // No per-type status bar notifications — the foreground service
    // notification already tells staff something is alerting.
    // _syncNotifications() was removed to avoid notification shade clutter.

    if (_currentlyPlaying == target) {
      print('AlertStateManager._sync: already playing ${target.soundKey} - no change');
      return;
    }

    _currentlyPlaying = target;
    await _startOrSwitch(target);
  }

  static AlertType? _highestPriority() {
    if (_escalationActive) return AlertType.escalation;
    if (_foodOrderCount > 0) return AlertType.foodOrder;
    if (_serviceTaskCount > 0) return AlertType.serviceTask;
    if (_deliveryCount > 0) return AlertType.delivery;
    return null;
  }

  static Future<void> _startOrSwitch(AlertType type) async {
    // Build count-aware notification text for the foreground service.
    // This is the persistent Android notification required while the service runs.
    final notifTitle = switch (type) {
      AlertType.escalation  => '🚨 Escalation — Immediate action needed',
      AlertType.foodOrder   => '🍽️ New Food Order${_foodOrderCount > 1 ? ' ($_foodOrderCount pending)' : ''}',
      AlertType.serviceTask => '📢 Service Request${_serviceTaskCount > 1 ? ' ($_serviceTaskCount pending)' : ''}',
      AlertType.delivery    => '🚚 Delivery Ready${_deliveryCount > 1 ? ' ($_deliveryCount orders)' : ''}',
    };
    final notifBody = switch (type) {
      AlertType.escalation  => 'SLA breach detected — tap to view',
      AlertType.foodOrder   => 'Awaiting acceptance',
      AlertType.serviceTask => 'Awaiting assignment',
      AlertType.delivery    => 'Awaiting pickup',
    };

    final taskData = jsonEncode({'sound': type.soundKey, 'loop': true});
    final isRunning = await FlutterForegroundTask.isRunningService;

    if (isRunning) {
      // Send new sound to the running handler — no service restart needed
      FlutterForegroundTask.sendDataToTask(taskData);
      await FlutterForegroundTask.updateService(
        notificationTitle: notifTitle,
        notificationText: notifBody,
      );
      print('AlertStateManager._startOrSwitch: switched sound -> ${type.soundKey}');
    } else {
      await FlutterForegroundTask.startService(
        notificationTitle: notifTitle,
        notificationText: notifBody,
        callback: unifiedAlertStartCallback,
      );
      // Send data after starting since taskData parameter may not be available
      await Future.delayed(const Duration(milliseconds: 100));
      FlutterForegroundTask.sendDataToTask(taskData);
      print('AlertStateManager._startOrSwitch: service started -> ${type.soundKey}');
    }
  }

  /// Maintains one silent ongoing notification per active alert type.
  /// These give staff a persistent status-bar view of ALL pending alerts,
  /// while audio is handled exclusively by the foreground service.
  static Future<void> _syncNotifications() async {
    final states = {
      AlertType.escalation: _escalationActive,
      AlertType.foodOrder: _foodOrderCount > 0,
      AlertType.serviceTask: _serviceTaskCount > 0,
      AlertType.delivery: _deliveryCount > 0,
    };

    for (final entry in states.entries) {
      final type = entry.key;
      final isActive = entry.value;

      if (isActive) {
        final countLabel = switch (type) {
          AlertType.foodOrder => ' ($_foodOrderCount pending)',
          AlertType.serviceTask => ' ($_serviceTaskCount pending)',
          AlertType.delivery => ' ($_deliveryCount pending)',
          AlertType.escalation => '',
        };

        await localNotifications.show(
          type.notifId,
          type.title,
          '${type.body}$countLabel',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'alert_status_channel',
              'Alert Status',
              channelDescription: 'Persistent status for active alerts',
              importance: Importance.low,
              priority: Priority.low,
              ongoing: true,
              autoCancel: false,
              playSound: false, // audio is managed by the foreground service
              enableVibration: false,
              showWhen: false,
            ),
          ),
        );
      } else {
        await localNotifications.cancel(type.notifId);
      }
    }
  }

  static Future<void> _clearAllNotifications() async {
    for (final type in AlertType.values) {
      await localNotifications.cancel(type.notifId);
    }
  }

  static Future<void> _stopService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        print('AlertStateManager._stopService: foreground service stopped');
      }
    } catch (e) {
      print('AlertStateManager._stopService error: $e');
    }
  }

  // ── Debug ────────────────────────────────────────────────────────────────
  static void printState() {
    print('AlertStateManager state: food=$_foodOrderCount task=$_serviceTaskCount '
        'delivery=$_deliveryCount escalation=$_escalationActive playing=$_currentlyPlaying');
  }
}
