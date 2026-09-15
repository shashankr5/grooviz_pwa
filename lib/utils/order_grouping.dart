// utils/order_grouping.dart
//
// Shared food-order grouping logic.
//
import '../utils/food_order_status.dart';

/// Parse an order-time string safely. Returns [DateTime.now()] on failure so
/// that sort operations never crash on malformed timestamps.
DateTime parseOrderDate(String s) {
  if (s.trim().isEmpty) return DateTime.now();
  try {
    var str = s.trim().replaceFirst(' ', 'T');
    // Truncate microsecond precision if present
    if (str.contains('.')) {
      final parts = str.split('.');
      if (parts[1].length > 3) {
        final ms = parts[1].replaceAll(RegExp(r'[^\d]'), '');
        final cleanMs = ms.length >= 3 ? ms.substring(0, 3) : ms;
        final tzSuffix = str.endsWith('Z') || str.endsWith('z') ? 'Z' : '';
        str = '${parts[0]}.$cleanMs$tzSuffix';
      }
    }

    // Strip trailing Z so database timestamp is treated directly as local hotel time
    if (str.endsWith('Z') || str.endsWith('z')) {
      str = str.substring(0, str.length - 1);
    }
    return DateTime.parse(str);
  } catch (_) {
    try {
      var fallback = s.trim().replaceFirst(' ', 'T');
      if (fallback.endsWith('Z') || fallback.endsWith('z')) {
        fallback = fallback.substring(0, fallback.length - 1);
      }
      return DateTime.parse(fallback);
    } catch (_) {
      return DateTime.now();
    }
  }
}

/// Collapse a flat list of food-order API rows (one row per item) into a list
/// of grouped order maps (one entry per order_number, with an `items[]` array).
///
/// This mirrors FoodOrdersPage._groupApiOrders() exactly except:
///   - No mutation of _maxDelayReachedOrders (caller handles that if needed).
///   - No dependency on `this` — fully standalone.
///
/// [apiOrders] must be the already-mapped list from FoodOrderService
/// (_mapFoodOrders or _mapCancelledOrders), NOT raw API rows.
List<Map<String, dynamic>> groupFoodOrderRows(List apiOrders) {
  final Map<String, Map<String, dynamic>> grouped = {};

  for (final o in apiOrders) {
    final orderNo     = o['orderNumber'];
    final raw         = o['raw'];
    final createdTime = (raw?['created_at'] ?? raw?['order_time'] ?? raw?['delivered_time'] ?? '').toString();

    if (!grouped.containsKey(orderNo)) {
      final extraVal = o['extraEtaMinutes'] ?? raw?['extra_eta_minutes'] ?? 0;
      final extraEta = extraVal is num
          ? extraVal.toInt()
          : (int.tryParse(extraVal.toString()) ?? 0);

      final locked = o['etaLocked'] == true ||
          o['etaLocked'] == 1 ||
          o['etaLocked'] == '1' ||
          raw?['eta_locked'] == true ||
          raw?['eta_locked'] == 1 ||
          raw?['eta_locked'] == '1' ||
          extraEta >= 14;

      final acceptedTimeStr = (raw?['summary_preparing_time'] ??
              raw?['status_updated_time'] ??
              raw?['kitchen_accepted_at'] ??
              '')
          .toString();
      final acceptedDate = (o['status'] == FoodOrderStatus.preparing.label &&
              acceptedTimeStr.isNotEmpty)
          ? parseOrderDate(acceptedTimeStr)
          : null;
      final createdDate  = parseOrderDate(createdTime);

      DateTime? expiresDate;
      final rawExpires = (raw?['final_eta_time'] ??
              raw?['eta_time'] ??
              raw?['eta_expires_at'] ??
              o['finalEtaTime'] ??
              '')
          .toString();

      if (rawExpires.isNotEmpty) {
        expiresDate = parseOrderDate(rawExpires);
      } else if (acceptedDate != null) {
        expiresDate = acceptedDate.add(Duration(minutes: 15 + extraEta));
      } else {
        expiresDate = createdDate.add(Duration(minutes: 15 + extraEta));
      }

      final tapCountVal = raw?['summary_eta_tap_count'] ??
          raw?['eta_tap_count'] ??
          o['etaTapCount'] ??
          0;
      final tapCount    = tapCountVal is num
          ? tapCountVal.toInt()
          : (int.tryParse(tapCountVal.toString()) ?? 0);

      // Resolve a non-zero integer summaryId.  _safeInt in FoodOrderService
      // converts null → 0, so we must treat 0 as "absent" here and fall through
      // to the raw field so the accept / update calls never send order_id=0.
      final rawSummaryId = o['summaryId'];
      final resolvedSummaryId = _resolveNonZeroInt(rawSummaryId)
          ?? _resolveNonZeroInt(raw?['summary_id'])
          ?? _resolveNonZeroInt(raw?['food_summary_id']);

      final double directOrderTotal = _asDouble(
        raw?['total_order_price'] ??
        raw?['order_grand_total'] ??
        raw?['grand_total'],
      );

      grouped[orderNo] = {
        'summaryId':    resolvedSummaryId,
        'orderNo':      orderNo,
        'room':         o['roomNumber'],
        'guest':        (o['guestName'] ?? 'Guest').toString(),
        'status':       o['status'],
        'items':        <Map<String, dynamic>>[],
        'raw':          raw,
        'createdAt':    createdDate,
        'acceptedAt':   acceptedDate,
        'etaExpiresAt': expiresDate,
        'etaTapCount':  tapCount,
        'etaMinutes':   15 + extraEta,
        'extraEta':     extraEta,
        // NOTE: etaLocked is stored here for read-only display purposes.
        // FoodOrdersPage additionally tracks locked orders in its own Set.
        'etaLocked':    locked,
        'cancelReason': o['cancelReason'] ?? raw?['cancel_reason'] ?? '',
        'isVeg':        o['isVeg'] ?? raw?['is_veg'],
        'totalOrderPrice': directOrderTotal,
        '_accumulatedTotal': 0.0,
        // Escalation fields (read-only display)
        'isEscalated':       o['isEscalated'] == true || raw?['is_escalated'] == 1,
        'escalationHistory': o['escalationHistory'] is List ? o['escalationHistory'] : [],
      };
    }

    final dynamic rawItemPrice = o['price'] ??
        raw?['food_price'] ??
        raw?['item_price'] ??
        raw?['price'] ??
        raw?['food_item_price'] ??
        raw?['rate'];
    final dynamic rawItemTotal = o['totalPrice'] ??
        raw?['total_price'] ??
        raw?['item_total'] ??
        raw?['item_total_price'] ??
        raw?['total_amount'] ??
        raw?['amount'];
    final int itemQty = _asInt(o['quantity']) > 0 ? _asInt(o['quantity']) : 1;
    final double itemUnitPrice = _asDouble(rawItemPrice);
    final double itemTotalPrice = rawItemTotal != null
        ? _asDouble(rawItemTotal)
        : (itemUnitPrice > 0 ? (itemUnitPrice * itemQty) : 0.0);
    final double resolvedUnitPrice = itemUnitPrice > 0
        ? itemUnitPrice
        : (itemTotalPrice > 0 && itemQty > 0 ? (itemTotalPrice / itemQty) : 0.0);
    final double resolvedItemTotal = itemTotalPrice > 0 ? itemTotalPrice : (resolvedUnitPrice * itemQty);

    (grouped[orderNo]!['items'] as List<Map<String, dynamic>>).add({
      'name':         o['foodItem'],
      'qty':          itemQty,
      'price':        resolvedUnitPrice,
      'totalPrice':   resolvedItemTotal,
      'instructions': o['cookingInstructions'],
      'isVeg':        o['isVeg'] ?? o['raw']?['is_veg'] ?? raw?['is_veg'],
    });

    // Always accumulate item totals
    final double accumulated = (grouped[orderNo]!['_accumulatedTotal'] as double? ?? 0.0) + resolvedItemTotal;
    grouped[orderNo]!['_accumulatedTotal'] = accumulated;
  }

  // Finalize order totals: if multiple items or direct total is missing/smaller, use accumulated sum
  for (final order in grouped.values) {
    final double accumulated = (order['_accumulatedTotal'] as double? ?? 0.0);
    final double directTotal = _asDouble(order['totalOrderPrice']);
    if (accumulated > 0 && (directTotal <= 0 || (order['items'] as List).length > 1 || directTotal < accumulated)) {
      order['totalOrderPrice'] = accumulated;
    } else if (directTotal > 0) {
      order['totalOrderPrice'] = directTotal;
    } else {
      order['totalOrderPrice'] = accumulated;
    }
  }

  return grouped.values.toList();
}

double _asDouble(dynamic v) {
  if (v == null) return 0.0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0.0;
}

int _asInt(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? 0;
}

/// Returns [v] as a positive (non-zero) int, or null when v is null / 0 / unparseable.
/// Used everywhere we resolve summaryId so that order_id=0 is never sent to the API.
int? _resolveNonZeroInt(dynamic v) {
  if (v == null) return null;
  final n = v is int ? v : int.tryParse(v.toString());
  if (n == null || n <= 0) return null;
  return n;
}
