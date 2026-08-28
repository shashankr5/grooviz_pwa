// services/alert_reload_coordinator.dart
//
// Alert reload coordinator for queue reconciliation

import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/user_session_helper.dart';
import 'food_order_service.dart';
import 'task_service.dart';
import 'order_alert_service.dart';
import 'task_alert_service.dart';

class AlertReloadCoordinator {
  static final AlertReloadCoordinator _instance = AlertReloadCoordinator._internal();
  static AlertReloadCoordinator get instance => _instance;
  factory AlertReloadCoordinator() => _instance;
  AlertReloadCoordinator._internal();

  // Stream for service start failed events (for backward compatibility)
  static final StreamController<String> _serviceFailController = StreamController.broadcast();
  static Stream<String> get onServiceStartFailed => _serviceFailController.stream;

  static void init() {
    // Initialize coordination streams
    OrderAlertService.onNewOrder.listen((_) => _instance._handleOrderEvent());
    TaskAlertService.onNewTask.listen((_) => _instance._handleTaskEvent());
    TaskAlertService.onNewDelivery.listen((_) => _instance._handleDeliveryEvent());
  }

  void _handleOrderEvent() async {
    // Reload food orders when order events occur
    await reloadFood(silentReconcile: false);
  }

  void _handleTaskEvent() async {
    // Reload tasks when task events occur
    await reloadTasks(silentReconcile: false);
  }

  void _handleDeliveryEvent() async {
    // Reload delivery queue when delivery events occur
    await reloadDelivery(silentReconcile: false);
  }

  Future<void> reloadFood({bool silentReconcile = false}) async {
    try {
      final response = await FoodOrderService().getFoodOrders();
      final orders = response['orders'] as List<dynamic>? ?? [];
      final pendingCount = orders.where((order) => 
        order['status']?.toString().toLowerCase() == 'pending'
      ).length;
      
      OrderAlertService.resetCount(pendingCount, reconcileAlert: silentReconcile);
    } catch (e) {
      print('AlertReloadCoordinator.reloadFood error: $e');
    }
  }

  Future<void> reloadTasks({bool silentReconcile = false}) async {
    try {
      final response = await TaskService().getTasks();
      final tasks = response['tasks'] as List<dynamic>? ?? [];
      final pendingCount = tasks.where((task) => 
        task['status']?.toString().toLowerCase() == 'pending' ||
        task['status']?.toString().toLowerCase() == 'assigned'
      ).length;
      
      final escalatedCount = tasks.where((task) => 
        task['escalated'] == true
      ).length;
      
      TaskAlertService.resetServiceCount(pendingCount, reconcileAlert: silentReconcile);
      TaskAlertService.setEscalationActive(escalatedCount > 0, reconcileAlert: silentReconcile);
    } catch (e) {
      print('AlertReloadCoordinator.reloadTasks error: $e');
    }
  }

  Future<void> reloadDelivery({bool silentReconcile = false}) async {
    try {
      final response = await FoodOrderService().getFoodOrders();
      final orders = response['orders'] as List<dynamic>? ?? [];
      final readyCount = orders.where((order) => 
        order['status']?.toString().toLowerCase() == 'ready'
      ).length;
      
      TaskAlertService.resetDeliveryCount(readyCount, reconcileAlert: silentReconcile);
    } catch (e) {
      print('AlertReloadCoordinator.reloadDelivery error: $e');
    }
  }
}