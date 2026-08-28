// utils/order_grouping.dart
//
// Shared food-order grouping logic.
//
// WHY THIS EXISTS:
//   FoodOrdersPage._groupApiOrders() was a private instance method. EntityResolver
//   needed the same grouping to return complete orders (all items, not one row).
//   Extracting it here means both callers share one implementation that can't drift.
//
// IMPORTANT NOTES ON WHAT IS/ISN'T HERE:
//   • etaLocked / _maxDelayReachedOrders mutation is intentionally NOT included.
//     That is page-level ETA state used only by FoodOrdersPage. The entity resolver
//     and detail page do not need ETA tracking — they just need the grouped structure.
//     FoodOrdersPage.groupFoodOrderRows() calls this and then applies ETA state itself.
//
//   • Delivered room-service orders (HomeService.getDeliveredOrdersForRoomService)
//     return a different schema (delivery_page rows) and are NOT handled here.
//     Tapping ORDER_DELIVERED notifications intentionally tab-switches only —
//     no detail push — because there is no matching entityId routing for that type.

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
        // Escalation fields (read-only display)
        'isEscalated':       o['isEscalated'] == true || raw?['is_escalated'] == 1,
        'escalationHistory': o['escalationHistory'] is List ? o['escalationHistory'] : [],
      };
    }

    (grouped[orderNo]!['items'] as List<Map<String, dynamic>>).add({
      'name':         o['foodItem'],
      'qty':          o['quantity'],
      'instructions': o['cookingInstructions'],
      'isVeg':        o['isVeg'] ?? o['raw']?['is_veg'] ?? raw?['is_veg'],
    });
  }

  return grouped.values.toList();
}

/// Returns [v] as a positive (non-zero) int, or null when v is null / 0 / unparseable.
/// Used everywhere we resolve summaryId so that order_id=0 is never sent to the API.
int? _resolveNonZeroInt(dynamic v) {
  if (v == null) return null;
  final n = v is int ? v : int.tryParse(v.toString());
  if (n == null || n <= 0) return null;
  return n;
}
