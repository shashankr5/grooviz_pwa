// fcm_background.dart
import 'package:com.tekchant.screensyncmobileapp/services/order_alert_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  // Initialize foreground task (required for stop() to work in background)
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

  final type = message.data['type'];
  final stopAlert = message.data['stop_alert'];

  print('📩 Background message received');
  print('Type: $type');
  print('stopAlert: $stopAlert');

  if (type == 'NEW_FOOD_ORDER') {
    await OrderAlertService.start();
    return;
  }

  if (type == 'ORDER_ACCEPTED') {
    if (stopAlert == 'true') {
      print('Background: stopping alert for acceptor');
      await OrderAlertService.stop();
    } else {
      print('Background: other user, alert continues');
    }
    return;
  }

  if (type == 'ORDER_DELIVERED') {
    print('Background: order delivered, stopping alert');
    await OrderAlertService.stop();
    return;
  }

  if (type == 'ORDER_STATUS_CHANGED') {
    // READY, PREPARING, etc.
    final hasPending = (message.data['has_pending_orders'] ?? '').toString().toLowerCase() == 'true';
    if (!hasPending) {
      print('Background: no pending orders, stopping alert');
      await OrderAlertService.stop();
    }
    return;
  }

  print('Background: unhandled message type $type');
}