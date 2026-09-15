// services/websocket_service.dart
//
// CHANGES IN THIS VERSION:
//  • FIX: Registration now sent ONLY after channel.ready — prevents frames
//    being dropped during the AWS API Gateway HTTP-upgrade handshake.
//  • FIX: 25-second heartbeat ping timer keeps the connection alive through
//    AWS API Gateway idle-timeout and mobile NAT/carrier connection resets.
//  • FIX: Unlimited reconnect retries (no hard cap) while user is logged in.
//    Delay caps at 30 s with jitter — never abandons reconnection.
//  • FIX: connect() auto-loads userId/enterpriseId from session when omitted.
//  • FIX: Expanded audio-stop event types cover all acceptance/delivery variants.
//  • Retained: RUSH_HOUR_UPDATED broadcast, session/role revocation, FIX-5 disconnect.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'notification_service.dart';
import 'session_change_service.dart';
import '../utils/user_session_helper.dart';

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Future<void> _messageQueue = Future<void>.value();

  final StreamController<Map<String, dynamic>> _controller =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get stream => _controller.stream;

  final ValueNotifier<bool> isConnected = ValueNotifier(false);

  bool _isDisposed = false;
  bool _isConnecting = false;

  String? _userId;
  String? _enterpriseId;

  // ── Heartbeat ─────────────────────────────────────────────────────────────
  // AWS API Gateway WebSocket API drops idle connections after ~10 minutes.
  // Mobile NATs / carrier firewalls can drop them even sooner (30–60 s).
  // We ping every 25 seconds to keep the connection alive indefinitely.
  Timer? _heartbeatTimer;
  static const Duration _heartbeatInterval = Duration(seconds: 25);

  static const String _wsUrl =
      'wss://3fj7tlzfk3.execute-api.ap-south-1.amazonaws.com/production';

  Future<void> _cleanupChannel() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    try {
      await _subscription?.cancel();
    } catch (_) {}
    _subscription = null;

    try {
      _channel?.sink.close(status.goingAway);
    } catch (_) {}
    _channel = null;
  }

  // ── Connect ────────────────────────────────────────────────────────────

  /// Connects to the WebSocket server.
  /// If [userId] / [enterpriseId] are omitted they are loaded from the
  /// user session automatically so callers don't need to pass credentials.
  void connect({String? userId, String? enterpriseId}) async {
    // Auto-load from session when not provided.
    if (userId == null || enterpriseId == null) {
      final storedUserId       = await UserSessionHelper.getUserId();
      final storedEnterpriseId = await UserSessionHelper.getEnterpriseId();
      userId       ??= storedUserId?.toString();
      enterpriseId ??= storedEnterpriseId?.toString();
    }

    final sameCredentials = userId == _userId && enterpriseId == _enterpriseId;
    if (sameCredentials && isConnected.value) {
      debugPrint('WebSocket: already connected for user=$_userId — skipping reconnect');
      return;
    }

    if (userId != null) _userId = userId;
    if (enterpriseId != null) _enterpriseId = enterpriseId;

    _isDisposed = false;

    if (_isConnecting) return;
    _isConnecting = true;

    try {
      await _cleanupChannel();
      final channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      _channel = channel;

      // ── CRITICAL: wait for the socket handshake to complete before
      // sending any frames. AWS API Gateway silently drops registration
      // frames sent before the $connect route handler finishes.
      channel.ready.then((_) {
        _isConnecting = false;
        if (!isConnected.value) {
          isConnected.value = true;
          _onConnected();
          debugPrint('WebSocket connected | user=$_userId');
        }
        // Register and start heartbeat only after handshake is confirmed.
        _sendRegistration();
        _startHeartbeat();
      }).catchError((e) {
        _isConnecting = false;
        isConnected.value = false;
        debugPrint('WebSocket ready connection error: $e');
        _scheduleReconnect();
      });

      _subscription = channel.stream.listen(
        (message) {
          // First message may arrive before ready.then fires on some platforms.
          _isConnecting = false;
          if (!isConnected.value) {
            isConnected.value = true;
            _onConnected();
            debugPrint('WebSocket connected (first message) | user=$_userId');
            _sendRegistration();
            _startHeartbeat();
          }
          _enqueueMessage(message);
        },
        onError: (error) {
          _isConnecting = false;
          _onError(error);
        },
        onDone: () {
          _isConnecting = false;
          _onDone();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _isConnecting = false;
      isConnected.value = false;
      debugPrint('WebSocket connection failed (caught): $e');
      _scheduleReconnect();
    }
  }

  void _sendRegistration() {
    if (_userId == null || _enterpriseId == null) return;
    try {
      _channel?.sink.add(jsonEncode({
        'action': 'register',
        'enterprise_id': _enterpriseId,
        'user_id': _userId,
      }));
      debugPrint('WebSocket: registered | user=$_userId enterprise=$_enterpriseId');
    } catch (e) {
      debugPrint('WebSocket: registration send error: $e');
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (!isConnected.value || _channel == null) return;
      try {
        _channel!.sink.add(jsonEncode({'action': 'ping'}));
      } catch (e) {
        debugPrint('WebSocket: heartbeat send error: $e');
      }
    });
  }

  // ── Disconnect ─────────────────────────────────────────────────────────

  void disconnect() {
    debugPrint('WebSocket: disconnecting (logout)');
    _isDisposed = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close(status.normalClosure);
    _channel = null;
    isConnected.value = false;
    _userId = null;
    _enterpriseId = null;
  }

  // ── Send ───────────────────────────────────────────────────────────────

  void sendMessage(Map<String, dynamic> message) {
    if (_channel == null || !isConnected.value) return;
    try {
      _channel!.sink.add(jsonEncode(message));
    } catch (e) {
      debugPrint('WS sendMessage error: $e');
    }
  }

  // ── Message handler ────────────────────────────────────────────────────

  void _enqueueMessage(dynamic message) {
    _messageQueue = _messageQueue.then((_) => _handleMessage(message));
  }

  Future<void> _handleMessage(dynamic message) async {
    try {
      final data = jsonDecode(message as String);
      final type = (data['type'] ?? '').toString().toUpperCase();

      // Silently ignore server pong / heartbeat acks — don't broadcast them.
      if (type == 'PONG' || type == 'PING') return;

      debugPrint('WS Received: $type');

      // Broadcast raw event to all page-level listeners first.
      if (!_controller.isClosed) _controller.add(data);

        // ── Stop notification audio when task/order is accepted or delivered.
        //    Closing a service request is business-only and must not stop audio.
      if (type == 'SERVICE_TASK_ACCEPTED'  ||
          type == 'SERVICE_REQUEST_ACCEPTED'||
          type == 'TASK_ACCEPTED'           ||
          type == 'ORDER_ACCEPTED'          ||
          type == 'FOOD_ORDER_ACCEPTED'     ||
          type == 'DELIVERY_ACCEPTED'       ||
          type == 'ORDER_STATUS_CHANGED'    ||
          type == 'ORDER_STATUS_UPDATED'    ||
          type == 'ORDER_DELIVERED'         ||
          type == 'DELIVERY_DELIVERED'      ||
          type == 'FOOD_ORDER_DELIVERED') {
        // Backend may nest fields inside data: { ... } — check both layers.
        final payload = (data['data'] is Map)
            ? data['data'] as Map<String, dynamic>
            : data;
        final srId = (payload['service_request_id'] ??
                payload['service_order_id'] ??
                payload['task_id']          ??
                payload['id']               ??
                data['service_request_id']  ??
                data['service_order_id']    ??
                data['task_id']             ??
                data['id'])
            ?.toString();
        final orderId = (payload['order_id'] ?? data['order_id'])?.toString();
        final summaryId = (payload['summary_id']          ??
                payload['food_order_summary_id']           ??
                payload['food_summary_id']                 ??
                data['summary_id']                         ??
                data['food_order_summary_id']              ??
                data['food_summary_id'])
            ?.toString();
        unawaited(NotificationService.instance.stopAlert(
          serviceRequestId: srId,
          orderId: orderId,
          foodOrderSummaryId: summaryId,
        ));
      }

      // ── Rush hour sync ───────────────────────────────────────────────
      if (type == 'RUSH_HOUR_UPDATED') return;

      // ── Session / Role revocation ──────────────────────────────────────

      if (type == 'SESSION_INVALIDATED' ||
          type == 'ROLE_UPDATED' ||
          type == 'DEPARTMENT_UPDATED') {
        final rawReason = data['reason']?.toString().trim();
        final bool roleChanged =
            data['role_changed'] == true || data['role'] != null;
        final bool deptChanged =
            data['dept_changed'] == true || data['departments'] != null;

        final reason = rawReason?.isNotEmpty == true
            ? rawReason!
            : roleChanged && deptChanged
                ? 'Your role and department have been updated by an administrator.'
                : roleChanged
                    ? 'Your role has been changed by an administrator.'
                    : deptChanged
                        ? 'Your department assignment has changed.'
                        : 'Your account permissions have changed.';

        SessionChangeService.instance.setChangeReason(reason);
        SessionChangeService.instance
            .notifyRoleChange(data['role']?.toString() ?? '');

        disconnect();
        UserSessionHelper.clearSession();
        return;
      }
    } catch (e) {
      debugPrint('WS Message error: $e');
    }
  }

  // ── Error / Done ───────────────────────────────────────────────────────

  void _onError(dynamic error) {
    debugPrint('WebSocket Error: $error');
    isConnected.value = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _scheduleReconnect();
  }

  void _onDone() {
    debugPrint('WebSocket disconnected');
    isConnected.value = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (_userId != null) _scheduleReconnect();
  }

  // ── Reconnect ──────────────────────────────────────────────────────────

  int _reconnectAttempts = 0;
  // No hard cap — keep retrying while the user is logged in.
  // Exponential delay caps at 30 s with ±30 % jitter.
  static const Duration _baseDelay = Duration(seconds: 2);
  static const Duration _maxDelay  = Duration(seconds: 30);

  void _onConnected() {
    _reconnectAttempts = 0;
    debugPrint('[WebSocket] Connected — reconnect counter reset');
  }

  void _scheduleReconnect() {
    if (_isDisposed || _userId == null) return;

    final exponential = _baseDelay * (1 << _reconnectAttempts.clamp(0, 10));
    final capped = exponential > _maxDelay ? _maxDelay : exponential;
    final jitter = Duration(
      milliseconds:
          (Random().nextDouble() * 0.3 * capped.inMilliseconds).toInt(),
    );
    final delay = capped + jitter;

    _reconnectAttempts++;
    debugPrint(
        '[WebSocket] Reconnect attempt $_reconnectAttempts in ${delay.inSeconds}s');

    Future.delayed(delay, () {
      if (_userId != null && !_isDisposed) {
        connect(userId: _userId, enterpriseId: _enterpriseId);
      }
    });
  }

  // ── Dispose ────────────────────────────────────────────────────────────

  void dispose() {
    _isDisposed = true;
    _subscription?.cancel();
    _channel?.sink.close(status.normalClosure);
    if (!_controller.isClosed) _controller.close();
    isConnected.value = false;
  }
}
