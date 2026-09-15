// lib/widgets/timeline_order_card.dart
import 'package:flutter/material.dart';
import '../widgets/kot_preview_sheet.dart';
import '../utils/date_formatter.dart';
import '../theme/app_colors.dart';

class TimelineOrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final VoidCallback? onTap;

  const TimelineOrderCard({
    super.key,
    required this.order,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final status = (order['status'] ?? '').toString();
    final statusUpper = status.toUpperCase();

    final isDelivered = statusUpper == 'DELIVERED';
    final isCancelled = statusUpper == 'CANCELLED' || statusUpper == 'CANCELED';
    final isReady = statusUpper == 'READY';
    final isPreparing = statusUpper == 'PREPARING';

    Color nodeColor = AppColors.primary;
    if (isDelivered) nodeColor = AppColors.success;
    if (isCancelled) nodeColor = AppColors.error;
    if (isReady) nodeColor = AppColors.success;
    if (isPreparing) nodeColor = AppColors.warning;

    final roomNumber = (order['roomNumber'] ?? order['room'] ?? order['raw']?['room_number'] ?? '101').toString();
    final orderNumber = (order['orderNumber'] ?? order['orderNo'] ?? order['raw']?['order_number'] ?? 'ORD-000').toString();
    final guestName = (order['guestName'] ?? order['guest'] ?? order['raw']?['guest_name'])?.toString();

    // Resolve food item name and quantity from grouped items[] if present,
    // otherwise fall back to the flat foodItem/name field (legacy/ungrouped).
    final itemsList = order['items'] as List?;
    final String foodItem;
    final String quantity;
    if (itemsList != null && itemsList.isNotEmpty) {
      // Show all item names joined, e.g. "Butter Chicken, Naan x2"
      final parts = itemsList.map((i) {
        final n = (i['name'] ?? '').toString().trim();
        final q = (i['qty'] ?? i['quantity'] ?? 1);
        return q.toString() == '1' ? n : '$n x$q';
      }).where((s) => s.isNotEmpty).toList();
      foodItem = parts.isNotEmpty ? parts.join(', ') : 'Food Item';
      final totalQty = itemsList.fold<int>(0, (sum, i) {
        final q = i['qty'] ?? i['quantity'] ?? 1;
        return sum + (q is int ? q : int.tryParse(q.toString()) ?? 1);
      });
      quantity = totalQty.toString();
    } else {
      foodItem = (order['foodItem'] ?? order['name'] ?? 'Food Item').toString();
      quantity = (order['quantity'] ?? order['qty'] ?? 1).toString();
    }
    final cancelReason = order['cancelReason'] ?? order['raw']?['cancel_reason'];

    final double totalOrderPrice = () {
      final raw = order['raw'] as Map? ?? {};
      final v = order['totalOrderPrice'] ?? raw['total_order_price'] ?? raw['total_amount'] ?? raw['grand_total'] ?? raw['amount'];
      return (v is num) ? v.toDouble() : (double.tryParse(v?.toString() ?? '') ?? 0.0);
    }();

    DateTime? orderTime;
    try {
      final rawTime = order['createdAt'] ?? order['raw']?['order_time'] ?? order['raw']?['created_at'];
      orderTime = rawTime is DateTime ? rawTime : DateTime.tryParse(rawTime.toString());
    } catch (_) {}

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Timeline Node Rail
          Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 4),
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: nodeColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: nodeColor.withValues(alpha: 0.3),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  width: 2,
                  color: Colors.grey.shade300,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),

          // Main Card Content
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade200),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.03),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Top Row: Room Pill & Status + KOT Button
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.indigo.shade50,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.meeting_room_rounded,
                                  size: 13,
                                  color: Colors.indigo,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    'ROOM $roomNumber',
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.indigo,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),

                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // KOT Button
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () => KOTPreviewSheet.show(context, order),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryLight,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.print_rounded, size: 13, color: AppColors.primary),
                                    SizedBox(width: 3),
                                    Text(
                                      "KOT",
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),

                            // Status Badge
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: nodeColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                statusUpper,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: nodeColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Dedicated Full-Width Order Number Row
                    Row(
                      children: [
                        const Text(
                          'Order #: ',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.black54,
                          ),
                        ),
                        Expanded(
                          child: SelectableText(
                            orderNumber,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // Items Summary Line
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.primaryLight,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${quantity}x',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            foodItem,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (totalOrderPrice > 0) ...[
                          const SizedBox(width: 8),
                          Text(
                            '\u20b9${totalOrderPrice.toStringAsFixed(totalOrderPrice.truncateToDouble() == totalOrderPrice ? 0 : 2)}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: Colors.black,
                            ),
                          ),
                        ],
                      ],
                    ),

                    // Guest Name & Time Row
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (orderTime != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.access_time_rounded,
                                size: 12,
                                color: Colors.black45,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                DateFormatter.formatDateTimeAmPm(
                                  orderTime.toIso8601String().replaceAll('T', ' '),
                                ),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        if (guestName != null && guestName.trim().isNotEmpty)
                          Flexible(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.person_rounded,
                                  size: 12,
                                  color: Colors.black45,
                                ),
                                const SizedBox(width: 3),
                                Flexible(
                                  child: Text(
                                    guestName,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: Colors.black54,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),

                    // Cancellation Reason (if applicable)
                    if (isCancelled && cancelReason != null && cancelReason.toString().trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.errorLight,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.error.withValues(alpha: 0.2)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline_rounded, size: 14, color: AppColors.error),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Reason: ${cancelReason.toString().trim()}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Escalation indicator
                    if (_isEscalated(order)) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.amber.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, size: 13, color: Colors.amber.shade700),
                            const SizedBox(width: 6),
                            Text(
                              'Escalated',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.amber.shade800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isEscalated(Map<String, dynamic> order) {
    if (order['isEscalated'] == true) return true;
    // Use a safe cast — JSON-decoded maps come back as Map<dynamic, dynamic>
    // which cannot be hard-cast to Map<String, dynamic> and throws a _TypeError.
    final rawDynamic = order['raw'];
    if (rawDynamic is Map) {
      if (rawDynamic['is_escalated'] == 1 || rawDynamic['is_escalated'] == true) return true;
    }
    return false;
  }
}
