// services/fcm_background.dart
//
// CHANGES IN THIS VERSION:
//  FIX-1/2/3 from previous version kept.
//  NEW: Added PULSE case — starts service if not running (sound plays on
//       next foreground onStart via FCM).
//  NEW: Added ESCALATION_ALERT case — starts service (plays once on foreground).
//  NEW: Added ACCEPTED case — stops service immediately (cross-device stop).

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'unified_alert_foreground_task.dart';

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'order_alert_service',
      channelName: 'Order Alert Service',
      channelDescription: 'Plays alert sound for new orders and tasks',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      autoRunOnBoot: false,
      allowWakeLock: true,
      eventAction: ForegroundTaskEventAction.nothing(),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers — safe to call from background isolate (no singleton state)
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _startServiceIfNeeded() async {
  try {
    final isRunning = await FlutterForegroundTask.isRunningService;
    if (!isRunning) {
      await FlutterForegroundTask.startService(
        notificationTitle: 'New Alert',
        notificationText: 'Tap to view',
        callback: unifiedAlertStartCallback,
      );
    }
  } catch (e) {
    print('BG: _startServiceIfNeeded error: $e');
  }
}

Future<void> _stopServiceIfRunning() async {
  try {
    final isRunning = await FlutterForegroundTask.isRunningService;
    if (isRunning) {
      await FlutterForegroundTask.stopService();
    }
  } catch (e) {
    print('BG: _stopServiceIfRunning error: $e');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Background handler entry point
// ─────────────────────────────────────────────────────────────────────────────

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  _initForegroundTask();

  final type      = (message.data['type'] ?? '').toString();
  final stopAlert = message.data['stop_alert'] == 'true';
  print('Background FCM | type=$type | stop_alert=$stopAlert');

  switch (type) {

    // ── Food order alerts ──────────────────────────────────────────────────

    case 'NEW_FOOD_ORDER':
      await _startServiceIfNeeded();
      return;

    case 'ORDER_ACCEPTED':
    case 'ORDER_CANCELLED':
      if (stopAlert) {
        await _stopServiceIfRunning();
        print('BG: $type – service stopped (stop_alert=true)');
      } else {
        print('BG: $type – service will reset on app foreground');
      }
      return;

    case 'ORDER_DELIVERED':
      await _stopServiceIfRunning();
      return;

    case 'ORDER_STATUS_CHANGED':
      final orderStatus = (message.data['order_status'] ?? message.data['status'] ?? '').toString().toUpperCase();
      if (orderStatus == 'READY') {
        await _startServiceIfNeeded();
      }
      return;

    case 'ORDER_READY':
    case 'FOOD_ORDER_READY':
    case 'DELIVERY_READY':
    case 'DELIVERY_NOTIFICATION':
      await _startServiceIfNeeded();
      return;

    // ── Service task alerts ────────────────────────────────────────────────

    case 'NEW_SERVICE_TASK':
      await _startServiceIfNeeded();
      return;

    case 'SERVICE_TASK_ACCEPTED':
      if (stopAlert) {
        await _stopServiceIfRunning();
        print('BG: SERVICE_TASK_ACCEPTED – service stopped (stop_alert=true)');
      } else {
        print('BG: SERVICE_TASK_ACCEPTED – will reset on app foreground');
      }
      return;

    // ── Delivery alerts ────────────────────────────────────────────────────

    case 'NEW_DELIVERY_TASK':
      await _startServiceIfNeeded();
      return;

    case 'DELIVERY_ACCEPTED':
      if (stopAlert) {
        await _stopServiceIfRunning();
        print('BG: DELIVERY_ACCEPTED – service stopped (stop_alert=true)');
      } else {
        print('BG: DELIVERY_ACCEPTED – will reset on app foreground');
      }
      return;

    case 'DELIVERY_DELIVERED':
      await _stopServiceIfRunning();
      return;

    // ── NEW: Lambda pulse ────────────────────────────────────────────────────
    //
    // Sent by EventBridge job for unaccepted tasks. In the background isolate
    // we can only start/stop the service — the actual sound plays in onStart()
    // when the foreground service fires.

    case 'PULSE':
      await _startServiceIfNeeded();
      print('BG: PULSE – service started/kept running for next sound play');
      return;

    // ── NEW: Escalation alert ──────────────────────────────────────────────
    //
    // Sent only to the escalation recipient. Start the service — the
    // UnifiedAlertTaskHandler will play the escalation sound once (no loop).

    case 'ESCALATION_ALERT':
      await _startServiceIfNeeded();
      print('BG: ESCALATION_ALERT – service started for one-shot escalation sound');
      return;

    // ── NEW: Cross-device accept stop ──────────────────────────────────────
    //
    // Lambda broadcasts this after any device accepts a task.
    // Stop the foreground service immediately on all other devices.

    case 'ACCEPTED':
      await _stopServiceIfRunning();
      print('BG: ACCEPTED – foreground service stopped (cross-device)');
      return;

    default:
      print('Background FCM: unhandled type=$type');
      return;
  }
}