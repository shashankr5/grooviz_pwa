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
      final v = isVegFlag.toString();
      return v == '1' || v == 'true';
    }
    return name.toLowerCase().contains('veg');
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
}
