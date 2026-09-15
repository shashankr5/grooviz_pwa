// midnight_notifier.dart
//
// Singleton that fires a broadcast stream event at local midnight.
// Any page that needs to reset its state at day rollover subscribes to
// [MidnightNotifier.instance.onMidnight] and triggers a data reload.
//
// Usage:
//   _midnightSub = MidnightNotifier.instance.onMidnight.listen((_) {
//     _loadData();
//   });
//   // cancel in dispose()
//   _midnightSub?.cancel();

import 'dart:async';

class MidnightNotifier {
  MidnightNotifier._();
  static final MidnightNotifier instance = MidnightNotifier._();

  final StreamController<void> _controller =
      StreamController<void>.broadcast();

  Stream<void> get onMidnight => _controller.stream;

  Timer? _timer;
  DateTime _lastDate = DateTime.now();

  /// Call once at app startup (after first frame).
  /// Safe to call multiple times — only starts one timer.
  void start() {
    if (_timer != null) return;
    _lastDate = DateTime.now();
    _timer = Timer.periodic(const Duration(minutes: 30), (_) {
      final now = DateTime.now();
      if (now.day != _lastDate.day ||
          now.month != _lastDate.month ||
          now.year != _lastDate.year) {
        _lastDate = now;
        _controller.add(null);
      }
    });
  }

  /// Call on logout so the timer doesn't keep running needlessly.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
