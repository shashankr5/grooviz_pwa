// notification_handler.dart  (UPDATED)
//
// Foreground FCM handler. Routes all three alert types while the app is open.
// Two Android notification channels are registered:
//   high_importance_channel  → food orders  (bell_notification sound)
//   task_alert_channel       → service tasks & delivery (task_notification sound)

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../utils/order_alert_sound.dart';
import '../services/order_alert_service.dart';
import '../services/task_alert_service.dart';   // ← NEW
import 'fcm_service.dart';

final FlutterLocalNotificationsPlugin localNotifications =
    FlutterLocalNotificationsPlugin();

Future<void> setupFirebaseNotifications() async {
  await _initializeLocalNotifications();

  final messaging = FirebaseMessaging.instance;

  String? token;
  try {
    token = await messaging.getToken();
    print('📱 FCM Token: $token');
  } catch (e) {
    print('⚠️ FCM token fetch failed (will retry automatically): $e');
  }

  // FOREGROUND
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    print('📨 Foreground message');
    if (message.data.isEmpty && message.notification == null) {
      print('⛔ Empty message ignored');
      return;
    }
    _showNotification(message);
  });

  // TERMINATED → tapped notification opens app
  final initialMessage = await messaging.getInitialMessage();
  if (initialMessage != null) {
    print('🚀 Opened from terminated');
    _handleMessage(initialMessage);
  }

  // BACKGROUND → TAP
  FirebaseMessaging.onMessageOpenedApp.listen(_handleMessage);
}

Future<void> _initializeLocalNotifications() async {
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings iosSettings =
      DarwinInitializationSettings();

  await localNotifications.initialize(
    const InitializationSettings(android: androidSettings, iOS: iosSettings),
  );
}

Future<void> createNotificationChannel() async {
  final plugin = localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  // Food order channel (existing)
  await plugin?.createNotificationChannel(const AndroidNotificationChannel(
    'high_importance_channel',
    'High Importance Notifications',
    description: 'Alerts for new food orders.',
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('bell_notification'),
  ));

  // Service task & delivery channel (NEW)
  await plugin?.createNotificationChannel(const AndroidNotificationChannel(
    'task_alert_channel',
    'Task & Delivery Alerts',
    description: 'Alerts for new service requests and ready delivery orders.',
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('task_notification'),
  ));

  // Foreground service channel (existing)
  await plugin?.createNotificationChannel(const AndroidNotificationChannel(
    'order_alert_service',
    'Order Alert Service',
    description: 'Foreground service for order and task alerts.',
    importance: Importance.high,
    playSound: false,
  ));
}

// ── Notification details helpers ──────────────────────────────────────────

const _foodOrderDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'high_importance_channel',
    'High Importance Notifications',
    channelDescription: 'Alerts for new food orders.',
    importance: Importance.max,
    priority: Priority.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('bell_notification'),
  ),
  iOS: DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
  ),
);

const _taskAlertDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'task_alert_channel',
    'Task & Delivery Alerts',
    channelDescription: 'Alerts for new service requests and delivery orders.',
    importance: Importance.max,
    priority: Priority.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('task_notification'),
  ),
  iOS: DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
  ),
);

// ── Main notification handler ─────────────────────────────────────────────

Future<void> _showNotification(RemoteMessage message) async {
  final data  = message.data;
  final title = data['title'] ?? '📢 Notification';
  final body  = data['body'] ?? data['message'] ?? '';
  final type  = (data['type'] ?? '').toString();

  print('🎯 Foreground notification | type=$type');

  final stopAlert = (data['stop_alert'] ?? '').toString().toLowerCase();

  // Route to correct alert service
  switch (type) {
    // Food orders
    case 'NEW_FOOD_ORDER':
      await OrderAlertService.start();
      OrderAlertService.notifyNewOrder();
      break;
    case 'ORDER_ACCEPTED':
      if (stopAlert == 'true') await OrderAlertService.stopOne();
      break;
    case 'ORDER_DELIVERED':
      await OrderAlertService.stop();
      break;

    // Service tasks
    case 'NEW_SERVICE_TASK':
      await TaskAlertService.startServiceAlert();
      TaskAlertService.notifyNewTask();
      break;
    case 'SERVICE_TASK_ACCEPTED':
      if (stopAlert == 'true') await TaskAlertService.stopOneServiceAlert();
      break;

    // Delivery
    case 'NEW_DELIVERY_TASK':
      await TaskAlertService.startDeliveryAlert();
      TaskAlertService.notifyNewDelivery();
      break;
    case 'DELIVERY_ACCEPTED':
      if (stopAlert == 'true') await TaskAlertService.stopOneDeliveryAlert();
      break;
    case 'DELIVERY_DELIVERED':
      await TaskAlertService.stopOneDeliveryAlert();
      break;
  }

  // Show the visible notification banner
  final isTaskType = type == 'NEW_SERVICE_TASK'  ||
                     type == 'SERVICE_TASK_ACCEPTED' ||
                     type == 'NEW_DELIVERY_TASK'  ||
                     type == 'DELIVERY_ACCEPTED'  ||
                     type == 'DELIVERY_DELIVERED';

  localNotifications.show(
    message.hashCode,
    title,
    body,
    isTaskType ? _taskAlertDetails : _foodOrderDetails,
    payload: data.toString(),
  );
}

void _handleMessage(RemoteMessage message) {
  print('👆 Notification tapped | type=${message.data['type']}');

  switch (message.data['type']) {
    case 'NEW_FOOD_ORDER':
      OrderAlertService.notifyNewOrder();
      break;
    case 'NEW_SERVICE_TASK':
      TaskAlertService.notifyNewTask();
      break;
    case 'NEW_DELIVERY_TASK':
      TaskAlertService.notifyNewDelivery();
      break;
  }
}