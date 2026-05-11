import 'package:flutter/material.dart';
import '../services/checkout_service.dart';
import '../utils/app_colors.dart';
import 'guest_checkout_page.dart' show OrdersSection;

class GuestCheckoutHistoryPage extends StatefulWidget {
  const GuestCheckoutHistoryPage({super.key});

  @override
  State<GuestCheckoutHistoryPage> createState() => _GuestCheckoutHistoryPageState();
}

class _GuestCheckoutHistoryPageState extends State<GuestCheckoutHistoryPage> {
  late Future<List<Map<String, dynamic>>> _futureGuests;
  String _search = '';
  final Set<int> _expandedIds = {};
  final Map<int, Future<Map<String, dynamic>>> _billFutures = {};

  @override
  void initState() {
    super.initState();
    _futureGuests = _loadHistory();
  }

  // ── Loaders ───────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _loadHistory() async {
    final res = await CheckoutService().getGuestCheckoutReport();
    if (res['success'] != true) throw Exception(res['message']);
    final all = List<Map<String, dynamic>>.from(res['guests']);
    return all.where((g) => (g['raw']?['status'] ?? '') == 'Checked_out').toList();
  }

  // ── Date helpers ──────────────────────────────────────────────────────────

  DateTime? _parseDate(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return DateTime.parse(s);
    } catch (_) {
      return null;
    }
  }

  /// "04/05/2026 • 2:30 PM"  — consistent with home_page style
  String _formatDateTime(String? s) {
    final d = _parseDate(s);
    if (d == null) return '—';
    final day    = d.day.toString().padLeft(2, '0');
    final month  = d.month.toString().padLeft(2, '0');
    final year   = d.year;
    final hour12 = d.hour > 12 ? d.hour - 12 : (d.hour == 0 ? 12 : d.hour);
    final minute = d.minute.toString().padLeft(2, '0');
    final period = d.hour >= 12 ? 'PM' : 'AM';
    return '$day/$month/$year • $hour12:$minute $period';
  }

  /// "04/05/2026"
  String _formatDateOnly(String? s) {
    final d = _parseDate(s);
    if (d == null) return '—';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  String _stayDuration(String? checkIn, String? checkOut) {
    final i = _parseDate(checkIn);
    final o = _parseDate(checkOut);
    if (i == null || o == null) return '—';
    final diff = o.difference(i).inDays;
    return diff == 0 ? 'Same day' : '$diff night${diff > 1 ? 's' : ''}';
  }

  void _toggleExpand(Map<String, dynamic> guest) {
    final id = (guest['guestId'] as num?)?.toInt();
    if (id == null) return;
    setState(() {
      if (_expandedIds.contains(id)) {
        _expandedIds.remove(id);
      } else {
        _expandedIds.add(id);
        _billFutures.putIfAbsent(
          id,
          () => CheckoutService().getGuestBill(guestId: id),
        );
      }
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Checkout History',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
            letterSpacing: -0.3,
          ),
        ),
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
                      onPressed: () => setState(() => _futureGuests = _loadHistory()),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final all = snap.data ?? [];
          final filtered = _search.isEmpty
              ? all
              : all.where((g) {
                  final q = _search.toLowerCase();
                  return (g['guestName'] ?? '').toLowerCase().contains(q) ||
                      (g['roomNumber']?.toString() ?? '').contains(q) ||
                      (g['contact'] ?? '').contains(q);
                }).toList();

          return Column(
            children: [
              // ── Search bar ──────────────────────────────────────────────
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: TextField(
                  onChanged: (v) => setState(() => _search = v),
                  style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Search by name, room, phone…',
                    hintStyle: const TextStyle(color: AppColors.textDisabled, fontSize: 14),
                    prefixIcon: const Icon(Icons.search_rounded,
                        color: AppColors.textDisabled, size: 20),
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

              // ── Count label ─────────────────────────────────────────────
              if (all.isNotEmpty)
                Container(
                  width: double.infinity,
                  color: const Color(0xFFF5F7FA),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Text(
                    '${filtered.length} guest${filtered.length != 1 ? 's' : ''} checked out today',
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500),
                  ),
                ),

              // ── List ────────────────────────────────────────────────────
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.history_toggle_off_rounded,
                                size: 48, color: AppColors.textDisabled),
                            const SizedBox(height: 14),
                            Text(
                              _search.isNotEmpty
                                  ? 'No results for "$_search"'
                                  : 'No checkout history today',
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        color: AppColors.primary,
                        onRefresh: () async =>
                            setState(() => _futureGuests = _loadHistory()),
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final g  = filtered[i];
                            final id = (g['guestId'] as num?)?.toInt();
                            return _HistoryCard(
                              guest: g,
                              expanded: id != null && _expandedIds.contains(id),
                              billFuture: id != null ? _billFutures[id] : null,
                              onTap: () => _toggleExpand(g),
                              formatDateTime: _formatDateTime,
                              formatDateOnly: _formatDateOnly,
                              stayDuration: _stayDuration,
                            );
                          },
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// History Card
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
    final raw      = guest['raw'] ?? {};
    final duration = stayDuration(
      raw['checked_in_time']?.toString(),
      raw['checked_out_time']?.toString(),
    );
    final name        = (guest['guestName'] ?? 'G').toString().trim();
    final firstLetter = name.isNotEmpty ? name[0].toUpperCase() : 'G';

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: expanded
                ? AppColors.primary.withOpacity(0.2)
                : AppColors.borderLight,
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
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
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
                                'Out · ${formatDateTime(guest['checkoutDate'])}',
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.textSecondary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Checked Out badge + chevron
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.successLight,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_rounded,
                                size: 11, color: AppColors.success),
                            SizedBox(width: 4),
                            Text(
                              'Checked Out',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.success),
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

            // ── Expanded ───────────────────────────────────────────────
            if (expanded) ...[
              const Divider(height: 1, color: AppColors.borderLight),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Stay info grid
                    Row(
                      children: [
                        Expanded(
                          child: _MiniDetail(
                            icon: Icons.login_rounded,
                            label: 'Check-in',
                            value: formatDateOnly(raw['checked_in_time']?.toString()),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _MiniDetail(
                            icon: Icons.logout_rounded,
                            label: 'Checked Out',
                            value: formatDateTime(guest['checkoutDate']),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _MiniDetail(
                            icon: Icons.nights_stay_outlined,
                            label: 'Stay',
                            value: duration,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _MiniDetail(
                            icon: Icons.badge_outlined,
                            label: 'Guest ID',
                            value: '#${guest['guestId'] ?? '—'}',
                          ),
                        ),
                      ],
                    ),
                    if (guest['contact']?.toString().isNotEmpty == true) ...[
                      const SizedBox(height: 10),
                      _MiniDetail(
                        icon: Icons.phone_outlined,
                        label: 'Contact',
                        value: guest['contact'],
                      ),
                    ],
                    if (guest['email']?.toString().isNotEmpty == true) ...[
                      const SizedBox(height: 10),
                      _MiniDetail(
                        icon: Icons.email_outlined,
                        label: 'Email',
                        value: guest['email'],
                      ),
                    ],
                    if ((raw['device_name'] ?? '').toString().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _MiniDetail(
                        icon: Icons.devices_outlined,
                        label: 'Devices',
                        value: raw['device_name'].toString(),
                      ),
                    ],

                    // Food orders — shown immediately on expand
                    OrdersSection(billFuture: billFuture),
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
// Mini Detail tile
// ─────────────────────────────────────────────────────────────────────────────

class _MiniDetail extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _MiniDetail(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: AppColors.textDisabled),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}