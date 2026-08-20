import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/deep_link_payload.dart';
import '../services/notification_navigation_coordinator.dart';
import '../services/order_alert_service.dart';
import '../services/task_alert_service.dart';
import '../utils/user_session_helper.dart';
import 'notification_constants.dart';
import 'notification_message_builder.dart';

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

  // Cold start from FCM push notification tap
  final initialMessage = await messaging.getInitialMessage();
  if (initialMessage != null) _handleMessage(initialMessage);

  // Resume/Foreground from FCM push notification tap
  FirebaseMessaging.onMessageOpenedApp.listen(_handleMessage);

  // Cold start from Local Notification tap
  try {
    final launchDetails = await localNotifications.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      final payload = launchDetails?.notificationResponse?.payload;
      if (payload != null && payload.isNotEmpty) {
        try {
          final Map<String, dynamic> data = Map<String, dynamic>.from(jsonDecode(payload));
          _handleMessage(RemoteMessage(data: data));
        } catch (_) {
          _handleMessage(RemoteMessage(data: {'type': payload}));
        }
      }
    }
  } catch (e) {
    print('⚠️ localNotifications launch details check error: $e');
  }
}

Future<void> _initializeLocalNotifications() async {
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings iosSettings = DarwinInitializationSettings();
  await localNotifications.initialize(
    const InitializationSettings(android: androidSettings, iOS: iosSettings),
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      final payload = response.payload;
      if (payload != null && payload.isNotEmpty) {
        print('👆 Local notification tapped | payload=$payload');
        try {
          final Map<String, dynamic> data = Map<String, dynamic>.from(jsonDecode(payload));
          _handleMessage(RemoteMessage(data: data));
        } catch (_) {
          _handleMessage(RemoteMessage(data: {'type': payload}));
        }
      }
    },
  );
}

Future<void> createNotificationChannel() async {
  final plugin = localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  // Delete cached legacy channels to clear OS-level vibration flags
  try {
    await plugin?.deleteNotificationChannel(NotifChannel.foodOrder);
    await plugin?.deleteNotificationChannel(NotifChannel.task);
    await plugin?.deleteNotificationChannel(NotifChannel.foreground);
    await plugin?.deleteNotificationChannel(NotifChannel.delivery);
    await plugin?.deleteNotificationChannel(NotifChannel.escalation);
    await plugin?.deleteNotificationChannel('high_importance_channel');
  } catch (_) {}

  final zeroVibration = Int64List.fromList([0]);

  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    NotifChannel.foodOrder, 'Food Order Alerts',
    description: 'Incoming food orders requiring staff acceptance',
    importance: Importance.max, playSound: true, enableVibration: false,
    vibrationPattern: zeroVibration,
    sound: const RawResourceAndroidNotificationSound('bell_notification'),
  ));

  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    NotifChannel.task, 'Service Task Alerts',
    description: 'Housekeeping, engineering and maintenance requests',
    importance: Importance.max, playSound: true, enableVibration: false,
    vibrationPattern: zeroVibration,
    sound: const RawResourceAndroidNotificationSound('task_notification'),
  ));

  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    NotifChannel.foreground, 'Order Alert Service',
    description: 'Foreground service for order and task alerts.',
    importance: Importance.high, playSound: false, enableVibration: false,
    vibrationPattern: zeroVibration,
  ));

  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    NotifChannel.delivery, 'Delivery Alerts',
    description: 'Orders ready and waiting for delivery assignment',
    importance: Importance.max, playSound: true, enableVibration: false,
    vibrationPattern: zeroVibration,
    sound: const RawResourceAndroidNotificationSound('delivery_notification'),
  ));

  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    NotifChannel.escalation, 'Escalation Alerts',
    description: 'SLA-breached tasks requiring management review',
    importance: Importance.max, playSound: true, enableVibration: false,
    vibrationPattern: zeroVibration,
    sound: const RawResourceAndroidNotificationSound('escalation_notification'),
  ));
}

// ── Notification Details builders ─────────────────────────────────────────

NotificationDetails _buildDetails(NotifMessage msg, {bool isGroupSummary = false}) {
  final android = AndroidNotificationDetails(
    msg.channelId,
    _channelName(msg.channelId),
    channelDescription: _channelDescription(msg.channelId),
    importance:        Importance.max,
    priority:          Priority.max,
    icon:              msg.icon,
    color:             Color(msg.color),
    colorized:         false,
    ticker:            msg.ticker,
    styleInformation: BigTextStyleInformation(
      msg.bigText,
      contentTitle: msg.title,
      summaryText:  'ScreenSync',
    ),
    groupKey:          NotifGroup.key,
    setAsGroupSummary: isGroupSummary,
    autoCancel:        true,
    enableVibration:   false,
    vibrationPattern:  Int64List.fromList([0]),
    playSound:         false, // audio handled by foreground service
  );

  const ios = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: false,
  );

  return NotificationDetails(android: android, iOS: ios);
}

Future<void> _showNotification(RemoteMessage message) async {
  final data = message.data;
  final type = (data['type'] ?? '').toString();

  // Guard: Ignore FCM messages if no active user session exists
  final int? userId = await UserSessionHelper.getUserId();
  if (userId == null || userId == 0) {
    print('Foreground FCM | No active user session. Ignoring.');
    return;
  }

  // Load user departments to filter out irrelevant notifications
  final depts = await UserSessionHelper.getDepartments();
  final normalized = depts.map((e) => e.toLowerCase().trim()).toList();
  final isRoomService = normalized.any((d) => (d.contains("room") && d.contains("service")) || d.contains("roomservice"));
  final isFoodBeverage = normalized.any((d) => d.contains("food") || d.contains("beverage") || d.contains("fnb") || d.contains("fb"));
  final isRoomServiceOrFnB = isRoomService || isFoodBeverage;

  print('🎯 Foreground FCM | type=$type | depts=$normalized');

  switch (type) {
    case 'NEW_FOOD_ORDER':
      if (!isRoomServiceOrFnB) {
        print('Foreground FCM | Ignoring NEW_FOOD_ORDER for non-F&B user.');
        return;
      }
      await OrderAlertService.ensureRunning();
      OrderAlertService.notifyNewOrder();
      break;

    case 'ORDER_ACCEPTED':
      if (!isRoomServiceOrFnB) return;
      OrderAlertService.notifyNewOrder();
      break;

    case 'ORDER_CANCELLED':
      if (!isRoomServiceOrFnB) return;
      OrderAlertService.notifyNewOrder();
      break;

    case 'ORDER_DELIVERED':
      if (!isRoomServiceOrFnB) return;
      await OrderAlertService.stop();
      break;

    case 'ORDER_STATUS_CHANGED':
      final orderStatus = (data['order_status'] ?? data['status'] ?? '').toString().toUpperCase();
      if (orderStatus == 'READY') {
        if (!isRoomService) return;
        await TaskAlertService.ensureDeliveryRunning();
        TaskAlertService.notifyNewDelivery();
      }
      break;

    case 'ORDER_READY':
    case 'FOOD_ORDER_READY':
    case 'DELIVERY_READY':
    case 'DELIVERY_NOTIFICATION':
      if (!isRoomService) {
        print('Foreground FCM | Ignoring delivery alerts for non-Room Service user.');
        return;
      }
      await TaskAlertService.ensureDeliveryRunning();
      TaskAlertService.notifyNewDelivery();
      break;

    case 'NEW_SERVICE_REQUEST':
    case 'NEW_SERVICE_TASK':
      await TaskAlertService.ensureServiceRunning();
      TaskAlertService.notifyNewTask();
      break;

    case 'SERVICE_TASK_ACCEPTED':
      TaskAlertService.notifyNewTask();
      break;

    case 'SERVICE_STATUS_UPDATE':
      final action = (data['action'] ?? '').toString();
      if (action == 'Reject' || action == 'Cancel') {
        await TaskAlertService.stopAll();
        await OrderAlertService.stop();
      } else {
        TaskAlertService.notifyNewTask();
      }
      break;

    case 'SERVICE_GUEST_UPDATE':
      TaskAlertService.notifyNewTask();
      break;

    case 'TASK_REASSIGNED':
      await TaskAlertService.ensureServiceRunning();
      TaskAlertService.notifyNewTask();
      break;

    case 'NEW_DELIVERY_TASK':
      if (!isRoomService) {
        print('Foreground FCM | Ignoring delivery alerts for non-Room Service user.');
        return;
      }
      await TaskAlertService.ensureDeliveryRunning();
      TaskAlertService.notifyNewDelivery();
      break;

    case 'DELIVERY_ACCEPTED':
      if (!isRoomService) return;
      TaskAlertService.notifyNewDelivery();
      break;

    case 'DELIVERY_DELIVERED':
      if (!isRoomService) return;
      TaskAlertService.notifyNewDelivery();
      break;

    case 'PULSE':
      final alertType = (data['alert_type'] ?? 'service').toString();
      switch (alertType) {
        case 'food':
          if (!isRoomServiceOrFnB) return;
          await OrderAlertService.ensureRunning();
          OrderAlertService.notifyNewOrder();
          break;
        case 'delivery':
          if (!isRoomService) return;
          await TaskAlertService.ensureDeliveryRunning();
          TaskAlertService.notifyNewDelivery();
          break;
        case 'service':
        default:
          await TaskAlertService.ensureServiceRunning();
          TaskAlertService.notifyNewTask();
          break;
      }
      break;

    case 'ESCALATION_ALERT':
      await TaskAlertService.ensureEscalationRunning();
      final badgeCount = int.tryParse(data['badge_count']?.toString() ?? '0') ?? 0;
      TaskAlertService.resetEscalationCount(badgeCount);
      break;

    case 'ESCALATION_STARTED':
    case 'ESCALATION_STAGE_1':
    case 'ESCALATION_PULSE':
      await TaskAlertService.ensureEscalationRunning();
      // Escalation pulses are reminders, not service-task mutations. Emitting
      // onNewTask here made every pulse reload get_all_services_mobile twice:
      // once in HomePage and once in AlertReloadCoordinator.
      break;

    case 'PENDING_ACCEPTANCE':
      await TaskAlertService.ensureServiceRunning();
      TaskAlertService.notifyNewTask();
      break;

    case 'ACCEPTED':
      TaskAlertService.resetServiceCount(0);
      TaskAlertService.notifyNewTask();
      break;

    default:
      print('Foreground FCM: unhandled type=$type');
  }

  final msg = NotificationMessageBuilder.build(data);

  try {
    await localNotifications.show(
      msg.notifId,
      msg.title,
      msg.body,
      _buildDetails(msg),
      payload: jsonEncode(data),
    );
    await updateGroupSummary();
  } catch (e) {
    // A bad native notification resource must not escape the FCM callback:
    // it can delay acknowledgement and cause the same pulse to be redelivered.
    print('Foreground notification display error: $e');
  }
}

Future<void> updateGroupSummary() async {
  try {
    final active = await localNotifications.getActiveNotifications();
    final screensyncCount = active
        .where((n) => [
              NotifId.foodOrder,
              NotifId.delivery,
              NotifId.serviceTask,
              NotifId.escalation,
            ].contains(n.id))
        .length;

    if (screensyncCount == 0) {
      await localNotifications.cancel(NotifId.groupSummary);
      return;
    }

    final summaryParts = <String>[];
    for (final n in active) {
      if (n.id == NotifId.foodOrder)   summaryParts.add('Food Orders');
      if (n.id == NotifId.delivery)    summaryParts.add('Deliveries');
      if (n.id == NotifId.serviceTask) summaryParts.add('Service Tasks');
      if (n.id == NotifId.escalation)  summaryParts.add('Escalation');
    }
    final summaryBody = summaryParts.join(' · ');

    final summaryMsg = NotifMessage(
      title:     'ScreenSync',
      body:      summaryBody,
      bigText:   summaryBody,
      ticker:    'ScreenSync alerts',
      notifId:   NotifId.groupSummary,
      channelId: NotifChannel.foodOrder,
      color:     0xFF1A1A2E,
      icon:      NotifIcon.fallback,
    );

    await localNotifications.show(
      NotifId.groupSummary,
      'ScreenSync',
      summaryBody,
      _buildDetails(summaryMsg, isGroupSummary: true),
    );
  } catch (e) {
    print('updateGroupSummary error: $e');
  }
}

String _channelName(String channelId) {
  switch (channelId) {
    case NotifChannel.foodOrder:  return 'Food Order Alerts';
    case NotifChannel.delivery:   return 'Delivery Alerts';
    case NotifChannel.task:       return 'Service Task Alerts';
    case NotifChannel.escalation: return 'Escalation Alerts';
    default:                      return 'ScreenSync Alerts';
  }
}

String _channelDescription(String channelId) {
  switch (channelId) {
    case NotifChannel.foodOrder:  return 'Incoming food orders requiring staff acceptance';
    case NotifChannel.delivery:   return 'Orders ready and waiting for delivery assignment';
    case NotifChannel.task:       return 'Housekeeping, engineering and maintenance requests';
    case NotifChannel.escalation: return 'SLA-breached tasks requiring management review';
    default:                      return 'ScreenSync operational alerts';
  }
}

void _handleMessage(RemoteMessage message) {
  final data = message.data;
  final String rawType = (data['type'] ?? data['event_type'] ?? data['alert_type'] ?? '').toString().toUpperCase();
  print('👆 Notification tapped | type=$rawType | data=$data');

  final payload = DeepLinkPayload.fromData(data, source: 'fcm');
  NotificationNavigationCoordinator.instance.handleDeepLink(payload);
}
