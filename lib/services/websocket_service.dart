// services/websocket_service.dart
//
// FIXES APPLIED:
//  FIX-3 (BLOCKER): Added connection identity guard in connect().
//          Previously, every FoodOrdersPage.initState() called
//          ws.connect() which closed and reopened the channel unconditionally.
//          Tab switches, navigation pops, and app resumes all caused a
//          reconnect storm — during the 1-5s reconnect window, FCM/WS
//          events were silently dropped.
//          Now connect() is a no-op if already connected with the same
//          userId + enterpriseId. Only reconnects when credentials change
//          (i.e. a different user logs in) or when the connection is lost.
//
//  FIX-5: Added disconnect() method for use on logout. Prevents the old
//          user's WS channel from receiving events after logout.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'order_alert_service.dart';
import 'task_alert_service.dart';

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  final StreamController<Map<String, dynamic>> _controller =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get stream => _controller.stream;

  final ValueNotifier<bool> isConnected = ValueNotifier(false);

  bool _isDisposed   = false;
  bool _isConnecting = false;

  String? _userId;
  String? _enterpriseId;

  static const String _wsUrl =
      'wss://3fj7tlzfk3.execute-api.ap-south-1.amazonaws.com/production';

  // ── Connect ────────────────────────────────────────────────────────────

  void connect({String? userId, String? enterpriseId}) {
    // FIX-3: Guard — skip reconnect if already connected with same credentials.
    // This prevents the reconnect storm caused by FoodOrdersPage.initState()
    // calling connect() on every tab switch / navigation / app resume.
    final sameCredentials = userId == _userId && enterpriseId == _enterpriseId;
    if (sameCredentials && isConnected.value) {
      print('WebSocket: already connected for user=$_userId — skipping reconnect');
      return;
    }

    // Update credentials if they changed (e.g. different user logging in)
    if (userId != null)       _userId       = userId;
    if (enterpriseId != null) _enterpriseId = enterpriseId;

    if (_isConnecting || _isDisposed) return;
    _isConnecting = true;

    try {
      _channel?.sink.close(status.goingAway);
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));

      _subscription?.cancel();
      _subscription = _channel!.stream.listen(
        (message) {
          if (!isConnected.value) {
            isConnected.value = true;
            print('WebSocket connected | user=$_userId');
          }
          _handleMessage(message);
        },
        onError: _onError,
        onDone:  _onDone,
      );

      if (_userId != null && _enterpriseId != null) {
        _channel!.sink.add(jsonEncode({
          'action':        'register',
          'enterprise_id': _enterpriseId,
          'user_id':       _userId,
        }));
      }
    } catch (e) {
      print('WebSocket connection failed: $e');
      _scheduleReconnect();
    } finally {
      _isConnecting = false;
    }
  }

  // ── Disconnect (call on logout) ────────────────────────────────────────

  // FIX-5: Explicit disconnect for logout. Clears credentials so the next
  // connect() call (after new login) opens a fresh channel for the new user.
  void disconnect() {
    print('WebSocket: disconnecting (logout)');
    _isDisposed = false; // allow future reconnect after new login
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close(status.normalClosure);
    _channel = null;
    isConnected.value = false;
    _userId       = null;
    _enterpriseId = null;
  }

  // ── Send ───────────────────────────────────────────────────────────────

  void sendMessage(Map<String, dynamic> message) {
    if (_channel == null || !isConnected.value) return;
    try {
      _channel!.sink.add(jsonEncode(message));
    } catch (e) {
      print('WS sendMessage error: $e');
    }
  }

  // ── Message handler ────────────────────────────────────────────────────

  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String);
      final type = (data['type'] ?? '').toString().toUpperCase();

      print('WS Received: $type');

      // Broadcast to all page listeners first.
      if (!_controller.isClosed) {
        _controller.add(data);
      }

      // ── Food order alerts ──────────────────────────────────────────────

      if (type == 'NEW_FOOD_ORDER') {
        OrderAlertService.ensureRunning();
        return;
      }

      if (type == 'ORDER_ACCEPTED' || type == 'ORDER_CANCELLED') {
        OrderAlertService.notifyNewOrder();
        return;
      }

      if (type == 'ORDER_DELIVERED') {
        OrderAlertService.stop();
        return;
      }

      // ORDER_STATUS_CHANGED (READY/PREPARING) → no alert action.

      // ── Service task alerts ────────────────────────────────────────────

      if (type == 'NEW_SERVICE_TASK') {
        TaskAlertService.ensureServiceRunning();
        TaskAlertService.notifyNewTask();
        return;
      }

      if (type == 'SERVICE_TASK_ACCEPTED') {
        TaskAlertService.notifyNewTask();
        return;
      }

      // ── Delivery alerts ────────────────────────────────────────────────

      if (type == 'NEW_DELIVERY_TASK') {
        TaskAlertService.ensureDeliveryRunning();
        TaskAlertService.notifyNewDelivery();
        return;
      }

      if (type == 'DELIVERY_ACCEPTED') {
        TaskAlertService.notifyNewDelivery();
        return;
      }

      if (type == 'DELIVERY_DELIVERED') {
        TaskAlertService.notifyNewDelivery();
        return;
      }

    } catch (e) {
      print('WS Message error: $e');
    }
  }

  // ── Error / Done ───────────────────────────────────────────────────────

  void _onError(dynamic error) {
    print('WebSocket Error: $error');
    isConnected.value = false;
    _scheduleReconnect();
  }

  void _onDone() {
    print('WebSocket disconnected');
    isConnected.value = false;
    // Only reconnect if we still have credentials (not logged out)
    if (_userId != null) _scheduleReconnect();
  }

  // ── Reconnect ──────────────────────────────────────────────────────────

  void _scheduleReconnect() {
    if (_isDisposed || _userId == null) return;
    Future.delayed(const Duration(seconds: 5), () {
      if (!_isDisposed && _userId != null) {
        connect(userId: _userId, enterpriseId: _enterpriseId);
      }
    });
  }

  // ── Dispose ────────────────────────────────────────────────────────────

  void dispose() {
    _isDisposed = true;
    _subscription?.cancel();
    _channel?.sink.close(status.normalClosure);
    _controller.close();
    isConnected.dispose();
  }
}