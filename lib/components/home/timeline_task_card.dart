// components/home/timeline_task_card.dart
import 'dart:async';
import 'dart:convert';
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
      if (val is DateTime) return val.toLocal();
      final str = val.toString().trim();
      if (str.isEmpty || str == 'null') return null;
      final raw = DateTime.tryParse(str.replaceAll(' ', 'T'));
      if (raw == null) return null;
      // MySQL returns timestamps without timezone — treat as UTC → local.
      if (!str.contains('Z') && !str.contains('z') && !str.contains('+')) {
        return DateTime.utc(raw.year, raw.month, raw.day, raw.hour, raw.minute, raw.second).toLocal();
      }
      return raw.toLocal();
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

    // ── Escalation styling ─────────────────────────────────────────────────
    // is_escalated == 1 is set by check_and_escalate_unified and surfaced by
    // get_all_services_mobile1. Use it as the sole source of truth for the
    // red-border + accent-strip visual treatment on the card.
    final role        = escalationRoleFromName(widget.userRole);
    final accentStyle = EscalationVisibility.accentStyle(role);
    final esc         = EscalationInfo.fromTask(task);

    // Determine if this is an ACTIVE escalated task (not closed)
    final bool isActiveEscalated = isEscalated && 
        statusStr.toLowerCase() != 'closed';

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: isActiveEscalated
              ? EscalationDisplay.escalatedBorder()
              : Border.all(color: AppColors.border.withValues(alpha: 0.6)),
          boxShadow: [BoxShadow(color: AppColors.shadow, blurRadius: 10, offset: Offset(0, 4))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Escalation accent strip (only active escalated tasks) ─────
            if (isActiveEscalated) _buildEscalationStrip(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Row 1: Room Pill, Request ID & Status Badge
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                        mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 5),
                              decoration: BoxDecoration(
                                color: AppColors.primaryLight,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.meeting_room_outlined,
                                      color: AppColors.primary, size: 14),
                                  const SizedBox(width: 4),
                                  Text(
                                    'ROOM $roomStr',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTypography.title.copyWith(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (requestId.isNotEmpty && requestId != '0') ...[
                              const SizedBox(width: 6),
                              Flexible(
                                child: Container(
                                  constraints:
                                      const BoxConstraints(maxWidth: 90),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppColors.bg,
                                    borderRadius: BorderRadius.circular(7),
                                    border: Border.all(
                                        color: AppColors.border
                                            .withValues(alpha: 0.6)),
                                  ),
                                  child: Text(
                                    '#$requestId',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTypography.caption.copyWith(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),

                      // Status Pill & Live Resolution Timer
                      Row(
                        mainAxisSize: MainAxisSize.min,
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
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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

                  // Title / order-items block
                  // Catalog orders (is_from_order=1) show the parsed item list.
                  // Plain requests keep the existing single-title display.
                  () {
                    final isFromOrder = (task['is_from_order'] ?? 0) != 0;
                    final rawItems = task['order_items'];
                    final items = (rawItems is List) ? rawItems : <dynamic>[];
                    final orderNumber = task['order_number']?.toString();
                    final grandTotal  = task['grand_total'];

                    if (isFromOrder && items.isNotEmpty) {
                      // ── Catalog order: show each item as a chip row ──────
                      final totalStr = grandTotal != null
                          ? '₹${(grandTotal as num).toStringAsFixed(2)}'
                          : null;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Service Order',
                                  style: AppTypography.title.copyWith(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                              if (totalStr != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppColors.successLight,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    totalStr,
                                    style: AppTypography.caption.copyWith(
                                      color: AppColors.success,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (orderNumber != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              '#$orderNumber',
                              style: AppTypography.caption.copyWith(
                                color: AppColors.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          ...items.map((item) {
                            final name   = (item['service_name'] ?? item['food_name'] ?? '').toString();
                            final option = (item['option_name'] ?? '').toString();
                            final qty    = (item['quantity'] as num?)?.toInt() ?? 1;
                            final amt    = (item['total_amount'] as num?)?.toDouble() ?? 0.0;
                            final label  = option.isNotEmpty ? '$name · $option' : name;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                children: [
                                  Container(
                                    width: 20, height: 20,
                                    decoration: BoxDecoration(
                                      color: AppColors.primaryLight,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Center(
                                      child: Text(
                                        '$qty',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.primary,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      label,
                                      style: AppTypography.caption.copyWith(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textPrimary,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (amt > 0)
                                    Text(
                                      '₹${amt.toStringAsFixed(0)}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                ],
                              ),
                            );
                          }),
                        ],
                      );
                    }

                    // ── Plain request: existing regex title display ───────
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
                      displayTitle  = match.group(2) ?? titleStr;
                      final qtyStr  = match.group(3);
                      if (qtyStr != null) quantity = int.tryParse(qtyStr);
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

                  // ── Removed duplicate SLA Countdown ──────────────────
                  // SLA information is already displayed in the escalation banner above
                  // to avoid showing duplicate countdown information

                  // Row 5: Quick Action Buttons — shown for all open/pending incoming tasks
                  if (statusStr.toLowerCase() == 'open' ||
                      statusStr.toLowerCase() == 'pending') ...[
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

  /// Build real SLA countdown based on API data
  Widget _buildRealSlaCountdown(Map<String, dynamic> task) {
    final slaInfo = _calculateRealSla(task);
    if (slaInfo == null) return const SizedBox.shrink();

    final seconds = slaInfo['remainingSeconds'] as int;
    final isOverdue = seconds < 0;
    final displaySeconds = seconds.abs();
    
    final mm = (displaySeconds ~/ 60).toString().padLeft(2, '0');
    final ss = (displaySeconds % 60).toString().padLeft(2, '0');
    
    final text = isOverdue ? '+$mm:$ss' : '$mm:$ss';
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  /// Calculate real SLA based on API response data
  Map<String, dynamic>? _calculateRealSla(Map<String, dynamic> task) {
    final status = (task['status'] ?? 'Open').toString().toLowerCase();
    final createdAt = _parseTimestamp(task['created_at']);
    final acceptedAt = _parseTimestamp(task['accepted_at']);
    final escalationTimeMinutes = (task['escalation_time_minutes'] as num?)?.toInt();
    
    if (createdAt == null) return null;
    
    final now = DateTime.now();
    
    // Parse escalation history to get specific SLA minutes
    final escalationHistory = _parseEscalationHistory(task);
    
    if (status == 'open' || (status == 'pending' && acceptedAt == null)) {
      // ── ACCEPTANCE SLA: Time to accept the task ──
      
      // Try to get acceptance_time_minutes from escalation history first
      int? acceptanceSlaMinutes;
      for (final escalation in escalationHistory) {
        final acceptanceMinutes = escalation['acceptance_time_minutes'] as int?;
        if (acceptanceMinutes != null) {
          acceptanceSlaMinutes = acceptanceMinutes;
          break;
        }
      }
      
      // Fallback to escalation_time_minutes if no specific acceptance SLA
      acceptanceSlaMinutes ??= escalationTimeMinutes;
      
      if (acceptanceSlaMinutes == null || acceptanceSlaMinutes <= 0) return null;
      
      final acceptanceDue = createdAt.add(Duration(minutes: acceptanceSlaMinutes));
      final remainingSeconds = acceptanceDue.difference(now).inSeconds;
      
      return {
        'type': 'acceptance',
        'remainingSeconds': remainingSeconds,
        'slaMinutes': acceptanceSlaMinutes,
      };
      
    } else if (status == 'in progress' && acceptedAt != null) {
      // ── COMPLETION SLA: Time to complete after acceptance ──
      
      // Try to get completion_time_minutes from escalation history
      int? completionSlaMinutes;
      for (final escalation in escalationHistory) {
        final completionMinutes = escalation['completion_time_minutes'] as int?;
        if (completionMinutes != null) {
          completionSlaMinutes = completionMinutes;
          break;
        }
      }
      
      // Fallback to escalation_time_minutes if no specific completion SLA
      completionSlaMinutes ??= escalationTimeMinutes;
      
      if (completionSlaMinutes == null || completionSlaMinutes <= 0) return null;
      
      final completionDue = acceptedAt.add(Duration(minutes: completionSlaMinutes));
      final remainingSeconds = completionDue.difference(now).inSeconds;
      
      return {
        'type': 'completion',
        'remainingSeconds': remainingSeconds,
        'slaMinutes': completionSlaMinutes,
      };
    }
    
    return null;
  }

  /// Parse escalation history from API response
  List<Map<String, dynamic>> _parseEscalationHistory(Map<String, dynamic> task) {
    final escalationHistoryRaw = task['escalation_history'];
    if (escalationHistoryRaw == null) return [];
    
    try {
      List escalationList = [];
      if (escalationHistoryRaw is String) {
        if (escalationHistoryRaw.trim().isEmpty || escalationHistoryRaw == '[]') return [];
        escalationList = jsonDecode(escalationHistoryRaw) as List;
      } else if (escalationHistoryRaw is List) {
        escalationList = escalationHistoryRaw;
      }
      
      return escalationList.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      print('Error parsing escalation history: $e');
      return [];
    }
  }

  Widget _buildEscalationStrip() {
    final view = EscalationView.fromTask(widget.task);
    if (!view.isEscalated || view.phase == EscalationPhase.closed) {
      return const SizedBox.shrink();
    }

    final tokens = SlaTokens.forSeverity(view.severity);
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 14),
      decoration: BoxDecoration(
        color: tokens.fg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
      ),
      child: Row(children: [
        const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 12),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            view.accentStripTitle,
            style: const TextStyle(
              color: Colors.white, fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (view.hasCountdown) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              view.countdownLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ]),
    );
  }
}