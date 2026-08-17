// lib/widgets/direct_request_card.dart
//
// Type A — plain text / chat-style service request card.
// Shown when ServiceRequest.isCatalogOrder == false.

import 'package:flutter/material.dart';
import '../models/service_request.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../theme/app_spacing.dart';
import '../utils/date_formatter.dart';

class DirectRequestCard extends StatelessWidget {
  final ServiceRequest request;
  final VoidCallback onTap;
  final VoidCallback? onAccept;

  const DirectRequestCard({
    super.key,
    required this.request,
    required this.onTap,
    this.onAccept,
  });


  Color _statusBg(String s) {
    switch (s.toLowerCase()) {
      case 'open':
      case 'pending':    return AppColors.infoLight;
      case 'in progress': return AppColors.orangeLight;
      case 'closed':     return AppColors.successLight;
      default:           return AppColors.surfaceAlt;
    }
  }

  Color _statusFg(String s) {
    switch (s.toLowerCase()) {
      case 'open':
      case 'pending':    return AppColors.info;
      case 'in progress': return AppColors.orange;
      case 'closed':     return AppColors.success;
      default:           return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool showAccept = onAccept != null && !request.isClosed;

    // Parse: "Order #SRV20260814140331419 - Ayurvedic Massage x1"
    final rawTitle = request.displayTitle;
    final regExp = RegExp(
      r'^Order\s+(#[A-Za-z0-9]+)\s*-\s*(.*?)(?:\s+x\s*(\d+))?$',
      caseSensitive: false,
    );
    final match = regExp.firstMatch(rawTitle.trim());

    String displayService = rawTitle;
    String? parsedOrderId;
    int? quantity;

    if (match != null) {
      parsedOrderId = match.group(1);
      displayService = match.group(2) ?? rawTitle;
      final qtyStr = match.group(3);
      if (qtyStr != null) {
        quantity = int.tryParse(qtyStr);
      }
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
              color: AppColors.shadow,
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header (Room, Ticket ID, Status badge) ─────────────────────
            _Header(
              request: request,
              statusBg: _statusBg(request.status),
              statusFg: _statusFg(request.status),
            ),

            // ── Escalation Banner ──────────────────────────────────────────
            if (request.isEscalated) _EscalationBanner(request: request),

            // ── Body ───────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          displayService,
                          style: AppTypography.title.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                            fontSize: 18,
                          ),
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
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),

                  // Extracted order ID styled as monospace secondary
                  if (parsedOrderId != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Order $parsedOrderId',
                      style: AppTypography.caption.copyWith(
                        color: AppColors.textSecondary,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ],

                  if (request.answer.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.chat_bubble_outline,
                            size: 14, color: AppColors.textSecondary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            request.answer,
                            style: AppTypography.bodySecondary.copyWith(
                              color: AppColors.textSecondary,
                              fontStyle: FontStyle.italic,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: AppSpacing.md),
                  const Divider(height: 1, color: AppColors.borderLight),
                  const SizedBox(height: AppSpacing.sm),

                  // Guest Row & Time
                  Row(
                    children: [
                      const Icon(Icons.person_outline,
                          size: 16, color: AppColors.textSecondary),
                      const SizedBox(width: 6),
                      Text(
                        request.guestName ?? 'Guest',
                        style: AppTypography.bodySecondary.copyWith(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.access_time,
                          size: 14, color: AppColors.textDisabled),
                      const SizedBox(width: 4),
                      Text(
                        DateFormatter.formatDateTimeObjectAmPm(request.createdAt),
                        style: AppTypography.caption.copyWith(
                          color: AppColors.textDisabled,
                        ),
                      ),
                    ],
                  ),

                  // Assignment status row
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.assignment_ind_outlined,
                          size: 16, color: AppColors.textSecondary),
                      const SizedBox(width: 6),
                      Text(
                        request.assignedToName != null && request.assignedToName!.isNotEmpty
                            ? 'Assigned: ${request.assignedToName}'
                            : 'Assigned: -',
                        style: AppTypography.bodySecondary.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ── Accept Button Footer ──────────────────────────────────────────
            if (showAccept) ...[
              Padding(
                padding: const EdgeInsets.only(
                    left: AppSpacing.md, right: AppSpacing.md, bottom: AppSpacing.md),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: onAccept,
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text('Accept Request'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: AppTypography.buttonLabel.copyWith(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Internal subwidgets ────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final ServiceRequest request;
  final Color statusBg;
  final Color statusFg;

  const _Header({
    required this.request,
    required this.statusBg,
    required this.statusFg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: const BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: Row(
        children: [
          // Room pill (with door icon)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.meeting_room_outlined,
                    size: 14, color: AppColors.primary),
                const SizedBox(width: 4),
                Text(
                  'ROOM ${request.roomNumber.toUpperCase()}',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          
          // Ticket / request ID chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '#${request.serviceRequestId}',
              style: AppTypography.caption.copyWith(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          
          const Spacer(),

          // Status Badge at top right
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: statusBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              request.status.toUpperCase(),
              style: AppTypography.caption.copyWith(
                color: statusFg,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EscalationBanner extends StatelessWidget {
  final ServiceRequest request;
  const _EscalationBanner({required this.request});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: 6),
      color: AppColors.errorLight,
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 14, color: AppColors.error),
          const SizedBox(width: 6),
          Text(
            'Escalated${request.currentStageName != null ? ': ${request.currentStageName}' : ''}',
            style: AppTypography.caption.copyWith(
              color: AppColors.error,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
