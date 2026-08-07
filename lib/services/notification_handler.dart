import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../main.dart';
import '../pages/delivery_page.dart';
import '../pages/main_navigation.dart';
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

  await plugin?.createNotificationChannel(const AndroidNotificationChannel(
    'delivery_alert_channel', 'Delivery Alerts',
    description: 'Alerts for room service delivery orders.',
    importance: Importance.max, playSound: true,
    sound: RawResourceAndroidNotificationSound('delivery_notification'),
  ));

  await plugin?.createNotificationChannel(const AndroidNotificationChannel(
    'escalation_alert_channel', 'Escalation Alerts',
    description: 'Alerts for escalated tasks requiring immediate attention.',
    importance: Importance.max, playSound: true,
    sound: RawResourceAndroidNotificationSound('escalation_notification'),
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

const _deliveryAlertDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'delivery_alert_channel', 'Delivery Alerts',
    channelDescription: 'Alerts for room service delivery orders.',
    importance: Importance.max, priority: Priority.high, playSound: true,
    sound: RawResourceAndroidNotificationSound('delivery_notification'),
  ),
  iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
);

const _escalationAlertDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'escalation_alert_channel', 'Escalation Alerts',
    channelDescription: 'Alerts for escalated tasks.',
    importance: Importance.max, priority: Priority.high, playSound: true,
    sound: RawResourceAndroidNotificationSound('escalation_notification'),
  ),
  iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
);

Future<void> _showNotification(RemoteMessage message) async {
  final data  = message.data;
  final title = data['title'] ?? message.notification?.title ?? '📢 Notification';
  final body  = data['body']  ?? message.notification?.body  ?? data['message'] ?? '';
  final type  = (data['type'] ?? '').toString();

  print('🎯 Foreground FCM | type=$type');

  bool isTaskType       = false;
  bool isDeliveryType   = false;
  bool isEscalationType = false;

  switch (type) {
    case 'NEW_FOOD_ORDER':
      await OrderAlertService.ensureRunning();
      OrderAlertService.notifyNewOrder();
      break;

    case 'ORDER_ACCEPTED':
      OrderAlertService.notifyNewOrder();
      break;

    case 'ORDER_CANCELLED':
      OrderAlertService.notifyNewOrder();
      break;

    case 'ORDER_DELIVERED':
      await OrderAlertService.stop();
      break;

    case 'ORDER_STATUS_CHANGED':
      final orderStatus = (data['order_status'] ?? data['status'] ?? '').toString().toUpperCase();
      if (orderStatus == 'READY') {
        isDeliveryType = true;
        await TaskAlertService.ensureDeliveryRunning();
        TaskAlertService.notifyNewDelivery();
      }
      break;

    case 'ORDER_READY':
    case 'FOOD_ORDER_READY':
    case 'DELIVERY_READY':
    case 'DELIVERY_NOTIFICATION':
      isDeliveryType = true;
      await TaskAlertService.ensureDeliveryRunning();
      TaskAlertService.notifyNewDelivery();
      break;

    case 'NEW_SERVICE_TASK':
      isTaskType = true;
      await TaskAlertService.ensureServiceRunning();
      TaskAlertService.notifyNewTask();
      break;

    case 'SERVICE_TASK_ACCEPTED':
      isTaskType = true;
      TaskAlertService.notifyNewTask();
      break;

    case 'NEW_DELIVERY_TASK':
      isDeliveryType = true;
      await TaskAlertService.ensureDeliveryRunning();
      TaskAlertService.notifyNewDelivery();
      break;

    case 'DELIVERY_ACCEPTED':
      isDeliveryType = true;
      TaskAlertService.notifyNewDelivery();
      break;

    case 'DELIVERY_DELIVERED':
      isDeliveryType = true;
      TaskAlertService.notifyNewDelivery();
      break;

    case 'PULSE':
      final alertType = (data['alert_type'] ?? 'service').toString();
      switch (alertType) {
        case 'food':
          await OrderAlertService.ensureRunning();
          OrderAlertService.notifyNewOrder();
          break;
        case 'delivery':
          isDeliveryType = true;
          await TaskAlertService.ensureDeliveryRunning();
          TaskAlertService.notifyNewDelivery();
          break;
        case 'service':
        default:
          isTaskType = true;
          await TaskAlertService.ensureServiceRunning();
          TaskAlertService.notifyNewTask();
          break;
      }
      break;

    case 'ESCALATION_ALERT':
      isEscalationType = true;
      await TaskAlertService.ensureEscalationRunning();
      final badgeCount = int.tryParse(data['badge_count']?.toString() ?? '0') ?? 0;
      TaskAlertService.resetEscalationCount(badgeCount);
      break;

    case 'ACCEPTED':
      isTaskType = true;
      TaskAlertService.resetServiceCount(0);
      TaskAlertService.notifyNewTask();
      break;

    default:
      print('Foreground FCM: unhandled type=$type');
  }

  NotificationDetails details;
  if (isEscalationType) {
    details = _escalationAlertDetails;
  } else if (isDeliveryType) {
    details = _deliveryAlertDetails;
  } else if (isTaskType) {
    details = _taskAlertDetails;
  } else {
    details = _foodOrderDetails;
  }

  await localNotifications.show(
    message.hashCode, title, body,
    details,
    payload: data.toString(),
  );
}

void _handleMessage(RemoteMessage message) {
  print('👆 Notification tapped | type=${message.data['type']}');
  switch (message.data['type']) {

    // ── Food order taps → Food Orders tab ─────────────────────────────────
    case 'NEW_FOOD_ORDER':
    case 'ORDER_ACCEPTED':
    case 'ORDER_CANCELLED':
      OrderAlertService.notifyNewOrder();
      _navigateToFood();
      break;

    // ── Service task taps → Home tab ───────────────────────────────────────
    case 'NEW_SERVICE_TASK':
    case 'SERVICE_TASK_ACCEPTED':
    case 'ACCEPTED':
      TaskAlertService.notifyNewTask();
      _navigateToHome();
      break;

    case 'ESCALATION_ALERT':
      TaskAlertService.notifyNewTask();
      _navigateToHome();
      break;

    // ── Delivery taps → Delivery page (push) ───────────────────────────────
    case 'NEW_DELIVERY_TASK':
    case 'DELIVERY_ACCEPTED':
    case 'DELIVERY_DELIVERED':
    case 'ORDER_READY':
    case 'FOOD_ORDER_READY':
    case 'DELIVERY_READY':
    case 'DELIVERY_NOTIFICATION':
      TaskAlertService.notifyNewDelivery();
      _navigateToDelivery();
      break;

    case 'ORDER_STATUS_CHANGED':
      final orderStatus = (message.data['order_status'] ?? message.data['status'] ?? '').toString().toUpperCase();
      if (orderStatus == 'READY') {
        TaskAlertService.notifyNewDelivery();
        _navigateToDelivery();
      }
      break;

    // ── PULSE — route by alert_type ────────────────────────────────────────
    case 'PULSE':
      final alertType = (message.data['alert_type'] ?? 'service').toString();
      if (alertType == 'food') {
        OrderAlertService.notifyNewOrder();
        _navigateToFood();
      } else if (alertType == 'delivery') {
        TaskAlertService.notifyNewDelivery();
        _navigateToDelivery();
      } else {
        TaskAlertService.notifyNewTask();
        _navigateToHome();
      }
      break;
  }
}

// ── Navigate to Home tab (service tasks) ─────────────────────────────────────
void _navigateToHome() {
  if (MainNavigation.tabSwitchCallback != null) {
    MainNavigation.tabSwitchCallback!('home');
  } else {
    pendingDeepLinkRoute = 'home';
  }
}

// ── Navigate to Food Orders tab ───────────────────────────────────────────────
void _navigateToFood() {
  if (MainNavigation.tabSwitchCallback != null) {
    MainNavigation.tabSwitchCallback!('food');
  } else {
    pendingDeepLinkRoute = 'food';
  }
}

// ── Navigate to Delivery page (push) ─────────────────────────────────────────
// Case I — app foregrounded/backgrounded: push immediately.
// Case II — cold start (app was killed): stash route, consumed post-frame.
void _navigateToDelivery() {
  final navState = navigatorKey.currentState;
  if (navState != null) {
    navState.push(MaterialPageRoute(builder: (_) => const DeliveryPage()));
  } else {
    pendingDeepLinkRoute = 'delivery';
  }
}