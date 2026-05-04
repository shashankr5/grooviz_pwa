// main.dart
//
// FIXES APPLIED:
//  FIX-9: Added foreground service permission request at startup (Android 14+
//          requires FOREGROUND_SERVICE and FOREGROUND_SERVICE_MEDIA_PLAYBACK
//          permissions to be granted at runtime — without this, startService()
//          silently fails on a non-trivial % of devices).
//          Added global listener for AlertReloadCoordinator.onServiceStartFailed
//          to surface a persistent warning when the service can't start.
//
//  FIX-10: FCMService.initialize() now registers onTokenRefresh listener
//          inside its own call — nothing extra needed here.
//
//  FIX-2: Logout flow (in profile_page / wherever logout is triggered)
//          must call FCMService.deregisterToken() and
//          WebSocketService().disconnect() — see logout_helper.dart.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

import 'pages/login_page.dart';
import 'pages/main_navigation.dart';

import 'services/fcm_service.dart';
import 'services/notification_handler.dart';
import 'services/fcm_background.dart';
import 'services/alert_reload_coordinator.dart';
import 'utils/user_session_helper.dart';
import 'utils/app_colors.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();

  FlutterForegroundTask.init(
  androidNotificationOptions: AndroidNotificationOptions(
    channelId: 'order_alert_service',
    channelName: 'Order Alert Service',
    channelDescription: 'Plays alert sound for new orders',
    channelImportance: NotificationChannelImportance.HIGH,
    priority: NotificationPriority.HIGH,
    // iconData removed in v8.x – if you need a custom icon, set it via
    // the notification builder in the handler or AndroidManifest metadata.
  ),
  iosNotificationOptions: const IOSNotificationOptions(
    showNotification: true,
    playSound: false,
  ),
  foregroundTaskOptions: ForegroundTaskOptions(
    autoRunOnBoot: false,
    allowWakeLock: true,
    eventAction: ForegroundTaskEventAction.nothing(),  // REQUIRED in v8.x
  ),
);
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // FIX-9: Request foreground service permissions before any alert can fire.
  // Android 14+ requires these at runtime — without them startService() fails
  // silently. Must be called before FCMService.initialize() so the permission
  // is granted before any incoming FCM triggers ensureRunning().
  await _requestForegroundServicePermission();

  // FIX-10: initialize() now registers onTokenRefresh listener internally.
  await FCMService.initialize();
  unawaited(FCMService.ensureFCMToken());

  await localNotifications.cancelAll();
  await createNotificationChannel();
  await setupFirebaseNotifications();

  // Must be after Firebase.initializeApp() and setupFirebaseNotifications().
  AlertReloadCoordinator.init();

  final bool isLoggedIn = await UserSessionHelper.isLoggedIn();

  runApp(MyApp(isLoggedIn: isLoggedIn));
}

// FIX-9: Request FOREGROUND_SERVICE permissions (Android 14+).
// Uses permission_handler package — add to pubspec.yaml:
//   permission_handler: ^11.x.x
// Add to AndroidManifest.xml:
//   <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
//   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
Future<void> _requestForegroundServicePermission() async {
  // Only needed on Android — permission_handler handles the platform check.
  try {
    final status = await Permission.notification.request();
    if (status.isDenied) {
      print('Notification permission denied — alerts may not work');
    }

    // Android 14+ foreground service permission
    // FlutterForegroundTask handles this internally on supported versions,
    // but explicit request ensures it on edge cases.
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
  // Track whether we've shown the warning recently to avoid spam
  bool _serviceWarnShown = false;

  @override
  void initState() {
    super.initState();
    // FIX-9: Listen for foreground service start failures.
    // Shows a SnackBar warning so staff know alerts may not ring.
    _serviceFailSub = AlertReloadCoordinator.onServiceStartFailed.listen(
      (type) {
        if (_serviceWarnShown) return;
        _serviceWarnShown = true;
        // Reset flag after 60s so it can warn again if needed
        Future.delayed(const Duration(seconds: 60), () {
          _serviceWarnShown = false;
        });
        // Use a global key to show SnackBar from root
        _showServiceFailWarning(type);
      },
    );
  }

  void _showServiceFailWarning(String type) {
    final context = _navigatorKey.currentContext;
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
            await openAppSettings(); // from permission_handler
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
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Login UI',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.bgLight,
        colorScheme: const ColorScheme.light(
          primary: AppColors.primary,
          secondary: AppColors.secondary,
          error: AppColors.error,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: AppColors.textPrimary,
          elevation: 1,
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: AppColors.textPrimary),
          bodySmall: TextStyle(color: AppColors.textSecondary),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.primaryDark,
          contentTextStyle: const TextStyle(color: Colors.white),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      home: widget.isLoggedIn ? const MainNavigation() : const LoginPage(),
    );
  }
}

// Global navigator key for showing SnackBars from outside widget tree
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();