// notification_handler.dart — FINAL
//
// Foreground FCM handler.
//
// KEY CHANGE: All NEW_* events call ensureRunning() (no counter).
// All ACCEPTED/CANCELLED events call notify*() which triggers coordinator
// and page reloads → resetCount(serverValue).
// stopOne() is NEVER called here — it belongs only on the acceptor device
// inside the page action, and even there only for service/cancel flows.
// For food order accept, _loadFoodOrders() → resetCount() is called directly.

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../services/order_alert_service.dart';
import '../services/task_alert_service.dart';

final FlutterLocalNotificationsPlugin localNotifications =
    FlutterLocalNotificationsPlugin();

Future<void> setupFirebaseNotifications() async {
  await _initializeLocalNotifications();

  final messaging = FirebaseMessaging.instance;

  try {
    final token = await messaging.getToken();
    print('📱 FCM Token: $token');
  } catch (e) {
    print('⚠️ FCM token fetch failed: $e');
  }

  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    if (message.data.isEmpty && message.notification == null) return;
    _showNotification(message);
  });

  final initialMessage = await messaging.getInitialMessage();
  if (initialMessage != null) _handleMessage(initialMessage);

  FirebaseMessaging.onMessageOpenedApp.listen(_handleMessage);
}

Future<void> _initializeLocalNotifications() async {
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings iosSettings = DarwinInitializationSettings();
  await localNotifications.initialize(
    const InitializationSettings(android: androidSettings, iOS: iosSettings),
  );
}

Future<void> createNotificationChannel() async {
  final plugin = localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  await plugin?.createNotificationChannel(const AndroidNotificationChannel(
    'high_importance_channel', 'High Importance Notifications',
    description: 'Alerts for new food orders.',
    importance: Importance.max, playSound: true,
    sound: RawResourceAndroidNotificationSound('bell_notification'),
  ));
  await plugin?.createNotificationChannel(const AndroidNotificationChannel(
    'task_alert_channel', 'Task & Delivery Alerts',
    description: 'Alerts for service requests and delivery orders.',
    importance: Importance.max, playSound: true,
    sound: RawResourceAndroidNotificationSound('task_notification'),
  ));
  await plugin?.createNotificationChannel(const AndroidNotificationChannel(
    'order_alert_service', 'Order Alert Service',
    description: 'Foreground service for order and task alerts.',
    importance: Importance.high, playSound: false,
  ));
}

const _foodOrderDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'high_importance_channel', 'High Importance Notifications',
    channelDescription: 'Alerts for new food orders.',
    importance: Importance.max, priority: Priority.high, playSound: true,
    sound: RawResourceAndroidNotificationSound('bell_notification'),
  ),
  iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
);

const _taskAlertDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'task_alert_channel', 'Task & Delivery Alerts',
    channelDescription: 'Alerts for service requests and delivery orders.',
    importance: Importance.max, priority: Priority.high, playSound: true,
    sound: RawResourceAndroidNotificationSound('task_notification'),
  ),
  iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
);

Future<void> _showNotification(RemoteMessage message) async {
  final data  = message.data;
  final title = data['title'] ?? message.notification?.title ?? '📢 Notification';
  final body  = data['body']  ?? message.notification?.body  ?? data['message'] ?? '';
  final type  = (data['type'] ?? '').toString();

  print('🎯 Foreground FCM | type=$type');

  bool isTaskType = false;

  switch (type) {

    // ── Food order alerts ──────────────────────────────────────────────────

    case 'NEW_FOOD_ORDER':
      // ensureRunning() — no counter increment. If WS already started it,
      // this is a no-op (service already running). No double-increment.
      await OrderAlertService.ensureRunning();
      OrderAlertService.notifyNewOrder();
      break;

    case 'ORDER_ACCEPTED':
      // Do NOT call stopOne(). The acceptor device calls _loadFoodOrders()
      // directly after accept, which calls resetCount(serverPending).
      // Non-acceptor devices: notifyNewOrder() → coordinator + page reload
      // → resetCount(serverPending).
      OrderAlertService.notifyNewOrder();
      break;

    case 'ORDER_CANCELLED':
      // Same: let reload + resetCount decide whether to stop.
      OrderAlertService.notifyNewOrder();
      break;

    case 'ORDER_DELIVERED':
      await OrderAlertService.stop();
      break;

    case 'ORDER_STATUS_CHANGED':
      // READY / PREPARING — no alert action.
      break;

    // ── Service task alerts ────────────────────────────────────────────────

    case 'NEW_SERVICE_TASK':
      isTaskType = true;
      await TaskAlertService.ensureServiceRunning();
      TaskAlertService.notifyNewTask();
      break;

    case 'SERVICE_TASK_ACCEPTED':
      isTaskType = true;
      // Do NOT call stopOneServiceAlert() on non-acceptor devices.
      // home_page._acceptTask() calls it on the acceptor after the API call,
      // then _loadTasks() → resetServiceCount() confirms for all.
      TaskAlertService.notifyNewTask();
      break;

    // ── Delivery alerts ────────────────────────────────────────────────────

    case 'NEW_DELIVERY_TASK':
      isTaskType = true;
      await TaskAlertService.ensureDeliveryRunning();
      TaskAlertService.notifyNewDelivery();
      break;

    case 'DELIVERY_ACCEPTED':
      isTaskType = true;
      // Do NOT call stopOneDeliveryAlert() on non-acceptor devices.
      TaskAlertService.notifyNewDelivery();
      break;

    case 'DELIVERY_DELIVERED':
      isTaskType = true;
      TaskAlertService.notifyNewDelivery();
      break;

    default:
      print('Foreground FCM: unhandled type=$type');
  }

  await localNotifications.show(
    message.hashCode, title, body,
    isTaskType ? _taskAlertDetails : _foodOrderDetails,
    payload: data.toString(),
  );
}

void _handleMessage(RemoteMessage message) {
  print('👆 Notification tapped | type=${message.data['type']}');
  switch (message.data['type']) {
    case 'NEW_FOOD_ORDER':
    case 'ORDER_ACCEPTED':
    case 'ORDER_CANCELLED':
      OrderAlertService.notifyNewOrder();
      break;
    case 'NEW_SERVICE_TASK':
    case 'SERVICE_TASK_ACCEPTED':
      TaskAlertService.notifyNewTask();
      break;
    case 'NEW_DELIVERY_TASK':
    case 'DELIVERY_ACCEPTED':
    case 'DELIVERY_DELIVERED':
      TaskAlertService.notifyNewDelivery();
      break;
  }
}