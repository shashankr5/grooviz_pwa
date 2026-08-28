// lib/widgets/order_history_detail_sheet.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/kot_ticket_model.dart';
import '../services/kot_printer_service.dart';
import '../widgets/kot_preview_sheet.dart';
import '../utils/app_snackbar.dart';
import '../utils/date_formatter.dart';
import '../theme/app_colors.dart';

class OrderHistoryDetailSheet extends StatelessWidget {
  final Map<String, dynamic> order;

  const OrderHistoryDetailSheet({
    super.key,
    required this.order,
  });

  static void show(BuildContext context, Map<String, dynamic> order) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OrderHistoryDetailSheet(order: order),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ticket = KOTTicketModel.fromFoodOrder(order);
    final status = (order['status'] ?? '').toString();
    final statusUpper = status.toUpperCase();

    final isDelivered = statusUpper == 'DELIVERED';
    final isCancelled = statusUpper == 'CANCELLED' || statusUpper == 'CANCELED';
    final isReady = statusUpper == 'READY';
    final isPreparing = statusUpper == 'PREPARING';

    Color statusColor = AppColors.primary;
    if (isDelivered) statusColor = AppColors.success;
    if (isCancelled) statusColor = AppColors.error;
    if (isReady) statusColor = AppColors.success;
    if (isPreparing) statusColor = AppColors.warning;

    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        top: 12,
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.receipt_long_rounded,
                  color: statusColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Order Audit & Details',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: AppColors.textDisabled),
              ),
            ],
          ),
          const SizedBox(height: 16),

          Flexible(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Meta Info Card
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAFAFA),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.indigo.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.meeting_room_rounded,
                                    size: 14,
                                    color: Colors.indigo,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'ROOM ${ticket.roomNumber}',
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.indigo,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                statusUpper,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: statusColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Text(
                              'Order #: ',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: Colors.black54,
                              ),
                            ),
                            Expanded(
                              child: SelectableText(
                                ticket.orderNumber,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (ticket.guestName != null && ticket.guestName!.trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(Icons.person_rounded, size: 14, color: Colors.black54),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Guest: ${ticket.guestName}',
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: Colors.black87,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(Icons.access_time_rounded, size: 14, color: Colors.black54),
                            const SizedBox(width: 6),
                            Text(
                              'Placed: ${DateFormatter.formatDateTime(ticket.orderTime.toIso8601String().replaceAll('T', ' '))}',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: Colors.black87,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  // Lifecycle Audit Stepper
                  const Text(
                    'Order Lifecycle Stepper',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Row(
                      children: [
                        _buildStepNode('Placed', isDone: true),
                        _buildStepConnector(isDone: isPreparing || isReady || isDelivered),
                        _buildStepNode('Preparing', isDone: isPreparing || isReady || isDelivered),
                        _buildStepConnector(isDone: isReady || isDelivered),
                        _buildStepNode('Ready', isDone: isReady || isDelivered),
                        _buildStepConnector(isDone: isDelivered),
                        _buildStepNode('Delivered', isDone: isDelivered, isCancel: isCancelled),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  // Itemized Food List
                  const Text(
                    'Ordered Items',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 10),

                  ...ticket.items.map((item) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFAFAFA),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.primaryLight,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '${item.quantity}x',
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                item.name,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: item.isVeg ? AppColors.successLight : AppColors.errorLight,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                item.isVeg ? 'VEG' : 'NON-VEG',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: item.isVeg ? AppColors.success : AppColors.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )),

                  // Special Instructions / Cancellation Box
                  if (isCancelled && order['cancelReason'] != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.errorLight,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.error.withValues(alpha: 0.2)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.cancel_rounded, size: 15, color: AppColors.error),
                              SizedBox(width: 6),
                              Text(
                                'CANCELLATION REASON',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.error,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            order['cancelReason'].toString(),
                            style: const TextStyle(fontSize: 12, color: Colors.black87),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // Escalation History Section
                  if (_isOrderEscalated(order)) ...[
                    const SizedBox(height: 18),
                    const Text(
                      'Escalation History',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 10),
                    _buildEscalationSection(order),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Actions
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await KOTPrinterService.copyReceiptToClipboard(ticket);
                    if (context.mounted) {
                      AppSnackBar.show(context, 'KOT text copied to clipboard 📋');
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy Receipt'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    KOTPreviewSheet.show(context, order);
                  },
                  icon: const Icon(Icons.print_rounded, size: 18),
                  label: const Text('View KOT'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStepNode(String label, {bool isDone = false, bool isCancel = false}) {
    Color c = isDone ? AppColors.success : Colors.grey.shade300;
    if (isCancel) c = AppColors.error;

    return Expanded(
      child: Column(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
            ),
            child: Icon(
              isCancel
                  ? Icons.close_rounded
                  : isDone
                      ? Icons.check_rounded
                      : Icons.circle_outlined,
              size: 14,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: isDone ? FontWeight.bold : FontWeight.normal,
              color: isDone ? AppColors.textPrimary : AppColors.textDisabled,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildStepConnector({bool isDone = false}) {
    return Expanded(
      child: Container(
        height: 2,
        color: isDone ? AppColors.success : Colors.grey.shade300,
        margin: const EdgeInsets.only(bottom: 14),
      ),
    );
  }

  // ── ESCALATION HELPERS ──────────────────────────────────────────────────

  bool _isOrderEscalated(Map<String, dynamic> order) {
    if (order['isEscalated'] == true) return true;
    final raw = order['raw'] as Map<String, dynamic>?;
    if (raw != null && (raw['is_escalated'] == 1 || raw['is_escalated'] == true)) return true;
    return false;
  }

  Widget _buildEscalationSection(Map<String, dynamic> order) {
    final history = _resolveEscalationHistory(order);
    if (history.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.amber.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.amber.shade200),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 15, color: Colors.amber.shade700),
            const SizedBox(width: 8),
            const Text(
              'Escalated (details unavailable)',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Column(
        children: history.asMap().entries.map((entry) {
          final e = entry.value;
          final isLast = entry.key == history.length - 1;
          final level = e['level'] ?? 0;
          final toUser = e['toUser'] as Map<String, dynamic>? ?? {};
          final fromUsers = e['fromUsers'] as List? ?? [];
          final escalatedAt = (e['escalatedAt'] ?? '').toString();

          final toName = (toUser['userName'] ?? '').toString();
          final toRole = (toUser['roleName'] ?? '').toString();

          String fromLabel = '';
          if (fromUsers.isNotEmpty) {
            final first = fromUsers[0] as Map<String, dynamic>;
            fromLabel = '${first['userName'] ?? ''} (${first['roleName'] ?? ''})';
          }

          String timeLabel = '';
          if (escalatedAt.isNotEmpty) {
            timeLabel = DateFormatter.formatDateTimeAmPm(escalatedAt);
          }

          return Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Level indicator
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: level <= 1 ? Colors.amber.shade600 : Colors.orange.shade700,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '$level',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Level $level',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.amber.shade800,
                            ),
                          ),
                          if (timeLabel.isNotEmpty)
                            Text(
                              timeLabel,
                              style: const TextStyle(
                                fontSize: 10,
                                fontFamily: 'monospace',
                                color: AppColors.textSecondary,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      if (fromLabel.isNotEmpty)
                        Text(
                          '$fromLabel  \u2192  $toName ($toRole)',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textPrimary,
                          ),
                        )
                      else
                        Text(
                          'To: $toName ($toRole)',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textPrimary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  List<Map<String, dynamic>> _resolveEscalationHistory(Map<String, dynamic> order) {
    // Try pre-parsed escalationHistory first
    final parsed = order['escalationHistory'];
    if (parsed is List && parsed.isNotEmpty) {
      return parsed.cast<Map<String, dynamic>>();
    }
    // Fallback: try raw.escalation_history
    final raw = order['raw'] as Map<String, dynamic>?;
    if (raw == null) return [];
    final rawHistory = raw['escalation_history'];
    if (rawHistory == null) return [];
    try {
      List list;
      if (rawHistory is String) {
        if (rawHistory.trim().isEmpty) return [];
        list = json.decode(rawHistory) as List;
      } else if (rawHistory is List) {
        list = rawHistory;
      } else {
        return [];
      }
      return list.map<Map<String, dynamic>>((entry) {
        final e = Map<String, dynamic>.from(entry);
        final toUser = e['to_user'] is Map ? Map<String, dynamic>.from(e['to_user']) : <String, dynamic>{};
        final fromUsers = (e['from_users'] is List)
            ? (e['from_users'] as List).map((f) => Map<String, dynamic>.from(f)).toList()
            : <Map<String, dynamic>>[];
        return {
          'level': e['level'] ?? 0,
          'toUser': {
            'userId': toUser['user_id'],
            'userName': toUser['user_name'] ?? '',
            'roleName': toUser['role_name'] ?? '',
          },
          'fromUsers': fromUsers.map((f) => {
            'userId': f['user_id'],
            'userName': f['user_name'] ?? '',
            'roleName': f['role_name'] ?? '',
          }).toList(),
          'escalatedAt': e['escalated_at'] ?? '',
        };
      }).toList();
    } catch (_) {
      return [];
    }
  }
}
