// pages/food_order_detail_page.dart
//
// Read-only detail view for a single food order, opened when the user taps a
// food-order notification (NEW_FOOD_ORDER, ORDER_ACCEPTED, ORDER_CANCELLED,
// ORDER_STATUS_CHANGED).
//
// Visual language is identical to FoodOrdersPage._buildOrderCard() — same
// card structure, same status chip, same item rows, same cooking instructions
// and cancel-reason banners — so the order looks exactly the same whether the
// user arrives via the main list or a notification tap.
//
// This page is intentionally read-only: action buttons (Accept / Mark Ready /
// Cancel) are omitted because the notification recipient may not be the F&B
// staff member responsible for the order. They can navigate to FoodOrdersPage
// via the bottom nav to take action.

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../utils/food_order_status.dart';
import '../utils/date_formatter.dart';
import '../utils/order_grouping.dart';
import '../components/app_badge.dart';

class FoodOrderDetailPage extends StatelessWidget {
  /// A fully-grouped order map as returned by groupFoodOrderRows() and
  /// EntityResolver.resolveFoodOrder(). Must contain:
  ///   orderNo, room, guest, status, items[], createdAt, cancelReason,
  ///   raw (for is_veg, order_status)
  final Map<String, dynamic> order;

  const FoodOrderDetailPage({super.key, required this.order});

  // ── Helpers ───────────────────────────────────────────────────────────────

  bool _isVeg(dynamic isVegFlag, String name) {
    if (isVegFlag != null) {
      final v = isVegFlag.toString().trim().toLowerCase();
      if (v == '1' || v == 'true' || v == 'veg') return true;
      if (v == '0' || v == 'false' || v == 'non-veg' || v == 'nonveg') return false;
    }
    final lower = name.toLowerCase();
    return lower.contains('veg') &&
        !lower.contains('non-veg') &&
        !lower.contains('non veg') &&
        !lower.contains('nonveg');
  }

  /// FSSAI-style veg/non-veg indicator — matches food_orders_page._fssaiIcon()
  Widget _fssaiIcon(bool isVeg) {
    final c = isVeg ? AppColors.success : AppColors.error;
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(border: Border.all(color: c, width: 1.5)),
      child: Center(
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
      ),
    );
  }

  Color _chipColor(String status) => AppColors.statusColor(status);

  String _formattedDateTime(DateTime time) =>
      DateFormatter.formatDateTimeObjectAmPm(time);

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final items     = (order['items'] as List? ?? []);
    final status    = (order['status'] ?? '').toString();
    final room      = (order['room']   ?? '-').toString();
    final guest     = (order['guest']  ?? 'Guest').toString();
    final orderNo   = (order['orderNo'] ?? '-').toString();
    final createdAt = order['createdAt'] as DateTime? ?? DateTime.now();
    final cancelReason = (order['cancelReason'] ?? '').toString();

    final instructionsList = items
        .map((i) => (i['instructions'] ?? '').toString().trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();

    final chipColor = _chipColor(status);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Order Details', style: AppTypography.appBarTitle),
            Text('Room $room', style: AppTypography.appBarSubtitle),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildOrderCard(
              items: items,
              status: status,
              room: room,
              guest: guest,
              orderNo: orderNo,
              createdAt: createdAt,
              cancelReason: cancelReason,
              instructionsList: instructionsList,
              chipColor: chipColor,
            ),
            const SizedBox(height: 16),
            // Navigate-to-list nudge
            _buildActionNudge(context),
          ],
        ),
      ),
    );
  }

  /// Order card — visually identical to FoodOrdersPage._buildOrderCard()
  /// minus animation scaffolding (shake/blink) and action buttons.
  Widget _buildOrderCard({
    required List items,
    required String status,
    required String room,
    required String guest,
    required String orderNo,
    required DateTime createdAt,
    required String cancelReason,
    required List<String> instructionsList,
    required Color chipColor,
  }) {
    final isCancelled = status == FoodOrderStatus.cancelled.label;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header: Room badge + Status chip + Order# + Time ─────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Room badge (matches food_orders_page style)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isCancelled
                          ? AppColors.error.withOpacity(0.08)
                          : Colors.indigo.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Room ',
                          style: TextStyle(
                            fontSize: 15,
                            color: isCancelled
                                ? AppColors.error
                                : Colors.indigo,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          room,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: isCancelled
                                ? AppColors.error
                                : Colors.indigo,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // Status chip
                        AppBadge(
                          label: status,
                          color: chipColor,
                          backgroundColor: chipColor.withOpacity(0.1),
                          small: true,
                        ),
                        const SizedBox(height: 6),
                        // Order number
                        Text(
                          '#$orderNo',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        // Timestamp
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            const Icon(Icons.calendar_today_rounded,
                                size: 11, color: AppColors.textDisabled),
                            const SizedBox(width: 3),
                            Text(
                              _formattedDateTime(createdAt),
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // ── Guest name ────────────────────────────────────────────────
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: const BoxDecoration(
                      color: AppColors.surfaceAlt,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.person_rounded,
                        size: 13, color: AppColors.textSecondary),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      guest,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),

              _buildOrderLifecycleStepper(order),

              const Divider(height: 16, color: AppColors.borderLight),

              // ── Items header ──────────────────────────────────────────────
              const Row(
                children: [
                  Icon(Icons.restaurant_menu_rounded,
                      size: 13, color: AppColors.textDisabled),
                  SizedBox(width: 5),
                  Text(
                    'Order Items',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textDisabled,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 7),

              // ── Item rows ─────────────────────────────────────────────────
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No items recorded',
                    style: TextStyle(
                        fontSize: 13, color: AppColors.textDisabled),
                  ),
                )
              else
                ...items.map<Widget>((i) {
                  final name  = (i['name'] ?? '').toString();
                  final qty   = i['qty'];
                  final isVeg = _isVeg(i['isVeg'], name);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _fssaiIcon(isVeg),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            '$qty',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  );
                }),

              // ── Cooking instructions ──────────────────────────────────────
              if (instructionsList.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.infoLight,
                    borderRadius: BorderRadius.circular(10),
                    border:
                        Border.all(color: AppColors.info.withOpacity(0.25)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_rounded,
                          color: AppColors.info, size: 14),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Cooking Instructions',
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.info),
                            ),
                            const SizedBox(height: 2),
                            ...instructionsList.map((ins) => Text(
                                  ins,
                                  style: const TextStyle(
                                      fontSize: 12, height: 1.4),
                                )),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // ── Cancel reason ─────────────────────────────────────────────
              if (isCancelled && cancelReason.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.errorLight,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.error.withOpacity(0.2)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.cancel_rounded,
                          color: AppColors.error, size: 14),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Cancelled Reason',
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.error),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              cancelReason,
                              style:
                                  const TextStyle(fontSize: 12, height: 1.4),
                            ),
                          ],
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
    );
  }

  /// Nudge banner prompting navigation to the full food orders list.
  Widget _buildActionNudge(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withOpacity(0.15)),
      ),
      child: Row(
        children: [
          const Icon(Icons.restaurant_rounded,
              size: 18, color: AppColors.primary),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Go to Food Orders to accept, prepare, or update this order.',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.primary,
                  height: 1.4),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Go back',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderLifecycleStepper(Map<String, dynamic> order) {
    final raw = order['raw'] as Map<String, dynamic>? ?? {};
    final status = (order['status'] ?? '').toString();
    final isCancelled = status == FoodOrderStatus.cancelled.label ||
        (raw['order_status'] ?? '').toString().toUpperCase() == 'CANCELLED';

    final createdAt = order['createdAt'] as DateTime? ??
        parseOrderDate((raw['created_at'] ?? raw['order_time'] ?? '').toString());

    final preparingTimeStr = (raw['summary_preparing_time'] ??
            raw['status_updated_time'] ??
            raw['kitchen_accepted_at'] ??
            '')
        .toString();
    final preparingAt = order['acceptedAt'] as DateTime? ??
        (preparingTimeStr.isNotEmpty ? parseOrderDate(preparingTimeStr) : null);

    final readyTimeStr = (raw['summary_ready_time'] ?? '').toString();
    final readyAt = order['readyAt'] as DateTime? ??
        (readyTimeStr.isNotEmpty ? parseOrderDate(readyTimeStr) : null);

    final deliveredTimeStr = (raw['summary_delivered_time'] ?? '').toString();
    final deliveredAt =
        deliveredTimeStr.isNotEmpty ? parseOrderDate(deliveredTimeStr) : null;

    final cancelledTimeStr = (raw['summary_cancelled_time'] ?? '').toString();
    final cancelledAt =
        cancelledTimeStr.isNotEmpty ? parseOrderDate(cancelledTimeStr) : null;

    final elapsedMins = DateTime.now().difference(createdAt).inMinutes.clamp(0, 9999);

    int activeStage = 0;
    if (isCancelled) {
      activeStage = 3;
    } else if (deliveredAt != null || status == FoodOrderStatus.delivered.label) {
      activeStage = 3;
    } else if (readyAt != null || status == FoodOrderStatus.ready.label) {
      activeStage = 2;
    } else if (preparingAt != null || status == FoodOrderStatus.preparing.label) {
      activeStage = 1;
    }

    final steps = [
      {
        'title': 'Placed',
        'time': DateFormatter.formatDateTimeOnlyAmPm(createdAt),
        'isDone': true,
        'isActive': activeStage == 0,
        'color': AppColors.primary,
        'icon': Icons.receipt_long_rounded,
      },
      {
        'title': 'Preparing',
        'time': preparingAt != null
            ? DateFormatter.formatDateTimeOnlyAmPm(preparingAt)
            : (activeStage > 1 ? 'Done' : '(Pending)'),
        'isDone': activeStage >= 1 && !isCancelled,
        'isActive': activeStage == 1 && !isCancelled,
        'color': AppColors.warning,
        'icon': Icons.restaurant_rounded,
      },
      {
        'title': 'Ready',
        'time': readyAt != null
            ? DateFormatter.formatDateTimeOnlyAmPm(readyAt)
            : (activeStage > 2 ? 'Done' : '(Pending)'),
        'isDone': activeStage >= 2 && !isCancelled,
        'isActive': activeStage == 2 && !isCancelled,
        'color': AppColors.info,
        'icon': Icons.check_circle_outline_rounded,
      },
      {
        'title': isCancelled ? 'Cancelled' : 'Delivered',
        'time': isCancelled
            ? (cancelledAt != null ? DateFormatter.formatDateTimeOnlyAmPm(cancelledAt) : 'Cancelled')
            : (deliveredAt != null
                ? DateFormatter.formatDateTimeOnlyAmPm(deliveredAt)
                : '(Pending)'),
        'isDone': activeStage == 3,
        'isActive': activeStage == 3,
        'color': isCancelled ? AppColors.error : AppColors.success,
        'icon': isCancelled ? Icons.cancel_outlined : Icons.done_all_rounded,
      },
    ];

    String statePillLabel;
    Color statePillColor;

    if (isCancelled) {
      final reason = (order['cancelReason'] ?? raw['cancel_reason'] ?? '').toString();
      statePillLabel = reason.isNotEmpty ? "Cancelled: $reason" : "Order Cancelled";
      statePillColor = AppColors.error;
    } else if (activeStage == 3) {
      statePillLabel = "Delivered to Room ${order['room']}";
      statePillColor = AppColors.success;
    } else if (activeStage == 2) {
      statePillLabel = "Ready for Delivery • Room ${order['room']}";
      statePillColor = AppColors.success;
    } else if (activeStage == 1) {
      statePillLabel = "Preparing in Kitchen...";
      statePillColor = AppColors.warning;
    } else {
      statePillLabel = "New Order Placed • Awaiting Acceptance";
      statePillColor = AppColors.primary;
    }

    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AppColors.primaryLight,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.timeline_rounded, size: 12, color: AppColors.primary),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    "Order Timeline",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.borderLight),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.timer_outlined, size: 11, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      "$elapsedMins min elapsed",
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Stack(
            alignment: Alignment.topCenter,
            children: [
              Positioned(
                top: 11,
                left: 28,
                right: 28,
                child: Stack(
                  children: [
                    Container(
                      height: 2.5,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: isCancelled
                          ? 1.0
                          : (activeStage / (steps.length - 1)).clamp(0.0, 1.0),
                      child: Container(
                        height: 2.5,
                        decoration: BoxDecoration(
                          color: isCancelled ? AppColors.error : AppColors.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: steps.map((step) {
                  final isDone = step['isDone'] as bool;
                  final isActive = step['isActive'] as bool;
                  final color = step['color'] as Color;

                  return Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: isDone || isActive ? color : Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isDone || isActive ? color : Colors.grey.shade300,
                              width: 2,
                            ),
                            boxShadow: isActive
                                ? [
                                    BoxShadow(
                                      color: color.withOpacity(0.35),
                                      blurRadius: 6,
                                      spreadRadius: 1,
                                    ),
                                  ]
                                : null,
                          ),
                          child: Center(
                            child: Icon(
                              step['icon'] as IconData,
                              size: 12,
                              color: isDone || isActive ? Colors.white : Colors.grey.shade400,
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          step['title'] as String,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: isActive || isDone ? FontWeight.w700 : FontWeight.w500,
                            color: isActive
                                ? color
                                : (isDone ? AppColors.textPrimary : AppColors.textDisabled),
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          step['time'] as String,
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                            color: isActive
                                ? color
                                : (isDone ? AppColors.textSecondary : Colors.grey.shade400),
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: statePillColor.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: statePillColor.withOpacity(0.25)),
            ),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: statePillColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: statePillColor.withOpacity(0.5),
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    statePillLabel,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: statePillColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
