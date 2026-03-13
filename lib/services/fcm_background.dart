//fcm_background.dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'order_alert_service.dart';


bool _hasPendingOrders(RemoteMessage message) {
  final value = (message.data['has_pending_orders'] ?? '').toString().toLowerCase();
  return value == 'true' || value == '1' || value == 'yes';
}


@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  // 🔥 MUST initialize foreground task in background isolate
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

  // Ignore empty system messages
  if (message.data.isEmpty && message.notification == null) {
    return;
  }

  print('📩 Background message received');
  print('Title: ${message.notification?.title}');
  print('Data: ${message.data}');

  final type = message.data['type'];

  if (type == 'NEW_FOOD_ORDER') {
    await OrderAlertService.start();
    return;
  }

  if (type == 'FOOD_ORDER_STATUS_CHANGED') {
    if (!_hasPendingOrders(message)) {
      await OrderAlertService.stop();
   }
  }
}