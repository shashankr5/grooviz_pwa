// services/fcm_background.dart
//
// FIXES APPLIED:
//  FIX-1 (BLOCKER): Removed all AlertReloadCoordinator.instance calls.
//          The background isolate is a separate Dart isolate — it has
//          NO access to main isolate singletons. Calling them silently
//          operated on zero-initialized copies and did nothing.
//          Now the background handler only starts/stops the foreground
//          service. Counts are reset by the coordinator safety poll and
//          didChangeAppLifecycleState when the app foregrounds.
//
//  FIX-2: Added FlutterForegroundTask.stopService() for ORDER_DELIVERED
//          and DELIVERY_DELIVERED — these are definitive stop signals
//          that are safe to act on even from a background isolate.
//
//  FIX-3: Added immediate stop when stop_alert flag is 'true' for
//          ORDER_ACCEPTED, ORDER_CANCELLED, SERVICE_TASK_ACCEPTED,
//          DELIVERY_ACCEPTED. This ensures cross‑device alert silence
//          when another staff member accepts/cancels.

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

  final type = (message.data['type'] ?? '').toString();
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
      // READY / PREPARING — no alert action.
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

    default:
      print('Background FCM: unhandled type=$type');
      return;
  }
}