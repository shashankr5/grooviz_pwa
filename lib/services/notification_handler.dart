// notification_handler.dart
//
// CHANGES IN THIS VERSION:
//  • New FCM type: PULSE — reads alert_type from data, calls appropriate
//    ensureRunning() so the play-once foreground service fires fresh audio.
//  • New FCM type: ESCALATION_ALERT — calls ensureEscalationRunning()
//    (plays once) + refreshes badge via TaskAlertService.resetEscalationCount.
//  • New FCM type: ACCEPTED — reads service_request_id, calls
//    TaskAlertService.resetServiceCount(0) for cross-device foreground
//    service stop.
//  • createNotificationChannel() now adds delivery_alert_channel
//    (delivery_notification sound) and escalation_alert_channel
//    (escalation_notification sound).

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

  // ── Existing channels ────────────────────────────────────────────────────

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

  // ── NEW: Delivery alert channel ─────────────────────────────────────────
  await plugin?.createNotificationChannel(const AndroidNotificationChannel(
    'delivery_alert_channel', 'Delivery Alerts',
    description: 'Alerts for room service delivery orders.',
    importance: Importance.max, playSound: true,
    sound: RawResourceAndroidNotificationSound('delivery_notification'),
  ));

  // ── NEW: Escalation alert channel ───────────────────────────────────────
  await plugin?.createNotificationChannel(const AndroidNotificationChannel(
    'escalation_alert_channel', 'Escalation Alerts',
    description: 'Alerts for escalated tasks requiring immediate attention.',
    importance: Importance.max, playSound: true,
    sound: RawResourceAndroidNotificationSound('escalation_notification'),
  ));
}

// ── Notification detail presets ───────────────────────────────────────────

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

// NEW
const _deliveryAlertDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'delivery_alert_channel', 'Delivery Alerts',
    channelDescription: 'Alerts for room service delivery orders.',
    importance: Importance.max, priority: Priority.high, playSound: true,
    sound: RawResourceAndroidNotificationSound('delivery_notification'),
  ),
  iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
);

// NEW
const _escalationAlertDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'escalation_alert_channel', 'Escalation Alerts',
    channelDescription: 'Alerts for escalated tasks.',
    importance: Importance.max, priority: Priority.high, playSound: true,
    sound: RawResourceAndroidNotificationSound('escalation_notification'),
  ),
  iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
);

// ── Main foreground notification handler ─────────────────────────────────

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

    // ── Food order alerts ────────────────────────────────────────────────

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
      // READY / PREPARING — no alert action.
      break;

    // ── Service task alerts ──────────────────────────────────────────────

    case 'NEW_SERVICE_TASK':
      isTaskType = true;
      await TaskAlertService.ensureServiceRunning();
      TaskAlertService.notifyNewTask();
      break;

    case 'SERVICE_TASK_ACCEPTED':
      isTaskType = true;
      TaskAlertService.notifyNewTask();
      break;

    // ── Delivery alerts ──────────────────────────────────────────────────

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

    // ── NEW: Lambda pulse ────────────────────────────────────────────────
    //
    // The Lambda EventBridge job fires this every interval to re-ring
    // unaccepted tasks. alert_type maps to the appropriate sound.
    // Each PULSE call replays the sound once (play-once mode).

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

    // ── NEW: Escalation alert ────────────────────────────────────────────
    //
    // Sent only to the escalation recipient. Plays escalation sound once.
    // badge_count in the payload allows an immediate badge update without
    // a separate API call.

    case 'ESCALATION_ALERT':
      isEscalationType = true;
      await TaskAlertService.ensureEscalationRunning();
      final badgeCount = int.tryParse(data['badge_count']?.toString() ?? '0') ?? 0;
      TaskAlertService.resetEscalationCount(badgeCount);
      break;

    // ── NEW: Cross-device accept stop ────────────────────────────────────
    //
    // Lambda broadcasts this to all dept connections after any device
    // accepts a task. Stops the foreground service on every non-acceptor.

    case 'ACCEPTED':
      isTaskType = true;
      // Stop the alert — server has confirmed acceptance.
      // resetServiceCount(0) stops the foreground service immediately.
      TaskAlertService.resetServiceCount(0);
      // Also trigger a page refresh so the task list updates.
      TaskAlertService.notifyNewTask();
      break;

    default:
      print('Foreground FCM: unhandled type=$type');
  }

  // Pick the right notification channel for the tray notification
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
    case 'NEW_FOOD_ORDER':
    case 'ORDER_ACCEPTED':
    case 'ORDER_CANCELLED':
      OrderAlertService.notifyNewOrder();
      break;
    case 'NEW_SERVICE_TASK':
    case 'SERVICE_TASK_ACCEPTED':
    case 'ACCEPTED':
      TaskAlertService.notifyNewTask();
      break;
    case 'NEW_DELIVERY_TASK':
    case 'DELIVERY_ACCEPTED':
    case 'DELIVERY_DELIVERED':
      TaskAlertService.notifyNewDelivery();
      break;
    case 'ESCALATION_ALERT':
      // Tapping the escalation notification navigates to the home page;
      // the escalation badge is already refreshed in _showNotification.
      TaskAlertService.notifyNewTask();
      break;
    case 'PULSE':
      // Re-fire the appropriate stream so pages reload.
      final alertType = (message.data['alert_type'] ?? 'service').toString();
      if (alertType == 'food') {
        OrderAlertService.notifyNewOrder();
      } else if (alertType == 'delivery') {
        TaskAlertService.notifyNewDelivery();
      } else {
        TaskAlertService.notifyNewTask();
      }
      break;
  }
}