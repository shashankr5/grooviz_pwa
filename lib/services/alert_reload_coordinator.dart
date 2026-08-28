// services/alert_reload_coordinator.dart
//
// Server reconciliation - the "ears" of the alert system.
// Called EXPLICITLY by FCM handlers and WebSocket handlers.
// Fetches real counts from server, feeds them back to AlertStateManager
// which triggers _sync() to start/switch/stop alerts.
//
// NOTE: This no longer auto-reloads via stream listeners. Callers must
// explicitly call reloadX() to avoid double-reload races.

import 'dart:async';
import 'food_order_service.dart';
import 'task_service.dart';
import 'order_alert_service.dart';
import 'task_alert_service.dart';

class AlertReloadCoordinator {
  static final AlertReloadCoordinator _instance = AlertReloadCoordinator._internal();
  static AlertReloadCoordinator get instance => _instance;
  factory AlertReloadCoordinator() => _instance;
  AlertReloadCoordinator._internal();

  // Stream for service start failed events (kept for backward compatibility)
  static final StreamController<String> _serviceFailController = StreamController.broadcast();
  static Stream<String> get onServiceStartFailed => _serviceFailController.stream;

  /// No-op init kept for main() compatibility. Reloads are now explicit.
  static void init() {
    print('AlertReloadCoordinator: explicit-reload mode (no stream listeners)');
  }

  Future<void> reloadFood({bool silentReconcile = false}) async {
    try {
      final response = await FoodOrderService().getFoodOrders();
      // CRITICAL: Only reconcile if API call succeeded. Empty response on
      // failure should NOT be interpreted as "0 pending" - that would
      // wrongly stop an active alert.
      if (response['success'] != true) {
        print('AlertReloadCoordinator.reloadFood: API failed, skipping reconcile');
        return;
      }
      final orders = response['orders'] as List<dynamic>? ?? [];
      // Orders returned by getFoodOrders() have status mapped to labels:
      // 'Pending', 'Preparing' (Accepted), 'Ready'. Count only 'Pending'.
      final pendingCount = orders.where((order) =>
          order['status']?.toString().toLowerCase() == 'pending').length;

      print('AlertReloadCoordinator.reloadFood: server pendingCount=$pendingCount');
      await OrderAlertService.resetCount(pendingCount, reconcileAlert: silentReconcile);
    } catch (e) {
      print('AlertReloadCoordinator.reloadFood error: $e');
    }
  }

  Future<void> reloadTasks({bool silentReconcile = false}) async {
    try {
      final response = await TaskService().getTasks();
      if (response['success'] != true) {
        print('AlertReloadCoordinator.reloadTasks: API failed, skipping reconcile');
        return;
      }
      // TaskService.getTasks() returns response['services'] not response['tasks'].
      // Raw rows have fields: status ("Open"|"In Progress"|"Closed"),
      // closed (0|1), is_escalated (0|1), accepted_by_user_id, etc.
      final services = response['services'] as List<dynamic>? ?? [];

      // Pending = Open and not closed (not yet accepted by anyone)
      final pendingCount = services.where((s) {
        final status = s['status']?.toString().toUpperCase() ?? '';
        final closed = s['closed'];
        final acceptedBy = s['accepted_by_user_id'];
        // Truly pending: status Open, not closed, no acceptor
        return status == 'OPEN' &&
            (closed == 0 || closed == null) &&
            (acceptedBy == null || acceptedBy == 0);
      }).length;

      // Escalation alert fires ONLY for Open escalated tasks — ones with no
      // acceptor yet that still need someone to act.
      // In Progress = already accepted/being handled → no need to keep alarming.
      // Closed = done → excluded by closed == 0 check.
      final escalatedCount = services.where((s) {
        final status    = s['status']?.toString().toUpperCase() ?? '';
        final closed    = s['closed'];
        final isEscalated = s['is_escalated'];
        final acceptedBy  = s['accepted_by_user_id'];
        return (closed == 0 || closed == null) &&
            status == 'OPEN' &&
            (acceptedBy == null || acceptedBy == 0) &&
            (isEscalated == 1 || isEscalated == true);
      }).length;

      print('AlertReloadCoordinator.reloadTasks: pendingCount=$pendingCount escalated=$escalatedCount total=${services.length}');
      await TaskAlertService.resetServiceCount(pendingCount, reconcileAlert: silentReconcile);
      await TaskAlertService.setEscalationActive(escalatedCount > 0, reconcileAlert: silentReconcile);
    } catch (e) {
      print('AlertReloadCoordinator.reloadTasks error: $e');
    }
  }

  Future<void> reloadDelivery({bool silentReconcile = false}) async {
    try {
      final response = await FoodOrderService().getFoodOrders();
      if (response['success'] != true) {
        print('AlertReloadCoordinator.reloadDelivery: API failed, skipping reconcile');
        return;
      }
      final orders = response['orders'] as List<dynamic>? ?? [];
      final readyCount = orders.where((order) =>
          order['status']?.toString().toLowerCase() == 'ready').length;

      print('AlertReloadCoordinator.reloadDelivery: server readyCount=$readyCount');
      await TaskAlertService.resetDeliveryCount(readyCount, reconcileAlert: silentReconcile);
    } catch (e) {
      print('AlertReloadCoordinator.reloadDelivery error: $e');
    }
  }
}