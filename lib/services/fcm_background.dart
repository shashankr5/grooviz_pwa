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

  // Load user departments to filter out irrelevant notifications
  final depts = await UserSessionHelper.getDepartments();
  final normalized = depts.map((e) => e.toLowerCase().trim()).toList();
  final isRoomService = normalized.any((d) => (d.contains("room") && d.contains("service")) || d.contains("roomservice"));
  final isFoodBeverage = normalized.any((d) => d.contains("food") || d.contains("beverage") || d.contains("fnb") || d.contains("fb"));
  final isRoomServiceOrFnB = isRoomService || isFoodBeverage;

  final data      = message.data;
  final type      = (data['type'] ?? '').toString();
  final stopAlert = data['stop_alert'] == 'true';
  print('Background FCM | type=$type | stop_alert=$stopAlert | depts=$normalized');

  // Filter out notifications based on department authorizations
  switch (type) {
    case 'NEW_FOOD_ORDER':
      if (!isRoomServiceOrFnB) {
        print('Background FCM | Ignoring NEW_FOOD_ORDER for non-F&B user.');
        return;
      }
      await _startServiceIfNeeded();
      break;

    case 'NEW_SERVICE_TASK':
    case 'TASK_REASSIGNED':
    case 'ESCALATION_ALERT':
      await _startServiceIfNeeded();
      break;

    case 'NEW_DELIVERY_TASK':
    case 'ORDER_READY':
    case 'FOOD_ORDER_READY':
    case 'DELIVERY_READY':
    case 'DELIVERY_NOTIFICATION':
      if (!isRoomService) {
        print('Background FCM | Ignoring delivery alerts for non-Room Service user.');
        return;
      }
      await _startServiceIfNeeded();
      break;

    case 'PULSE':
      final alertType = (data['alert_type'] ?? 'service').toString();
      if (alertType == 'food' && !isRoomServiceOrFnB) return;
      if (alertType == 'delivery' && !isRoomService) return;
      await _startServiceIfNeeded();
      break;

    case 'ORDER_ACCEPTED':
    case 'ORDER_CANCELLED':
      if (!isRoomServiceOrFnB) return;
      if (stopAlert) {
        await _stopServiceIfRunning();
      }
      break;

    case 'DELIVERY_ACCEPTED':
      if (!isRoomService) return;
      if (stopAlert) {
        await _stopServiceIfRunning();
      }
      break;

    case 'SERVICE_TASK_ACCEPTED':
    case 'ACCEPTED':
      if (stopAlert) {
        await _stopServiceIfRunning();
      }
      break;

    case 'ORDER_DELIVERED':
      if (!isRoomServiceOrFnB) return;
      await _stopServiceIfRunning();
      break;

    case 'DELIVERY_DELIVERED':
      if (!isRoomService) return;
      await _stopServiceIfRunning();
      break;

    case 'ORDER_STATUS_CHANGED':
      final orderStatus = (data['order_status'] ?? data['status'] ?? '').toString().toUpperCase();
      if (orderStatus == 'READY') {
        if (!isRoomService) return;
        await _startServiceIfNeeded();
      }
      break;

    case 'SERVICE_STATUS_UPDATE':
    case 'SERVICE_GUEST_UPDATE':
      final newStatus = (data['new_status'] ?? data['status'] ?? '').toString().toUpperCase();
      if (newStatus == 'DELIVERED' || newStatus == 'COMPLETED' || newStatus == 'CANCELLED') {
        await _stopServiceIfRunning();
      }
      break;
  }

  await _showBackgroundNotification(data);
}

Future<void> _showBackgroundNotification(Map<String, dynamic> data) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios     = DarwinInitializationSettings();
    await plugin.initialize(const InitializationSettings(android: android, iOS: ios));

    final msg = NotificationMessageBuilder.build(data);

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
      msg.title,
      msg.body,
      NotificationDetails(android: androidDetails),
      payload: jsonEncode(data),
    );
  } catch (e) {
    debugPrint('Background notification display error: $e');
  }
}