// pages/guest_checkout_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../services/checkout_service.dart';
import '../services/websocket_service.dart';
import '../theme/app_typography.dart';
import '../theme/app_colors.dart';
import '../utils/app_snackbar.dart';
import '../utils/date_formatter.dart';
import '../components/skeleton_loader.dart';
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
  String _statusFilter = 'All';
  Timer? _ticker;
  int _tickCount = 0;
  StreamSubscription<Map<String, dynamic>>? _wsSubscription;

  @override
  void initState() {
    super.initState();
    _futureGuests = _loadGuests();
    _setupWebSocketListener();
    _ticker = Timer.periodic(
      const Duration(minutes: 1),
      (_) { if (mounted) setState(() => _tickCount++); },
    );
  }

  void _setupWebSocketListener() {
    _wsSubscription = WebSocketService().stream.listen((event) {
      if (!mounted) return;
      final type = (event['type'] ?? '').toString().toUpperCase();
      
      // Listen for checkout-related events
      if (type == 'GUEST_CHECKOUT' ||
          type == 'CHECKOUT_STATUS_CHANGED' ||
          type == 'GUEST_CHECKED_OUT' ||
          type == 'BOOKING_UPDATED') {
        // Reload guest list to reflect changes made on other devices
        setState(() => _futureGuests = _loadGuests());
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _wsSubscription?.cancel();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _loadGuests() async {
    final res = await CheckoutService().getGuestCheckoutReport();
    if (res['success'] != true) throw Exception(res['message']);
    return List<Map<String, dynamic>>.from(res['guests']);
  }

  String _formatDateTime(String? s) => DateFormatter.formatDateTimeAmPm(s);
  String _formatTime(String? s) => DateFormatter.formatTimeOnlyAmPm(s);

  // ── Status helpers ─────────────────────────────────────────────────────────

  _CheckoutStatus _statusFor(String? status) {
    switch ((status ?? '').toLowerCase()) {
      case 'overdue':
        return const _CheckoutStatus(
          color: AppColors.error,
          bg: AppColors.errorLight,
          icon: Icons.warning_amber_rounded,
          label: 'Overdue',
          filterKey: 'Overdue',
        );
      case 'checkout within 1 hour':
        return const _CheckoutStatus(
          color: AppColors.warning,
          bg: AppColors.warningLight,
          icon: Icons.timer_rounded,
          label: '< 1 hr',
          filterKey: 'Within 1 hr',
        );
      default:
        return const _CheckoutStatus(
          color: AppColors.info,
          bg: AppColors.infoLight,
          icon: Icons.schedule_rounded,
          label: 'Upcoming',
          filterKey: 'Upcoming',
        );
    }
  }

  String _countdownLabel(int? rawMinutes) {
    if (rawMinutes == null) return '';
    final adj = rawMinutes - _tickCount;
    if (adj <= 0) return 'Overdue';
    if (adj < 60) return '${adj}m left';
    final h = adj ~/ 60;
    final m = adj % 60;
    return m == 0 ? '${h}h left' : '${h}h ${m}m left';
  }

  Color _countdownColor(int? rawMinutes) {
    if (rawMinutes == null) return AppColors.textDisabled;
    final adj = rawMinutes - _tickCount;
    if (adj <= 0) return AppColors.error;
    if (adj <= 60) return AppColors.warning;
    return AppColors.success;
  }

  // ── Expand / collapse ──────────────────────────────────────────────────────

  void _toggleExpand(Map<String, dynamic> g) {
    final id = (g['guestId'] as num?)?.toInt();
    if (id == null) return;
    setState(() {
      if (_expandedIds.contains(id)) {
        _expandedIds.remove(id);
      } else {
        _expandedIds.add(id);
        _billFutures.putIfAbsent(
          id, () => CheckoutService().getGuestBill(guestId: id));
      }
    });
  }

  // ── Filtering ──────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _applyFilters(List<Map<String, dynamic>> all) {
    var list = all.where(
      (g) => (g['raw']?['status'] ?? '') != 'Checked_out').toList();
    if (_statusFilter != 'All') {
      list = list.where(
        (g) => _statusFor(g['checkoutStatus']).filterKey == _statusFilter)
          .toList();
    }
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list.where((g) =>
          (g['guestName'] ?? '').toLowerCase().contains(q) ||
          (g['roomNumber']?.toString() ?? '').contains(q) ||
          (g['contact'] ?? '').contains(q)).toList();
    }
    return list;
  }

  List<Map<String, dynamic>> _checkedOutToday(
      List<Map<String, dynamic>> all) =>
      all.where((g) => (g['raw']?['status'] ?? '') == 'Checked_out').toList();

  // ── Manual checkout ────────────────────────────────────────────────────────

  Future<void> _onManualCheckout(Map<String, dynamic> guest) async {
    final confirmed = await _showCheckoutConfirmSheet(guest);
    if (confirmed != true || !mounted) return;
    AppSnackBar.show(context,
        '${guest['guestName'] ?? 'Guest'} checked out successfully');
    setState(() => _futureGuests = _loadGuests());
  }

  Future<bool?> _showCheckoutConfirmSheet(Map<String, dynamic> guest) {
    final name = (guest['guestName'] ?? 'Guest').toString();
    final room = (guest['roomNumber'] ?? '—').toString();
    final time = _formatTime(guest['checkoutDate']);
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 40, height: 4,
                decoration: BoxDecoration(color: AppColors.border,
                    borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 24),
            Row(children: [
              Container(padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.logout_rounded,
                    size: 22, color: AppColors.primary)),
              const SizedBox(width: 12),
              const Expanded(child: Text('Confirm Checkout',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary))),
            ]),
            const SizedBox(height: 20),
            Container(padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.borderLight)),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: AppColors.primaryLight,
                      borderRadius: BorderRadius.circular(8)),
                  child: Text('Rm $room', style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800,
                      color: AppColors.primary))),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: const TextStyle(fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Row(children: [
                    const Icon(Icons.access_time_rounded,
                        size: 13, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text('Checkout at $time', style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
                  ]),
                ])),
              ])),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, false),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14))),
                child: const Text('Cancel', style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)))),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.check_circle_rounded, size: 18),
                label: const Text('Confirm Checkout', style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white, elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14))))),
            ]),
          ]),
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context)),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Checkout Today', style: AppTypography.appBarTitle),
          Text("Today's guest departures",
              style: AppTypography.appBarSubtitle),
        ]),
        actions: [
          IconButton(
            tooltip: 'Checkout history',
            icon: const Icon(Icons.history_rounded,
                color: AppColors.textSecondary),
            onPressed: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => const GuestCheckoutHistoryPage()))),
          const SizedBox(width: 4),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _futureGuests,
        builder: (ctx, snap) {
          // ── Loading ──────────────────────────────────────────────────────
          if (snap.connectionState == ConnectionState.waiting) {
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              itemCount: 6,
              itemBuilder: (_, __) => const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: SkeletonCheckoutCard()),
            );
          }

          // ── Error ────────────────────────────────────────────────────────
          if (snap.hasError) {
            return Center(child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(padding: const EdgeInsets.all(20),
                  decoration: const BoxDecoration(color: AppColors.errorLight,
                      shape: BoxShape.circle),
                  child: const Icon(Icons.wifi_off_rounded,
                      size: 36, color: AppColors.error)),
                const SizedBox(height: 16),
                Text(snap.error.toString().replaceFirst('Exception: ', ''),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textSecondary,
                        fontSize: 14)),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Retry'),
                  onPressed: () =>
                      setState(() => _futureGuests = _loadGuests()),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white, elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)))),
              ])));
          }

          final all = snap.data ?? [];
          final allActive = all.where(
              (g) => (g['raw']?['status'] ?? '') != 'Checked_out').toList();
          final active = _applyFilters(all);
          final checkedOut = _checkedOutToday(all);

          int countFor(String fk) => allActive.where(
              (g) => _statusFor(g['checkoutStatus']).filterKey == fk).length;
          final overdueCount   = countFor('Overdue');
          final within1hrCount = countFor('Within 1 hr');
          final upcomingCount  = countFor('Upcoming');

          return RefreshIndicator(
            color: AppColors.primary,
            onRefresh: () async =>
                setState(() => _futureGuests = _loadGuests()),
            child: CustomScrollView(slivers: [

              // ── Summary header ─────────────────────────────────────────
              if (all.isNotEmpty)
                SliverToBoxAdapter(child: _SummaryHeader(
                  totalActive:   allActive.length,
                  overdueCount:  overdueCount,
                  within1hr:     within1hrCount,
                  checkedOut:    checkedOut.length,
                )),

              // ── Search bar ─────────────────────────────────────────────
              SliverToBoxAdapter(child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _SearchBar(
                  onChanged: (v) => setState(() => _search = v)),
              )),

              // ── Filter chips ───────────────────────────────────────────
              SliverToBoxAdapter(child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 0, 16),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    _FilterChip(label: 'All',   count: allActive.length,
                        selected: _statusFilter == 'All',
                        color: AppColors.primary, bg: AppColors.primaryLight,
                        onTap: () => setState(() => _statusFilter = 'All')),
                    const SizedBox(width: 8),
                    _FilterChip(label: 'Overdue', count: overdueCount,
                        selected: _statusFilter == 'Overdue',
                        color: AppColors.error, bg: AppColors.errorLight,
                        onTap: () =>
                            setState(() => _statusFilter = 'Overdue')),
                    const SizedBox(width: 8),
                    _FilterChip(label: '< 1 hr', count: within1hrCount,
                        selected: _statusFilter == 'Within 1 hr',
                        color: AppColors.warning, bg: AppColors.warningLight,
                        onTap: () =>
                            setState(() => _statusFilter = 'Within 1 hr')),
                    const SizedBox(width: 8),
                    _FilterChip(label: 'Upcoming', count: upcomingCount,
                        selected: _statusFilter == 'Upcoming',
                        color: AppColors.info, bg: AppColors.infoLight,
                        onTap: () =>
                            setState(() => _statusFilter = 'Upcoming')),
                    const SizedBox(width: 16),
                  ])))),

              // ── Empty: no guests at all ────────────────────────────────
              if (all.isEmpty)
                SliverFillRemaining(child: _EmptyState(
                  icon: Icons.hotel_rounded,
                  color: AppColors.success,
                  bg: AppColors.successLight,
                  title: 'No checkouts today',
                  subtitle: 'Guests checking out today will appear here')),

              // ── Empty: filter / search returned nothing ────────────────
              if (all.isNotEmpty && active.isEmpty && checkedOut.isEmpty)
                SliverFillRemaining(child: _EmptyState(
                  icon: Icons.search_off_rounded,
                  color: AppColors.textDisabled,
                  bg: AppColors.surfaceAlt,
                  title: _search.isNotEmpty
                      ? 'No results for "$_search"'
                      : 'No $_statusFilter checkouts',
                  subtitle: _search.isNotEmpty
                      ? 'Try a different name or room number'
                      : null)),

              // ── Active (pending checkout) list ─────────────────────────
              if (active.isNotEmpty) ...[
                SliverToBoxAdapter(child: _SectionHeader(
                  label: 'Pending · ${active.length}',
                  icon: Icons.schedule_rounded,
                  color: AppColors.textSecondary,
                )),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList(delegate: SliverChildBuilderDelegate(
                    (_, i) {
                      final g = active[i];
                      final id = (g['guestId'] as num?)?.toInt();
                      final min = (g['minutesToCheckout'] as num?)?.toInt();
                      final st = _statusFor(g['checkoutStatus']);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _GuestCard(
                          guest: g,
                          statusColor: st.color,
                          statusBg: st.bg,
                          statusIcon: st.icon,
                          statusLabel: st.label,
                          accentColor: st.color,
                          expanded: id != null && _expandedIds.contains(id),
                          billFuture: id != null ? _billFutures[id] : null,
                          onTap: () => _toggleExpand(g),
                          onCheckout: () => _onManualCheckout(g),
                          formatDateTime: _formatDateTime,
                          formatTime: _formatTime,
                          countdownLabel: _countdownLabel(min),
                          countdownColor: _countdownColor(min),
                        ));
                    }, childCount: active.length)),
                ),
              ],

              // ── Checked-out today section ──────────────────────────────
              if (checkedOut.isNotEmpty) ...[
                SliverToBoxAdapter(child: _SectionHeader(
                  label: 'Checked Out · ${checkedOut.length}',
                  icon: Icons.check_circle_outline_rounded,
                  color: AppColors.success,
                )),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList(delegate: SliverChildBuilderDelegate(
                    (_, i) {
                      final g = checkedOut[i];
                      final id = (g['guestId'] as num?)?.toInt();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _GuestCard(
                          guest: g,
                          statusColor: AppColors.success,
                          statusBg: AppColors.successLight,
                          statusIcon: Icons.check_circle_rounded,
                          statusLabel: 'Checked Out',
                          accentColor: AppColors.success,
                          expanded: id != null && _expandedIds.contains(id),
                          billFuture: id != null ? _billFutures[id] : null,
                          onTap: () => _toggleExpand(g),
                          onCheckout: null,
                          formatDateTime: _formatDateTime,
                          formatTime: _formatTime,
                          countdownLabel: '',
                          countdownColor: AppColors.textDisabled,
                          isCheckedOut: true,
                        ));
                    }, childCount: checkedOut.length)),
                ),
              ],

              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ]),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Summary header — 4 KPI tiles
// ─────────────────────────────────────────────────────────────────────────────

class _SummaryHeader extends StatelessWidget {
  final int totalActive;
  final int overdueCount;
  final int within1hr;
  final int checkedOut;

  const _SummaryHeader({
    required this.totalActive,
    required this.overdueCount,
    required this.within1hr,
    required this.checkedOut,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: Row(children: [
        _KpiTile(value: '$totalActive', label: 'Total',
            color: AppColors.primary, bg: AppColors.primaryLight),
        const SizedBox(width: 8),
        _KpiTile(value: '$overdueCount', label: 'Overdue',
            color: AppColors.error, bg: AppColors.errorLight),
        const SizedBox(width: 8),
        _KpiTile(value: '$within1hr', label: '< 1 hr',
            color: AppColors.warning, bg: AppColors.warningLight),
        const SizedBox(width: 8),
        _KpiTile(value: '$checkedOut', label: 'Done',
            color: AppColors.success, bg: AppColors.successLight),
      ]),
    );
  }
}

class _KpiTile extends StatelessWidget {
  final String value;
  final String label;
  final Color color;
  final Color bg;

  const _KpiTile({
    required this.value,
    required this.label,
    required this.color,
    required this.bg,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(color: bg,
            borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          Text(value, style: TextStyle(fontSize: 20,
              fontWeight: FontWeight.w800, color: color,
              letterSpacing: -0.5)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11,
              fontWeight: FontWeight.w600, color: color.withOpacity(0.75))),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Search bar
// ─────────────────────────────────────────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  final ValueChanged<String> onChanged;

  const _SearchBar({required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: 'Search by name, room, phone…',
        hintStyle: const TextStyle(
            color: AppColors.textDisabled, fontSize: 14),
        prefixIcon: const Icon(Icons.search_rounded,
            color: AppColors.textDisabled, size: 20),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppColors.borderLight)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(
                color: AppColors.primary, width: 1.5)),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter chip
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
            color: selected ? color : AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
                color: selected ? color : AppColors.border, width: 1.5),
            boxShadow: selected ? [
              BoxShadow(color: color.withOpacity(0.25),
                  blurRadius: 8, offset: const Offset(0, 2))
            ] : []),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : AppColors.textSecondary)),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withOpacity(0.2)
                    : bg,
                borderRadius: BorderRadius.circular(10)),
            child: Text('$count', style: TextStyle(fontSize: 11,
                fontWeight: FontWeight.w800,
                color: selected ? Colors.white : color))),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section header
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;

  const _SectionHeader({
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 12,
            fontWeight: FontWeight.w600, color: color,
            letterSpacing: 0.4)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty state
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color bg;
  final String title;
  final String? subtitle;

  const _EmptyState({
    required this.icon,
    required this.color,
    required this.bg,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(child: Padding(
      padding: const EdgeInsets.all(40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(icon, size: 40, color: color)),
        const SizedBox(height: 18),
        Text(title, style: const TextStyle(fontSize: 16,
            fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            textAlign: TextAlign.center),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle!, style: AppTypography.bodySecondary,
              textAlign: TextAlign.center),
        ],
      ]),
    ));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Guest card — used for both active and checked-out guests
// ─────────────────────────────────────────────────────────────────────────────

class _GuestCard extends StatelessWidget {
  final Map<String, dynamic> guest;
  final Color statusColor;
  final Color statusBg;
  final IconData statusIcon;
  final String statusLabel;
  final Color accentColor;
  final bool expanded;
  final Future<Map<String, dynamic>>? billFuture;
  final VoidCallback onTap;
  final VoidCallback? onCheckout;
  final bool isCheckedOut;
  final String countdownLabel;
  final Color countdownColor;
  final String Function(String?) formatDateTime;
  final String Function(String?) formatTime;

  const _GuestCard({
    required this.guest,
    required this.statusColor,
    required this.statusBg,
    required this.statusIcon,
    required this.statusLabel,
    required this.accentColor,
    required this.expanded,
    required this.billFuture,
    required this.onTap,
    required this.onCheckout,
    required this.formatDateTime,
    required this.formatTime,
    required this.countdownLabel,
    required this.countdownColor,
    this.isCheckedOut = false,
  });

  @override
  Widget build(BuildContext context) {
    final name = (guest['guestName'] ?? 'G').toString().trim();
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'G';

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: expanded
                  ? accentColor.withOpacity(0.3)
                  : AppColors.borderLight,
              width: expanded ? 1.5 : 1),
          boxShadow: [BoxShadow(
              color: expanded
                  ? accentColor.withOpacity(0.08)
                  : AppColors.shadow,
              blurRadius: expanded ? 16 : 8,
              offset: const Offset(0, 2))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              // Left accent bar — encodes urgency at a glance
              Container(width: 4, color: accentColor),

              // Card content
              Expanded(child: Column(children: [
                // ── Header row ─────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center, children: [
                    // Avatar
                    Container(width: 44, height: 44,
                      decoration: BoxDecoration(
                          color: isCheckedOut
                              ? AppColors.successLight
                              : AppColors.primaryLight,
                          borderRadius: BorderRadius.circular(12)),
                      alignment: Alignment.center,
                      child: Text(initial, style: TextStyle(fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: isCheckedOut
                              ? AppColors.success
                              : AppColors.primary))),
                    const SizedBox(width: 12),

                    // Name + room + time
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: const TextStyle(fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.2),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                        Row(children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                                color: AppColors.primaryLight,
                                borderRadius: BorderRadius.circular(6)),
                            child: Text('Rm ${guest['roomNumber'] ?? '—'}',
                                style: const TextStyle(fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary))),
                          const SizedBox(width: 6),
                          Flexible(child: Text(
                            isCheckedOut
                                ? 'Out · ${formatTime(guest['checkoutDate'])}'
                                : 'Checkout · ${formatTime(guest['checkoutDate'])}',
                            style: const TextStyle(fontSize: 12,
                                color: AppColors.textSecondary),
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                        ]),
                        if (!isCheckedOut && countdownLabel.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Row(children: [
                            Icon(Icons.timer_outlined,
                                size: 12, color: countdownColor),
                            const SizedBox(width: 4),
                            Text(countdownLabel, style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w700,
                                color: countdownColor)),
                          ]),
                        ],
                      ])),

                    const SizedBox(width: 10),

                    // Status pill + expand arrow
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 5),
                        decoration: BoxDecoration(color: statusBg,
                            borderRadius: BorderRadius.circular(20)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(statusIcon, size: 11, color: statusColor),
                          const SizedBox(width: 4),
                          Text(statusLabel, style: TextStyle(fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: statusColor)),
                        ])),
                      const SizedBox(height: 8),
                      AnimatedRotation(
                          turns: expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 20, color: AppColors.textDisabled)),
                    ]),
                  ]),
                ),

                // ── Expanded detail ─────────────────────────────────────
                if (expanded) ...[
                  const Divider(height: 1, color: AppColors.borderLight),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      _DetailRow(icon: Icons.badge_outlined,
                          label: 'Guest ID',
                          value: '#${guest['guestId'] ?? '—'}'),
                      _DetailRow(icon: Icons.phone_outlined,
                          label: 'Contact',
                          value: guest['contact']?.toString().isNotEmpty == true
                              ? guest['contact'] : 'Not provided'),
                      _DetailRow(icon: Icons.email_outlined,
                          label: 'Email',
                          value: guest['email']?.toString().isNotEmpty == true
                              ? guest['email'] : 'Not provided'),
                      _DetailRow(icon: Icons.calendar_today_outlined,
                          label: 'Checkout',
                          value: formatDateTime(guest['checkoutDate'])),
                      if ((guest['raw']?['device_name'] ?? '')
                          .toString().isNotEmpty)
                        _DetailRow(icon: Icons.devices_outlined,
                            label: 'Devices',
                            value: guest['raw']['device_name'].toString()),

                      // Food orders bill
                      OrdersSection(billFuture: billFuture),

                      // Action button
                      if (!isCheckedOut && onCheckout != null) ...[
                        const SizedBox(height: 16),
                        SizedBox(width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: onCheckout,
                            icon: const Icon(Icons.logout_rounded, size: 16),
                            label: const Text('Manual Checkout',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15)),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(12))))),
                      ],
                      if (isCheckedOut) ...[
                        const SizedBox(height: 14),
                        Container(width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          decoration: BoxDecoration(
                              color: AppColors.successLight,
                              borderRadius: BorderRadius.circular(12)),
                          child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                            Icon(Icons.check_circle_rounded,
                                size: 15, color: AppColors.success),
                            SizedBox(width: 8),
                            Text('Guest has been checked out',
                                style: TextStyle(fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.success)),
                          ])),
                      ],
                    ])),
                ],
              ])),
            ]),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Orders section — shared with history page
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
          return const Padding(padding: EdgeInsets.only(top: 12),
            child: Column(children: [
              SkeletonFoodOrderCard(),
              SizedBox(height: 8),
              SkeletonFoodOrderCard()]));
        }
        if (snap.hasError || snap.data?['success'] != true) {
          return const SizedBox.shrink();
        }
        final orders = List<Map<String, dynamic>>.from(
            snap.data?['orders'] ?? []);
        if (orders.isEmpty) {
          return Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 14),
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.borderLight)),
            child: Row(children: [
              const Icon(Icons.receipt_long_outlined,
                  size: 15, color: AppColors.textDisabled),
              const SizedBox(width: 10),
              Text('No food orders placed',
                  style: AppTypography.bodySecondary.copyWith(
                      fontSize: 13)),
            ]));
        }
        final grandTotal = orders.fold<double>(
            0, (s, o) =>
                s + (o['total_order_price'] as num? ?? 0).toDouble());
        return Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          const Divider(height: 24, color: AppColors.borderLight),
          // Header row
          Row(children: [
            const Icon(Icons.receipt_long_outlined,
                size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 7),
            const Text('Food Orders', style: TextStyle(fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(20)),
              child: Text(
                '${orders.length} order${orders.length > 1 ? 's' : ''}',
                style: const TextStyle(fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary))),
          ]),
          const SizedBox(height: 10),
          ...orders.map((o) => _OrderRow(order: o)),
          const SizedBox(height: 4),
          // Total banner
          Container(width: double.infinity,
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 13),
            decoration: BoxDecoration(color: AppColors.primary,
                borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Text('Total Amount', style: TextStyle(fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.white70)),
              const Spacer(),
              Text('₹${grandTotal.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 17,
                      fontWeight: FontWeight.w800, color: Colors.white,
                      letterSpacing: -0.3)),
            ])),
        ]);
      },
    );
  }
}

// ── Order row ─────────────────────────────────────────────────────────────────

class _OrderRow extends StatelessWidget {
  final Map<String, dynamic> order;

  const _OrderRow({required this.order});

  @override
  Widget build(BuildContext context) {
    final items = List<Map<String, dynamic>>.from(order['items'] ?? []);
    final total = (order['total_order_price'] as num? ?? 0).toDouble();
    final orderNo = order['order_number']?.toString() ?? '—';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderLight)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Order #$orderNo', style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700,
              color: AppColors.textPrimary))),
          Text('₹${total.toStringAsFixed(2)}', style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w800,
              color: AppColors.primary)),
        ]),
        if (items.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...items.map((item) => Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Padding(padding: const EdgeInsets.only(top: 3),
                child: Container(width: 8, height: 8,
                  decoration: BoxDecoration(shape: BoxShape.circle,
                    color: (item['is_veg'] == true || item['is_veg'] == 1)
                        ? AppColors.success : AppColors.error,
                  ))),
              const SizedBox(width: 8),
              Expanded(child: Text(
                  item['food_name']?.toString() ?? '—',
                  style: const TextStyle(fontSize: 12,
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w500))),
              Text('×${item['quantity'] ?? 1}',
                  style: const TextStyle(fontSize: 12,
                      color: AppColors.textSecondary)),
              const SizedBox(width: 10),
              SizedBox(width: 58, child: Text(
                '₹${(item['total_price'] as num? ?? 0).toStringAsFixed(0)}',
                textAlign: TextAlign.end,
                style: const TextStyle(fontSize: 12,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600))),
            ]))),
        ],
      ]),
    );
  }
}

// ── Detail row ────────────────────────────────────────────────────────────────

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 15, color: AppColors.textDisabled),
        const SizedBox(width: 10),
        SizedBox(width: 72, child: Text(label,
            style: AppTypography.bodySecondary)),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary))),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal status data class
// ─────────────────────────────────────────────────────────────────────────────

class _CheckoutStatus {
  final Color color;
  final Color bg;
  final IconData icon;
  final String label;
  final String filterKey;

  const _CheckoutStatus({
    required this.color,
    required this.bg,
    required this.icon,
    required this.label,
    required this.filterKey,
  });
}
