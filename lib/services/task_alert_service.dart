// services/task_alert_service.dart
//
// Thin facade kept for call-site compatibility.
// All state and audio logic lives in AlertStateManager.

import 'alert_state_manager.dart';

class TaskAlertService {
  // ── Streams ──────────────────────────────────────────────────────────────
  static Stream<void> get onNewTask => AlertStateManager.onNewTask;
  static Stream<void> get onNewDelivery => AlertStateManager.onNewDelivery;

  static void notifyNewTask() => AlertStateManager.notifyNewTask();
  static void notifyNewDelivery() => AlertStateManager.notifyNewDelivery();

  // ── Getters ──────────────────────────────────────────────────────────────
  static int get serviceTaskCount => AlertStateManager.serviceTaskCount;
  static int get deliveryCount => AlertStateManager.deliveryCount;
  static int get totalPending => AlertStateManager.totalPending;
  static bool get escalationActive => AlertStateManager.escalationActive;

  // ── Start (legacy compatibility) ─────────────────────────────────────────
  
  /// Legacy - count should be set via setServiceTaskCount first
  static Future<bool> ensureServiceRunning() async {
    return AlertStateManager.serviceTaskCount > 0;
  }

  /// Legacy - count should be set via setDeliveryCount first
  static Future<bool> ensureDeliveryRunning() async {
    return AlertStateManager.deliveryCount > 0;
  }

  /// Legacy - escalation should be set via setEscalationActive first
  static Future<bool> ensureEscalationRunning() async {
    return AlertStateManager.escalationActive;
  }

  // ── Stop (optimistic decrements) ─────────────────────────────────────────
  
  static Future<void> stopOneServiceAlert() => AlertStateManager.dismissServiceTask();
  static Future<void> stopOneDeliveryAlert() => AlertStateManager.dismissDelivery();
  static Future<void> stopEscalation() => AlertStateManager.dismissEscalation();
  static Future<void> stopAll() => AlertStateManager.dismissAll();

  // ── Server reconciliation ────────────────────────────────────────────────
  
  static Future<void> resetServiceCount(int count, {bool reconcileAlert = false}) =>
      AlertStateManager.setServiceTaskCount(count, immediate: reconcileAlert);

  static Future<void> resetDeliveryCount(int count, {bool reconcileAlert = false}) =>
      AlertStateManager.setDeliveryCount(count, immediate: reconcileAlert);

  static Future<void> setEscalationActive(bool active, {bool reconcileAlert = false}) =>
      AlertStateManager.setEscalationActive(active, immediate: reconcileAlert);
}
