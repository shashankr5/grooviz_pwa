import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin localNotifications = FlutterLocalNotificationsPlugin();

Future<void> setupFirebaseNotifications() async {
  // Initialize local notifications
  await _initializeLocalNotifications();

  final messaging = FirebaseMessaging.instance;

  await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  // Token already saved by FCMService – this just logs
  final token = await messaging.getToken();
  print('📱 FCM Token: $token');

  // FOREGROUND
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    print('📨 Foreground message');
    _showNotification(message);
  });

  // TERMINATED
  final initialMessage = await messaging.getInitialMessage();
  if (initialMessage != null) {
    print('🚀 Opened from terminated');
    _handleMessage(initialMessage);
  }

  // BACKGROUND → TAP
  FirebaseMessaging.onMessageOpenedApp.listen(_handleMessage);
}

Future<void> _initializeLocalNotifications() async {
  const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings iosSettings = DarwinInitializationSettings();

  const InitializationSettings initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );

  await localNotifications.initialize(initSettings);
}

void _showNotification(RemoteMessage message) {
  final data = message.data;
  final title = message.notification?.title ?? 'Notification';
  final body = message.notification?.body ?? '';

  print('🎯 Showing notification');
  print('Title: $title');
  print('Body: $body');
  print('Type: ${data['type']}');
  print('Instance: ${data['instance_id']}');

  // Display notification on device
  localNotifications.show(
    message.hashCode,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'high_importance_channel',
        'High Importance Notifications',
        channelDescription: 'This channel is used for important notifications.',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    ),
    payload: data.toString(),
  );
}

void _handleMessage(RemoteMessage message) {
  print('👆 Notification tapped');

  final type = message.data['type'];

  switch (type) {
    case 'NEW_SERVICE_REQUEST':
      print('➡ Navigate to service request');
      break;

    default:
      print('➡ Open notifications');
  }
}
