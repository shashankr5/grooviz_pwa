// services/fcm_background.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/user_session_helper.dart';
import 'unified_alert_foreground_task.dart';
// Alert services
import 'order_alert_service.dart';
import 'task_alert_service.dart';
import 'alert_reload_coordinator.dart';

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'order_alert_service',
      channelName: 'ScreenSync Alerts',
      channelDescription: 'Plays alert sound for new orders, service tasks, and delivery',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      autoRunOnBoot: false,
      allowWakeLock: true,
      eventAction: ForegroundTaskEventAction.nothing(),
    ),
  );
}

Future<void> _stopServiceIfRunning() async {
  try {
    final isRunning = await FlutterForegroundTask.isRunningService;
    if (isRunning) {
      await FlutterForegroundTask.stopService();
    }
  } catch (e) {
    print('BG: _stopServiceIfRunning error: $e');
  }
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  _initForegroundTask();

  // Guard: Ignore FCM messages if no active user session exists
  final int? userId = await UserSessionHelper.getUserId();
  if (userId == null || userId == 0) {
    print('Background FCM | No active user session. Ignoring.');
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

  final data      = message.data;
  final type      = (data['type'] ?? '').toString();
  print('Background FCM | type=$type | role=$role | depts=$normalized');

  // ── Canonical alert and action types are handled. Legacy/stale types are
  // silently discarded so background isolates cannot start stale alerts.
  switch (type) {

    // ── NEW_FOOD_ORDER ─────────────────────────────────────────────────────
    case 'NEW_FOOD_ORDER':
      if (!isRoomServiceOrFnB) {
        print('Background FCM | Ignoring NEW_FOOD_ORDER for non-F&B user.');
        return;
      }
      await OrderAlertService.ensureRunning();
      // Reconcile with the server so a stale FCM doesn't keep the alert alive.
      await AlertReloadCoordinator.instance.reloadFood();
      if (OrderAlertService.pendingOrderCount == 0) return;
      break;

    // ── FOOD_ORDER_STATUS ───────────────────────────────────────────────────
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
      await AlertReloadCoordinator.instance.reloadDelivery();
      break;
    }

    // ── SERVICE_ORDER ────────────────────────────────────────────────────────
    case 'SERVICE_ORDER':
      await TaskAlertService.ensureServiceRunning();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    // ── NEW_SERVICE_REQUEST ─────────────────────────────────────────────────
    case 'NEW_SERVICE_REQUEST':
      await TaskAlertService.ensureServiceRunning();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    // ── TASK_REASSIGNED ────────────────────────────────────────────────────
    case 'TASK_REASSIGNED':
      await TaskAlertService.ensureServiceRunning();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    // ── ESCALATION ───────────────────────────────────────────────────────────
    // Scheduler fires looping escalation sound; reload so badge + highlights update.
    // Guard: if escalation is already playing, skip restart to avoid interruption.
    case 'ESCALATION':
      // Check current sound before restarting – avoid interrupting an ongoing escalation
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final currentSound = prefs.getString(AlertSoundKey.prefKey) ?? '';
      if (currentSound != AlertSoundKey.escalation) {
        await TaskAlertService.ensureEscalationRunning();
      } else {
        print('Background FCM: escalation already playing, skipping restart');
      }
      await AlertReloadCoordinator.instance.reloadTasks();
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
      // All other types are silently discarded.
      print('Background FCM: discarding unrecognised type=$type');
      return;
  }

  // ✅ ADD: Show Lambda's notification in background
  if (message.notification?.title != null && message.notification?.body != null) {
    await _showBackgroundLambdaNotification(message);
  }
}

Future<void> _showBackgroundLambdaNotification(RemoteMessage message) async {
  final plugin = FlutterLocalNotificationsPlugin();
  
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const ios = DarwinInitializationSettings();
  await plugin.initialize(const InitializationSettings(android: android, iOS: ios));
  
  await plugin.show(
    _getNotificationId(message.data['type']),
    message.notification!.title!,  // Lambda's exact title
    message.notification!.body!,   // Lambda's exact body
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