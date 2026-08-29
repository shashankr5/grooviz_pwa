// lib/components/home/delivery_command_card.dart
//
// The Delivery Command Card is a first-class module shown on the Home page
// exclusively for Room Service department users. It surfaces live delivery
// counts (Ready / Accepted / Delivered) and previews the oldest pending
// Ready order so staff can act without navigating first.
//
// Design contract:
//  • Urgency state  (readyCount > 0): orange left-accent, warm tinted bg,
//    pulsing status dot, preview row showing oldest Ready order.
//  • Calm state     (readyCount = 0): white card, neutral border, no pulse,
//    no preview row — card stays visible (not hidden) because Room Service
//    staff need the nav entry point even when nothing is pending.
//  • Loading state: skeleton shimmer matching the rest of the app's style.
//  • All state transitions animate via AnimatedContainer / AnimatedSwitcher.
//  • Tapping a mini-tile or the card body calls onNavigate(initialFilter).

import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../skeleton_loader.dart';

// ─────────────────────────────────────────────────────────────────────────────

class DeliveryCommandCard extends StatefulWidget {
  final int  readyCount;
  final int  acceptedCount;
  final int  deliveredCount;

  /// Oldest Ready grouped order map (may be null if none or still loading).
  /// Must already be grouped — not a raw item row.
  final Map<String, dynamic>? oldestReadyOrder;

  /// True while [_loadDeliveryCounts] is in flight (first load / refresh).
  final bool isLoading;

  /// Called with the tab key ('Ready' | 'Accepted' | 'Delivered') when user
  /// taps a mini-tile or the "View All" button.
  final void Function(String initialFilter) onNavigate;

  const DeliveryCommandCard({
    super.key,
    required this.readyCount,
    required this.acceptedCount,
    required this.deliveredCount,
    required this.onNavigate,
    this.oldestReadyOrder,
    this.isLoading = false,
  });

  @override
  State<DeliveryCommandCard> createState() => _DeliveryCommandCardState();
}

class _DeliveryCommandCardState extends State<DeliveryCommandCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double>   _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    // Subtle — stays between 0.35 and 1.0 with an easeInOut curve.
    _pulseAnimation = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  // ── Urgency helpers ───────────────────────────────────────────────────────

  bool get _hasReady => widget.readyCount > 0;

  Color get _cardBg =>
      _hasReady ? AppColors.orange.withOpacity(0.05) : Colors.white;

  // ── Elapsed helper ────────────────────────────────────────────────────────

  /// Returns a compact elapsed string using minutes, then hours, then days.
  /// Returns null if [dt] is null so callers can skip rendering.
  String? _elapsed(DateTime? dt) {
    if (dt == null) return null;
    final diff = DateTime.now().difference(dt);
    if (diff.isNegative) return null;
    if (diff.inMinutes < 1)  return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    final days = diff.inDays;
    if (days < 7) return '${days}d ago';
    return '${days ~/ 7}w ago';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading) return _buildSkeleton();
    return _buildCard();
  }

  // ── Skeleton ──────────────────────────────────────────────────────────────

  Widget _buildSkeleton() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row skeleton
          Row(
            children: [
              const SkeletonLoader(
                  width: 28,
                  height: 28,
                  borderRadius: BorderRadius.all(Radius.circular(8))),
              const SizedBox(width: 10),
              SkeletonLoader(
                  width: 120,
                  height: 14,
                  borderRadius: BorderRadius.circular(4)),
              const Spacer(),
              SkeletonLoader(
                  width: 64,
                  height: 28,
                  borderRadius: BorderRadius.circular(8)),
            ],
          ),
          const SizedBox(height: 14),
          // Three mini-tile skeletons
          Row(
            children: List.generate(3, (i) {
              final hasGap = i < 2;
              return Expanded(
                child: Padding(
                  padding:
                      EdgeInsets.only(right: hasGap ? 8 : 0),
                  child: SkeletonLoader(
                      height: 62,
                      borderRadius: BorderRadius.circular(12)),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  // ── Live card ─────────────────────────────────────────────────────────────

  Widget _buildCard() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        // Uniform border — Flutter cannot combine BorderRadius with
        // non-uniform border widths (different sides cause silent render failure).
        // The left accent is implemented as an overlay inside the Stack below.
        border: Border.all(
          color: _hasReady
              ? AppColors.orange.withOpacity(0.25)
              : AppColors.border,
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: _hasReady
                ? AppColors.orange.withOpacity(0.10)
                : Colors.black.withOpacity(0.04),
            blurRadius: _hasReady ? 14 : 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        children: [
          // Card content
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeaderRow(),
                const SizedBox(height: 12),
                _buildMiniTileRow(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Header row ────────────────────────────────────────────────────────────

  Widget _buildHeaderRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Icon with urgency tint
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: _hasReady
                ? AppColors.orange.withOpacity(0.12)
                : AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.delivery_dining_rounded,
            size: 18,
            color: _hasReady ? AppColors.orange : AppColors.textSecondary,
          ),
        ),
        const SizedBox(width: 10),

        // Title + subtitle
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                style: AppTypography.title.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _hasReady
                      ? AppColors.orange
                      : AppColors.textPrimary,
                ),
                child: const Text('Delivery Queue'),
              ),
              const SizedBox(height: 1),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  _hasReady
                      ? '${widget.readyCount} order${widget.readyCount == 1 ? '' : 's'} awaiting pick-up'
                      : 'Room Service · All clear',
                  key: ValueKey(_hasReady),
                  style: AppTypography.caption.copyWith(
                    fontSize: 11,
                    color: _hasReady
                        ? AppColors.orange.withOpacity(0.8)
                        : AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Pulsing dot (urgency only) + View All button
        if (_hasReady) ...[
          FadeTransition(
            opacity: _pulseAnimation,
            child: Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 10),
              decoration: const BoxDecoration(
                color: AppColors.orange,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
        _buildViewAllButton(),
      ],
    );
  }

  Widget _buildViewAllButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => widget.onNavigate('Ready'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: _hasReady
                ? AppColors.orange.withOpacity(0.10)
                : AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'View All',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _hasReady ? AppColors.orange : AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: _hasReady ? AppColors.orange : AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Mini tile row ─────────────────────────────────────────────────────────

  Widget _buildMiniTileRow() {
    final tiles = [
      _MiniTileData(
        label:  'Ready',
        count:  widget.readyCount,
        color:  AppColors.orange,
        icon:   Icons.room_service_rounded,
        filter: 'Ready',
      ),
      _MiniTileData(
        label:  'Accepted',
        count:  widget.acceptedCount,
        color:  AppColors.info,
        icon:   Icons.delivery_dining_rounded,
        filter: 'Accepted',
      ),
      _MiniTileData(
        label:  'Delivered',
        count:  widget.deliveredCount,
        color:  AppColors.success,
        icon:   Icons.check_circle_rounded,
        filter: 'Delivered',
      ),
    ];

    return Row(
      children: tiles.asMap().entries.map((entry) {
        final i    = entry.key;
        final tile = entry.value;
        final isActive = tile.label == 'Ready' && _hasReady;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < tiles.length - 1 ? 8 : 0),
            child: _buildMiniTile(tile, isActive: isActive),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildMiniTile(_MiniTileData tile, {required bool isActive}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => widget.onNavigate(tile.filter),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: isActive ? tile.color : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive
                  ? tile.color
                  : AppColors.border.withOpacity(0.6),
              width: isActive ? 1.5 : 1.0,
            ),
            boxShadow: [
              if (isActive)
                BoxShadow(
                    color: tile.color.withOpacity(0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 3))
              else
                BoxShadow(
                    color: Colors.black.withOpacity(0.03),
                    blurRadius: 4,
                    offset: const Offset(0, 1)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                tile.icon,
                size: 16,
                color: isActive ? Colors.white : tile.color,
              ),
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: isActive ? Colors.white : AppColors.textPrimary,
                  height: 1.1,
                ),
                child: Text('${tile.count}'),
              ),
              const SizedBox(height: 2),
              Text(
                tile.label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: isActive
                      ? Colors.white.withOpacity(0.85)
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Preview row ───────────────────────────────────────────────────────────

  Widget _buildPreviewRow({Key? key}) {
    final order    = widget.oldestReadyOrder!;
    final roomNo   = (order['roomNumber'] ?? '—').toString();
    final items    = order['items'] as List? ?? [];
    final dt       = order['_orderTimeDt'] as DateTime?;
    final elapsed  = _elapsed(dt);

    // Build item summary: "Pasta, Soup +2 more"
    String itemSummary = '—';
    if (items.isNotEmpty) {
      final firstName = (items.first['name'] ?? '').toString().trim();
      if (items.length == 1) {
        itemSummary = firstName;
      } else {
        itemSummary = '$firstName +${items.length - 1} more';
      }
    }

    return Padding(
      key: key,
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.orange.withOpacity(0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.orange.withOpacity(0.20)),
        ),
        child: Row(
          children: [
            const Icon(Icons.schedule_rounded,
                size: 13, color: AppColors.orange),
            const SizedBox(width: 7),
            // Room badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.orange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Rm $roomNo',
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: AppColors.orange),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            // Item names
            Expanded(
              child: Text(
                itemSummary,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Elapsed time
            if (elapsed != null) ...[
              const SizedBox(width: 6),
              Text(
                elapsed,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.orange.withOpacity(0.8)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Internal data model ───────────────────────────────────────────────────────

class _MiniTileData {
  final String  label;
  final int     count;
  final Color   color;
  final IconData icon;
  final String  filter;

  const _MiniTileData({
    required this.label,
    required this.count,
    required this.color,
    required this.icon,
    required this.filter,
  });
}
