// utils/ws_debouncer.dart
//
// Collapses a burst of WebSocket events into a single deferred call.
// Used to prevent redundant background syncs when the backend broadcasts
// multiple events for a single user action (e.g. accept fires 3–5 events).
//
// Usage:
//   final _syncDebouncer = WsDebouncer(const Duration(milliseconds: 400));
//   _syncDebouncer(() => _loadOrders(silent: true));
//   // Call dispose() in State.dispose().

import 'dart:async';
import 'package:flutter/foundation.dart';

class WsDebouncer {
  final Duration duration;
  Timer? _timer;

  WsDebouncer(this.duration);

  /// Schedule [action] to run after [duration].
  /// Any pending call that hasn't fired yet is cancelled and replaced.
  void call(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(duration, action);
  }

  /// Cancel any pending timer. Call from State.dispose().
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
