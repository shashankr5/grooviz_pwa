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
//
//  FIX-10: Added silentReconcile parameter to reloadFood/reloadTasks/reloadDelivery.
//          Cold-launch reconciliation passes silentReconcile:true so that
//          pre-existing pending requests do NOT restart the foreground alert.
//          Alerts are only ever started by live WS/FCM new-event callbacks.

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'food_order_service.dart';
import 'home_service.dart';
import 'order_alert_service.dart';
import 'task_service.dart';
import 'task_alert_service.dart';

class AlertReloadCoordinator with WidgetsBindingObserver {
  AlertReloadCoordinator._();
  static final AlertReloadCoordinator instance = AlertReloadCoordinator._();

  static void init() {
    instance._init();
  }

  StreamSubscription<void>? _orderSub;
  StreamSubscription<void>? _taskSub;
  StreamSubscription<void>? _deliverySub;

  bool _orderInFlight    = false;
  bool _taskInFlight     = false;
  bool _deliveryInFlight = false;

  // Collapse notification bursts into at most one follow-up request per
  // domain, instead of issuing a request per FCM message.
  bool _orderReloadQueued = false;
  bool _taskReloadQueued = false;
  bool _deliveryReloadQueued = false;
  bool _started = false;

  // FIX-9: Stream for foreground service start failures.
  // UI can listen and show a persistent warning banner.
  static final StreamController<String> _serviceFailController =
      StreamController.broadcast();
  static Stream<String> get onServiceStartFailed => _serviceFailController.stream;

  final FoodOrderService _foodOrderService = FoodOrderService();
  final HomeService      _homeService      = HomeService();

  /// Helper method to identify food delivery tasks that should not appear in Service Requests
  bool _isFoodDeliveryTask(Map<String, dynamic> task) {
    // Primary check: food_order_summary_id (most reliable indicator for food deliveries)
    final foodSummaryId = task['food_order_summary_id'] ?? task['raw']?['food_order_summary_id'];
    if (foodSummaryId != null &&
        foodSummaryId.toString().trim().isNotEmpty &&
        foodSummaryId.toString() != '0') {
      return true;
    }

    // REMOVED: is_from_order and service_order_id checks
    // These catch regular service orders (amenities, room service items) too
    // Only actual food deliveries should be filtered out

    // Check question content for explicit food delivery indicators
    // Be very specific to avoid false positives with regular service orders
    final question = ((task['question'] ?? task['title'] ?? task['raw']?['question'] ?? '').toString().toLowerCase());
    if (question.contains('food order') || 
        question.contains('food delivery') ||
        (question.contains('ready for delivery') && question.contains('food'))) {
      return true;
    }

    return false;
  }

  void _init() {
    if (_started) return;
    _start();
    WidgetsBinding.instance.addObserver(this);
  }

  void _start() {
    _started = true;

    _orderSub    = OrderAlertService.onNewOrder.listen((_) => reloadFood());
    _taskSub     = TaskAlertService.onNewTask.listen((_) => reloadTasks());
    _deliverySub = TaskAlertService.onNewDelivery.listen((_) => reloadDelivery());

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
      print('AlertReloadCoordinator: app resumed; targeted FCM reloads remain active');
    }
  }

  // ── Food orders ─────────────────────────────────────────────────────────

  /// [silentReconcile] must be true for cold-launch reconciliation calls.
  /// When true, a non-zero count keeps an already-running alert alive but
  /// never starts a fresh alert for pre-existing pending orders — only
  /// genuine new-event callbacks (WS/FCM) may start alerts.
  Future<void> reloadFood({bool silentReconcile = false}) async {
    if (_orderInFlight) {
      _orderReloadQueued = true;
      return;
    }
    _orderInFlight = true;
    try {
      final result = await _foodOrderService.getFoodOrders();
      if (result['success'] == true) {
        final orders = result['orders'] as List? ?? [];
        // Prefer the normalized status returned by FoodOrderService. The raw
        // database field differs between endpoint versions, while the mapped
        // value is consistently Pending / Preparing / Ready / etc.
        final pendingCount = orders.where((o) =>
            (o['status'] ?? '').toString().trim().toUpperCase() == 'PENDING').length;

        // FIX-10: Only start the alert for a live new-event reload.
        // Cold-launch reconciliation (silentReconcile:true) must never
        // re-trigger the alert for orders that were already pending before
        // the app was killed.
        if (pendingCount > 0 && !silentReconcile) {
          final started = await OrderAlertService.ensureRunning();
          if (!started) {
            _serviceFailController.add('food');
            print('AlertReloadCoordinator: foreground service failed to start (food)');
          }
        }

        OrderAlertService.resetCount(pendingCount, reconcileAlert: true);
        print('AlertReloadCoordinator: food resetCount($pendingCount) silentReconcile=$silentReconcile');
      }
    } catch (e) {
      print('AlertReloadCoordinator.reloadFood error: $e');
    } finally {
      _orderInFlight = false;
      if (_orderReloadQueued) {
        _orderReloadQueued = false;
        unawaited(reloadFood());
      }
    }
  }

  // ── Service tasks ───────────────────────────────────────────────────────

  /// [silentReconcile] must be true for cold-launch reconciliation calls.
  /// When true, a non-zero count keeps an already-running alert alive but
  /// never starts a fresh "New Service Request" notification for pre-existing
  /// open tasks — only genuine new-event callbacks (WS/FCM) may start alerts.
  Future<void> reloadTasks({bool silentReconcile = false}) async {
    if (_taskInFlight) {
      _taskReloadQueued = true;
      return;
    }
    _taskInFlight = true;
    try {
      final result = await _homeService.getTasks();
      if (result['success'] == true) {
        final tasks = result['tasks'] as List? ?? [];
        // Filter out food delivery tasks - they belong in Delivery page, not Service Requests
        final openCount = tasks.where((t) => 
          (t['status'] ?? '') == 'Open' && !_isFoodDeliveryTask(t)
        ).length;

        // FIX-10: Only start the alert for a live new-event reload.
        // Cold-launch reconciliation (silentReconcile:true) must never
        // re-trigger the "New Service Request" notification for tasks
        // that were already open before the app was killed.
        if (openCount > 0 && !silentReconcile) {
          final started = await TaskAlertService.ensureServiceRunning();
          if (!started) {
            _serviceFailController.add('task');
          }
        }

        TaskAlertService.resetServiceCount(openCount, reconcileAlert: true);
        print('AlertReloadCoordinator: service resetServiceCount($openCount) silentReconcile=$silentReconcile');
      }
    } catch (e) {
      print('AlertReloadCoordinator.reloadTasks error: $e');
    } finally {
      _taskInFlight = false;
      if (_taskReloadQueued) {
        _taskReloadQueued = false;
        unawaited(reloadTasks());
      }
    }
  }

  // ── Delivery (Ready orders) ─────────────────────────────────────────────

  /// [silentReconcile] must be true for cold-launch reconciliation calls.
  /// When true, a non-zero count keeps an already-running alert alive but
  /// never starts a fresh alert for pre-existing ready orders — only
  /// genuine new-event callbacks (WS/FCM) may start alerts.
  Future<void> reloadDelivery({bool silentReconcile = false}) async {
    if (_deliveryInFlight) {
      _deliveryReloadQueued = true;
      return;
    }
    _deliveryInFlight = true;
    try {
      final result = await TaskService().getAllServices();
      if (result['success'] == true) {
        final orders = (result['services'] as List? ?? const <dynamic>[])
            .whereType<Map>()
            .where((row) {
              final foodSummaryId = row['food_order_summary_id'];
              final status = row['status']?.toString().toLowerCase();
              return foodSummaryId != null && foodSummaryId.toString() != '0' &&
                  status != 'closed' && status != 'in progress' &&
                  status != 'in_progress' && row['accepted_at'] == null;
            })
            .toList();
        // FIX-8: Use shared utility — same deduplication as DeliveryPage
        final count = distinctOrderCount(orders);

        // FIX-10: Only start the alert for a live new-event reload.
        // Cold-launch reconciliation (silentReconcile:true) must never
        // re-trigger the delivery alert for orders already ready before
        // the app was killed.
        if (count > 0 && !silentReconcile) {
          final started = await TaskAlertService.ensureDeliveryRunning();
          if (!started) {
            _serviceFailController.add('delivery');
          }
        }

        TaskAlertService.resetDeliveryCount(count, reconcileAlert: true);
        print('AlertReloadCoordinator: delivery resetDeliveryCount($count) silentReconcile=$silentReconcile');
      }
    } catch (e) {
      print('AlertReloadCoordinator.reloadDelivery error: $e');
    } finally {
      _deliveryInFlight = false;
      if (_deliveryReloadQueued) {
        _deliveryReloadQueued = false;
        unawaited(reloadDelivery());
      }
    }
  }

  // ── FIX-8: Shared deduplication utility ────────────────────────────────
  //
  // Used by both this coordinator and DeliveryPage._loadReadyOrders().
  // Previously each had its own implementation — if they diverged, the
  // delivery alert count would be wrong and the alert would not stop.
  //
  // Pass unified service-request rows or legacy-shaped order rows.

  static int distinctOrderCount(List orders) {
    final seen = <dynamic>{};
    for (final o in orders) {
      final identifier = o['service_request_id'] ??
          o['orderNumber'] ?? o['order_number'];
      if (identifier != null) seen.add(identifier);
    }
    return seen.length;
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _orderSub?.cancel();
    _taskSub?.cancel();
    _deliverySub?.cancel();
    _serviceFailController.close();
  }
}
