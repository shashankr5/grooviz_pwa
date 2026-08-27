// services/fcm_background.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Added for escalation guard
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

    // A background FCM can arrive before the foreground startup has created
    // the channel. Register it here too so Android resolves notification.wav
    // instead of falling back to the device default sound.
    final androidPlugin = plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(
      AndroidNotificationChannel(
        msg.channelId,
        'ScreenSync Alerts',
        description: 'ScreenSync operational notifications',
        importance: Importance.max,
        playSound: true,
        enableVibration: false,
        sound: const RawResourceAndroidNotificationSound('notification'),
      ),
    );

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
      playSound:        true,
      sound:            const RawResourceAndroidNotificationSound('notification'),
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