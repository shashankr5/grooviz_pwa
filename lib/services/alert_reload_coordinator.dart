// services/alert_reload_coordinator.dart
//
// FIXES APPLIED:
//  FIX-4: Removed SharedPreferences import — sound key no longer needed
//          here since sound is passed via taskData in startService().
//
//  FIX-8: Extracted _distinctOrderCount() as a shared static utility so
//          DeliveryPage and this coordinator use identical deduplication
//          logic. Prevents delivery count divergence that kept the alert
//          alive after DeliveryPage thought it was done.
//
//  FIX-9: Added _serviceStartFailed flag. If ensureRunning() returns false
//          (foreground service failed to start), notifyServiceStartFailed
//          stream fires so the UI can show a persistent warning to staff.

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'food_order_service.dart';
import 'home_service.dart';
import 'order_alert_service.dart';
import 'task_alert_service.dart';

class AlertReloadCoordinator with WidgetsBindingObserver {
  AlertReloadCoordinator._();
  static final AlertReloadCoordinator instance = AlertReloadCoordinator._();

  static void init() {
    instance._start();
    WidgetsBinding.instance.addObserver(instance);
  }

  StreamSubscription<void>? _orderSub;
  StreamSubscription<void>? _taskSub;
  StreamSubscription<void>? _deliverySub;

  Timer? _pollTimer;

  bool _orderInFlight    = false;
  bool _taskInFlight     = false;
  bool _deliveryInFlight = false;

  // FIX-9: Stream for foreground service start failures.
  // UI can listen and show a persistent warning banner.
  static final StreamController<String> _serviceFailController =
      StreamController.broadcast();
  static Stream<String> get onServiceStartFailed => _serviceFailController.stream;

  final FoodOrderService _foodOrderService = FoodOrderService();
  final HomeService      _homeService      = HomeService();

  void _start() {
    _orderSub    = OrderAlertService.onNewOrder.listen((_) => reloadFood());
    _taskSub     = TaskAlertService.onNewTask.listen((_) => reloadTasks());
    _deliverySub = TaskAlertService.onNewDelivery.listen((_) => reloadDelivery());

    _pollTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _safetyPoll(),
    );

    print('AlertReloadCoordinator: started');
  }

  // ── App lifecycle ───────────────────────────────────────────────────────

  // Guards against notification-shade pulls (inactive→resumed without paused).
  bool _didPause = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _didPause = true;
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (!_didPause) return; // shade pull — skip
      _didPause = false;
      print('AlertReloadCoordinator: app resumed — polling');
      _safetyPoll();
    }
  }

  Future<void> _safetyPoll() async {
    final running = await FlutterForegroundTask.isRunningService;
    if (!running) return;
    print('AlertReloadCoordinator: safety poll running');
    await Future.wait([reloadFood(), reloadTasks(), reloadDelivery()]);
  }

  // ── Food orders ─────────────────────────────────────────────────────────

  Future<void> reloadFood() async {
    if (_orderInFlight) return;
    _orderInFlight = true;
    try {
      final result = await _foodOrderService.getFoodOrders();
      if (result['success'] == true) {
        final orders = result['orders'] as List? ?? [];
        final pendingCount = orders.where((o) {
          final raw = o['raw'] as Map? ?? {};
          final s = (raw['order_status'] ?? o['status'] ?? '').toString().toUpperCase();
          return s == 'PENDING';
        }).length;

        // FIX-9: Check if service start succeeds when count > 0
        if (pendingCount > 0) {
          final started = await OrderAlertService.ensureRunning();
          if (!started) {
            _serviceFailController.add('food');
            print('AlertReloadCoordinator: foreground service failed to start (food)');
          }
        }

        OrderAlertService.resetCount(pendingCount);
        print('AlertReloadCoordinator: food resetCount($pendingCount)');
      }
    } catch (e) {
      print('AlertReloadCoordinator.reloadFood error: $e');
    } finally {
      _orderInFlight = false;
    }
  }

  // ── Service tasks ───────────────────────────────────────────────────────

  Future<void> reloadTasks() async {
    if (_taskInFlight) return;
    _taskInFlight = true;
    try {
      final result = await _homeService.getTasks();
      if (result['success'] == true) {
        final tasks = result['tasks'] as List? ?? [];
        final openCount =
            tasks.where((t) => (t['status'] ?? '') == 'Open').length;

        if (openCount > 0) {
          final started = await TaskAlertService.ensureServiceRunning();
          if (!started) {
            _serviceFailController.add('task');
          }
        }

        TaskAlertService.resetServiceCount(openCount);
        print('AlertReloadCoordinator: service resetServiceCount($openCount)');
      }
    } catch (e) {
      print('AlertReloadCoordinator.reloadTasks error: $e');
    } finally {
      _taskInFlight = false;
    }
  }

  // ── Delivery (Ready orders) ─────────────────────────────────────────────

  Future<void> reloadDelivery() async {
    if (_deliveryInFlight) return;
    _deliveryInFlight = true;
    try {
      final result = await _homeService.getReadyOrdersForRoomService();
      if (result['success'] == true) {
        final orders = result['orders'] as List? ?? [];
        // FIX-8: Use shared utility — same deduplication as DeliveryPage
        final count = distinctOrderCount(orders);

        if (count > 0) {
          final started = await TaskAlertService.ensureDeliveryRunning();
          if (!started) {
            _serviceFailController.add('delivery');
          }
        }

        TaskAlertService.resetDeliveryCount(count);
        print('AlertReloadCoordinator: delivery resetDeliveryCount($count)');
      }
    } catch (e) {
      print('AlertReloadCoordinator.reloadDelivery error: $e');
    } finally {
      _deliveryInFlight = false;
    }
  }

  // ── FIX-8: Shared deduplication utility ────────────────────────────────
  //
  // Used by both this coordinator and DeliveryPage._loadReadyOrders().
  // Previously each had its own implementation — if they diverged, the
  // delivery alert count would be wrong and the alert would not stop.
  //
  // Pass the raw orders list (as returned by getReadyOrdersForRoomService).

  static int distinctOrderCount(List orders) {
    final seen = <dynamic>{};
    for (final o in orders) {
      final orderNo = o['orderNumber'] ?? o['order_number'];
      if (orderNo != null) seen.add(orderNo);
    }
    return seen.length;
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _orderSub?.cancel();
    _taskSub?.cancel();
    _deliverySub?.cancel();
    _pollTimer?.cancel();
    _serviceFailController.close();
  }
}