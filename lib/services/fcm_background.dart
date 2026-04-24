// fcm_background.dart
import 'package:com.tekchant.screensyncmobileapp/services/order_alert_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'order_alert_service',
      channelName: 'Order Alert Service',
      channelDescription: 'Plays alert sound for new orders',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: const ForegroundTaskOptions(
      autoRunOnBoot: false,
      allowWakeLock: true,
    ),
  );

  final type      = (message.data['type'] ?? '').toString();
  final stopAlert = (message.data['stop_alert'] ?? '').toString().toLowerCase();

  print('Background FCM | type=$type | stop_alert=$stopAlert');

  // ── New order → increment count and start alert ──────────────────────────
  // Each order increments independently so multiple orders each ring.
  if (type == 'NEW_FOOD_ORDER') {
    await OrderAlertService.start(); // increments count inside
    return;
  }

  // ── Order accepted ───────────────────────────────────────────────────────
  // Lambda sends stop_alert:'true' for all users (acceptor + others).
  // We decrement by 1 — if more orders still pending, alert keeps ringing.
  if (type == 'ORDER_ACCEPTED') {
    if (stopAlert == 'true') {
      await OrderAlertService.stopOne(); // decrements; stops only if count == 0
    }
    return;
  }

  // ── Order delivered → force stop (no pending concept at this stage) ──────
  if (type == 'ORDER_DELIVERED') {
    await OrderAlertService.stop();
    return;
  }

  // ── Status changed (READY, PREPARING) → no alert change ─────────────────
  if (type == 'ORDER_STATUS_CHANGED') {
    return;
  }
}