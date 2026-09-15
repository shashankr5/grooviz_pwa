// main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'pages/login_page.dart';
import 'pages/main_navigation.dart';

import 'theme/app_theme.dart';
import 'models/notification_event.dart';

import 'services/bluetooth_printer_service.dart';
import 'services/notification_service.dart';
import 'services/midnight_notifier.dart';
import 'utils/user_session_helper.dart';

import 'package:flutter/foundation.dart';

void main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
    } catch (e) {
      print('Firebase initialization failed: $e');
    }

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

    // ── Synchronous, non-blocking setup ──────────────────────────────────
    // None of these await network/permissions, so they cannot stall the
    // first frame. Registering the background handler here (before runApp)
    // ── RENDER THE SPLASH SCREEN FIRST ───────────────────────────────────
    // BLANK SCREEN FIX: Show splash screen immediately while all blocking
    // network/permission/plugin initialisation happens in the background.
    // The splash screen will handle login check and navigation internally.
    final bool isLoggedIn = await UserSessionHelper.isLoggedIn();
    
    runApp(MyApp(isLoggedIn: isLoggedIn));

    _initializeServicesAfterFirstFrame(isLoggedIn);
  }, (error, stack) {
    print('🔴 Zone Guard Error: $error\n$stack');
  });
}

/// All initialisation that can block on network, permission dialogs, or
/// platform services runs here — AFTER the first frame is drawn — so the UI
/// is always visible regardless of how these calls behave on a given device.
void _initializeServicesAfterFirstFrame(bool isLoggedIn) async {
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    // Printer service — not needed before first frame.
    unawaited(bluetoothPrinterService.init());
    // Start the midnight notifier so all pages can reset at day rollover.
    MidnightNotifier.instance.start();
    NotificationService.instance.onNotificationTap = (event) {
      final departmentName =
        (event.data['department_name'] ?? '').trim().toLowerCase();
      final isRoomServiceDelivery = event.type == NotificationType.foodOrderStatus &&
        (departmentName == 'room service' || event.serviceRequestId != null);
      final foodEvent = event.type == NotificationType.newFoodOrder ||
        (event.type == NotificationType.foodOrderStatus &&
          !isRoomServiceDelivery);
      MainNavigation.tabSwitchCallback?.call(foodEvent ? 'food' : 'home');
    };

    // Foreground messages: FCM suppresses the OS notification when the app is
    // open (setForegroundNotificationPresentationOptions is all-false), so we
    // must show it ourselves via flutter_local_notifications — which uses our
    // custom channels and plays the correct sound.
    // We also switch to the relevant tab so the staff sees the new item.
    NotificationService.instance.onNotificationReceived = (event) {
      final departmentName =
        (event.data['department_name'] ?? '').trim().toLowerCase();
      final isRoomServiceDelivery = event.type == NotificationType.foodOrderStatus &&
        (departmentName == 'room service' || event.serviceRequestId != null);
      final foodEvent = event.type == NotificationType.newFoodOrder ||
        (event.type == NotificationType.foodOrderStatus &&
          !isRoomServiceDelivery);
      MainNavigation.tabSwitchCallback?.call(foodEvent ? 'food' : 'home');
    };

    unawaited(NotificationService.instance.initialize());

  });
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

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();