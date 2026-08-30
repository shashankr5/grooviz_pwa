// services/notification_handler.dart
//
// CHANGES IN THIS VERSION:
//  • Migrated to AlertStateManager - single source of truth for all alert state.
//  • Removed direct calls to OrderAlertService/TaskAlertService.ensureRunning()
//  • Now uses AlertStateManager.incrementX() for new alerts
//  • AlertStateManager handles priority-based audio switching automatically

import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/deep_link_payload.dart';
import '../services/notification_navigation_coordinator.dart';
import '../services/escalation_service.dart';
import '../utils/user_session_helper.dart';
import 'alert_state_manager.dart';
import 'alert_reload_coordinator.dart';

final FlutterLocalNotificationsPlugin localNotifications =
    FlutterLocalNotificationsPlugin();

Future<void> setupFirebaseNotifications() async {
  await _initializeLocalNotifications();

  final messaging = FirebaseMessaging.instance;

  // Suppress FCM's own foreground notification display — we handle it
  // ourselves via _showLambdaNotification so it only appears once.
  await messaging.setForegroundNotificationPresentationOptions(
    alert: false,
    badge: false,
    sound: false,
  );

  try {
    final token = await messaging.getToken();
    print('FCM Token: $token');
  } catch (e) {
    print('FCM token fetch failed: $e');
  }

  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    final data = message.data;
    final type = (data['type'] ?? '').toString();

    // Handle alert sounds via AlertStateManager
    _handleForegroundMessage(data, type);

    // Show Lambda's notification in foreground
    if (message.notification != null &&
        message.notification!.title != null &&
        message.notification!.body != null) {
      _showLambdaNotification(message);
    }
  });

  // Cold start from FCM push notification tap
  final initialMessage = await messaging.getInitialMessage();
  if (initialMessage != null) {
    _handleMessage(initialMessage);
    await _reconcileAlertsAfterTap(initialMessage.data);
  }

  // Resume from FCM push notification tap
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    _handleMessage(message);
    _reconcileAlertsAfterTap(message.data);
  });

  // Cold start from Local Notification tap
  try {
    final launchDetails =
        await localNotifications.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      final payload = launchDetails?.notificationResponse?.payload;
      if (payload != null && payload.isNotEmpty) {
        Map<String, dynamic> data = {};
        try {
          data = Map<String, dynamic>.from(jsonDecode(payload));
          _handleMessage(RemoteMessage(data: data));
        } catch (_) {
          data = {'type': payload};
          _handleMessage(RemoteMessage(data: data));
        }
        await _reconcileAlertsAfterTap(data);
      }
    }
  } catch (e) {
    print('localNotifications launch details check error: $e');
  }
}

Future<void> _initializeLocalNotifications() async {
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings iosSettings =
      DarwinInitializationSettings();
  await localNotifications.initialize(
    const InitializationSettings(android: androidSettings, iOS: iosSettings),
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      final payload = response.payload;
      if (payload != null && payload.isNotEmpty) {
        print('Local notification tapped | payload=$payload');
        Map<String, dynamic> data = {};
        try {
          data = Map<String, dynamic>.from(jsonDecode(payload));
          _handleMessage(RemoteMessage(data: data));
        } catch (_) {
          data = {'type': payload};
          _handleMessage(RemoteMessage(data: data));
        }
        _reconcileAlertsAfterTap(data);
      }
    },
  );
}

Future<void> _showLambdaNotification(RemoteMessage message) async {
  await localNotifications.show(
    _getNotificationId(message.data['type']),
    message.notification!.title!,
    message.notification!.body!,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'screensync_alerts',
        'ScreenSync Alerts',
        importance: Importance.high,
        priority: Priority.high,
        autoCancel: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: false,
      ),
    ),
    payload: jsonEncode(message.data),
  );
}



int _getNotificationId(String? type) {
  switch (type) {
    case 'NEW_FOOD_ORDER':
      return 1001;
    case 'NEW_SERVICE_REQUEST':
      return 1002;
    case 'FOOD_ORDER_STATUS':
      return 1003;
    case 'ESCALATION':
      return 1004;
    case 'SERVICE_ORDER':
      return 1005;
    case 'TASK_REASSIGNED':
      return 1006;
    // Dedicated IDs added so these never collide with each other or the
    // default fallback (1000) when both fire in quick succession.
    case 'SERVICE_TASK_ACCEPTED':
    case 'ACCEPTED':
      return 1007;
    case 'TASK_CLOSED':
      return 1008;
    default:
      return 1000;
  }
}

Future<void> createNotificationChannel() async {
  final plugin = localNotifications.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();

  final zeroVibration = Int64List.fromList([0]);

  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    'screensync_alerts',
    'ScreenSync Alerts',
    description: 'Notifications from Lambda backend',
    importance: Importance.high,
    playSound: true,
    enableVibration: false,
    vibrationPattern: zeroVibration,
  ));

  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    'system_notifications',
    'System Notifications',
    description: 'App system notifications',
    importance: Importance.high,
    playSound: false,
    enableVibration: false,
    vibrationPattern: zeroVibration,
  ));

  // Alert status channel for persistent status notifications
  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    'alert_status_channel',
    'Alert Status',
    description: 'Persistent status for active alerts',
    importance: Importance.low,
    playSound: false,
    enableVibration: false,
    vibrationPattern: zeroVibration,
  ));
}

Future<void> _handleForegroundMessage(
    Map<String, dynamic> data, String type) async {
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
  final isManagerOrAdmin = role != null &&
      (role.toLowerCase().contains("manager") ||
          role.toLowerCase().contains("admin") ||
          role.toLowerCase().contains("supervisor") ||
          role.toLowerCase().contains("gm") ||
          role.toLowerCase().contains("executive") ||
          role.toLowerCase().contains("director"));
  final isRoomService = isManagerOrAdmin ||
      normalized.isEmpty ||
      normalized.any((d) =>
          (d.contains("room") && d.contains("service")) ||
          d.contains("roomservice") ||
          d.contains("delivery"));
  final isFoodBeverage = isManagerOrAdmin ||
      normalized.isEmpty ||
      normalized.any((d) =>
          d.contains("food") ||
          d.contains("beverage") ||
          d.contains("fnb") ||
          d.contains("fb") ||
          d.contains("kitchen"));
  final isRoomServiceOrFnB = isRoomService || isFoodBeverage;

  print(
      'Foreground FCM | type=$type | role=$role | depts=$normalized | isRoomService=$isRoomService | isFnB=$isFoodBeverage');

  // Foreground handler runs in MAIN ISOLATE — AlertReloadCoordinator stream
  // listeners are active, but we still call reload explicitly to ensure
  // ordering (reload BEFORE notify) and use silentReconcile:true for
  // immediate sync so the alert responds without the 400ms debounce.

  switch (type) {
    // ── NEW ALERTS ─────────────────────────────────────────────────────────
    case 'NEW_FOOD_ORDER':
      if (!isRoomServiceOrFnB) {
        print('Foreground FCM | Ignoring NEW_FOOD_ORDER for non-F&B user.');
        return;
      }
      await AlertReloadCoordinator.instance.reloadFood(silentReconcile: true);
      AlertStateManager.notifyNewFoodOrder();
      break;

    case 'FOOD_ORDER_STATUS':
      final rawStatus = (data['new_status'] ??
              data['food_order_status'] ??
              data['order_status'] ??
              data['status'] ??
              '')
          .toString()
          .toUpperCase();
      if (rawStatus != 'READY') return;
      await AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true);
      AlertStateManager.notifyNewDelivery();
      break;

    case 'SERVICE_ORDER':
    case 'NEW_SERVICE_REQUEST':
    case 'TASK_REASSIGNED':
      await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
      AlertStateManager.notifyNewTask();
      break;

    case 'ESCALATION':
      await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);

      // Guard: only fire the badge/list-refresh streams on the device that is
      // the actual escalation target. The Lambda already sends this FCM only
      // to the specific to_user_id token, but a safety check here prevents
      // badge inflation on shared devices or after token mis-assignment.
      //
      // Rules:
      //   to_user_id missing or '0'  → allow (old Lambda version without field)
      //   to_user_id == currentUserId → allow (this is the target device)
      //   to_user_id != currentUserId → skip (wrong device received the push)
      final _toUid    = (data['to_user_id'] ?? '').toString().trim();
      final _myUid    = (userId ?? 0).toString();
      final _isTarget = _toUid.isEmpty || _toUid == '0' || _toUid == _myUid;
      if (_isTarget) {
        EscalationService.instance.handleEscalationAlert(data);
      } else {
        print('Foreground FCM | ESCALATION skipped — to_user_id=$_toUid != currentUser=$_myUid');
      }
      AlertStateManager.notifyNewTask();
      break;

    // ── ACTION EVENTS - server is source of truth ─────────────────────────
    case 'ORDER_ACCEPTED':
    case 'ORDER_CANCELLED':
      await AlertReloadCoordinator.instance.reloadFood(silentReconcile: true);
      AlertStateManager.notifyNewFoodOrder();
      break;

    case 'ORDER_DELIVERED':
      await AlertStateManager.dismissAll();
      break;

    case 'SERVICE_TASK_ACCEPTED':
    case 'ACCEPTED':
      await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
      AlertStateManager.notifyNewTask();
      // Lambda now sends notification: { title, body } so _showLambdaNotification
      // (called in the outer onMessage.listen block) handles foreground display.
      // Android shows the notification automatically in background/killed state.
      // No local fallback needed here — that would duplicate the notification.
      break;

    case 'DELIVERY_ACCEPTED':
    case 'DELIVERY_DELIVERED':
      await AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true);
      AlertStateManager.notifyNewDelivery();
      break;

    case 'TASK_CLOSED':
      await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
      AlertStateManager.notifyNewTask();
      // Lambda now sends notification: { title, body } so _showLambdaNotification
      // (called in the outer onMessage.listen block) handles foreground display.
      // Android shows the notification automatically in background/killed state.
      // No local fallback needed here — that would duplicate the notification.
      break;

    default:
      print('Foreground FCM: discarding unrecognised type=$type');
      return;
  }
}

void _handleMessage(RemoteMessage message) {
  final data = message.data;
  final String rawType =
      (data['type'] ?? data['event_type'] ?? data['alert_type'] ?? '')
          .toString()
          .toUpperCase();
  print('Notification tapped | type=$rawType | data=$data');

  final payload = DeepLinkPayload.fromData(data, source: 'fcm');
  NotificationNavigationCoordinator.instance.handleDeepLink(payload);
}

// Queue reconciliation after notification tap
Future<void> _reconcileAlertsAfterTap(Map<String, dynamic> data) async {
  final String type = (data['type'] ?? '').toString().toUpperCase();
  print('Reconciling alerts after tap | type=$type');

  try {
    switch (type) {
      case 'SERVICE_ORDER':
      case 'NEW_SERVICE_REQUEST':
        await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
        break;

      case 'TASK_REASSIGNED':
        await AlertReloadCoordinator.instance
            .reloadTasks(silentReconcile: false);
        break;

      case 'ESCALATION':
        await AlertReloadCoordinator.instance
            .reloadTasks(silentReconcile: false);
        // Escalation state is set by the reload if there are escalated tasks
        break;

      case 'NEW_FOOD_ORDER':
        await AlertReloadCoordinator.instance.reloadFood(silentReconcile: true);
        break;

      case 'FOOD_ORDER_STATUS':
        await AlertReloadCoordinator.instance
            .reloadDelivery(silentReconcile: true);
        break;

      case 'ORDER_ACCEPTED':
      case 'ORDER_CANCELLED':
        await AlertReloadCoordinator.instance.reloadFood(silentReconcile: true);
        break;

      case 'ORDER_DELIVERED':
        await AlertStateManager.dismissAll();
        break;

      case 'SERVICE_TASK_ACCEPTED':
      case 'ACCEPTED':
        AlertStateManager.setEscalationActive(false);
        await AlertReloadCoordinator.instance
            .reloadTasks(silentReconcile: true);
        break;

      case 'DELIVERY_ACCEPTED':
      case 'DELIVERY_DELIVERED':
        await AlertReloadCoordinator.instance
            .reloadDelivery(silentReconcile: true);
        break;

      case 'TASK_CLOSED':
        AlertStateManager.setEscalationActive(false);
        await AlertReloadCoordinator.instance
            .reloadTasks(silentReconcile: true);
        break;

      default:
        await AlertReloadCoordinator.instance
            .reloadTasks(silentReconcile: true);
        await AlertReloadCoordinator.instance.reloadFood(silentReconcile: true);
        await AlertReloadCoordinator.instance
            .reloadDelivery(silentReconcile: true);
        break;
    }
  } catch (e) {
    print('_reconcileAlertsAfterTap error: $e');
  }
}

// Backward compatibility
Future<void> updateGroupSummary() async {
  // No-op: Lambda notifications handle grouping automatically
}
