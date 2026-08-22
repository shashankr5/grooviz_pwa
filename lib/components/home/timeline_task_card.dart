// components/home/timeline_task_card.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../utils/escalation_helpers.dart';

class TimelineTaskCard extends StatefulWidget {
  final Map<String, dynamic> task;
  final bool isSupervisor;
  /// Pass the current user's role string so escalation messaging is role-aware.
  final String userRole;
  final VoidCallback onTap;
  final VoidCallback? onAccept;
  final VoidCallback? onReassign;
  final bool isAccepting;

  const TimelineTaskCard({
    super.key,
    required this.task,
    required this.isSupervisor,
    this.userRole = '',
    required this.onTap,
    this.onAccept,
    this.onReassign,
    this.isAccepting = false,
  });

  @override
  State<TimelineTaskCard> createState() => _TimelineTaskCardState();
}

class _TimelineTaskCardState extends State<TimelineTaskCard>
    with SingleTickerProviderStateMixin {
  Timer? _tickerTimer;
  late AnimationController _blinkController;
  late Animation<double> _blinkAnimation;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _blinkAnimation =
        Tween<double>(begin: 0.2, end: 1.0).animate(_blinkController);

    _startTickerIfNeeded();
  }

  void _startTickerIfNeeded() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    _blinkController.dispose();
    super.dispose();
  }

  DateTime? _parseTimestamp(dynamic val) {
    if (val == null) return null;
    try {
      if (val is DateTime) return val;
      final str = val.toString().trim();
      if (str.isEmpty || str == 'null') return null;
      return DateTime.tryParse(str.replaceAll(' ', 'T'));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final String roomStr = (task['room'] ?? '-').toString();
    final String titleStr = (task['title'] ?? 'Service Request').toString();
    final String guestName = (task['guest'] ?? 'Guest').toString();
    final String statusStr = (task['status'] ?? 'Open').toString();
    final String timeStr = (task['time'] ?? '').toString();

    final String assignedTo = (task['assignedTo'] ??
            task['assigned_to_name'] ??
            task['raw']?['assigned_to_name'] ??
            '-')
        .toString();

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

    final bool isEscalated =
        task['is_escalated'] == 1 || task['isEscalated'] == true;

    final String requestId = (task['service_request_id'] ??
            task['task_id'] ??
            task['id'] ??
            task['raw']?['service_request_id'] ??
            '')
        .toString();

    // ── Resolution SLA Timer Logic ─────────────────────────────────────────
    final Color statusCol = AppColors.statusColor(statusStr);
    final Color statusBg = AppColors.statusLightColor(statusStr);

    // Escalation presentation is disabled. Keep only the normal card styling;
    // an independent resolution-SLA timer may still render where applicable.

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(color: AppColors.shadow, blurRadius: 10, offset: Offset(0, 4)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                                    color: AppColors.border
                                        .withValues(alpha: 0.6)),
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

                      // Status Pill & Live Resolution Timer
                      Row(
                        children: [
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
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Parse "Order #SRV20260814140331419 - Ayurvedic Massage x1"
                  () {
                    final regExp = RegExp(
                      r'^Order\s+(#[A-Za-z0-9]+)\s*-\s*(.*?)(?:\s+x\s*(\d+))?$',
                      caseSensitive: false,
                    );
                    final match = regExp.firstMatch(titleStr.trim());

                    String displayTitle = titleStr;
                    String? parsedOrderId;
                    int? quantity;

                    if (match != null) {
                      parsedOrderId = match.group(1);
                      displayTitle = match.group(2) ?? titleStr;
                      final qtyStr = match.group(3);
                      if (qtyStr != null) {
                        quantity = int.tryParse(qtyStr);
                      }
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                displayTitle,
                                style: AppTypography.title.copyWith(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (quantity != null) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryLight,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'Qty: $quantity',
                                  style: AppTypography.caption.copyWith(
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (parsedOrderId != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Order $parsedOrderId',
                            style: AppTypography.caption.copyWith(
                              color: AppColors.textSecondary,
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    );
                  }(),

                  const SizedBox(height: 8),

                  // Row 3: Guest & Timestamp Meta
                  Row(
                    children: [
                      if (guestName.isNotEmpty &&
                          guestName != 'Unknown Guest') ...[
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
                  if (isAlreadyAssigned)
                    Row(
                      children: [
                        const Icon(Icons.badge_outlined,
                            color: AppColors.textSecondary, size: 14),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            'Assigned: $assignedTo',
                            style: AppTypography.bodySecondary.copyWith(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),

                  // SLA Countdown — visible only on in-progress tasks
                  () {
                    if (statusStr.toLowerCase() != 'in progress') {
                      return const SizedBox.shrink();
                    }
                    final rawMap = task['raw'] as Map? ?? {};
                    final acceptedAtStr = (task['accepted_at'] ??
                            rawMap['accepted_at'] ??
                            '')
                        .toString();
                    final escalationMinsVal =
                        rawMap['escalation_time_minutes'] ??
                            task['escalation_time_minutes'];
                    final escalationMins = escalationMinsVal != null
                        ? int.tryParse(escalationMinsVal.toString())
                        : null;
                    if (escalationMins == null || escalationMins <= 0) {
                      return const SizedBox.shrink();
                    }
                    DateTime? acceptedAt;
                    if (acceptedAtStr.isNotEmpty &&
                        acceptedAtStr != 'null') {
                      acceptedAt = DateTime.tryParse(
                              acceptedAtStr.replaceAll(' ', 'T'))
                          ?.toLocal();
                    }
                    if (acceptedAt == null) return const SizedBox.shrink();

                    final deadline =
                        acceptedAt.add(Duration(minutes: escalationMins));
                    final remaining = deadline.difference(DateTime.now());
                    final isOverdue = remaining.isNegative;
                    final remSecs = remaining.abs().inSeconds;
                    final totalSecs = escalationMins * 60;
                    final pct = isOverdue
                        ? 0.0
                        : (remSecs / totalSecs).clamp(0.0, 1.0);
                    final Color slaColor = isOverdue || pct < 0.10
                        ? AppColors.error
                        : pct < 0.30
                            ? AppColors.warning
                            : AppColors.success;
                    final mm = (remSecs ~/ 60).toString().padLeft(2, '0');
                    final ss = (remSecs % 60).toString().padLeft(2, '0');
                    final label = isOverdue
                        ? '+$mm:$ss overdue'
                        : '$mm:$ss remaining';

                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: slaColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: slaColor.withValues(alpha: 0.25)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isOverdue
                                  ? Icons.timer_off_outlined
                                  : Icons.timer_outlined,
                              size: 12,
                              color: slaColor,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'SLA  $label',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: slaColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }(),

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
                        if (widget.onAccept != null)
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed:
                                  widget.isAccepting ? null : widget.onAccept,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 13),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 0,
                              ),
                              icon: widget.isAccepting
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
                                widget.isAccepting
                                    ? 'Accepting...'
                                    : 'Accept Request',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),

                        if (widget.onAccept != null && widget.onReassign != null)
                          const SizedBox(width: 10),

                        // Quick Reassign Button (Supervisor+)
                        if (widget.onReassign != null && widget.isSupervisor)
                          OutlinedButton.icon(
                            onPressed: widget.onReassign,
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 13, horizontal: 16),
                              side:
                                  const BorderSide(color: AppColors.border),
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
