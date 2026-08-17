// components/home/timeline_task_card.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

class TimelineTaskCard extends StatefulWidget {
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
    final String nextEscRaw = (task['next_escalation_at'] ??
            task['raw']?['next_escalation_at'] ??
            '')
        .toString();
    final DateTime? nextEscAt = _parseTimestamp(nextEscRaw);

    final bool isInProgress = statusStr.toLowerCase() == 'in progress';
    int? remainingSecs;
    if (isInProgress && nextEscAt != null) {
      remainingSecs = nextEscAt.difference(DateTime.now()).inSeconds;
    }

    final bool isWarningMin =
        remainingSecs != null && remainingSecs > 0 && remainingSecs <= 60;
    final bool isResolutionOverdue =
        remainingSecs != null && remainingSecs <= 0;

    if (isWarningMin) {
      if (!_blinkController.isAnimating) {
        _blinkController.repeat(reverse: true);
      }
    } else {
      if (_blinkController.isAnimating) {
        _blinkController.stop();
        _blinkController.value = 1.0;
      }
    }

    final Color statusCol = AppColors.statusColor(statusStr);
    final Color statusBg = AppColors.statusLightColor(statusStr);

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isEscalated || isResolutionOverdue
                ? AppColors.error
                : AppColors.border.withValues(alpha: 0.6),
            width: isEscalated || isResolutionOverdue ? 1.5 : 1.0,
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
                padding:
                    const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
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
                          if (isInProgress && remainingSecs != null) ...[
                            AnimatedBuilder(
                              animation: _blinkAnimation,
                              builder: (ctx, child) {
                                final opacity = isWarningMin
                                    ? _blinkAnimation.value
                                    : 1.0;
                                final color = isResolutionOverdue
                                    ? AppColors.error
                                    : (isWarningMin
                                        ? Colors.orange.shade800
                                        : AppColors.primary);
                                final bgColor = isResolutionOverdue
                                    ? AppColors.errorLight
                                    : (isWarningMin
                                        ? Colors.orange.shade50
                                        : AppColors.primaryLight);

                                final absSecs = remainingSecs!.abs();
                                final mins = (absSecs / 60).floor();
                                final secs = (absSecs % 60);
                                final timeFormatted =
                                    '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';

                                final label = isResolutionOverdue
                                    ? '+$timeFormatted'
                                    : timeFormatted;

                                return Opacity(
                                  opacity: opacity,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 7, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: bgColor,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                          color: color.withValues(alpha: 0.3),
                                          width: 1.0),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          isResolutionOverdue
                                              ? Icons.error_outline_rounded
                                              : (isWarningMin
                                                  ? Icons.bolt_rounded
                                                  : Icons.timer_outlined),
                                          size: 12,
                                          color: color,
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          label,
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                            color: color,
                                            letterSpacing: 0.2,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(width: 6),
                          ],
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

