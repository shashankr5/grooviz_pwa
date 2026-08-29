// lib/models/order_history_analytics_model.dart

class OrderHistoryAnalyticsModel {
  final int totalOrders;
  final int cancelledCount;
  final int deliveredCount;
  final double avgPrepMinutes;
  final double avgDeliveryMinutes;
  final double kitchenSlaPercent;
  final Map<int, int> hourlyVolume; // Hour (0-23) -> Count
  final Map<String, int> cancellationReasons;

  OrderHistoryAnalyticsModel({
    required this.totalOrders,
    required this.cancelledCount,
    required this.deliveredCount,
    required this.avgPrepMinutes,
    required this.avgDeliveryMinutes,
    required this.kitchenSlaPercent,
    required this.hourlyVolume,
    required this.cancellationReasons,
  });

  factory OrderHistoryAnalyticsModel.fromOrders(List<Map<String, dynamic>> orders) {
    int total = orders.length;
    int cancelled = 0;
    int delivered = 0;

    // Kitchen SLA: summary_preparing_time → summary_ready_time
    double totalPrepMins = 0;
    int    prepCount     = 0;
    int    slaMetCount   = 0; // orders where prep <= 15 min

    // Delivery SLA: summary_ready_time → summary_delivered_time
    double totalDeliveryMins = 0;
    int    deliveryCount     = 0;

    final Map<int, int>    hourlyMap = {};
    final Map<String, int> cancelMap = {};

    for (int i = 0; i < 24; i++) {
      hourlyMap[i] = 0;
    }

    for (final o in orders) {
      final status = (o['status'] ?? '').toString().toUpperCase();
      if (status == 'CANCELLED' || status == 'CANCELED') {
        cancelled++;
        final reason = (o['cancelReason'] ?? o['raw']?['cancel_reason'] ?? 'Unspecified').toString();
        cancelMap[reason] = (cancelMap[reason] ?? 0) + 1;
      } else if (status == 'DELIVERED') {
        delivered++;
      }

      // Hourly volume — use order placed time
      DateTime? orderTime;
      try {
        final rawTime = o['createdAt'] ?? o['raw']?['order_time'] ?? o['raw']?['created_at'];
        orderTime = rawTime is DateTime ? rawTime : DateTime.tryParse(rawTime.toString());
      } catch (_) {}

      if (orderTime != null) {
        final hour = orderTime.hour;
        hourlyMap[hour] = (hourlyMap[hour] ?? 0) + 1;
      }

      // ── Kitchen SLA: preparing_time → ready_time ──────────────────────────
      DateTime? preparingTime;
      DateTime? readyTime;
      try {
        final rawPrep  = o['raw']?['summary_preparing_time'];
        final rawReady = o['raw']?['summary_ready_time'];
        if (rawPrep  != null) preparingTime = rawPrep  is DateTime ? rawPrep  : DateTime.tryParse(rawPrep.toString());
        if (rawReady != null) readyTime     = rawReady is DateTime ? rawReady : DateTime.tryParse(rawReady.toString());
      } catch (_) {}

      if (preparingTime != null && readyTime != null) {
        final prepMins = readyTime.difference(preparingTime).inSeconds / 60.0;
        if (prepMins > 0 && prepMins < 180) { // sanity cap 3h
          totalPrepMins += prepMins;
          prepCount++;
          if (prepMins <= 15) slaMetCount++;
        }
      }

      // ── Delivery SLA: ready_time → delivered_time ─────────────────────────
      DateTime? deliveredTime;
      try {
        final rawDelivered = o['raw']?['summary_delivered_time'];
        if (rawDelivered != null) {
          deliveredTime = rawDelivered is DateTime
              ? rawDelivered
              : DateTime.tryParse(rawDelivered.toString());
        }
      } catch (_) {}

      if (readyTime != null && deliveredTime != null) {
        final deliveryMins = deliveredTime.difference(readyTime).inSeconds / 60.0;
        if (deliveryMins > 0 && deliveryMins < 120) { // sanity cap 2h
          totalDeliveryMins += deliveryMins;
          deliveryCount++;
        }
      }
    }

    // Average prep time — fall back to null display if no data
    final double avgPrep     = prepCount     > 0 ? totalPrepMins     / prepCount     : 0;
    final double avgDelivery = deliveryCount > 0 ? totalDeliveryMins / deliveryCount : 0;

    // Kitchen SLA % = orders prepared within 15 min / orders with prep data
    final double kitchenSla  = prepCount > 0
        ? (slaMetCount / prepCount) * 100
        : 0;

    return OrderHistoryAnalyticsModel(
      totalOrders:        total,
      cancelledCount:     cancelled,
      deliveredCount:     delivered,
      avgPrepMinutes:     double.parse(avgPrep.toStringAsFixed(1)),
      avgDeliveryMinutes: double.parse(avgDelivery.toStringAsFixed(1)),
      kitchenSlaPercent:  double.parse(kitchenSla.toStringAsFixed(1)),
      hourlyVolume:       hourlyMap,
      cancellationReasons: cancelMap,
    );
  }
}
