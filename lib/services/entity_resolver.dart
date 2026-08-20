// services/entity_resolver.dart
import 'dart:developer' as dev;
import 'food_order_service.dart';
import 'home_service.dart';
import '../utils/order_grouping.dart';

class EntityResolver {
  EntityResolver._();
  static final EntityResolver instance = EntityResolver._();

  final FoodOrderService _foodOrderService = FoodOrderService();
  final HomeService      _homeService      = HomeService();

  // ── resolveFoodOrder ──────────────────────────────────────────────────────
  //
  // Fixes applied vs old implementation:
  //
  // BUG 2 FIX — also checks cancelledOrders.
  //   Old code only looked in res['orders'] (active orders). An ORDER_CANCELLED
  //   notification tap always triggered the stale-order warning because cancelled
  //   orders were never searched. Now: search active first, then cancelled.
  //
  // BUG 3 FIX — groups rows before searching.
  //   getFoodOrders() returns one row per food item. Old code returned the first
  //   matching raw row, silently dropping other items in multi-item orders.
  //   Now: groupFoodOrderRows() collapses all rows for the same order_number into
  //   a single map with a complete items[] array — matching what FoodOrdersPage
  //   displays for the same order.
  //
  // DELIVERED ORDERS — intentionally OUT OF SCOPE.
  //   ORDER_DELIVERED notifications have no entityType/entityId in DeepLinkPayload
  //   and notification_handler only calls OrderAlertService.stop() for that type.
  //   Delivered room-service orders also use a different incompatible schema from
  //   HomeService.getDeliveredOrdersForRoomService(). Tapping delivered
  //   notifications tab-switches only — this is intentional, not a bug.

  Future<Map<String, dynamic>?> resolveFoodOrder(String orderId) async {
    try {
      final res = await _foodOrderService.getFoodOrders();
      if (res['success'] != true) return null;

      final idStr = orderId.trim();

      // ── Pass 1: active orders (Pending / Preparing / Ready) ──────────────
      final List activeRaw = res['orders'] as List? ?? [];
      final activeGrouped  = groupFoodOrderRows(activeRaw);
      final activeMatch    = _findInGrouped(activeGrouped, idStr);
      if (activeMatch != null) return activeMatch;

      // ── Pass 2: cancelled orders ──────────────────────────────────────────
      // getFoodOrders() returns cancelledOrders in the same response but the old
      // resolver never checked it — causing ORDER_CANCELLED taps to always fail.
      final List cancelledRaw = res['cancelledOrders'] as List? ?? [];
      final cancelledGrouped  = groupFoodOrderRows(cancelledRaw);
      // Ensure status is set correctly on grouped cancelled rows
      for (final o in cancelledGrouped) {
        o['status']       = 'Cancelled';
        o['cancelReason'] = o['cancelReason'] ?? o['raw']?['cancel_reason'] ?? '';
      }
      final cancelledMatch = _findInGrouped(cancelledGrouped, idStr);
      if (cancelledMatch != null) return cancelledMatch;

      // Order not found in any active or cancelled list
      dev.log('EntityResolver.resolveFoodOrder: order $idStr not found in active or cancelled orders');
      return null;
    } catch (e) {
      dev.log('EntityResolver.resolveFoodOrder error: $e');
      return null;
    }
  }

  /// Search a grouped order list for a matching orderNo or raw order_id.
  Map<String, dynamic>? _findInGrouped(
    List<Map<String, dynamic>> grouped,
    String idStr,
  ) {
    for (final order in grouped) {
      final orderNo = (order['orderNo'] ?? '').toString().trim();
      final rawId   = (order['raw']?['order_id'] ?? order['raw']?['id'] ?? '').toString().trim();
      if (orderNo == idStr || rawId == idStr) {
        return Map<String, dynamic>.from(order);
      }
    }
    return null;
  }

  // ── resolveServiceTask ────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> resolveServiceTask(int taskId) async {
    try {
      final res = await _homeService.getTasks();
      if (res['success'] != true) return null;

      final List tasks = res['tasks'] as List? ?? [];

      for (final t in tasks) {
        final raw  = t['raw'] as Map? ?? {};
        final srId = t['service_request_id'] ?? raw['service_request_id'] ?? raw['task_id'];
        final escId = t['escalation_instance_id'] ?? raw['escalation_instance_id'];

        if ((srId != null && int.tryParse(srId.toString()) == taskId) ||
            (escId != null && int.tryParse(escId.toString()) == taskId)) {
          return Map<String, dynamic>.from(t);
        }
      }

      return null;
    } catch (e) {
      dev.log('EntityResolver.resolveServiceTask error: $e');
      return null;
    }
  }
}
