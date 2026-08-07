// components/home/timeline_task_card.dart
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../utils/date_formatter.dart';

class TimelineTaskCard extends StatelessWidget {
  final Map<String, dynamic> task;
  final bool isSupervisor;
  final VoidCallback onTap;
  final VoidCallback? onAccept;
  final VoidCallback? onReassign;

  final bool isAccepting;

  const TimelineTaskCard({
    super.key,
    required this.task,
    required this.isSupervisor,
    required this.onTap,
    this.onAccept,
    this.onReassign,
    this.isAccepting = false,
  });

  @override
  Widget build(BuildContext context) {
    final String roomStr = (task['room'] ?? '-').toString();
    final String titleStr = (task['title'] ?? 'Service Request').toString();
    final String guestName = (task['guest'] ?? 'Guest').toString();
    final String statusStr = (task['status'] ?? 'Open').toString();
    final String timeStr = (task['time'] ?? '').toString();
    final String assignedTo = (task['assignedTo'] ?? task['assigned_to_name'] ?? task['raw']?['assigned_to_name'] ?? '-').toString();
    final bool isAlreadyAssigned = (assignedTo != '-' &&
                                    assignedTo != 'Unassigned' &&
                                    assignedTo.trim().isNotEmpty) ||
                                   task['isAccepted'] == true ||
                                   (task['assigned_to'] != null &&
                                    task['assigned_to'].toString() != '0' &&
                                    task['assigned_to'].toString() != 'null') ||
                                   (task['raw']?['assigned_to'] != null &&
                                    task['raw']?['assigned_to'].toString() != '0' &&
                                    task['raw']?['assigned_to'].toString() != 'null');

    final bool isEscalated = task['is_escalated'] == 1 || task['isEscalated'] == true;

    final String requestId = (task['service_request_id'] ??
                              task['task_id'] ??
                              task['id'] ??
                              task['raw']?['service_request_id'] ??
                              '').toString();

    final Color statusCol = AppColors.statusColor(statusStr);
    final Color statusBg = AppColors.statusLightColor(statusStr);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isEscalated
                ? AppColors.error
                : AppColors.border.withOpacity(0.6),
            width: isEscalated ? 1.5 : 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.shadow,
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Accent Bar for Escalated Items
            if (isEscalated)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                decoration: const BoxDecoration(
                  color: AppColors.error,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(14),
                    topRight: Radius.circular(14),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.white, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      'SLA BREACHED — REQUIRES SUPERVISOR ATTENTION',
                      style: AppTypography.caption.copyWith(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),

            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Row 1: Room Pill, Request ID & Status Badge
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          // Room Number Pill
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: AppColors.primaryLight,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.meeting_room_outlined,
                                    color: AppColors.primary, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  'ROOM $roomStr',
                                  style: AppTypography.title.copyWith(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (requestId.isNotEmpty && requestId != '0') ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 5),
                              decoration: BoxDecoration(
                                color: AppColors.bg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: AppColors.border.withOpacity(0.6)),
                              ),
                              child: Text(
                                '#$requestId',
                                style: AppTypography.caption.copyWith(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),

                      // Status Pill
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: statusBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          statusStr.toUpperCase(),
                          style: AppTypography.caption.copyWith(
                            color: statusCol,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Row 2: Task Title
                  Text(
                    titleStr,
                    style: AppTypography.title.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),

                  const SizedBox(height: 8),

                  // Row 3: Guest & Timestamp Meta
                  Row(
                    children: [
                      if (guestName.isNotEmpty && guestName != 'Unknown Guest') ...[
                        const Icon(Icons.person_outline,
                            color: AppColors.textSecondary, size: 14),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            guestName,
                            style: AppTypography.bodySecondary.copyWith(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      const Icon(Icons.access_time,
                          color: AppColors.textSecondary, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        timeStr,
                        style: AppTypography.bodySecondary.copyWith(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  // Row 4: Assigned Staff Meta
                  Row(
                    children: [
                      const Icon(Icons.badge_outlined,
                          color: AppColors.textSecondary, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        'Assigned: $assignedTo',
                        style: AppTypography.bodySecondary.copyWith(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),

                  // Row 5: Quick Action Buttons — ONLY shown when NOT assigned to anyone
                  if (!isAlreadyAssigned &&
                      (statusStr.toLowerCase() == 'open' ||
                       statusStr.toLowerCase() == 'pending')) ...[
                    const SizedBox(height: 14),
                    const Divider(height: 1, color: AppColors.borderLight),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        // Quick Accept Button
                        if (onAccept != null)
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: isAccepting ? null : onAccept,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 13),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 0,
                              ),
                              icon: isAccepting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.check_circle_rounded,
                                      size: 18, color: Colors.white),
                              label: Text(
                                isAccepting ? 'Accepting...' : 'Accept Request',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),

                        if (onAccept != null && onReassign != null)
                          const SizedBox(width: 10),

                        // Quick Reassign Button (Supervisor+)
                        if (onReassign != null && isSupervisor)
                          OutlinedButton.icon(
                            onPressed: onReassign,
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 13, horizontal: 16),
                              side: const BorderSide(
                                  color: AppColors.border),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(Icons.swap_horiz_rounded,
                                size: 18, color: AppColors.primary),
                            label: Text(
                              'Reassign',
                              style: AppTypography.bodySecondary.copyWith(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
