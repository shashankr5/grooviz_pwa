import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/deep_link_payload.dart';
import '../services/notification_navigation_coordinator.dart';
import '../services/escalation_service.dart';
import '../utils/user_session_helper.dart';
// Alert services
import 'order_alert_service.dart';
import 'task_alert_service.dart';
import 'alert_reload_coordinator.dart';

final FlutterLocalNotificationsPlugin localNotifications =
    FlutterLocalNotificationsPlugin();

Future<void> setupFirebaseNotifications() async {
  await _initializeLocalNotifications();

  // Initialize legacy system only
  // TEMP: Commented out standardized system to prevent dual system conflict
  // final coordinator = NotificationCoordinator.instance;
  // await coordinator.initialize();
  // StandardizedAlertReloadCoordinator.init();

  final messaging = FirebaseMessaging.instance;

  try {
    final token = await messaging.getToken();
    print('📱 FCM Token: $token');
  } catch (e) {
    print('⚠️ FCM token fetch failed: $e');
  }

  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    final data = message.data;
    final type = (data['type'] ?? '').toString();

    // ✅ KEEP: Alert sounds (existing logic preserved)
    _handleForegroundMessage(data, type);
    
    // ✅ ADD: Show Lambda's notification
    if (message.notification != null && 
        message.notification!.title != null && 
        message.notification!.body != null) {
      _showLambdaNotification(message);
    }
  });

  // ── Cold start from FCM push notification tap ────────────────────────────
  // When the app is opened from a killed state by tapping a notification,
  // navigate to the correct page and then reconcile the live queue counts.
  // We do NOT blindly stop alerts here — the queue may still have open items.
  // AlertReloadCoordinator.reload* stops the foreground service only if the
  // reconciled pending count drops to zero.
  final initialMessage = await messaging.getInitialMessage();
  if (initialMessage != null) {
    _handleMessage(initialMessage);
    await _reconcileAlertsAfterTap(initialMessage.data);
  }

  // ── Resume/Foreground from FCM push notification tap ─────────────────────
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    _handleMessage(message);
    _reconcileAlertsAfterTap(message.data);
  });

  // ── Cold start from Local Notification tap ───────────────────────────────
  try {
    final launchDetails = await localNotifications.getNotificationAppLaunchDetails();
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
        Map<String, dynamic> data = {};
        try {
          data = Map<String, dynamic>.from(jsonDecode(payload));
          _handleMessage(RemoteMessage(data: data));
        } catch (_) {
          data = {'type': payload};
          _handleMessage(RemoteMessage(data: data));
        }
        // Reconcile queue after tap — stop alert only if the server confirms
        // the queue is truly empty. Do not blindly call stopAll().
        _reconcileAlertsAfterTap(data);
      }
    },
  );
}

Future<void> _showLambdaNotification(RemoteMessage message) async {
  await localNotifications.show(
    _getNotificationId(message.data['type']),
    message.notification!.title!,  // Lambda's title directly
    message.notification!.body!,   // Lambda's body directly
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
    case 'NEW_FOOD_ORDER': return 1001;
    case 'NEW_SERVICE_REQUEST': return 1002;
    case 'FOOD_ORDER_STATUS': return 1003;  
    case 'ESCALATION': return 1004;
    case 'SERVICE_ORDER': return 1005;
    case 'TASK_REASSIGNED': return 1006;
    default: return 1000;
  }
}

Future<void> createNotificationChannel() async {
  final plugin = localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  final zeroVibration = Int64List.fromList([0]);

  // Create channel for Lambda notifications
  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    'screensync_alerts', 'ScreenSync Alerts',
    description: 'Notifications from Lambda backend',
    importance: Importance.high, 
    playSound: true, 
    enableVibration: false,
    vibrationPattern: zeroVibration,
  ));

  // Create system notifications channel
  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    'system_notifications', 'System Notifications',
    description: 'App system notifications',
    importance: Importance.high, 
    playSound: false, 
    enableVibration: false,
    vibrationPattern: zeroVibration,
  ));
}

Future<void> _handleForegroundMessage(Map<String, dynamic> data, String type) async {
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

  // Handle alert services only - Lambda notification shows automatically
  switch (type) {
    case 'NEW_FOOD_ORDER':
      if (!isRoomServiceOrFnB) {
        print('Foreground FCM | Ignoring NEW_FOOD_ORDER for non-F&B user.');
        return;
      }
      await OrderAlertService.ensureRunning();
      OrderAlertService.notifyNewOrder();
      await AlertReloadCoordinator.instance.reloadFood();
      if (OrderAlertService.pendingOrderCount == 0) return;
      break;

    case 'FOOD_ORDER_STATUS': {
      final rawStatus = (
        data['new_status'] ??
        data['food_order_status'] ??
        data['order_status'] ??
        data['status'] ??
        ''
      ).toString().toUpperCase();
      if (rawStatus != 'READY') return;
      await TaskAlertService.ensureDeliveryRunning();
      TaskAlertService.notifyNewDelivery();
      await AlertReloadCoordinator.instance.reloadDelivery();
      break;
    }

    case 'SERVICE_ORDER':
      await TaskAlertService.ensureServiceRunning();
      TaskAlertService.notifyNewTask();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    case 'NEW_SERVICE_REQUEST':
      await TaskAlertService.ensureServiceRunning();
      TaskAlertService.notifyNewTask();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    case 'TASK_REASSIGNED':
      await TaskAlertService.ensureServiceRunning();
      TaskAlertService.notifyNewTask();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    case 'ESCALATION':
      await TaskAlertService.ensureEscalationRunning();
      await AlertReloadCoordinator.instance.reloadTasks();
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
      print('Foreground FCM: discarding unrecognised type=$type');
      return;
  }
}

void _handleMessage(RemoteMessage message) {
  final data = message.data;
  final String rawType = (data['type'] ?? data['event_type'] ?? data['alert_type'] ?? '').toString().toUpperCase();
  print('👆 Notification tapped | type=$rawType | data=$data');

  final payload = DeepLinkPayload.fromData(data, source: 'fcm');
  NotificationNavigationCoordinator.instance.handleDeepLink(payload);
}

// ── Queue reconciliation after notification tap ──────────────────────────────
//
// Called whenever a notification is tapped (cold-start, resume, local).
//
// DESIGN CONTRACT:
//  • For data-only payloads (SERVICE_ORDER, NEW_SERVICE_REQUEST):
//    onBackgroundMessage fires reliably → alert is already running.
//    silentReconcile=true stops the service if the queue emptied while the
//    user was away, but never starts a fresh alert.
//
//  • For notification+data payloads (TASK_REASSIGNED, ESCALATION,
//    NEW_FOOD_ORDER, FOOD_ORDER_STATUS):
//    Android in background/killed state shows the OS tray notification and
//    onBackgroundMessage may be SKIPPED — the alert sound never started.
//    On tap, we must actively start the appropriate alert sound, then
//    reload from the server. If the work was already handled on another
//    device, the reload count comes back 0 and the sound stops immediately.
Future<void> _reconcileAlertsAfterTap(Map<String, dynamic> data) async {
  final String type = (data['type'] ?? '').toString().toUpperCase();
  print('🔄 Reconciling alerts after tap | type=$type');

  try {
    switch (type) {
      // ── Data-only payloads — silently reconcile only ─────────────────────
      // onBackgroundMessage ran, alert is already started.
      // Reconcile so we stop if another device already handled the task.
      case 'SERVICE_ORDER':
      case 'NEW_SERVICE_REQUEST':
        await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
        break;

      // ── TASK_REASSIGNED ──────────────────────────────────────────────────
      // notification+data → onBackgroundMessage may have been skipped.
      // FIX: Don't start alert before reconciliation - let reconciliation decide
      case 'TASK_REASSIGNED':
        await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: false); // Changed to false to allow restart
        break;

      // ── ESCALATION ───────────────────────────────────────────────────────
      // notification+data → onBackgroundMessage may have been skipped.
      // FIX: Don't start alert before reconciliation - let reconciliation decide
      case 'ESCALATION':
        await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: false); // Changed to false to allow restart
        // Start escalation alert after confirming there are escalated tasks
        await TaskAlertService.ensureEscalationRunning();
        break;

      // ── Food order types ─────────────────────────────────────────────────
      case 'NEW_FOOD_ORDER':
        await AlertReloadCoordinator.instance.reloadFood(silentReconcile: true);
        break;

      // ── Delivery / Ready queue ───────────────────────────────────────────
      case 'FOOD_ORDER_STATUS':
        await AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true);
        break;

      // ── Order action events ──────────────────────────────────────────────
      case 'ORDER_ACCEPTED':
      case 'ORDER_CANCELLED':
        await AlertReloadCoordinator.instance.reloadFood(silentReconcile: true);
        break;

      case 'ORDER_DELIVERED':
        // Delivery stops all food and task alerts
        await OrderAlertService.stop();
        await TaskAlertService.stopAll();
        break;

      case 'SERVICE_TASK_ACCEPTED':
      case 'ACCEPTED':
        await TaskAlertService.stopEscalation();
        await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
        break;

      case 'DELIVERY_ACCEPTED':
      case 'DELIVERY_DELIVERED':
        await AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true);
        break;

      case 'TASK_CLOSED':
        await TaskAlertService.stopEscalation();
        await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
        break;

      default:
        // For truly unknown types, do a full reconciliation across all queues.
        // This fallback is rarely reached now that action types are handled.
        await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
        await AlertReloadCoordinator.instance.reloadFood(silentReconcile: true);
        await AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true);
        break;
    }
  } catch (e) {
    print('⚠️ _reconcileAlertsAfterTap error: $e');
  }
}

// Backward compatibility - empty function since Lambda handles notifications
Future<void> updateGroupSummary() async {
  // No-op: Lambda notifications handle grouping automatically
}