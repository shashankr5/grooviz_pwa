// services/order_alert_service.dart
import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'order_alert_foreground_task.dart';

class OrderAlertService {
  // Track how many pending orders are currently alerting.
  // This is incremented on NEW_FOOD_ORDER and decremented on accept/cancel.
  // The alert stops only when this reaches 0.
  static int _pendingOrderCount = 0;

  static final StreamController<void> _newOrderController =
      StreamController.broadcast();

  static Stream<void> get onNewOrder => _newOrderController.stream;

  static void notifyNewOrder() {
    _newOrderController.add(null);
  }

  // Call this when a NEW order arrives.
  // Always starts (or keeps) the alert running.
  // Does NOT debounce — every new order must ring.
  static Future<bool> start() async {
    _pendingOrderCount++;
    print('OrderAlertService.start() | pendingCount=$_pendingOrderCount');

    try {
      final isRunning = await FlutterForegroundTask.isRunningService;

      if (!isRunning) {
        // Service not running — start it fresh
        await FlutterForegroundTask.startService(
          notificationTitle: 'New Order',
          notificationText: 'Waiting for acceptance...',
          callback: startCallback,
        );
        print('Foreground service started');
      } else {
        // Already running — keep ringing, just update the count
        print('Foreground service already running, keeping alert active');
      }

      return true;
    } catch (e) {
      print('OrderAlertService.start failed: $e');
      _pendingOrderCount = (_pendingOrderCount - 1).clamp(0, 9999);
      return false;
    }
  }

  // Call this when ONE order is accepted or cancelled.
  // Only stops the alert when ALL pending orders are handled.
  static Future<void> stopOne() async {
    _pendingOrderCount = (_pendingOrderCount - 1).clamp(0, 9999);
    print('OrderAlertService.stopOne() | pendingCount=$_pendingOrderCount');

    if (_pendingOrderCount == 0) {
      await _stopService();
    } else {
      print('Alert continues: $_pendingOrderCount order(s) still pending');
    }
  }

  // Call this to force-stop regardless of count (e.g. on page refresh/reload).
  // Resets the counter completely.
  static Future<void> stop() async {
    print('OrderAlertService.stop() | force stop, resetting count');
    _pendingOrderCount = 0;
    await _stopService();
  }

  // Reset count without stopping — call when page reloads from backend
  // and you have the authoritative pending count from the API response.
  static void resetCount(int pendingCount) {
    _pendingOrderCount = pendingCount.clamp(0, 9999);
    print('OrderAlertService.resetCount() | pendingCount=$_pendingOrderCount');

    if (_pendingOrderCount == 0) {
      _stopService();
    }
  }

  static Future<void> _stopService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        print('Foreground service stopped');
      }
    } catch (e) {
      print('OrderAlertService._stopService failed: $e');
    }
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(OrderAlertTaskHandler());
}