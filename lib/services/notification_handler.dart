import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/deep_link_payload.dart';
import '../services/notification_navigation_coordinator.dart';
import '../services/order_alert_service.dart';
import '../services/task_alert_service.dart';
import '../services/alert_reload_coordinator.dart';
import '../services/escalation_service.dart';
import '../utils/user_session_helper.dart';
import 'notification_constants.dart';
import 'notification_message_builder.dart';
import 'notification_policy.dart';

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
  if (initialMessage != null) {
    _handleMessage(initialMessage); // navigate to correct page
    // User tapped the notification to open the app — stop the looping alert.
    // AlertReloadCoordinator will re-evaluate true pending counts when the page loads.
    // If tasks remain open, the NEXT Lambda FCM pulse will restart the alert.
    await TaskAlertService.stopAll();
    await OrderAlertService.stop();
  }

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
      // Stop the looping alert — user acknowledged by tapping the local notification.
      await TaskAlertService.stopAll();
      await OrderAlertService.stop();
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
    sound: const RawResourceAndroidNotificationSound('notification'),
  ));

  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    NotifChannel.task, 'Service Task Alerts',
    description: 'Housekeeping, engineering and maintenance requests',
    importance: Importance.max, playSound: true, enableVibration: false,
    vibrationPattern: zeroVibration,
    sound: const RawResourceAndroidNotificationSound('notification'),
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
    sound: const RawResourceAndroidNotificationSound('notification'),
  ));

  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    NotifChannel.escalation, 'Escalation Alerts',
    description: 'SLA-breached tasks requiring management review',
    importance: Importance.max, playSound: true, enableVibration: false,
    vibrationPattern: zeroVibration,
    sound: const RawResourceAndroidNotificationSound('notification'),
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
    // Notification.wav plays once for the visible notification. Operational
    // request alerts continue separately in the foreground service.
    playSound:         true,
    sound:             const RawResourceAndroidNotificationSound('notification'),
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

  // Load user departments & role to filter out irrelevant notifications
  final depts = await UserSessionHelper.getDepartments();
  final role = await UserSessionHelper.getRole();
  final normalized = depts.map((e) => e.toLowerCase().trim()).toList();
  final isManagerOrAdmin = role != null && (
    role.toLowerCase().contains("manager") ||
    role.toLowerCase().contains("admin") ||
    role.toLowerCase().contains("supervisor") ||
    role.toLowerCase().contains("gm") ||
    role.toLowerCase().contains("executive") ||
    role.toLowerCase().contains("director")
  );
  final isRoomService = isManagerOrAdmin || normalized.isEmpty || normalized.any((d) => (d.contains("room") && d.contains("service")) || d.contains("roomservice") || d.contains("delivery"));
  final isFoodBeverage = isManagerOrAdmin || normalized.isEmpty || normalized.any((d) => d.contains("food") || d.contains("beverage") || d.contains("fnb") || d.contains("fb") || d.contains("kitchen"));
  final isRoomServiceOrFnB = isRoomService || isFoodBeverage;

  print('🎯 Foreground FCM | type=$type | role=$role | depts=$normalized | isRoomService=$isRoomService | isFnB=$isFoodBeverage');

  // ── Canonical alert types and action events are handled here. ─────────────
  // All legacy delivery/order-accepted/pulse/escalation-legacy events are
  // silently dropped so stale alerts cannot accumulate.
  switch (type) {

    // ── NEW_FOOD_ORDER ─────────────────────────────────────────────────────
    // TV device places a food order → notify F&B / Room Service staff.
    // Alert loops until any device accepts, which triggers a task reload
    // that will reset the count to 0 via AlertReloadCoordinator.
    case 'NEW_FOOD_ORDER':
      if (!isRoomServiceOrFnB) {
        print('Foreground FCM | Ignoring NEW_FOOD_ORDER for non-F&B user.');
        return;
      }
      await OrderAlertService.ensureRunning();
      OrderAlertService.notifyNewOrder();
      // Confirm the live queue before keeping the foreground alert.
      await AlertReloadCoordinator.instance.reloadFood();
      if (OrderAlertService.pendingOrderCount == 0) return;
      break;

      case 'FOOD_ORDER_STATUS':
        final status = (data['new_status'] ?? data['order_status'] ?? data['status'] ?? '')
          .toString().toUpperCase();
        if (status != 'READY') return;
        await TaskAlertService.ensureDeliveryRunning();
        TaskAlertService.notifyNewDelivery();
        await AlertReloadCoordinator.instance.reloadDelivery();
        break;

    // ── SERVICE_ORDER ──────────────────────────────────────────────────────
    // TV device places a service booking → notify Service dept staff.
    // Treated identically to NEW_SERVICE_REQUEST on the client side.
    case 'SERVICE_ORDER':
      await TaskAlertService.ensureServiceRunning();
      TaskAlertService.notifyNewTask();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    // ── NEW_SERVICE_REQUEST ────────────────────────────────────────────────
    // WhatsApp webhook OR any backend path that creates a service_request.
    // Alert loops until any staff member accepts — cross-device stop is
    // handled by AlertReloadCoordinator.reloadTasks() resetting count to 0.
    case 'NEW_SERVICE_REQUEST':
      await TaskAlertService.ensureServiceRunning();
      TaskAlertService.notifyNewTask();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    // ── TASK_REASSIGNED ────────────────────────────────────────────────────
    // A supervisor has reassigned a task to this user.
    // Start the service alert loop so the new assignee is notified.
    case 'TASK_REASSIGNED':
      await TaskAlertService.ensureServiceRunning();
      TaskAlertService.notifyNewTask();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    // ── ESCALATION ─────────────────────────────────────────────────────────
    // Scheduler fired — SLA breached, task climbed the hierarchy.
    // Looping escalation sound + reload so the escalated
    // badge count and red card highlight update immediately.
    case 'ESCALATION':
      await TaskAlertService.ensureEscalationRunning();
      await AlertReloadCoordinator.instance.reloadTasks();
      // Emit escalation streams so HomePage and TasksPage refresh instantly
      // without needing a WebSocket event. The badge count is recomputed
      // from the task list by each page, so an empty map is sufficient here.
      EscalationService.instance.handleEscalationAlert(data);
      break;

    case 'ORDER_ACCEPTED':
    case 'ORDER_CANCELLED':
      OrderAlertService.notifyNewOrder();
      await AlertReloadCoordinator.instance.reloadFood();
      return;

    case 'ORDER_DELIVERED':
      await OrderAlertService.stop();
      await TaskAlertService.stopAll();
      return;

    case 'SERVICE_TASK_ACCEPTED':
    case 'ACCEPTED':
      await TaskAlertService.stopEscalation();
      TaskAlertService.notifyNewTask();
      await AlertReloadCoordinator.instance.reloadTasks();
      return;

    case 'DELIVERY_ACCEPTED':
    case 'DELIVERY_DELIVERED':
      TaskAlertService.notifyNewDelivery();
      await AlertReloadCoordinator.instance.reloadDelivery();
      return;

    case 'TASK_CLOSED':
      await TaskAlertService.stopEscalation();
      TaskAlertService.notifyNewTask();
      await AlertReloadCoordinator.instance.reloadTasks();
      return;

    default:
      // All other types (legacy delivery, order-accepted, pulses, etc.)
      // are silently discarded — they either come from a different Lambda
      // that is not part of the current backend or are obsolete.
      print('Foreground FCM: discarding unrecognised type=$type');
      return;
  }

  if (!NotificationPolicy.shouldShowLocalNotification(data)) {
    return;
  }

  final msg = NotificationMessageBuilder.build(data);
  final title = data['title']?.toString().trim();
  final body = data['body']?.toString().trim();

  try {
    await localNotifications.show(
      msg.notifId,
      title == null || title.isEmpty ? msg.title : title,
      body == null || body.isEmpty ? msg.body : body,
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
