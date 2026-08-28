// services/order_alert_service.dart
//
// Thin facade kept for call-site compatibility.
// All state and audio logic lives in AlertStateManager.

import 'alert_state_manager.dart';

class OrderAlertService {
  // ── Streams ──────────────────────────────────────────────────────────────
  static Stream<void> get onNewOrder => AlertStateManager.onNewFoodOrder;
  static void notifyNewOrder() => AlertStateManager.notifyNewFoodOrder();

  // ── Getters ──────────────────────────────────────────────────────────────
  static int get pendingOrderCount => AlertStateManager.foodOrderCount;

  // ── Start/Stop ───────────────────────────────────────────────────────────
  
  /// Legacy compatibility - count should be set via setFoodOrderCount first
  static Future<bool> start() => ensureRunning();

  static Future<bool> ensureRunning() async {
    // Count is set by the caller (FCM handler) via setFoodOrderCount()
    // before calling ensureRunning — this triggers AlertStateManager._sync()
    return AlertStateManager.foodOrderCount > 0;
  }

  /// Optimistic decrement when accepting an order on THIS device
  static Future<void> stopOne() => AlertStateManager.dismissFoodOrder();

  /// Force-stop all (logout / ORDER_DELIVERED)
  static Future<void> stop() => AlertStateManager.dismissAll();

  // ── Server reconciliation ────────────────────────────────────────────────
  
  /// PRIMARY STOP GATE. Called by _loadFoodOrders() and AlertReloadCoordinator.
  /// Only reliable cross-device stop mechanism.
  /// [reconcileAlert] forces immediate sync (used by background FCM handler).
  static Future<void> resetCount(int count, {bool reconcileAlert = false}) =>
      AlertStateManager.setFoodOrderCount(count, immediate: reconcileAlert);
}
