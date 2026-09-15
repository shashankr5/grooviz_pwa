// lib/widgets/escalation_timeline_sheet.dart
//
// Read-only bottom sheet that displays the escalation history for a food order.
// Shows a vertical timeline with from/to user, role, and timestamp per level.

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../utils/date_formatter.dart';

class EscalationTimelineSheet extends StatelessWidget {
  final String orderNumber;
  final List<Map<String, dynamic>> escalationHistory;

  const EscalationTimelineSheet({
    super.key,
    required this.orderNumber,
    required this.escalationHistory,
  });

  /// Show the escalation timeline as a modal bottom sheet.
  static void show(
    BuildContext context, {
    required String orderNumber,
    required List<Map<String, dynamic>> escalationHistory,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EscalationTimelineSheet(
        orderNumber: orderNumber,
        escalationHistory: escalationHistory,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.7;

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
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.amber.shade700,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Escalation History',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Order #$orderNumber',
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: AppColors.textDisabled),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Timeline content
          Flexible(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                children: [
                  if (escalationHistory.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.borderLight),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.info_outline_rounded, size: 32, color: AppColors.textDisabled),
                          SizedBox(height: 8),
                          Text(
                            'No escalation details available',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ...escalationHistory.asMap().entries.map(
                      (entry) => _buildTimelineEntry(
                        entry.value,
                        isLast: entry.key == escalationHistory.length - 1,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineEntry(Map<String, dynamic> entry, {bool isLast = false}) {
    final level = entry['level'] ?? 0;
    final toUser = entry['toUser'] as Map<String, dynamic>? ?? {};
    final fromUsers = entry['fromUsers'] as List? ?? [];
    final escalatedAt = (entry['escalatedAt'] ?? '').toString();

    final toName = (toUser['userName'] ?? '').toString();
    final toRole = (toUser['roleName'] ?? '').toString();

    String fromLabel = '';
    if (fromUsers.isNotEmpty) {
      final first = fromUsers[0] as Map<String, dynamic>;
      final fromName = (first['userName'] ?? '').toString();
      final fromRole = (first['roleName'] ?? '').toString();
      fromLabel = '$fromName ($fromRole)';
    }

    String timeLabel = '';
    if (escalatedAt.isNotEmpty) {
      timeLabel = DateFormatter.formatDateTimeAmPm(escalatedAt);
    }

    // Node color progressively intensifies
    final Color nodeColor = level <= 1
        ? Colors.amber.shade600
        : level == 2
            ? Colors.orange.shade700
            : AppColors.error;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Timeline rail
          SizedBox(
            width: 32,
            child: Column(
              children: [
                Container(
                  width: 20,
                  height: 20,
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
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: Colors.amber.shade200,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Content card
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.borderLight),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Level header + time
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: nodeColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Level $level',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: nodeColor,
                          ),
                        ),
                      ),
                      if (timeLabel.isNotEmpty)
                        Text(
                          timeLabel,
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: AppColors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // From user
                  if (fromLabel.isNotEmpty) ...[
                    Row(
                      children: [
                        Icon(Icons.arrow_upward_rounded,
                            size: 13, color: Colors.grey.shade500),
                        const SizedBox(width: 6),
                        const Text(
                          'From: ',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            fromLabel,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],

                  // To user
                  Row(
                    children: [
                      Icon(Icons.arrow_downward_rounded,
                          size: 13, color: nodeColor),
                      const SizedBox(width: 6),
                      const Text(
                        'To: ',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '$toName ($toRole)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: nodeColor,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
