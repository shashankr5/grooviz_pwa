// services/websocket_service.dart
//
// CHANGES IN THIS VERSION:
//  • Stop looping alerts immediately on all devices when a task or order is accepted/cancelled, cross-device.
//  • RUSH_HOUR_UPDATED — broadcast to all page listeners so FoodOrdersPage
//    can update rush hour state in real-time across all devices without
//    a manual reload. No sound or alert side-effects needed for this type.
//
// Previous changes retained:
//  • ESCALATION_ALERT — ignored
//  • PULSE            — re-rings task alert sound
//  • ACCEPTED         — another device accepted a task; refreshes task list and stops alert loops
//  • TASK_CLOSED      — task closed from another device; refreshes task list
//  FIX-3: Connection identity guard in connect()
//  FIX-5: disconnect() for use on logout

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'order_alert_service.dart';
import 'task_alert_service.dart';
import 'session_change_service.dart';
import '../utils/user_session_helper.dart';

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

  Future<void> _cleanupChannel() async {
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

  void connect({String? userId, String? enterpriseId}) async {
    // FIX-3: Guard — skip reconnect if already connected with same credentials.
    final sameCredentials = userId == _userId && enterpriseId == _enterpriseId;
    if (sameCredentials && isConnected.value) {
      print('WebSocket: already connected for user=$_userId — skipping reconnect');
      return;
    }

    if (userId != null)       _userId       = userId;
    if (enterpriseId != null) _enterpriseId = enterpriseId;

    // Reset disposed flag so a re-login after dispose() can reconnect cleanly.
    _isDisposed = false;

    if (_isConnecting) return;
    _isConnecting = true;

    try {
      await _cleanupChannel();
      final channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      _channel = channel;

      // Handle async connection error on channel.ready so SocketException is never unhandled
      unawaited(channel.ready.then((_) {
        _isConnecting = false;
        if (!isConnected.value) {
          isConnected.value = true;
          _onConnected();
          print('WebSocket connected | user=$_userId');
        }
      }).catchError((e) {
        _isConnecting = false;
        isConnected.value = false;
        print('WebSocket ready connection error: $e');
        _scheduleReconnect();
      }));

      _subscription = channel.stream.listen(
        (message) {
          _isConnecting = false;
          if (!isConnected.value) {
            isConnected.value = true;
            _onConnected();
            print('WebSocket connected | user=$_userId');
          }
          _handleMessage(message);
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

      if (_userId != null && _enterpriseId != null) {
        channel.sink.add(jsonEncode({
          'action':        'register',
          'enterprise_id': _enterpriseId,
          'user_id':       _userId,
        }));
      }
    } catch (e) {
      _isConnecting = false;
      isConnected.value = false;
      print('WebSocket connection failed (caught): $e');
      _scheduleReconnect();
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
        OrderAlertService.notifyNewOrder();
        return;
      }

      if (type == 'ORDER_ACCEPTED' || type == 'ORDER_CANCELLED') {
        // Optimistically decrement and stop if count hits zero, keep looping if > 0
        OrderAlertService.stopOne();
        OrderAlertService.notifyNewOrder();
        return;
      }

      if (type == 'ORDER_DELIVERED') {
        TaskAlertService.stopAll();
        OrderAlertService.stop();
        OrderAlertService.notifyNewOrder();
        return;
      }

      if (type == 'ORDER_STATUS_CHANGED' || type == 'ORDER_STATUS_UPDATED') {
        final newStatus = (data['new_status'] ?? data['order_status'] ?? data['status'] ?? '').toString().toUpperCase();
        if (newStatus == 'READY') {
          TaskAlertService.ensureDeliveryRunning();
          TaskAlertService.notifyNewDelivery();
        }
        OrderAlertService.notifyNewOrder();
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
        // Optimistically decrement and stop if count hits zero, keep looping if > 0
        TaskAlertService.stopOneServiceAlert();
        TaskAlertService.notifyNewTask();
        return;
      }

      if (type == 'SERVICE_STATUS_CHANGED' || type == 'SERVICE_STATUS_UPDATE' || type == 'TASK_REASSIGNED') {
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

      // Escalation is not an active client feature.  Ignore its transport
      // events so they cannot create a sound, badge, stale list, or alert.
      if (type == 'ESCALATION_ALERT' ||
          type == 'ESCALATION_STARTED' ||
          type == 'ESCALATION_STAGE_1' ||
          type == 'ESCALATION_PULSE') {
        return;
      }

      // ── Pulse ──────────────────────────────────────────────────────────

      if (type == 'PULSE') {
        // A pulse is not a new request. Re-ring only when the already
        // reconciled queue says actionable service work still exists.
        if (TaskAlertService.pendingServiceCount > 0) {
          TaskAlertService.ensureServiceRunning();
        }
        return;
      }

      // ── Accepted ───────────────────────────────────────────────────────

      if (type == 'ACCEPTED') {
        // Optimistically decrement and stop if count hits zero, keep looping if > 0
        TaskAlertService.stopOneServiceAlert();
        TaskAlertService.notifyNewTask();
        return;
      }

      // ── Task closed ────────────────────────────────────────────────────

      if (type == 'TASK_CLOSED') {
        TaskAlertService.notifyNewTask();
        return;
      }

      // ── Real-time Session / Role Revocation ─────────────────────────────

      if (type == 'SESSION_INVALIDATED' || type == 'ROLE_UPDATED' || type == 'DEPARTMENT_UPDATED') {
        final rawReason = data['reason']?.toString().trim();
        final bool roleChanged = data['role_changed'] == true || data['role'] != null;
        final bool deptChanged = data['dept_changed'] == true || data['departments'] != null;

        String reason;
        if (rawReason != null && rawReason.isNotEmpty) {
          reason = rawReason;
        } else if (roleChanged && deptChanged) {
          reason = 'Your role and department have been updated by an administrator.';
        } else if (roleChanged) {
          reason = 'Your role has been changed by an administrator.';
        } else if (deptChanged) {
          reason = 'Your department assignment has changed.';
        } else {
          reason = 'Your account permissions have changed.';
        }

        SessionChangeService.instance.setChangeReason(reason);
        SessionChangeService.instance.notifyRoleChange(data['role']?.toString() ?? '');

        // Stop alerts, disconnect socket, and clear local session
        OrderAlertService.stop();
        TaskAlertService.stopAll();
        disconnect();
        UserSessionHelper.clearSession();
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

  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;
  static const Duration _baseDelay = Duration(seconds: 2);
  static const Duration _maxDelay  = Duration(seconds: 60);

  void _onConnected() {
    _reconnectAttempts = 0;
    debugPrint('[WebSocket] Connected — reconnect counter reset');
  }

  void _scheduleReconnect() {
    if (_isDisposed || _userId == null) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('[WebSocket] Max reconnect attempts reached ($_maxReconnectAttempts)');
      return;
    }

    final exponential = _baseDelay * (1 << _reconnectAttempts);
    final capped      = exponential > _maxDelay ? _maxDelay : exponential;
    final jitter      = Duration(
      milliseconds: (Random().nextDouble() * 0.3 * capped.inMilliseconds).toInt(),
    );
    final delay = capped + jitter;

    _reconnectAttempts++;
    debugPrint('[WebSocket] Reconnect attempt $_reconnectAttempts in ${delay.inSeconds}s');

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
    isConnected.value = false; // signal disconnected; do NOT call .dispose()
  }
}
