// pages/guest_checkout_history_page.dart
import 'package:flutter/material.dart';
import '../services/checkout_service.dart';
import '../theme/app_typography.dart';
import '../theme/app_colors.dart';
import '../utils/date_formatter.dart';
import '../components/skeleton_loader.dart';
import 'guest_checkout_page.dart' show OrdersSection;

class GuestCheckoutHistoryPage extends StatefulWidget {
  const GuestCheckoutHistoryPage({super.key});

  @override
  State<GuestCheckoutHistoryPage> createState() =>
      _GuestCheckoutHistoryPageState();
}

class _GuestCheckoutHistoryPageState
    extends State<GuestCheckoutHistoryPage> {
  late Future<List<Map<String, dynamic>>> _futureGuests;
  String _search = '';
  final Set<int> _expandedIds = {};
  final Map<int, Future<Map<String, dynamic>>> _billFutures = {};

  @override
  void initState() {
    super.initState();
    _futureGuests = _loadHistory();
  }

  Future<List<Map<String, dynamic>>> _loadHistory() async {
    final res = await CheckoutService().getGuestCheckoutReport();
    if (res['success'] != true) throw Exception(res['message']);
    final all = List<Map<String, dynamic>>.from(res['guests']);
    return all.where(
        (g) => (g['raw']?['status'] ?? '') == 'Checked_out').toList();
  }

  DateTime? _parseDate(String? s) {
    if (s == null || s.isEmpty) return null;
    try { return DateTime.parse(s); } catch (_) { return null; }
  }

  String _formatDateTime(String? s) => DateFormatter.formatDateTimeAmPm(s);
  String _formatDateOnly(String? s) =>
      DateFormatter.formatDateOnlyFullYear(s);

  String _stayDuration(String? checkIn, String? checkOut) {
    final i = _parseDate(checkIn);
    final o = _parseDate(checkOut);
    if (i == null || o == null) return '—';
    final diff = o.difference(i).inDays;
    return diff == 0 ? 'Same day' : '$diff night${diff > 1 ? 's' : ''}';
  }

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
        title: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          const Text('Checkout History', style: AppTypography.appBarTitle),
          Text("Today's completed departures",
              style: AppTypography.appBarSubtitle),
        ]),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded,
                color: AppColors.textSecondary),
            onPressed: () =>
                setState(() => _futureGuests = _loadHistory())),
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
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 14)),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Retry'),
                  onPressed: () =>
                      setState(() => _futureGuests = _loadHistory()),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white, elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)))),
              ])));
          }

          final all = snap.data ?? [];

          // ── Total revenue across all checked-out guests ──────────────────
          // (computed eagerly so the header always shows real numbers)

          final filtered = _search.isEmpty
              ? all
              : all.where((g) {
                  final q = _search.toLowerCase();
                  return (g['guestName'] ?? '').toLowerCase().contains(q) ||
                      (g['roomNumber']?.toString() ?? '').contains(q) ||
                      (g['contact'] ?? '').contains(q);
                }).toList();

          return RefreshIndicator(
            color: AppColors.primary,
            onRefresh: () async =>
                setState(() => _futureGuests = _loadHistory()),
            child: CustomScrollView(slivers: [

              // ── Summary banner ─────────────────────────────────────────
              if (all.isNotEmpty)
                SliverToBoxAdapter(child: _HistorySummary(
                    totalGuests: all.length)),

              // ── Search bar ─────────────────────────────────────────────
              SliverToBoxAdapter(child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _SearchBar(
                    onChanged: (v) => setState(() => _search = v)),
              )),

              // ── Result count ───────────────────────────────────────────
              if (all.isNotEmpty)
                SliverToBoxAdapter(child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Text(
                    '${filtered.length} guest${filtered.length != 1 ? 's' : ''} checked out today',
                    style: const TextStyle(fontSize: 12,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500)),
                )),

              const SliverToBoxAdapter(child: SizedBox(height: 8)),

              // ── Empty state ────────────────────────────────────────────
              if (filtered.isEmpty)
                SliverFillRemaining(child: _EmptyState(
                  icon: _search.isNotEmpty
                      ? Icons.search_off_rounded
                      : Icons.history_toggle_off_rounded,
                  color: AppColors.textDisabled,
                  bg: AppColors.surfaceAlt,
                  title: _search.isNotEmpty
                      ? 'No results for "$_search"'
                      : 'No checkouts recorded today',
                  subtitle: _search.isNotEmpty
                      ? 'Try a different name or room number'
                      : 'Completed checkouts will appear here',
                )),

              // ── Guest list ─────────────────────────────────────────────
              if (filtered.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList(delegate: SliverChildBuilderDelegate(
                    (_, i) {
                      final g = filtered[i];
                      final id = (g['guestId'] as num?)?.toInt();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _HistoryCard(
                          guest: g,
                          expanded: id != null && _expandedIds.contains(id),
                          billFuture: id != null ? _billFutures[id] : null,
                          onTap: () => _toggleExpand(g),
                          formatDateTime: _formatDateTime,
                          formatDateOnly: _formatDateOnly,
                          stayDuration: _stayDuration,
                        ));
                    }, childCount: filtered.length)),
                ),

              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ]),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// History summary banner
// ─────────────────────────────────────────────────────────────────────────────

class _HistorySummary extends StatelessWidget {
  final int totalGuests;

  const _HistorySummary({required this.totalGuests});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(
            color: AppColors.primary.withOpacity(0.25),
            blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: Row(children: [
        Container(padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.check_circle_rounded,
              color: Colors.white, size: 24)),
        const SizedBox(width: 14),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Completed Checkouts',
              style: TextStyle(fontSize: 13,
                  fontWeight: FontWeight.w500, color: Colors.white70)),
          const SizedBox(height: 2),
          Text('$totalGuests guest${totalGuests != 1 ? 's' : ''} today',
              style: const TextStyle(fontSize: 20,
                  fontWeight: FontWeight.w800, color: Colors.white,
                  letterSpacing: -0.5)),
        ])),
        Container(padding: const EdgeInsets.symmetric(
            horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10)),
          child: const Text('Today', style: TextStyle(fontSize: 12,
              fontWeight: FontWeight.w600, color: Colors.white))),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Search bar (shared look with checkout page)
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
// History card
// ─────────────────────────────────────────────────────────────────────────────

class _HistoryCard extends StatelessWidget {
  final Map<String, dynamic> guest;
  final bool expanded;
  final Future<Map<String, dynamic>>? billFuture;
  final VoidCallback onTap;
  final String Function(String?) formatDateTime;
  final String Function(String?) formatDateOnly;
  final String Function(String?, String?) stayDuration;

  const _HistoryCard({
    required this.guest,
    required this.expanded,
    required this.billFuture,
    required this.onTap,
    required this.formatDateTime,
    required this.formatDateOnly,
    required this.stayDuration,
  });

  @override
  Widget build(BuildContext context) {
    final raw = guest['raw'] ?? {};
    final duration = stayDuration(
        raw['checked_in_time']?.toString(),
        raw['checked_out_time']?.toString());
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
                  ? AppColors.success.withOpacity(0.3)
                  : AppColors.borderLight,
              width: expanded ? 1.5 : 1),
          boxShadow: [BoxShadow(
              color: expanded
                  ? AppColors.success.withOpacity(0.08)
                  : AppColors.shadow,
              blurRadius: expanded ? 16 : 8,
              offset: const Offset(0, 2))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              // Left green accent bar — all history = checked out
              Container(width: 4, color: AppColors.success),

              Expanded(child: Column(children: [
                // ── Header ────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                    // Avatar
                    Container(width: 44, height: 44,
                      decoration: BoxDecoration(
                          color: AppColors.successLight,
                          borderRadius: BorderRadius.circular(12)),
                      alignment: Alignment.center,
                      child: Text(initial, style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800,
                          color: AppColors.success))),
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
                            'Out · ${formatDateTime(guest['checkoutDate'])}',
                            style: const TextStyle(fontSize: 12,
                                color: AppColors.textSecondary),
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                        ]),
                        if (duration != '—') ...[
                          const SizedBox(height: 4),
                          Row(children: [
                            const Icon(Icons.nights_stay_outlined,
                                size: 11,
                                color: AppColors.textDisabled),
                            const SizedBox(width: 4),
                            Text(duration, style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary)),
                          ]),
                        ],
                      ])),

                    const SizedBox(width: 10),

                    // Badge + expand arrow
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 5),
                        decoration: BoxDecoration(
                            color: AppColors.successLight,
                            borderRadius: BorderRadius.circular(20)),
                        child: Row(mainAxisSize: MainAxisSize.min,
                            children: [
                          const Icon(Icons.check_circle_rounded,
                              size: 11, color: AppColors.success),
                          const SizedBox(width: 4),
                          const Text('Checked Out', style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w600,
                              color: AppColors.success)),
                        ])),
                      const SizedBox(height: 8),
                      AnimatedRotation(turns: expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 20,
                              color: AppColors.textDisabled)),
                    ]),
                  ]),
                ),

                // ── Expanded detail ────────────────────────────────────
                if (expanded) ...[
                  const Divider(height: 1, color: AppColors.borderLight),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      // Stay grid — 2-column
                      Row(children: [
                        Expanded(child: _MiniDetailTile(
                            icon: Icons.login_rounded, label: 'Check-in',
                            value: formatDateOnly(
                                raw['checked_in_time']?.toString()))),
                        const SizedBox(width: 8),
                        Expanded(child: _MiniDetailTile(
                            icon: Icons.logout_rounded,
                            label: 'Checked Out',
                            value: formatDateTime(
                                guest['checkoutDate']))),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(child: _MiniDetailTile(
                            icon: Icons.nights_stay_outlined,
                            label: 'Stay', value: duration)),
                        const SizedBox(width: 8),
                        Expanded(child: _MiniDetailTile(
                            icon: Icons.badge_outlined, label: 'Guest ID',
                            value: '#${guest['guestId'] ?? '—'}')),
                      ]),
                      if (guest['contact']?.toString().isNotEmpty == true) ...[
                        const SizedBox(height: 8),
                        _MiniDetailTile(icon: Icons.phone_outlined,
                            label: 'Contact',
                            value: guest['contact'].toString()),
                      ],
                      if (guest['email']?.toString().isNotEmpty == true) ...[
                        const SizedBox(height: 8),
                        _MiniDetailTile(icon: Icons.email_outlined,
                            label: 'Email',
                            value: guest['email'].toString()),
                      ],
                      if ((raw['device_name'] ?? '').toString().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _MiniDetailTile(icon: Icons.devices_outlined,
                            label: 'Devices',
                            value: raw['device_name'].toString()),
                      ],
                      // Food orders
                      OrdersSection(billFuture: billFuture),
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
// Mini detail tile — compact 2-column grid inside expanded card
// ─────────────────────────────────────────────────────────────────────────────

class _MiniDetailTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _MiniDetailTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.borderLight)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 13, color: AppColors.textDisabled),
        const SizedBox(width: 8),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 10,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary),
              maxLines: 2, overflow: TextOverflow.ellipsis),
        ])),
      ]),
    );
  }
}
