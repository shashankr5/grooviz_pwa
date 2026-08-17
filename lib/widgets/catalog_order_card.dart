// lib/widgets/catalog_order_card.dart
//
// Type B — invoice / booking-style service order card.
// Shown when ServiceRequest.isCatalogOrder == true.

import 'package:flutter/material.dart';
import '../models/service_request.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../theme/app_spacing.dart';

class CatalogOrderCard extends StatelessWidget {
  final ServiceRequest request;
  final VoidCallback onTap;
  final VoidCallback? onAccept;

  const CatalogOrderCard({
    super.key,
    required this.request,
    required this.onTap,
    this.onAccept,
  });

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String _formatPrice(double? v) {
    if (v == null) return '';
    return '₹${v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 2)}';
  }

  @override
  Widget build(BuildContext context) {
    final bool showAccept = onAccept != null && !request.isClosed;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
              color: AppColors.shadow,
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ───────────────────────────────────────────────────
            _CatalogHeader(
              request: request,
              timeAgo: _timeAgo(request.createdAt),
              formatPrice: _formatPrice,
            ),

            // ── Escalation Banner ─────────────────────────────────────────
            if (request.isEscalated)
              _EscalationBanner(stageName: request.currentStageName),

            // ── Order Items ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...request.orderItems.map((item) =>
                      _OrderItemRow(item: item, formatPrice: _formatPrice)),

                  // ── Booking & Special Request Info Box ───────────────
                  if (request.hasBooking || request.hasSpecialRequest) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _InfoBox(request: request),
                  ],

                  // ── Guest info ────────────────────────────────────────
                  if (request.guestName != null &&
                      request.guestName!.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        Icon(Icons.person_outline,
                            size: 14, color: AppColors.textSecondary),
                        const SizedBox(width: 4),
                        Text(
                          request.guestName!,
                          style: AppTypography.bodySecondary.copyWith(
                              color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // ── Footer Action ─────────────────────────────────────────────
            if (showAccept) ...[
              const Divider(height: 1, color: AppColors.borderLight),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onTap,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          side: const BorderSide(color: AppColors.border),
                          padding:
                              const EdgeInsets.symmetric(vertical: 11),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Text('View Details',
                            style: AppTypography.buttonLabel
                                .copyWith(fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: onAccept,
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('Accept Order'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          padding:
                              const EdgeInsets.symmetric(vertical: 11),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          textStyle: AppTypography.buttonLabel
                              .copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Subwidgets ────────────────────────────────────────────────────────────────

class _CatalogHeader extends StatelessWidget {
  final ServiceRequest request;
  final String timeAgo;
  final String Function(double?) formatPrice;

  const _CatalogHeader({
    required this.request,
    required this.timeAgo,
    required this.formatPrice,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: const BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
        ),
      ),
      child: Row(
        children: [
          // Room pill
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'Room ${request.roomNumber}',
              style: AppTypography.caption.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Order number chip
          if (request.orderNumber != null &&
              request.orderNumber!.isNotEmpty)
            Expanded(
              child: Text(
                '#${request.orderNumber!.length > 16 ? request.orderNumber!.substring(request.orderNumber!.length - 10) : request.orderNumber}',
                style: AppTypography.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontFamily: 'monospace',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const Spacer(),
          // Price badge
          if (request.grandTotal != null && request.grandTotal! > 0)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.successLight,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                formatPrice(request.grandTotal),
                style: AppTypography.caption.copyWith(
                  color: AppColors.success,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          const SizedBox(width: 6),
          Icon(Icons.access_time,
              size: 13, color: AppColors.textDisabled),
          const SizedBox(width: 2),
          Text(timeAgo,
              style: AppTypography.caption
                  .copyWith(color: AppColors.textDisabled)),
        ],
      ),
    );
  }
}

class _OrderItemRow extends StatelessWidget {
  final ServiceOrderItem item;
  final String Function(double?) formatPrice;

  const _OrderItemRow({required this.item, required this.formatPrice});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Item name + quantity
          Row(
            children: [
              const Icon(Icons.inventory_2_outlined,
                  size: 14, color: AppColors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${item.quantity}× ${item.serviceName}',
                  style: AppTypography.bodyPrimary.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          // Option + price sub-line
          if (item.optionName != null && item.optionName!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 3),
              child: Text(
                '${item.optionName}${item.optionPrice != null && item.optionPrice! > 0 ? '  •  ${formatPrice(item.optionPrice)}' : ''}',
                style: AppTypography.bodySecondary
                    .copyWith(color: AppColors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  final ServiceRequest request;
  const _InfoBox({required this.request});

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = [];

    if (request.hasBooking) {
      final item = request.orderItems.firstWhere(
        (i) => i.bookingDate != null && i.bookingDate!.isNotEmpty,
      );
      rows.add(Row(
        children: [
          const Icon(Icons.calendar_today,
              size: 13, color: AppColors.info),
          const SizedBox(width: 6),
          Text(
            '${item.bookingDate ?? ''}${item.bookingTime != null ? '  @  ${item.bookingTime}' : ''}',
            style: AppTypography.bodySecondary
                .copyWith(color: AppColors.info, fontWeight: FontWeight.w600),
          ),
        ],
      ));
    }

    if (request.hasSpecialRequest) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 6));
      final item = request.orderItems.firstWhere(
        (i) => i.specialRequest != null && i.specialRequest!.isNotEmpty,
      );
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.notes, size: 13, color: AppColors.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              item.specialRequest!,
              style: AppTypography.bodySecondary
                  .copyWith(color: AppColors.warning),
            ),
          ),
        ],
      ));
    }

    final Color borderColor =
        request.hasBooking ? AppColors.info : AppColors.warning;
    final Color bgColor =
        request.hasBooking ? AppColors.infoLight : AppColors.warningLight;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: borderColor, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }
}

class _EscalationBanner extends StatelessWidget {
  final String? stageName;
  const _EscalationBanner({this.stageName});

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
            'Escalated${stageName != null ? ': $stageName' : ''}',
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
