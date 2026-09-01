// main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

import 'pages/login_page.dart';
import 'pages/main_navigation.dart';
import 'theme/app_theme.dart';

import 'services/fcm_service.dart';
import 'services/notification_handler.dart';
import 'services/fcm_background.dart';
import 'services/alert_reload_coordinator.dart';
import 'services/notification_navigation_coordinator.dart';
import 'services/bluetooth_printer_service.dart';
import 'utils/user_session_helper.dart';
import 'utils/notification_permission_manager.dart';

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

    // Firebase must be ready before onBackgroundMessage is registered and
    // before any messaging call. Guarded so a config/network failure on a
    // specific device can NEVER abort the launch and leave a blank screen.
    try {
      await Firebase.initializeApp();
    } catch (e) {
      print('🔴 Firebase.initializeApp() failed (continuing): $e');
    }

    // ── Synchronous, non-blocking setup ──────────────────────────────────
    // None of these await network/permissions, so they cannot stall the
    // first frame. Registering the background handler here (before runApp)
    // is required by firebase_messaging.
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

    // REQUIRED: opens this (main app) isolate's communication port so
    // sendDataToTask() calls made from AlertStateManager (_startOrSwitch /
    // _stopService) reliably reach the running UnifiedAlertTaskHandler.
    // The background FCM isolate (fcm_background.dart) calls this too —
    // each isolate that talks to the task handler must open its own port.
    FlutterForegroundTask.initCommunicationPort();

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Local, fast disk read — safe to await before the first frame.
    final bool isLoggedIn = await UserSessionHelper.isLoggedIn();

    // ── RENDER THE UI FIRST ──────────────────────────────────────────────
    // BLANK SCREEN FIX: previously main() awaited permission dialogs,
    // FCMService.initialize(), setupFirebaseNotifications() (which awaits an
    // un-timeboxed getToken()) and more BEFORE runApp(). On devices where any
    // of those calls hangs (no Play Services connectivity, permission dialog,
    // slow FCM), runApp() was never reached → permanent blank screen.
    // We now draw the login/home screen immediately and push ALL blocking
    // network/permission/plugin initialisation to after the first frame.
    runApp(MyApp(isLoggedIn: isLoggedIn));

    _initializeServicesAfterFirstFrame(isLoggedIn);
  }, (error, stack) {
    print('🔴 Zone Guard Error: $error\n$stack');
  });
}

/// All initialisation that can block on network, permission dialogs, or
/// platform services runs here — AFTER the first frame is drawn — so the UI
/// is always visible regardless of how these calls behave on a given device.
void _initializeServicesAfterFirstFrame(bool isLoggedIn) {
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    // Notification permission (may show an Android 13+ dialog — now shown
    // over the rendered UI instead of a blank screen).
    try {
      await _requestForegroundServicePermission();
    } catch (e) {
      print('Permission request failed (non-fatal): $e');
    }

    // FCM token acquisition — robust, self-timeboxed, retry-driven.
    try {
      await FCMService.initialize();
      unawaited(FCMService.ensureFCMToken());
    } catch (e) {
      print('FCM initialise failed (non-fatal): $e');
    }

    // Printer service — not needed before first frame.
    unawaited(bluetoothPrinterService.init());

    // Local notifications + FCM message/deep-link wiring.
    try {
      await localNotifications.cancelAll();
      await createNotificationChannel();
      await setupFirebaseNotifications();
    } catch (e) {
      print('Notification setup failed (non-fatal): $e');
    }

    AlertReloadCoordinator.init();

    // COLD LAUNCH RECONCILIATION — silentReconcile:true prevents alerts firing
    // for pre-existing pending tasks on a fresh launch.
    //
    // NOTE: No manual stopAll() / stop() call here. Each reload calls
    // AlertStateManager.setXCount(immediate:true) which triggers _sync()
    // internally. If all counts are zero after the reload, _sync() calls
    // _stopService() on its own. A manual stop would race against the counts
    // the reloads just set and could silence a legitimately active alert.
    if (isLoggedIn) {
      try {
        await Future.wait([
          AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true),
          AlertReloadCoordinator.instance.reloadFood(silentReconcile: true),
          AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true),
        ]);
      } catch (e) {
        print('Cold launch reconciliation reloads failed: $e');
      }
    }
  });
}

Future<void> _requestForegroundServicePermission() async {
  // Notification-only at cold start (no context yet for battery dialog).
  // The one-time battery optimisation sheet is shown by MainNavigation
  // after the first frame via NotificationPermissionManager.requestAllPermissions().
  await NotificationPermissionManager.requestNotificationOnly();
}

class MyApp extends StatefulWidget {
  final bool isLoggedIn;
  const MyApp({super.key, required this.isLoggedIn});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();

    // Cold start / app-was-killed notification tap:
    // setupFirebaseNotifications() runs in main() before runApp(), so the
    // Navigator does not exist yet and any push attempt made there would
    // silently no-op. NotificationNavigationCoordinator stashes the payload
    // internally; once the first frame is drawn here (Navigator guaranteed
    // to exist) we consume it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumePendingDeepLink();
    });
  }

  void _consumePendingDeepLink() {
    NotificationNavigationCoordinator.instance.onPostLogin();
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

// Public so notification_handler.dart can access the navigator.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();