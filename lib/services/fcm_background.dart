// services/fcm_background.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../utils/user_session_helper.dart';
import 'unified_alert_foreground_task.dart';
import 'notification_constants.dart';
import 'notification_message_builder.dart';
import 'notification_policy.dart';
import 'alert_reload_coordinator.dart';
import 'order_alert_service.dart';
import 'task_alert_service.dart';

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

Future<void> _startServiceIfNeeded() async {
  try {
    final isRunning = await FlutterForegroundTask.isRunningService;
    if (isRunning) {
      await FlutterForegroundTask.restartService();
    } else {
      await FlutterForegroundTask.startService(
        notificationTitle: 'New Alert',
        notificationText: 'Tap to view',
        callback: unifiedAlertStartCallback,
      );
    }
  } catch (e) {
    print('BG: _startServiceIfNeeded error: $e');
  }
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

  // ── Only the 5 canonical types are handled. All legacy/stale types are
  // silently discarded so background isolates cannot start stale alerts.
  switch (type) {

    // ── NEW_FOOD_ORDER ─────────────────────────────────────────────────────
    case 'NEW_FOOD_ORDER':
      if (!isRoomServiceOrFnB) {
        print('Background FCM | Ignoring NEW_FOOD_ORDER for non-F&B user.');
        return;
      }
      await _startServiceIfNeeded();
      // Reconcile with the server so a stale FCM doesn't keep the alert alive.
      await AlertReloadCoordinator.instance.reloadFood();
      if (OrderAlertService.pendingOrderCount == 0) return;
      break;

    // ── SERVICE_ORDER ──────────────────────────────────────────────────────
    // TV service booking — treated identically to NEW_SERVICE_REQUEST.
    case 'SERVICE_ORDER':
      await _startServiceIfNeeded();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    // ── NEW_SERVICE_REQUEST ────────────────────────────────────────────────
    case 'NEW_SERVICE_REQUEST':
      await _startServiceIfNeeded();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    // ── TASK_REASSIGNED ────────────────────────────────────────────────────
    case 'TASK_REASSIGNED':
      await _startServiceIfNeeded();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    // ── ESCALATION ─────────────────────────────────────────────────────────
    // One-shot non-looping sound; reload so badge + highlights update.
    case 'ESCALATION':
      await TaskAlertService.ensureEscalationRunning();
      await AlertReloadCoordinator.instance.reloadTasks();
      break;

    default:
      // All other types (legacy delivery, order-accepted, pulses, etc.)
      // are silently discarded.
      print('Background FCM: discarding unrecognised type=$type');
      return;
  }

  if (NotificationPolicy.shouldShowLocalNotification(data)) {
    await _showBackgroundNotification(data);
  }
}

Future<void> _showBackgroundNotification(Map<String, dynamic> data) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios     = DarwinInitializationSettings();
    await plugin.initialize(const InitializationSettings(android: android, iOS: ios));

    final msg = NotificationMessageBuilder.build(data);
    final title = data['title']?.toString().trim();
    final body = data['body']?.toString().trim();

    final androidDetails = AndroidNotificationDetails(
      msg.channelId,
      msg.channelId,
      importance:       Importance.max,
      priority:         Priority.max,
      icon:             msg.icon,
      color:            Color(msg.color),
      ticker:           msg.ticker,
      styleInformation: BigTextStyleInformation(msg.bigText, contentTitle: msg.title),
      groupKey:         NotifGroup.key,
      autoCancel:       true,
      playSound:        false,
    );

    await plugin.show(
      msg.notifId,
      title == null || title.isEmpty ? msg.title : title,
      body == null || body.isEmpty ? msg.body : body,
      NotificationDetails(android: androidDetails),
      payload: jsonEncode(data),
    );
  } catch (e) {
    debugPrint('Background notification display error: $e');
  }
}
