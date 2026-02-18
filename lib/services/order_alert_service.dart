import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'order_alert_foreground_task.dart';

class OrderAlertService {
  static Future<void> start() async {
    if (await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.startService(
      notificationTitle: 'New Order',
      notificationText: 'Waiting for acceptance...',
      callback: startCallback,
    );
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(OrderAlertTaskHandler());
}
