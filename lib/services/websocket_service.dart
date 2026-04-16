// websocket_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'order_alert_service.dart';

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

  bool _isDisposed = false;
  bool _isConnecting = false;

  String? _userId;
  String? _enterpriseId;

  // ✅ CORRECT WEBSOCKET URL FOR AWS API GATEWAY
  static const String _wsUrl = 'wss://3fj7tlzfk3.execute-api.ap-south-1.amazonaws.com/production';

  // ================= CONNECT =================
  void connect({String? userId, String? enterpriseId}) {
    if (userId != null) _userId = userId;
    if (enterpriseId != null) _enterpriseId = enterpriseId;

    if (_isConnecting || _isDisposed) return;
    _isConnecting = true;

    try {
      _channel?.sink.close(status.goingAway);

      _channel = WebSocketChannel.connect(
        Uri.parse(_wsUrl),
      );

      _subscription?.cancel();
      _subscription = _channel!.stream.listen(
        (message) {
          if (!isConnected.value) {
            isConnected.value = true;
            print('✅ WebSocket connected (confirmed)');
          }
          _handleMessage(message);
        },
        onError: _onError,
        onDone: _onDone,
      );

      // ✅ Register user with correct payload format expected by backend
      if (_userId != null && _enterpriseId != null) {
        _channel!.sink.add(jsonEncode({
          'action': 'register',
          'enterprise_id': _enterpriseId,
          'user_id': _userId,
        }));
        print('📤 Sent registration: enterprise_id=$_enterpriseId, user_id=$_userId');
      } else {
        print('⚠️ Missing userId or enterpriseId, registration skipped');
      }
    } catch (e) {
      print('❌ WebSocket connection failed: $e');
      _scheduleReconnect();
    } finally {
      _isConnecting = false;
    }
  }

  // ================= MESSAGE HANDLER =================
  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String);
      print('📡 WS Received: ${data['type'] ?? data['action']}');

      if (!_controller.isClosed) {
        _controller.add(data);
      }

      // 🔔 Handle alerts based on event type
      final type = data['type'];
      if (type == 'NEW_FOOD_ORDER') {
        OrderAlertService.start();

      } 
      else if (type == 'ORDER_ACCEPTED') {
        OrderAlertService.stop();

      }
      else if (type == 'ORDER_STATUS_CHANGED') {
        // READY, etc.
        OrderAlertService.stop();

      }
      else if (type == 'ORDER_DELIVERED') {
        // ✅ Stop alert when order is delivered
        OrderAlertService.stop();
      }
    } catch (e) {
      print('❌ WS Message error: $e');
    }
  }

  // ================= ERROR =================
  void _onError(dynamic error) {
    print('❌ WebSocket Error: $error');
    isConnected.value = false;
    _scheduleReconnect();
  }

  // ================= DISCONNECT =================
  void _onDone() {
    print('⚠️ WebSocket disconnected');
    isConnected.value = false;
    _scheduleReconnect();
  }

  // ================= RECONNECT =================
  void _scheduleReconnect() {
    if (_isDisposed) return;

    Future.delayed(const Duration(seconds: 5), () {
      if (!_isDisposed) {
        connect(userId: _userId, enterpriseId: _enterpriseId);
      }
    });
  }

  // ================= DISPOSE =================
  void dispose() {
    _isDisposed = true;
    _subscription?.cancel();
    _channel?.sink.close(status.normalClosure);
    _controller.close();
    isConnected.dispose();
  }
}