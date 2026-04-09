import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'order_alert_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  // 🔥 Foreground service init (for food orders)
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

  // Ignore empty messages
  if (message.data.isEmpty && message.notification == null) {
    return;
  }

  print('📩 Background message received');
  print('Data: ${message.data}');

  final type = message.data['type'];

  // ✅ CASE 1: FOOD ORDER → START LOOP SOUND
  if (type == 'NEW_FOOD_ORDER') {
    await OrderAlertService.start();
    return;
  }

  // ✅ CASE 2: SERVICE REQUEST → SHOW NORMAL NOTIFICATION

  try {
    final FlutterLocalNotificationsPlugin notifications =
        FlutterLocalNotificationsPlugin();

    // 🔥 MUST initialize inside background isolate
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initSettings =
        InitializationSettings(android: androidSettings);

    await notifications.initialize(initSettings);

    await notifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      message.data['title'] ?? '📢 New Service Request',
      message.data['body'] ?? message.data['message'] ?? '',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'high_importance_channel',
          'High Importance Notifications',
          channelDescription:
              'This channel is used for important notifications.',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
        ),
      ),
    );

    print('✅ Background service request notification shown');
  } catch (e) {
    print('❌ Background notification failed: $e');
  }
}