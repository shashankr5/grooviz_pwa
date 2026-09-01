// services/websocket_service.dart
//
// CHANGES IN THIS VERSION:
//  • Migrated to AlertStateManager - single source of truth for all alert state.
//  • All alert sound logic now handled by AlertStateManager with priority-based
//    audio switching (Escalation > Food > Task > Delivery).
//
// Previous changes retained:
//  • RUSH_HOUR_UPDATED — broadcast to stream listeners only
//  • FIX-3: Connection identity guard in connect()
//  • FIX-5: disconnect() for use on logout

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'alert_state_manager.dart';
import 'alert_reload_coordinator.dart';
import 'escalation_service.dart';
import 'session_change_service.dart';
import '../utils/user_session_helper.dart';

// Helper: reload server truth then notify UI listeners.
// silentReconcile:true forces immediate _sync() (no 400ms debounce).
void _reloadAndNotifyFood() {
  AlertReloadCoordinator.instance.reloadFood(silentReconcile: true).then((_) {
    AlertStateManager.notifyNewFoodOrder();
  });
}

void _reloadAndNotifyTasks() {
  AlertReloadCoordinator.instance.reloadTasks(silentReconcile: true).then((_) {
    AlertStateManager.notifyNewTask();
  });
}

void _reloadAndNotifyDelivery() {
  AlertReloadCoordinator.instance.reloadDelivery(silentReconcile: true).then((_) {
    AlertStateManager.notifyNewDelivery();
  });
}

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
    final sameCredentials = userId == _userId && enterpriseId == _enterpriseId;
    if (sameCredentials && isConnected.value) {
      print('WebSocket: already connected for user=$_userId — skipping reconnect');
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
          'action': 'register',
          'enterprise_id': _enterpriseId,
          'user_id': _userId,
        }));
      }
    } catch (e) {
      _isConnecting = false;
      isConnected.value = false;
      print('WebSocket connection failed (caught): $e');
      _scheduleReconnect();
    }
  }

  // ── Disconnect ─────────────────────────────────────────────────────────

  void disconnect() {
    print('WebSocket: disconnecting (logout)');
    _isDisposed = true;
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
      print('WS sendMessage error: $e');
    }
  }

  // ── Message handler ────────────────────────────────────────────────────

  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String);
      final type = (data['type'] ?? '').toString().toUpperCase();

      print('WS Received: $type');

      // Broadcast raw event to all page-level listeners first
      if (!_controller.isClosed) _controller.add(data);

      // WS runs in MAIN ISOLATE. Every handler follows the same pattern:
      //   1. Reload from server (source of truth) with reconcileAlert=true
      //   2. notifyNewX() to refresh page UIs
      // The reload calls setXCount() with immediate=true → sync runs now,
      // no 400ms debounce, so alerts stop as soon as the API returns.

      // ── Food order events ─────────────────────────────────────────────
      if (type == 'NEW_FOOD_ORDER' ||
          type == 'ORDER_ACCEPTED' ||
          type == 'ORDER_CANCELLED') {
        _reloadAndNotifyFood();
        return;
      }

      if (type == 'ORDER_DELIVERED') {
        // Delivery ends everything
        AlertStateManager.dismissAll();
        AlertStateManager.notifyNewFoodOrder();
        return;
      }

      if (type == 'ORDER_STATUS_CHANGED' ||
          type == 'ORDER_STATUS_UPDATED' ||
          type == 'FOOD_ORDER_STATUS') {
        final newStatus = (data['new_status'] ??
                data['order_status'] ??
                data['status'] ??
                '')
            .toString()
            .toUpperCase();
        if (newStatus == 'READY') {
          _reloadAndNotifyDelivery();
        } else {
          _reloadAndNotifyFood();
        }
        return;
      }

      // ── Rush hour sync (no alert side-effects) ────────────────────────
      if (type == 'RUSH_HOUR_UPDATED') return;

      // ── Service task events ───────────────────────────────────────────
      if (type == 'NEW_SERVICE_TASK' ||
          type == 'NEW_SERVICE_REQUEST' ||
          type == 'SERVICE_TASK_ACCEPTED' ||
          type == 'ACCEPTED' ||
          type == 'SERVICE_STATUS_CHANGED' ||
          type == 'SERVICE_STATUS_UPDATE' ||
          type == 'TASK_REASSIGNED' ||
          type == 'TASK_CLOSED') {
        _reloadAndNotifyTasks();
        // A food-delivery job IS a service request, so an accept/close/status
        // change can clear an Open delivery request. Recount deliveries so the
        // delivery siren drops the moment a colleague accepts — matching the
        // delivery screen and the new reloadDelivery (Open-SR) definition.
        if (type == 'SERVICE_TASK_ACCEPTED' ||
            type == 'ACCEPTED' ||
            type == 'TASK_CLOSED' ||
            type == 'SERVICE_STATUS_CHANGED' ||
            type == 'SERVICE_STATUS_UPDATE') {
          // For delivery orders: dismiss delivery alert first, then reload to get accurate count
          if (type == 'SERVICE_TASK_ACCEPTED' || type == 'ACCEPTED') {
            AlertStateManager.dismissDelivery();
          }
          _reloadAndNotifyDelivery();
        }
        return;
      }

      // ── Delivery events ───────────────────────────────────────────────
      if (type == 'NEW_DELIVERY_TASK' ||
          type == 'ORDER_READY' ||
          type == 'FOOD_ORDER_READY' ||
          type == 'DELIVERY_READY' ||
          type == 'DELIVERY_ACCEPTED' ||
          type == 'DELIVERY_DELIVERED') {
        _reloadAndNotifyDelivery();
        return;
      }

      // ── Escalation ─────────────────────────────────────────────────────

      if (type == 'ESCALATION_ALERT') {
        EscalationService.instance.handleEscalationAlert(data);
        // EscalationService sets AlertStateManager.setEscalationActive(true)
        return;
      }

      if (type == 'ESCALATION_STARTED' ||
          type == 'ESCALATION_STAGE_1' ||
          type == 'ESCALATION_PULSE') {
        return;
      }

      // ── Pulse ──────────────────────────────────────────────────────────
      if (type == 'PULSE') return;

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

        AlertStateManager.dismissAll();
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
  static const Duration _maxDelay = Duration(seconds: 60);

  void _onConnected() {
    _reconnectAttempts = 0;
    debugPrint('[WebSocket] Connected — reconnect counter reset');
  }

  void _scheduleReconnect() {
    if (_isDisposed || _userId == null) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint(
          '[WebSocket] Max reconnect attempts reached ($_maxReconnectAttempts)');
      return;
    }

    final exponential = _baseDelay * (1 << _reconnectAttempts);
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
