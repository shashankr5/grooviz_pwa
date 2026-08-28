// services/fcm_background.dart
//
// Background FCM handler - runs in a SEPARATE ISOLATE from the main app.
//
// CRITICAL: Because this runs in its own isolate:
//   • notifyNewX() streams do NOT reach the main isolate's listeners
//   • AlertReloadCoordinator listeners registered in main() do NOT fire here
//   • We MUST call reloadX() explicitly and await it
//   • All setX() calls use immediate=true so sync fires before isolate dies

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../utils/user_session_helper.dart';
import 'alert_state_manager.dart';
import 'alert_reload_coordinator.dart';

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'order_alert_service',
      channelName: 'ScreenSync Alerts',
      channelDescription:
          'Plays alert sound for new orders, service tasks, and delivery',
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

  final data = message.data;
  final type = (data['type'] ?? '').toString();
  print('Background FCM | type=$type | role=$role | depts=$normalized');

  switch (type) {
    // ────────────────────────────────────────────────────────────────────────
    // NEW ALERTS - reload from server, then flush sync
    // ────────────────────────────────────────────────────────────────────────
    case 'NEW_FOOD_ORDER':
      if (!isRoomServiceOrFnB) {
        print('Background FCM | Ignoring NEW_FOOD_ORDER for non-F&B user.');
        return;
      }
      // Reload with reconcileAlert=true → immediate sync, no debounce
      await AlertReloadCoordinator.instance.reloadFood(silentReconcile: true);
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
      break;

    case 'SERVICE_ORDER':
    case 'NEW_SERVICE_REQUEST':
    case 'TASK_REASSIGNED':
      await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
      break;

    case 'ESCALATION':
      // Reload will detect escalated=true tasks and set escalation flag
      await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
      break;

    // ────────────────────────────────────────────────────────────────────────
    // ACTION EVENTS - server is source of truth
    // Use break (not return) so execution falls through to flushSync() below.
    // flushSync() calls _sync() which calls _stopService() — without it the
    // foreground service keeps playing sound even after counts drop to zero.
    // ────────────────────────────────────────────────────────────────────────
    case 'ORDER_ACCEPTED':
    case 'ORDER_CANCELLED':
      await AlertReloadCoordinator.instance.reloadFood(silentReconcile: true);
      break;

    case 'ORDER_DELIVERED':
      await AlertStateManager.dismissAll();
      break;

    case 'SERVICE_TASK_ACCEPTED':
    case 'ACCEPTED':
      await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
      break;

    case 'DELIVERY_ACCEPTED':
    case 'DELIVERY_DELIVERED':
      await AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true);
      break;

    case 'TASK_CLOSED':
      await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
      break;

    default:
      print('Background FCM: discarding unrecognised type=$type');
      return;
  }

  // Explicit flush guarantees sync runs before isolate terminates.
  await AlertStateManager.flushSync();
  print('Background FCM: flushSync complete for type=$type');
}
