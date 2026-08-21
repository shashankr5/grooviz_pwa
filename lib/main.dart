// main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'pages/login_page.dart';
import 'pages/main_navigation.dart';
import 'pages/delivery_page.dart';
import 'theme/app_theme.dart';

import 'services/fcm_service.dart';
import 'services/notification_handler.dart';
import 'services/fcm_background.dart';
import 'services/alert_reload_coordinator.dart';
import 'services/task_alert_service.dart';
import 'services/order_alert_service.dart';
import 'services/notification_navigation_coordinator.dart';
import 'services/bluetooth_printer_service.dart';
import 'utils/user_session_helper.dart';
import 'utils/app_colors.dart';

import 'package:flutter/foundation.dart';

void main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Intercept framework UI / rendering errors
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      print('🔴 Flutter Framework Error (intercepted): ${details.exception}');
    };

    // Intercept unhandled platform, socket, and async isolate errors
    PlatformDispatcher.instance.onError = (error, stack) {
      print('🔴 Uncaught Async Error (intercepted): $error\n$stack');
      return true; // Prevent native crash
    };

    await Firebase.initializeApp();

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'order_alert_service',
        channelName: 'ScreenSync Alerts',
        channelDescription: 'Plays alert sound for new orders',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
        enableVibration: false,
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
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    await _requestForegroundServicePermission();

    await FCMService.initialize();
    unawaited(FCMService.ensureFCMToken());

    await localNotifications.cancelAll();
    await createNotificationChannel();
    await setupFirebaseNotifications();

    AlertReloadCoordinator.init();

    // Initialize printer service — reloads persisted queue and print history
    unawaited(bluetoothPrinterService.init());

    final bool isLoggedIn = await UserSessionHelper.isLoggedIn();

    if (isLoggedIn) {
      // COLD LAUNCH RECONCILIATION:
      // Fetch the true pending counts from the server before rendering the app.
      try {
        await AlertReloadCoordinator.instance.reloadTasks();
        await AlertReloadCoordinator.instance.reloadFood();
        await AlertReloadCoordinator.instance.reloadDelivery();
      } catch (e) {
        print('Cold launch reconciliation reloads failed: $e');
      }

      // If true pending counts are zero, cancel all notifications and stop the service
      if (TaskAlertService.totalPending == 0 && OrderAlertService.pendingOrderCount == 0) {
        await TaskAlertService.stopAll();
        await OrderAlertService.stop();
        // Cancel all local notifications in the shade
        try {
          final FlutterLocalNotificationsPlugin localNotif = FlutterLocalNotificationsPlugin();
          await localNotif.cancelAll();
        } catch (_) {}
      }
    }

    runApp(MyApp(isLoggedIn: isLoggedIn));
  }, (error, stack) {
    print('🔴 Zone Guard Error: $error\n$stack');
  });
}

Future<void> _requestForegroundServicePermission() async {
  try {
    final status = await Permission.notification.request();
    if (status.isDenied) {
      print('Notification permission denied — alerts may not work');
    }
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  } catch (e) {
    print('Permission request error (non-fatal): $e');
  }
}

class MyApp extends StatefulWidget {
  final bool isLoggedIn;
  const MyApp({super.key, required this.isLoggedIn});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription<String>? _serviceFailSub;
  bool _serviceWarnShown = false;

  @override
  void initState() {
    super.initState();

    // FIX-1 (Bug 1): Case II — cold start / app-was-killed notification tap.
    // setupFirebaseNotifications() runs in main() *before* runApp(), so at
    // that point the Navigator does not exist yet and any push attempt made
    // there would silently no-op. Instead, notification_handler.dart stashes
    // the intended route in pendingDeepLinkRoute; once the first frame has
    // been drawn here (Navigator guaranteed to exist), we consume it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumePendingDeepLink();
    });

    _serviceFailSub = AlertReloadCoordinator.onServiceStartFailed.listen(
      (type) {
        if (_serviceWarnShown) return;
        _serviceWarnShown = true;
        Future.delayed(const Duration(seconds: 60), () {
          _serviceWarnShown = false;
        });
        _showServiceFailWarning(type);
      },
    );
  }

  void _consumePendingDeepLink() {
    NotificationNavigationCoordinator.instance.onPostLogin();
  }

  void _showServiceFailWarning(String type) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '⚠️ Alert sound may not work. Check notification permissions.',
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: AppColors.error,
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Fix',
          textColor: Colors.white,
          onPressed: () async {
            await openAppSettings();
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _serviceFailSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Grooviz Connect',
      theme: AppTheme.light,
      home: widget.isLoggedIn ? const MainNavigation() : const LoginPage(),
    );
  }
}

// Public so notification_handler.dart can import and write to these.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Set by notification_handler.dart when a notification is tapped.
// Supported values: 'home', 'food', 'delivery'.
// Consumed once by _MyAppState after the first frame renders.
String? pendingDeepLinkRoute;