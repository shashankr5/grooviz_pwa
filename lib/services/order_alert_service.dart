// services/order_alert_service.dart
import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'order_alert_foreground_task.dart';

class OrderAlertService {
  static DateTime? _lastTrigger;

  static Future<bool> start() async {
    try {
      //if (await FlutterForegroundTask.isRunningService) return true;
      final now = DateTime.now();

      // Debounce (avoid spam from multiple FCMs)
      if (_lastTrigger != null &&
          now.difference(_lastTrigger!) < const Duration(seconds: 2)) {
        print('⏱ Debounced duplicate order alert');
        return true;
      }
      _lastTrigger = now;

      final isRunning = await FlutterForegroundTask.isRunningService;

      // 🔥 FORCE RESTART (CRITICAL)
      if (isRunning) {
        print('🔄 Restarting existing foreground service...');
        await FlutterForegroundTask.stopService();

        // Small delay ensures clean restart
        await Future.delayed(const Duration(milliseconds: 300));
      }

      await FlutterForegroundTask.startService(
        notificationTitle: 'New Order',
        notificationText: 'Waiting for acceptance...',
        callback: startCallback,
      );

      return true;
    } catch (e) {
      print('OrderAlertService.start failed: $e');
      return false;
    }
  }

  static final StreamController<void> _newOrderController =
      StreamController.broadcast();

  static Stream<void> get onNewOrder => _newOrderController.stream;

  static void notifyNewOrder() {
    _newOrderController.add(null);
  }

  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
      _lastTrigger = null;
    } catch (e) {
      print('OrderAlertService.stop failed: $e');
    }
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(OrderAlertTaskHandler());
}