//notification_handler.dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../utils/order_alert_sound.dart';
import '../services/order_alert_service.dart';
import 'fcm_service.dart';


final FlutterLocalNotificationsPlugin localNotifications = FlutterLocalNotificationsPlugin();


Future<void> setupFirebaseNotifications() async {
  // Initialize local notifications
  await _initializeLocalNotifications();

  final messaging = FirebaseMessaging.instance;

  // Token already saved by FCMService – this just logs
  final token = await FCMService.getCachedFCMToken();
  print('FCM token (cached): $token');

  // FOREGROUND
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    print('📨 Foreground message');

    // Ignore totally empty/system messages
    if (message.data.isEmpty && message.notification == null) {
      print('⛔ Empty message ignored');
      return;
    }

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

Future<void> createNotificationChannel() async {
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'high_importance_channel', // MUST match showNotification
    'High Importance Notifications',
    description: 'This channel is used for important notifications.',
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('bell_notification'),
  );

  await localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
      
    // Also create the channel used by the foreground service (important for Android 13+ to ensure service notifications work properly)
    const AndroidNotificationChannel fgChannel = AndroidNotificationChannel(
    'order_alert_service', // used by FlutterForegroundTask.init
    'Order Alert Service',
    description: 'Foreground service notifications for order alerts.',
    importance: Importance.high,
    playSound: false, // foreground service plays audio itself; don't play notification sound
    );

    await localNotifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(fgChannel);
    // Order Alert Service
}

Future<void> _showNotification(RemoteMessage message) async {
  final data = message.data;
  final title = data['title'] ?? '📢 New Service Request';
  final body = data['body'] ?? data['message'] ?? '';
  final String? type = data['type'];

  print('🎯 Showing notification');
  print('Title: $title');
  print('Body: $body');
  print('Type: ${data['type']}');
  print('Instance: ${data['instance_id']}');

  if (type == 'NEW_FOOD_ORDER') {
    // 🔔 Foreground sound
    //OrderAlertSound.start();
    // 🔔 Background / closed app sound
    await OrderAlertService.start();
    OrderAlertService.notifyNewOrder();
  }

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
        sound: RawResourceAndroidNotificationSound('bell_notification'),
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

    case 'NEW_FOOD_ORDER':
      // 🔔 ensure alert sound stops if running
      OrderAlertService.notifyNewOrder();
      break;

    case 'NEW_SERVICE_REQUEST':
      print('➡ Navigate to service request');
      // TODO: add navigation logic here
      break;

    default:
      print('➡ Open notifications');
  }
}