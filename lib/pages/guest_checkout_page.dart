import 'dart:async';
import 'package:flutter/material.dart';
import '../services/checkout_service.dart';

import '../theme/app_typography.dart';
import '../theme/app_colors.dart';
import '../components/app_dialog.dart';
import '../utils/app_snackbar.dart';
import '../utils/date_formatter.dart';
import 'guest_checkout_history_page.dart';

class GuestCheckoutPage extends StatefulWidget {
  const GuestCheckoutPage({super.key});

  @override
  State<GuestCheckoutPage> createState() => _GuestCheckoutPageState();
}

class _GuestCheckoutPageState extends State<GuestCheckoutPage> {
  late Future<List<Map<String, dynamic>>> _futureGuests;
  final Set<int> _expandedIds = {};
  final Map<int, Future<Map<String, dynamic>>> _billFutures = {};

  String _search = '';
  String _statusFilter = 'All'; // All | Overdue | Within 1 hr | Upcoming

  // Ticks every minute so live countdown strings refresh
  Timer? _ticker;
  int _tickCount = 0;

  @override
  void initState() {
    super.initState();
    _futureGuests = _loadGuests();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _tickCount++);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  DateTime? _parseDate(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return DateTime.parse(s);
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _loadGuests() async {
    final res = await CheckoutService().getGuestCheckoutReport();
    if (res['success'] != true) throw Exception(res['message']);
    return List<Map<String, dynamic>>.from(res['guests']);
  }

  /// "04/05/2026 • 2:30 PM"  — matches home_page style
  String _formatDateTime(String? s) {
    return DateFormatter.formatDateTimeAmPm(s);
  }

  /// "2:30 PM"
  String _formatTime(String? s) {
    return DateFormatter.formatTimeOnlyAmPm(s);
  }

  Map<String, dynamic> _statusStyle(String? status) {
    switch ((status ?? '').toLowerCase()) {
      case 'overdue':
        return {
          'color': AppColors.error,
          'bg': AppColors.errorLight,
          'icon': Icons.warning_amber_rounded,
          'chipLabel': 'Overdue',
          'filterKey': 'Overdue',
        };
      case 'checkout within 1 hour':
        return {
          'color': AppColors.warning,
          'bg': AppColors.warningLight,
          'icon': Icons.timer_rounded,
          'chipLabel': '< 1 hr',
          'filterKey': 'Within 1 hr',
        };
      default:
        return {
          'color': AppColors.info,
          'bg': AppColors.infoLight,
          'icon': Icons.schedule_rounded,
          'chipLabel': 'Upcoming',
          'filterKey': 'Upcoming',
        };
    }
  }

  /// Live countdown string derived from minutes_to_checkout,
  /// adjusted by elapsed tick count (1 tick = 1 minute).
  String _countdownLabel(int? rawMinutes) {
    if (rawMinutes == null) return '';
    final adjusted = rawMinutes - _tickCount;
    if (adjusted <= 0) return 'Overdue';
    if (adjusted < 60) return '${adjusted}m left';
    final h = adjusted ~/ 60;
    final m = adjusted % 60;
    return m == 0 ? '${h}h left' : '${h}h ${m}m left';
  }

  Color _countdownColor(int? rawMinutes) {
    if (rawMinutes == null) return AppColors.textDisabled;
    final adjusted = rawMinutes - _tickCount;
    if (adjusted <= 0) return AppColors.error;
    if (adjusted <= 60) return AppColors.warning;
    return AppColors.success;
  }

  void _toggleExpand(Map<String, dynamic> guest) {
    final id = guest['guestId'];
    if (id == null) return;
    final intId = (id as num).toInt();
    setState(() {
      if (_expandedIds.contains(intId)) {
        _expandedIds.remove(intId);
      } else {
        _expandedIds.add(intId);
        _billFutures.putIfAbsent(
          intId,
          () => CheckoutService().getGuestBill(guestId: intId),
        );
      }
    });
  }

  void _onManualCheckout(Map<String, dynamic> guest) async {
    final confirmed = await AppDialog.show(
      context,
      title: 'Confirm Checkout',
      message: 'Check out ${guest['guestName'] ?? 'this guest'} from Room ${guest['roomNumber'] ?? '—'}?',
      confirmLabel: 'Check Out',
      cancelLabel: 'Cancel',
      isDestructive: false,
    );

    if (confirmed == true && mounted) {
      // TODO: wire up your checkout API call here
      AppSnackBar.show(context, '${guest['guestName']} checked out successfully');
      setState(() => _futureGuests = _loadGuests());
    }
  }

  // ── Filter helpers ─────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _applyFilters(List<Map<String, dynamic>> all) {
    // Active (not yet checked out)
    List<Map<String, dynamic>> list = all
        .where((g) => (g['raw']?['status'] ?? '').toString() != 'Checked_out')
        .toList();

    // Status chip filter
    if (_statusFilter != 'All') {
      list = list.where((g) {
        final s = _statusStyle(g['checkoutStatus']);
        return s['filterKey'] == _statusFilter;
      }).toList();
    }

    // Search filter
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list.where((g) {
        return (g['guestName'] ?? '').toLowerCase().contains(q) ||
            (g['roomNumber']?.toString() ?? '').contains(q) ||
            (g['contact'] ?? '').contains(q);
      }).toList();
    }

    return list;
  }

  List<Map<String, dynamic>> _checkedOutToday(List<Map<String, dynamic>> all) =>
      all.where((g) => (g['raw']?['status'] ?? '') == 'Checked_out').toList();

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text('Checkout Today', style: AppTypography.appBarTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.history_rounded, color: AppColors.textPrimary),
            tooltip: 'Checkout History',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const GuestCheckoutHistoryPage()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _futureGuests,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2),
            );
          }

          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off_rounded, size: 48, color: AppColors.textDisabled),
                    const SizedBox(height: 16),
                    Text(
                      snap.error.toString().replaceFirst('Exception: ', ''),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: () => setState(() => _futureGuests = _loadGuests()),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                      ),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final all = snap.data ?? [];
          final allActive = all
              .where((g) => (g['raw']?['status'] ?? '').toString() != 'Checked_out')
              .toList();
          final active     = _applyFilters(all);
          final checkedOut = _checkedOutToday(all);

          // Counts per status for filter chip badges
          int _count(String filterKey) =>
              allActive.where((g) => _statusStyle(g['checkoutStatus'])['filterKey'] == filterKey).length;

          return RefreshIndicator(
            color: AppColors.primary,
            onRefresh: () async => setState(() => _futureGuests = _loadGuests()),
            child: CustomScrollView(
              slivers: [
                // ── Search bar ────────────────────────────────────────────
                SliverToBoxAdapter(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: TextField(
                      onChanged: (v) => setState(() => _search = v),
                      style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'Search by name, room, phone…',
                        hintStyle: const TextStyle(color: AppColors.textDisabled, fontSize: 14),
                        prefixIcon: const Icon(Icons.search_rounded, color: AppColors.textDisabled, size: 20),
                        filled: true,
                        fillColor: const Color(0xFFF5F7FA),
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                ),

                // ── Status filter chips ───────────────────────────────────
                SliverToBoxAdapter(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _FilterChip(
                            label: 'All',
                            count: allActive.length,
                            selected: _statusFilter == 'All',
                            color: AppColors.primary,
                            bg: AppColors.primaryLight,
                            onTap: () => setState(() => _statusFilter = 'All'),
                          ),
                          const SizedBox(width: 8),
                          _FilterChip(
                            label: 'Overdue',
                            count: _count('Overdue'),
                            selected: _statusFilter == 'Overdue',
                            color: AppColors.error,
                            bg: AppColors.errorLight,
                            onTap: () => setState(() => _statusFilter = 'Overdue'),
                          ),
                          const SizedBox(width: 8),
                          _FilterChip(
                            label: '< 1 hr',
                            count: _count('Within 1 hr'),
                            selected: _statusFilter == 'Within 1 hr',
                            color: AppColors.warning,
                            bg: AppColors.warningLight,
                            onTap: () => setState(() => _statusFilter = 'Within 1 hr'),
                          ),
                          const SizedBox(width: 8),
                          _FilterChip(
                            label: 'Upcoming',
                            count: _count('Upcoming'),
                            selected: _statusFilter == 'Upcoming',
                            color: AppColors.info,
                            bg: AppColors.infoLight,
                            onTap: () => setState(() => _statusFilter = 'Upcoming'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // ── Empty state ───────────────────────────────────────────
                if (all.isEmpty)
                  SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.hotel_rounded, size: 52, color: AppColors.textDisabled),
                          const SizedBox(height: 14),
                          Text(
                            'No checkouts today',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Guests checking out today will appear here',
                            style: AppTypography.bodySecondary.copyWith(fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),

                // ── Active guests ─────────────────────────────────────────
                if (active.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                      child: _SectionLabel(
                        label: 'Upcoming · ${active.length}',
                        icon: Icons.schedule_rounded,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) {
                        final g   = active[i];
                        final id  = (g['guestId'] as num?)?.toInt();
                        final min = (g['minutesToCheckout'] as num?)?.toInt();
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                          child: _GuestCard(
                            guest: g,
                            expanded: id != null && _expandedIds.contains(id),
                            billFuture: id != null ? _billFutures[id] : null,
                            onTap: () => _toggleExpand(g),
                            onCheckout: () => _onManualCheckout(g),
                            formatDateTime: _formatDateTime,
                            formatTime: _formatTime,
                            statusStyle: _statusStyle,
                            countdownLabel: _countdownLabel(min),
                            countdownColor: _countdownColor(min),
                          ),
                        );
                      },
                      childCount: active.length,
                    ),
                  ),
                ],

                // ── Checked out today ─────────────────────────────────────
                if (checkedOut.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, active.isNotEmpty ? 14 : 20, 16, 8),
                      child: _SectionLabel(
                        label: 'Checked Out Today · ${checkedOut.length}',
                        icon: Icons.check_circle_outline_rounded,
                        color: AppColors.success,
                      ),
                    ),
                  ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) {
                        final g  = checkedOut[i];
                        final id = (g['guestId'] as num?)?.toInt();
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                          child: _GuestCard(
                            guest: g,
                            expanded: id != null && _expandedIds.contains(id),
                            billFuture: id != null ? _billFutures[id] : null,
                            onTap: () => _toggleExpand(g),
                            onCheckout: null,
                            formatDateTime: _formatDateTime,
                            formatTime: _formatTime,
                            statusStyle: _statusStyle,
                            countdownLabel: '',
                            countdownColor: AppColors.textDisabled,
                            isCheckedOut: true,
                          ),
                        );
                      },
                      childCount: checkedOut.length,
                    ),
                  ),
                ],

                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter Chip
// ─────────────────────────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final Color color;
  final Color bg;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.color,
    required this.bg,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? color : bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? color : color.withOpacity(0.25),
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : color,
              ),
            ),
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: selected ? Colors.white.withOpacity(0.25) : color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section Label
// ─────────────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;

  const _SectionLabel({required this.label, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Guest Card
// ─────────────────────────────────────────────────────────────────────────────

class _GuestCard extends StatelessWidget {
  final Map<String, dynamic> guest;
  final bool expanded;
  final Future<Map<String, dynamic>>? billFuture;
  final VoidCallback onTap;
  final VoidCallback? onCheckout;
  final bool isCheckedOut;
  final String countdownLabel;
  final Color countdownColor;

  final String Function(String?) formatDateTime;
  final String Function(String?) formatTime;
  final Map<String, dynamic> Function(String?) statusStyle;

  const _GuestCard({
    required this.guest,
    required this.expanded,
    required this.billFuture,
    required this.onTap,
    required this.onCheckout,
    required this.formatDateTime,
    required this.formatTime,
    required this.statusStyle,
    required this.countdownLabel,
    required this.countdownColor,
    this.isCheckedOut = false,
  });

  @override
  Widget build(BuildContext context) {
    final style      = statusStyle(guest['checkoutStatus']);
    final statusColor = isCheckedOut ? AppColors.success : (style['color'] as Color);
    final statusBg    = isCheckedOut ? AppColors.successLight : (style['bg'] as Color);
    final statusIcon  = isCheckedOut ? Icons.check_circle_rounded : (style['icon'] as IconData);
    final statusChip  = isCheckedOut ? 'Checked Out' : (style['chipLabel'] as String);

    final name        = (guest['guestName'] ?? 'G').toString().trim();
    final firstLetter = name.isNotEmpty ? name[0].toUpperCase() : 'G';

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: expanded ? AppColors.primary.withOpacity(0.2) : AppColors.borderLight,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(expanded ? 0.07 : 0.04),
              blurRadius: expanded ? 16 : 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: [
            // ── Collapsed Row ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Avatar
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.primaryLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      firstLetter,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Name + room + time + countdown
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.primaryLight,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Rm ${guest['roomNumber'] ?? '—'}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                isCheckedOut
                                    ? 'Out · ${formatTime(guest['checkoutDate'])}'
                                    : 'Checkout · ${formatTime(guest['checkoutDate'])}',
                                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        // Live countdown timer row
                        if (!isCheckedOut && countdownLabel.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(Icons.timer_outlined, size: 11, color: countdownColor),
                              const SizedBox(width: 4),
                              Text(
                                countdownLabel,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: countdownColor,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Status chip + chevron
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                        decoration: BoxDecoration(
                          color: statusBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(statusIcon, size: 11, color: statusColor),
                            const SizedBox(width: 4),
                            Text(
                              statusChip,
                              style: TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.w600, color: statusColor),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      AnimatedRotation(
                        turns: expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: const Icon(Icons.keyboard_arrow_down_rounded,
                            size: 20, color: AppColors.textDisabled),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ── Expanded Details ───────────────────────────────────────
            if (expanded) ...[
              const Divider(height: 1, color: AppColors.borderLight),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailRow(
                      icon: Icons.badge_outlined,
                      label: 'Guest ID',
                      value: '#${guest['guestId'] ?? '—'}',
                    ),
                    _DetailRow(
                      icon: Icons.phone_outlined,
                      label: 'Contact',
                      value: (guest['contact']?.toString().isNotEmpty == true)
                          ? guest['contact']
                          : 'Not provided',
                    ),
                    _DetailRow(
                      icon: Icons.email_outlined,
                      label: 'Email',
                      value: (guest['email']?.toString().isNotEmpty == true)
                          ? guest['email']
                          : 'Not provided',
                    ),
                    _DetailRow(
                      icon: Icons.calendar_today_outlined,
                      label: 'Checkout',
                      value: formatDateTime(guest['checkoutDate']),
                    ),
                    if ((guest['raw']?['device_name'] ?? '').toString().isNotEmpty)
                      _DetailRow(
                        icon: Icons.devices_outlined,
                        label: 'Devices',
                        value: guest['raw']['device_name'].toString(),
                      ),

                    // Food orders — shown immediately on expand
                    OrdersSection(billFuture: billFuture),

                    // Manual checkout button
                    if (!isCheckedOut && onCheckout != null) ...[
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: onCheckout,
                          icon: const Icon(Icons.logout_rounded, size: 16),
                          label: const Text(
                            'Manual Checkout',
                            style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.1),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],

                    if (isCheckedOut) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: AppColors.successLight,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_rounded, size: 16, color: AppColors.success),
                            SizedBox(width: 8),
                            Text(
                              'Guest has been checked out',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.success),
                            ),
                          ],
                        ),
                      ),
                    ],
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

// ─────────────────────────────────────────────────────────────────────────────
// Orders Section — shared between both pages
// ─────────────────────────────────────────────────────────────────────────────

class OrdersSection extends StatelessWidget {
  final Future<Map<String, dynamic>>? billFuture;

  const OrdersSection({super.key, required this.billFuture});

  @override
  Widget build(BuildContext context) {
    if (billFuture == null) return const SizedBox.shrink();

    return FutureBuilder<Map<String, dynamic>>(
      future: billFuture,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
              ),
            ),
          );
        }

        if (snap.hasError || snap.data?['success'] != true) {
          return const SizedBox.shrink();
        }

        final orders = List<Map<String, dynamic>>.from(snap.data?['orders'] ?? []);

        if (orders.isEmpty) {
          return Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F7FA),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.receipt_long_outlined, size: 16, color: AppColors.textDisabled),
                const SizedBox(width: 10),
                Text('No food orders placed',
                    style: AppTypography.bodySecondary.copyWith(fontSize: 13)),
              ],
            ),
          );
        }

        double grandTotal = 0;
        for (final o in orders) {
          grandTotal += (o['total_order_price'] as num? ?? 0).toDouble();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Divider(height: 24, color: AppColors.borderLight),

            // Header
            Row(
              children: [
                Icon(Icons.receipt_long_outlined, size: 15, color: AppColors.textSecondary),
                const SizedBox(width: 7),
                Text(
                  'Food Orders',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${orders.length} order${orders.length > 1 ? 's' : ''}',
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.primary),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            ...orders.map((o) => _OrderRow(order: o)),

            const SizedBox(height: 4),

            // Grand total bar
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Text(
                    'Total Amount',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white70),
                  ),
                  const Spacer(),
                  Text(
                    '₹${grandTotal.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Order Row
// ─────────────────────────────────────────────────────────────────────────────

class _OrderRow extends StatelessWidget {
  final Map<String, dynamic> order;

  const _OrderRow({required this.order});

  @override
  Widget build(BuildContext context) {
    final items   = List<Map<String, dynamic>>.from(order['items'] ?? []);
    final total   = (order['total_order_price'] as num? ?? 0).toDouble();
    final orderNo = order['order_number']?.toString() ?? '—';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Order #$orderNo',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
              ),
              const Spacer(),
              Text(
                '₹${total.toStringAsFixed(2)}',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.primary),
              ),
            ],
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...items.map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: (item['is_veg'] == true || item['is_veg'] == 1)
                                ? AppColors.success
                                : AppColors.error,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item['food_name']?.toString() ?? '—',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w500),
                        ),
                      ),
                      Text(
                        'x${item['quantity'] ?? 1}',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 56,
                        child: Text(
                          '₹${(item['total_price'] as num? ?? 0).toStringAsFixed(0)}',
                          textAlign: TextAlign.end,
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Detail Row
// ─────────────────────────────────────────────────────────────────────────────

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: AppColors.textDisabled),
          const SizedBox(width: 10),
          SizedBox(
            width: 80,
            child: Text(label,
                style: AppTypography.bodySecondary),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}



