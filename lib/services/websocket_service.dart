// services/websocket_service.dart
//
// CHANGES IN THIS VERSION:
//  • RUSH_HOUR_UPDATED — broadcast to all page listeners so FoodOrdersPage
//    can update rush hour state in real-time across all devices without
//    a manual reload. No sound or alert side-effects needed for this type.
//
// Previous changes retained:
//  • ESCALATION_ALERT — calls TaskAlertService.notifyEscalation()
//  • PULSE            — re-rings task alert sound
//  • ACCEPTED         — another device accepted a task; refreshes task list
//  • TASK_CLOSED      — task closed from another device; refreshes task list
//  FIX-3: Connection identity guard in connect()
//  FIX-5: disconnect() for use on logout

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
    final sameCredentials = userId == _userId && enterpriseId == _enterpriseId;
    if (sameCredentials && isConnected.value) {
      print('WebSocket: already connected for user=$_userId — skipping reconnect');
      return;
    }

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

  void disconnect() {
    print('WebSocket: disconnecting (logout)');
    _isDisposed = false;
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

      // Broadcast to all page listeners first so any page-level
      // StreamBuilder or stream.listen() receives the raw event
      // before we act on side-effects below.
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

      if (type == 'ORDER_STATUS_CHANGED' || type == 'ORDER_STATUS_UPDATED') {
        final newStatus = (data['new_status'] ?? data['order_status'] ?? data['status'] ?? '').toString().toUpperCase();
        if (newStatus == 'READY') {
          TaskAlertService.ensureDeliveryRunning();
          TaskAlertService.notifyNewDelivery();
        }
        return;
      }

      // ── ETA update ────────────────────────────────────────────────────
      // ORDER_ETA_UPDATED is already broadcast to stream listeners above.
      // FoodOrdersPage._handleSocketEtaUpdate() handles it directly.
      // No side-effect needed here.

      // ── Rush Hour sync ─────────────────────────────────────────────────
      if (type == 'RUSH_HOUR_UPDATED') {
        return;
      }

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

      if (type == 'NEW_DELIVERY_TASK' || type == 'ORDER_READY' || type == 'FOOD_ORDER_READY' || type == 'DELIVERY_READY') {
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

      // ── Escalation alert ───────────────────────────────────────────────

      if (type == 'ESCALATION_ALERT') {
        final badgeCount = int.tryParse(
              (data['badge_count'] ?? '').toString(),
            ) ??
            0;
        TaskAlertService.notifyEscalation(badgeCount);
        return;
      }

      // ── Pulse ──────────────────────────────────────────────────────────

      if (type == 'PULSE') {
        TaskAlertService.ensureServiceRunning();
        TaskAlertService.notifyNewTask();
        return;
      }

      // ── Accepted ───────────────────────────────────────────────────────

      if (type == 'ACCEPTED') {
        TaskAlertService.stopOneServiceAlert();
        TaskAlertService.notifyNewTask();
        return;
      }

      // ── Task closed ────────────────────────────────────────────────────

      if (type == 'TASK_CLOSED') {
        TaskAlertService.notifyNewTask();
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