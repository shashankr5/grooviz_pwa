// services/fcm_background.dart
//
// Background FCM handler - runs in a SEPARATE ISOLATE from the main app.
//
// CRITICAL: Because this runs in its own isolate:
//   • notifyNewX() streams do NOT reach the main isolate's listeners
//   • AlertReloadCoordinator listeners registered in main() do NOT fire here
//   • We MUST call reloadX() explicitly and await it
//   • All setX() calls use immediate=true so sync fires before isolate dies
//   • sendDataToTask() (used inside AlertStateManager) also needs this
//     isolate's own communication port opened via initCommunicationPort() —
//     otherwise stop/switch signals to the running foreground task silently
//     no-op and the alert sound keeps playing until the app is reopened.

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

  // REQUIRED: opens the comms port for THIS isolate so sendDataToTask()
  // (called later inside AlertStateManager._sync / _startOrSwitch /
  // _stopService) can actually reach the running UnifiedAlertTaskHandler.
  // Without this, sendDataToTask() silently no-ops when called from the
  // background FCM isolate, which is why the alert sound previously kept
  // playing on other devices until the app was manually reopened.
  FlutterForegroundTask.initCommunicationPort();
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

  final data = message.data;
  final type = (data['type'] ?? '').toString();
  final stopAlert = (data['stop_alert'] ?? 'false').toString().toLowerCase() == 'true';

  print('Background FCM | type=$type | stop_alert=$stopAlert');

  // ── CRITICAL: If stop_alert is true, stop immediately ──
  // This handles SERVICE_TASK_ACCEPTED notifications which need cross-device
  // alert coordination. TASK_CLOSED does NOT send stop_alert since alerts
  // already stopped when the task was accepted.
  if (stopAlert) {
    print('Background FCM | stop_alert=true - stopping alert immediately');
    
    // Stop the siren IMMEDIATELY
    await AlertStateManager.dismissAll();
    
    // Then reconcile from server to get accurate counts
    await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
    await AlertReloadCoordinator.instance.reloadFood(silentReconcile: true);
    await AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true);
    
    print('Background FCM | stop_alert handled - siren stopped');
    // DON'T RETURN - let flushSync() run at the end
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

  print('Background FCM | type=$type | stop_alert=$stopAlert | role=$role | depts=$normalized');

  // Only process switch cases if stop_alert is false OR if it's SERVICE_TASK_ACCEPTED
  // SERVICE_TASK_ACCEPTED needs to run its delivery reload even when stopAlert=true
  if (!stopAlert || type == 'SERVICE_TASK_ACCEPTED' || type == 'ACCEPTED') {
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
        if (rawStatus == 'READY') {
          await AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true);
        }
        // break — not return — so flushSync() always runs below.
        // A return would skip flushSync() and leave the foreground service
        // playing sound even after the status changed to non-READY.
        break;

      case 'SERVICE_ORDER':
      case 'NEW_SERVICE_REQUEST':
      case 'TASK_REASSIGNED':
        print('Background FCM | Processing service request: $type');
        await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
        print('Background FCM | Completed reloadTasks for: $type');
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
        // stop_alert already handled at the top
        // But we still reconcile to be safe
        await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
        // For delivery orders: dismiss delivery alert first, then reload to get accurate count
        await AlertStateManager.dismissDelivery();
        await AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true);
        break;

      case 'DELIVERY_ACCEPTED':
      case 'DELIVERY_DELIVERED':
        await AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true);
        break;

      case 'TASK_CLOSED':
        // No stop_alert for close - alerts already stopped at accept
        // Just reconcile to update counts and remove closed tasks
        await AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true);
        await AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true);
        break;

      default:
        print('Background FCM: discarding unrecognised type=$type');
        break;
    }
  }

  // Explicit flush guarantees sync runs before isolate terminates.
  await AlertStateManager.flushSync();
  print('Background FCM: flushSync complete for type=$type');
}
