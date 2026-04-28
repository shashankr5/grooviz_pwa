// fcm_background.dart
//
// Background FCM handler. Handles all three alert categories:
//
//   FOOD ORDERS   : NEW_FOOD_ORDER, ORDER_ACCEPTED, ORDER_DELIVERED,
//                   ORDER_STATUS_CHANGED
//   SERVICE TASKS : NEW_SERVICE_TASK, SERVICE_TASK_ACCEPTED
//   DELIVERY      : NEW_DELIVERY_TASK, DELIVERY_ACCEPTED, DELIVERY_DELIVERED

import 'package:com.tekchant.screensyncmobileapp/services/order_alert_service.dart';
import 'package:com.tekchant.screensyncmobileapp/services/task_alert_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

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
    foregroundTaskOptions: const ForegroundTaskOptions(
      autoRunOnBoot: false,
      allowWakeLock: true,
    ),
  );
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  _initForegroundTask();

  final type      = (message.data['type'] ?? '').toString();
  final stopAlert = (message.data['stop_alert'] ?? '').toString().toLowerCase();

  print('Background FCM | type=$type | stop_alert=$stopAlert');

  switch (type) {

    // ── Food order alerts (unchanged) ────────────────────────────────────
    case 'NEW_FOOD_ORDER':
      await OrderAlertService.start();
      return;

    case 'ORDER_ACCEPTED':
      if (stopAlert == 'true') await OrderAlertService.stopOne();
      return;

    case 'ORDER_DELIVERED':
      await OrderAlertService.stop();
      return;

    case 'ORDER_STATUS_CHANGED':
      // READY / PREPARING status changes — no food alert action
      return;

    // ── Service task alerts ──────────────────────────────────────────────
    // NEW_SERVICE_TASK is sent by the Lambda that creates service requests
    // (the whatsapp bot / guest TV Lambda), NOT by get_tasks_mobile.
    case 'NEW_SERVICE_TASK':
      await TaskAlertService.startServiceAlert();
      TaskAlertService.notifyNewTask(); // triggers HomePage to call _loadTasks()
      return;

    // Sent by accept_task Lambda when a staff member accepts the task.
    case 'SERVICE_TASK_ACCEPTED':
      if (stopAlert == 'true') await TaskAlertService.stopOneServiceAlert();
      return;

    // ── Delivery alerts ───────────────────────────────────────────────────
    // NEW_DELIVERY_TASK is sent by update_food_order_status Lambda when
    // the kitchen marks an order READY — room service must now pick it up.
    case 'NEW_DELIVERY_TASK':
      await TaskAlertService.startDeliveryAlert();
      TaskAlertService.notifyNewDelivery(); // triggers DeliveryPage to reload
      return;

    // Sent when room service accepts the order (picks it up from kitchen).
    case 'DELIVERY_ACCEPTED':
      if (stopAlert == 'true') await TaskAlertService.stopOneDeliveryAlert();
      return;

    // Sent when the order is delivered — safety net to clear any lingering alert.
    case 'DELIVERY_DELIVERED':
      await TaskAlertService.stopOneDeliveryAlert();
      return;

    default:
      print('Background FCM: unhandled type=$type');
      return;
  }
}