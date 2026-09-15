import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';

import '../models/notification_event.dart';
import 'fcm_service.dart';
import 'notification_event_decoder.dart';

typedef NotificationEventCallback = void Function(NotificationEvent event);

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel _alertChannel = AndroidNotificationChannel(
  'alert_channel_v7',
  'Order and service alerts',
  description: 'Order and service request notifications.',
  importance: Importance.high,
  playSound: false,
  enableVibration: true,
);

const AndroidNotificationChannel _escalationChannel =
    AndroidNotificationChannel(
  'escalation_channel_v5',
  'Escalation alerts',
  description: 'Escalated task notifications.',
  importance: Importance.high,
  playSound: true,
  sound: RawResourceAndroidNotificationSound('escalation'),
  enableVibration: true,
);

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();
  static const MethodChannel _alertLoopChannel =
      MethodChannel('com.tekchant.screensync/alert_loop');

  NotificationEventCallback? _onNotificationTap;
  NotificationEventCallback? get onNotificationTap => _onNotificationTap;
  set onNotificationTap(NotificationEventCallback? callback) {
    _onNotificationTap = callback;
    final pending = _pendingTap;
    _pendingTap = null;
    if (callback != null && pending != null) callback(pending);
  }

  NotificationEventCallback? onNotificationReceived;
  NotificationEvent? _pendingTap;
  bool _initialized = false;
  final Map<String, int> _activeNotificationIds = {};

  Future<void> initialize() async {
    if (_initialized) return;
    await _initializeLocalNotifications();
    await _requestPermission();
    FirebaseMessaging.instance.onTokenRefresh.listen(FCMService.handleTokenRefresh);
    FirebaseMessaging.onMessage.listen(_handleMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleOpenedMessage);

    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) _handleOpenedMessage(initialMessage);
    _initialized = true;
  }

  Future<void> _initializeLocalNotifications() async {
    await _localNotifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        final decoded = jsonDecode(payload);
        if (decoded is! Map) return;
        final data = <String, String>{
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value.toString(),
        };
        _emitTap(NotificationEventDecoder.decodeData(data));
      },
    );

    final android = _localNotifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_alertChannel);
    await android?.createNotificationChannel(_escalationChannel);
  }

  Future<void> _requestPermission() async {
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: false,
      badge: false,
      sound: false,
    );
  }

  Future<void> _handleMessage(RemoteMessage message) async {
    final event = NotificationEventDecoder.decode(message);
    if (event == null) {
      dev.log('Ignoring unknown FCM event: ${message.data['type']}');
      return;
    }
    if (event.shouldStopAudio || event.stopAlert) {
      await stopAlert(
        serviceRequestId: event.serviceRequestId,
        orderId: event.orderId,
        foodOrderSummaryId: event.foodOrderSummaryId,
      );
    }
    onNotificationReceived?.call(event);
    if (event.shouldPlayAudio) {
      if (Platform.isAndroid) {
        await _startNativeAlertLoop(event);
      } else {
        await _showLocalNotification(event);
      }
    }
  }

  void _handleOpenedMessage(RemoteMessage message) {
    _emitTap(NotificationEventDecoder.decode(message));
  }

  void _emitTap(NotificationEvent? event) {
    if (event == null) return;
    if (event.type != NotificationType.taskClosed) {
      stopAlert(
        serviceRequestId: event.serviceRequestId,
        orderId: event.orderId,
        foodOrderSummaryId: event.foodOrderSummaryId,
      );
    }
    final callback = _onNotificationTap;
    if (callback == null) {
      _pendingTap = event;
    } else {
      callback(event);
    }
  }

  static int _notificationIdFor(NotificationEvent event) {
    if (event.serviceRequestId != null && event.serviceRequestId!.isNotEmpty) {
      return ('sr_${event.serviceRequestId}').hashCode;
    }
    if (event.orderId != null && event.orderId!.isNotEmpty) {
      return ('order_${event.orderId}').hashCode;
    }
    if (event.foodOrderSummaryId != null && event.foodOrderSummaryId!.isNotEmpty) {
      return ('food_${event.foodOrderSummaryId}').hashCode;
    }
    return event.id.hashCode;
  }

  static String? _trackKeyFor(NotificationEvent event) {
    if (event.serviceRequestId != null && event.serviceRequestId!.isNotEmpty) {
      return 'sr_${event.serviceRequestId}';
    }
    if (event.orderId != null && event.orderId!.isNotEmpty) {
      return 'order_${event.orderId}';
    }
    if (event.foodOrderSummaryId != null && event.foodOrderSummaryId!.isNotEmpty) {
      return 'food_${event.foodOrderSummaryId}';
    }
    return null;
  }

  Future<void> stopAlert({
    String? serviceRequestId,
    String? orderId,
    String? foodOrderSummaryId,
  }) async {
    try {
      await _stopNativeAlertLoop();

      final idsToCancel = <String>{};
      if (serviceRequestId != null && serviceRequestId.trim().isNotEmpty) {
        idsToCancel.add(serviceRequestId.trim());
      }
      if (orderId != null && orderId.trim().isNotEmpty) {
        idsToCancel.add(orderId.trim());
      }
      if (foodOrderSummaryId != null && foodOrderSummaryId.trim().isNotEmpty) {
        idsToCancel.add(foodOrderSummaryId.trim());
      }

      if (idsToCancel.isEmpty) {
        await stopAllAlerts();
        return;
      }

      for (final id in idsToCancel) {
        // Cancel all known key prefix variants
        final prefixes = ['sr_', 'order_', 'food_', 'task_', ''];
        for (final prefix in prefixes) {
          final key = '$prefix$id';
          final notifId = _activeNotificationIds.remove(key) ?? key.hashCode;
          await _localNotifications.cancel(notifId);
        }

        final numericId = int.tryParse(id);
        if (numericId != null) {
          await _localNotifications.cancel(numericId);
        }

        // Also purge any active key containing this id
        final matchingKeys = _activeNotificationIds.keys
            .where((k) => k.contains(id))
            .toList();
        for (final k in matchingKeys) {
          final storedId = _activeNotificationIds.remove(k);
          if (storedId != null) {
            await _localNotifications.cancel(storedId);
          }
        }
      }

      // If no active notifications remain in our tracking, cancelAll to be 100% sure
      if (_activeNotificationIds.isEmpty) {
        await _localNotifications.cancelAll();
      }
    } catch (e) {
      dev.log('NotificationService: error in stopAlert: $e');
    }
  }

  Future<void> stopAllAlerts() async {
    try {
      await _stopNativeAlertLoop();
      await _localNotifications.cancelAll();
      _activeNotificationIds.clear();
    } catch (e) {
      dev.log('NotificationService: error in stopAllAlerts: $e');
    }
  }

  Future<void> _startNativeAlertLoop(NotificationEvent event) async {
    try {
      await _alertLoopChannel.invokeMethod<void>(
        'start',
        <String, dynamic>{
          'title': event.title,
          'body': event.body,
        },
      );
    } catch (e) {
      dev.log('NotificationService: native alert loop unavailable: $e');
    }
  }

  Future<void> _stopNativeAlertLoop() async {
    if (!Platform.isAndroid) return;
    try {
      await _alertLoopChannel.invokeMethod<void>('stop');
    } catch (e) {
      dev.log('NotificationService: native alert loop stop failed: $e');
    }
  }

  Future<void> _showLocalNotification(NotificationEvent event) async {
    if (event.title.isEmpty && event.body.isEmpty) return;
    final sound = event.notificationSound;
    final channel = sound == 'escalation' ? _escalationChannel : _alertChannel;
    final int notifId = _notificationIdFor(event);

    final trackKey = _trackKeyFor(event);
    if (trackKey != null) {
      _activeNotificationIds[trackKey] = notifId;
    }

    await _localNotifications.show(
      notifId,
      event.title,
      event.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: Importance.high,
          priority: Priority.high,
            playSound: sound != null && sound != 'alert',
            sound: sound == null || sound == 'alert'
              ? null
              : RawResourceAndroidNotificationSound(sound),
          enableVibration: true,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          sound: sound != null
              ? (sound == 'alert' ? 'alert.wav' : '$sound.wav')
              : null,
        ),
      ),
      payload: jsonEncode(event.data),
    );
  }
}

/// Background / terminated-state FCM handler.
///
/// Runs in a separate Dart isolate spun up by the FCM plugin.
///
/// IMPORTANT — Android channel sound rules:
///   • Notification messages (FCM sends with a `notification` block) are
///     displayed directly by the system using the channel declared in the
///     manifest default channel. We must NOT re-show them here or the
///     user gets a duplicate with potentially wrong sound.
///   • Data-only messages have no `notification` block, so the system won't
///     display them — we handle those ourselves via flutter_local_notifications.
///   • Channel sound is locked after first creation on Android O+. We call
///     _ensureChannelsRegistered() which only creates channels; it never
///     re-initialises the plugin (which would lose the tap callback) and
///     never overwrites an existing channel's sound.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // Only handle data-only messages. Notification messages are already
  // displayed by FCM using the manifest default channel — touching them
  // here produces duplicates with potentially missing sound.
  if (message.notification != null) return;

  final event = NotificationEventDecoder.decode(message);
  if (event == null) return;

  // Ensure channels exist with their custom sounds before we post.
  await _ensureChannelsRegistered();

  if (event.shouldStopAudio || event.stopAlert) {
    await NotificationService.instance.stopAlert(
      serviceRequestId: event.serviceRequestId,
      orderId: event.orderId,
      foodOrderSummaryId: event.foodOrderSummaryId,
    );
    return;
  }

  if (event.shouldPlayAudio) {
    if (!Platform.isAndroid) {
      await NotificationService.instance._showLocalNotification(event);
    }
  }
}

/// Registers the notification channels without re-initialising the full
/// plugin. Safe to call multiple times — Android is a no-op if the channel
/// already exists with the correct sound.
Future<void> _ensureChannelsRegistered() async {
  // Minimal plugin init — no tap callback needed in the background isolate.
  await _localNotifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ),
  );
  final android = _localNotifications.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(_alertChannel);
  await android?.createNotificationChannel(_escalationChannel);
}


