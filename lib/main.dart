//main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'pages/login_page.dart';
import 'pages/main_navigation.dart';

import 'services/fcm_service.dart';
import 'services/notification_handler.dart';
import 'services/fcm_background.dart';
import 'utils/user_session_helper.dart';
import 'utils/notification_permission_manager.dart';
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
      iconData: const NotificationIconData(
        resType: ResourceType.mipmap,
        resPrefix: ResourcePrefix.ic,
        name: 'launcher',
      ),
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: const ForegroundTaskOptions(
      autoRunOnBoot: false,
      allowWakeLock: true,
    ),
  );

  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  //await NotificationPermissionManager.requestAllNotificationPermissions(); // permission for foreground service notifications (Android 13+)

  await FCMService.initialize();

  unawaited(FCMService.ensureFCMToken());

  await localNotifications.cancelAll();

  await createNotificationChannel();

  await setupFirebaseNotifications();

  // ✅ Check if user is logged in
  final bool isLoggedIn = await UserSessionHelper.isLoggedIn();

  runApp(MyApp(isLoggedIn: isLoggedIn));

  //unawaited(_bootstrapPush());
}

//Future<void> _bootstrapPush() async {
//  await FCMService.initialize();
//  await localNotifications.cancelAll();
//  await createNotificationChannel();
//  await setupFirebaseNotifications();
//}

class MyApp extends StatelessWidget {
  final bool isLoggedIn;

  const MyApp({super.key, required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      // This decides startup screen
      home: isLoggedIn ? const MainNavigation() : const LoginPage(),
    );
  }
}