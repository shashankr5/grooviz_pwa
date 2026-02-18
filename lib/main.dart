//main.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'pages/login_page.dart';
import 'pages/main_navigation.dart';

import 'services/fcm_service.dart';
import 'utils/user_session_helper.dart';
import 'services/notification_handler.dart';
import 'services/fcm_background.dart';
import 'utils/notification_permission_manager.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';


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

  FCMService.initialize();

  await NotificationPermissionManager.requestSafely();

  await setupFirebaseNotifications();

  await localNotifications.cancelAll();

  await createNotificationChannel();

  // ✅ Check if user is logged in
  final bool isLoggedIn = await UserSessionHelper.isLoggedIn();

  runApp(MyApp(isLoggedIn: isLoggedIn));
}

class MyApp extends StatelessWidget {
  final bool isLoggedIn;

  const MyApp({super.key, required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Login UI',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
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