import 'package:flutter/material.dart';
import '../services/checkout_service.dart';
import '../utils/app_colors.dart';
import '../utils/app_snackbar.dart';
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

  @override
  void initState() {
    super.initState();
    _futureGuests = _loadGuests();
  }

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

  String _formatTime(String? s) {
    final d = _parseDate(s);
    if (d == null) return '—';
    final h = d.hour > 12 ? d.hour - 12 : (d.hour == 0 ? 12 : d.hour);
    final m = d.minute.toString().padLeft(2, '0');
    final period = d.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $period';
  }

  String _formatDate(String? s) {
    final d = _parseDate(s);
    if (d == null) return '—';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Map<String, dynamic> _statusStyle(String? status) {
    switch ((status ?? '').toLowerCase()) {
      case 'overdue':
        return {'color': AppColors.error, 'bg': AppColors.errorLight, 'icon': Icons.warning_amber_rounded};
      case 'checkout within 1 hour':
        return {'color': AppColors.warning, 'bg': AppColors.warningLight, 'icon': Icons.timer_rounded};
      default:
        return {'color': AppColors.info, 'bg': AppColors.infoLight, 'icon': Icons.schedule_rounded};
    }
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Colors.white,
        title: const Text(
          'Confirm Checkout',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
        ),
        content: Text(
          'Check out ${guest['guestName'] ?? 'this guest'} from Room ${guest['roomNumber'] ?? '—'}?',
          style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            child: const Text('Check Out'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      // TODO: wire up your checkout API call here
      AppSnackBar.show(context, '${guest['guestName']} checked out successfully');
      setState(() => _futureGuests = _loadGuests());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Checkout Today',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
            letterSpacing: -0.3,
          ),
        ),
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

          final guests = snap.data ?? [];
          final active = guests.where((g) => (g['raw']?['status'] ?? '') != 'Checked_out').toList();
          final checkedOut = guests.where((g) => (g['raw']?['status'] ?? '') == 'Checked_out').toList();

          if (guests.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.hotel_rounded, size: 52, color: AppColors.textDisabled),
                  SizedBox(height: 14),
                  Text(
                    'No checkouts today',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Guests checking out today will appear here',
                    style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            color: AppColors.primary,
            onRefresh: () async => setState(() => _futureGuests = _loadGuests()),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
              children: [
                if (active.isNotEmpty) ...[
                  _SectionLabel(
                    label: 'Upcoming · ${active.length}',
                    icon: Icons.schedule_rounded,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(height: 10),
                  ...active.map((g) {
                    final id = (g['guestId'] as num?)?.toInt();
                    return _GuestCard(
                      guest: g,
                      expanded: id != null && _expandedIds.contains(id),
                      billFuture: id != null ? _billFutures[id] : null,
                      onTap: () => _toggleExpand(g),
                      onCheckout: () => _onManualCheckout(g),
                      formatDate: _formatDate,
                      formatTime: _formatTime,
                      statusStyle: _statusStyle,
                    );
                  }),
                ],
                if (checkedOut.isNotEmpty) ...[
                  SizedBox(height: active.isNotEmpty ? 24 : 0),
                  _SectionLabel(
                    label: 'Checked Out Today · ${checkedOut.length}',
                    icon: Icons.check_circle_outline_rounded,
                    color: AppColors.success,
                  ),
                  const SizedBox(height: 10),
                  ...checkedOut.map((g) {
                    final id = (g['guestId'] as num?)?.toInt();
                    return _GuestCard(
                      guest: g,
                      expanded: id != null && _expandedIds.contains(id),
                      billFuture: id != null ? _billFutures[id] : null,
                      onTap: () => _toggleExpand(g),
                      onCheckout: null,
                      formatDate: _formatDate,
                      formatTime: _formatTime,
                      statusStyle: _statusStyle,
                      isCheckedOut: true,
                    );
                  }),
                ],
              ],
            ),
          );
        },
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
            letterSpacing: 0.4,
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

  final String Function(String?) formatDate;
  final String Function(String?) formatTime;
  final Map<String, dynamic> Function(String?) statusStyle;

  const _GuestCard({
    required this.guest,
    required this.expanded,
    required this.billFuture,
    required this.onTap,
    required this.onCheckout,
    required this.formatDate,
    required this.formatTime,
    required this.statusStyle,
    this.isCheckedOut = false,
  });

  String _shortStatus(String s) {
    if (s.toLowerCase().contains('within')) return '< 1 hr';
    if (s.toLowerCase() == 'overdue') return 'Overdue';
    if (s.toLowerCase() == 'checked out') return 'Done';
    return 'Upcoming';
  }

  @override
  Widget build(BuildContext context) {
    final style = statusStyle(guest['checkoutStatus']);
    final statusColor = isCheckedOut ? AppColors.success : (style['color'] as Color);
    final statusBg = isCheckedOut ? AppColors.successLight : (style['bg'] as Color);
    final statusIcon = isCheckedOut ? Icons.check_circle_rounded : (style['icon'] as IconData);
    final statusLabel = isCheckedOut ? 'Checked Out' : (guest['checkoutStatus'] ?? 'Upcoming');
    final name = (guest['guestName'] ?? 'G').toString().trim();
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
            color: expanded ? AppColors.primary.withOpacity(0.18) : AppColors.borderLight,
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
              padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
              child: Row(
                children: [
                  // Blue avatar
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

                  // Name + room + time
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
                            Text(
                              isCheckedOut
                                  ? 'Out · ${formatTime(guest['checkoutDate'])}'
                                  : 'Checkout · ${formatTime(guest['checkoutDate'])}',
                              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Status chip
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
                          _shortStatus(statusLabel),
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: statusColor),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.keyboard_arrow_down_rounded,
                        size: 20, color: AppColors.textDisabled),
                  ),
                ],
              ),
            ),

            // ── Expanded Details ────────────────────────────────────────
            if (expanded) ...[
              const Divider(height: 1, color: AppColors.borderLight),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailRow(icon: Icons.badge_outlined, label: 'Guest ID', value: '#${guest['guestId'] ?? '—'}'),
                    _DetailRow(
                      icon: Icons.phone_outlined,
                      label: 'Contact',
                      value: (guest['contact']?.toString().isNotEmpty == true) ? guest['contact'] : 'Not provided',
                    ),
                    _DetailRow(
                      icon: Icons.email_outlined,
                      label: 'Email',
                      value: (guest['email']?.toString().isNotEmpty == true) ? guest['email'] : 'Not provided',
                    ),
                    _DetailRow(icon: Icons.calendar_today_outlined, label: 'Checkout', value: formatDate(guest['checkoutDate'])),
                    if ((guest['raw']?['device_name'] ?? '').toString().isNotEmpty)
                      _DetailRow(icon: Icons.devices_outlined, label: 'Devices', value: guest['raw']['device_name'].toString()),

                    // Orders
                    OrdersSection(billFuture: billFuture),

                    // Actions
                    if (!isCheckedOut && onCheckout != null) ...[
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: onCheckout,
                          icon: const Icon(Icons.logout_rounded, size: 16),
                          label: const Text('Manual Checkout',
                              style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.1)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.success),
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
            child: const Row(
              children: [
                Icon(Icons.receipt_long_outlined, size: 16, color: AppColors.textDisabled),
                SizedBox(width: 10),
                Text('No food orders placed',
                    style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
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
            const Divider(height: 24, color: AppColors.borderLight),

            // Header
            Row(
              children: [
                const Icon(Icons.receipt_long_outlined, size: 15, color: AppColors.textSecondary),
                const SizedBox(width: 7),
                const Text(
                  'Food Orders',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
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
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.primary),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Order rows
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
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white70),
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
    final items = List<Map<String, dynamic>>.from(order['items'] ?? []);
    final total = (order['total_order_price'] as num? ?? 0).toDouble();
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
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
              ),
              const Spacer(),
              Text(
                '₹${total.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.primary),
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
                          style: const TextStyle(fontSize: 12, color: AppColors.textPrimary, fontWeight: FontWeight.w500),
                        ),
                      ),
                      Text(
                        'x${item['quantity'] ?? 1}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 56,
                        child: Text(
                          '₹${(item['total_price'] as num? ?? 0).toStringAsFixed(0)}',
                          textAlign: TextAlign.end,
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
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
            child: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}