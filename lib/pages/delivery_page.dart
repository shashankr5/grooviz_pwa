// lib/pages/delivery_page.dart
//
// PREMIUM REDESIGN — Room Service Delivery Management
//
// Visual hierarchy: Room number is the anchor → Guest → Items → Time/Actions
// Motion: Smooth tab transitions, animated state changes, micro-interactions
// Polish: Graduated urgency colors, tailored empty states, receipt-style items
//
// Accepts optional [initialFilter] for deep-linking into Ready/Accepted/Delivered.

import 'dart:async';
import 'package:flutter/material.dart';
import '../services/home_service.dart';
import '../services/task_alert_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/date_formatter.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../services/notification_handler.dart';
import '../services/notification_constants.dart';
import '../components/skeleton_loader.dart';

// ── Shared veg helpers ────────────────────────────────────────────────────────

bool resolveIsVeg(dynamic isVegFlag) {
  if (isVegFlag == null) return false;
  final v = isVegFlag.toString().trim().toLowerCase();
  return v == '1' || v == 'true' || v == 'veg';
}

/// Premium veg/non-veg indicator — refined square with inner dot.
Widget vegIndicator(bool isVeg) {
  final c = isVeg ? AppColors.success : AppColors.error;
  return Container(
    width: 16,
    height: 16,
    decoration: BoxDecoration(
      border: Border.all(color: c, width: 2),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Center(
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────

class DeliveryPage extends StatefulWidget {
  /// Opens the page with this tab pre-selected.
  /// Defaults to 'Ready' — the most actionable state.
  final String initialFilter;

  const DeliveryPage({
    super.key,
    this.initialFilter = 'Ready',
  });

  @override
  State<DeliveryPage> createState() => _DeliveryPageState();
}

class _DeliveryPageState extends State<DeliveryPage>
    with SingleTickerProviderStateMixin {
  bool isLoading = true;
  String? errorMessage;
  late String selectedFilter;
  late TabController _tabController;

  final List<Map<String, dynamic>> readyOrders = [];
  final List<Map<String, dynamic>> acceptedOrders = [];
  final List<Map<String, dynamic>> deliveredOrders = [];
  final Set<String> _expandedTimelineOrders = <String>{};

  StreamSubscription<void>? _deliverySub;

  @override
  void initState() {
    super.initState();
    localNotifications.cancel(NotifId.delivery);
    updateGroupSummary();
    selectedFilter = widget.initialFilter;

    // Initialize TabController for smooth animated tab transitions
    final initialIndex = _filterToIndex(selectedFilter);
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: initialIndex,
    );
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() => selectedFilter = _indexToFilter(_tabController.index));
      }
    });

    _loadAllOrders();
    _deliverySub = TaskAlertService.onNewDelivery.listen((_) {
      if (mounted) _loadAllOrders();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _deliverySub?.cancel();
    super.dispose();
  }

  int _filterToIndex(String filter) {
    switch (filter) {
      case 'Ready':
        return 0;
      case 'Accepted':
        return 1;
      case 'Delivered':
        return 2;
      default:
        return 0;
    }
  }

  String _indexToFilter(int index) {
    switch (index) {
      case 0:
        return 'Ready';
      case 1:
        return 'Accepted';
      case 2:
        return 'Delivered';
      default:
        return 'Ready';
    }
  }

  // ── Data loading ──────────────────────────────────────────────────────────

  Future<void> _loadAllOrders() async {
    if (mounted) {
      setState(() {
        isLoading = readyOrders.isEmpty;
        errorMessage = null;
      });
    }
    try {
      // Load active 'Ready' tab first so UI renders immediately
      await _loadReadyOrders();
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
    // Fetch Accepted and Delivered in background without blocking screen
    _loadAcceptedOrders();
    _loadDeliveredOrders();
  }

  Future<void> _loadReadyOrders() async {
    final result = await HomeService().getReadyOrdersForRoomService();
    if (!mounted) return;
    if (result['success'] != true) {
      setState(() {
        errorMessage =
            result['message'] as String? ?? 'Unable to load orders.';
      });
      return;
    }
    final grouped = _groupOrders(
        List<Map<String, dynamic>>.from(result['orders'] as List? ?? []));
    setState(() {
      readyOrders
        ..clear()
        ..addAll(grouped.map((o) => {...o, 'uiStatus': 'Ready'}));
    });
    TaskAlertService.resetDeliveryCount(readyOrders.length);
  }

  Future<void> _loadAcceptedOrders() async {
    final result = await HomeService().getAcceptedOrdersForRoomService();
    if (!mounted) return;
    if (result['success'] != true) return;
    final grouped = _groupOrders(
        List<Map<String, dynamic>>.from(result['orders'] as List? ?? []));
    setState(() {
      acceptedOrders
        ..clear()
        ..addAll(grouped.map((o) => {...o, 'uiStatus': 'Accepted'}));
    });
  }

  Future<void> _loadDeliveredOrders() async {
    final result = await HomeService().getDeliveredOrdersForRoomService();
    if (!mounted) return;
    if (result['success'] != true) return;
    final grouped = _groupOrders(
        List<Map<String, dynamic>>.from(result['orders'] as List? ?? []));
    setState(() {
      deliveredOrders
        ..clear()
        ..addAll(grouped.map((o) => {...o, 'uiStatus': 'Delivered'}));
    });
  }

  // ── Grouping & parsing ────────────────────────────────────────────────────

  /// Parse order timestamp. Returns null (not DateTime(2000)) so callers can
  /// distinguish "no timestamp" from "very old order".
  DateTime? _parseOrderTime(String? ts) {
    if (ts == null || ts.trim().isEmpty) return null;
    try {
      String fixed = ts.trim();
      if (fixed.contains(' ') && !fixed.contains('T')) {
        fixed = fixed.replaceFirst(' ', 'T');
      }
      final parsed = DateTime.tryParse(fixed);
      return parsed;
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> _groupOrders(
      List<Map<String, dynamic>> apiOrders) {
    final Map<String, Map<String, dynamic>> grouped = {};
    for (final o in apiOrders) {
      final orderNo = o['orderNumber'];
      if (orderNo == null) continue;
      if (!grouped.containsKey(orderNo)) {
        final dt = _parseOrderTime(o['orderTime']?.toString());
        grouped[orderNo] = {
          'orderNumber': orderNo,
          'roomNumber': o['roomNumber'],
          'guestName': o['guestName'],
          'status': o['status'],
          'items': <Map<String, dynamic>>[],
          'orderTime': o['orderTime'],
          '_orderTimeDt': dt, // null when timestamp is absent/malformed
          'raw': o['raw'],
        };
      }
      (grouped[orderNo]!['items'] as List).add({
        'name': o['foodItem'],
        'qty': o['quantity'],
        'is_veg': o['raw']?['is_veg'] ?? o['is_veg'],
      });
    }

    final result = grouped.values.toList();
    // Sort newest-first. Orders with no timestamp float to end.
    result.sort((a, b) {
      final da = a['_orderTimeDt'] as DateTime?;
      final db = b['_orderTimeDt'] as DateTime?;
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });
    return result;
  }

  // ── Derived lists ─────────────────────────────────────────────────────────
  // Note: filteredOrders is kept for any future callers; _buildTabContent
  // resolves its own list independently so TabBarView children are always correct.

  List<Map<String, dynamic>> get filteredOrders {
    switch (selectedFilter) {
      case 'Ready':
        return readyOrders;
      case 'Accepted':
        return acceptedOrders;
      case 'Delivered':
        return deliveredOrders;
      default:
        return readyOrders;
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  String? _actionLoadingOrderNo;

  void _showGenericError() {
    if (!mounted) return;
    AppSnackBar.show(
        context, 'Something went wrong. Please try again.', isError: true);
  }

  Future<void> _acceptOrder(Map<String, dynamic> order) async {
    final orderNo = (order['orderNumber'] ?? '').toString();
    if (_actionLoadingOrderNo != null || orderNo.isEmpty) return;

    setState(() => _actionLoadingOrderNo = orderNo);

    try {
      final res = await HomeService().updateRoomServiceStatus(
          orderNumber: orderNo, action: 'Accept');

      if (!mounted) return;

      if (res['success'] != true && res['success'] != 1) {
        _showGenericError();
        return;
      }

      await TaskAlertService.stopOneDeliveryAlert();
      await _loadAllOrders();

      if (!mounted) return;

      // Switch tab ONLY AFTER API call succeeds and data reloads
      setState(() {
        selectedFilter = 'Accepted';
        _tabController.animateTo(1);
      });

      AppSnackBar.show(context, 'Order accepted ✅');
    } finally {
      if (mounted) setState(() => _actionLoadingOrderNo = null);
    }
  }

  Future<void> _deliverOrder(Map<String, dynamic> order) async {
    final confirm = await _showDeliverConfirmSheet(order);
    if (confirm != true) return;

    final orderNo = (order['orderNumber'] ?? '').toString();
    if (_actionLoadingOrderNo != null || orderNo.isEmpty) return;

    setState(() => _actionLoadingOrderNo = orderNo);

    try {
      final res = await HomeService().updateRoomServiceStatus(
          orderNumber: orderNo, action: 'Delivered');

      if (!mounted) return;

      if (res['success'] != true && res['success'] != 1) {
        _showGenericError();
        return;
      }

      await _loadAllOrders();

      if (!mounted) return;

      // Switch tab ONLY AFTER API call succeeds and data reloads
      setState(() {
        selectedFilter = 'Delivered';
        _tabController.animateTo(2);
      });

      AppSnackBar.show(context, 'Order delivered successfully 🎉');
    } finally {
      if (mounted) setState(() => _actionLoadingOrderNo = null);
    }
  }

  /// Premium confirmation sheet with order preview
  Future<bool?> _showDeliverConfirmSheet(Map<String, dynamic> order) {
    final roomNo = (order['roomNumber'] ?? '—').toString();
    final orderNo = (order['orderNumber'] ?? '—').toString();
    final items = order['items'] as List? ?? [];

    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Title
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.successLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.check_circle_rounded,
                        size: 24, color: AppColors.success),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Confirm Delivery',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // Order preview card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.borderLight),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('Room ',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary)),
                        Text(roomNo,
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary)),
                        const Spacer(),
                        Text('#$orderNo',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textSecondary)),
                      ],
                    ),
                    if (items.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const Divider(height: 1, color: AppColors.border),
                      const SizedBox(height: 10),
                      ...items.take(3).map<Widget>((item) {
                        final name = (item['name'] ?? '').toString();
                        final qty = item['qty'];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              Text('$qty×',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.textSecondary)),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(name,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: AppColors.textPrimary),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ],
                          ),
                        );
                      }),
                      if (items.length > 3)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('+${items.length - 3} more items',
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontStyle: FontStyle.italic,
                                  color: AppColors.textDisabled)),
                        ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // Action buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textPrimary,
                        side: const BorderSide(color: AppColors.border, width: 1.5),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Cancel',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.pop(ctx, true),
                      icon: const Icon(Icons.check_circle_rounded, size: 20),
                      label: const Text('Mark Delivered',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.success,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Formatting & Urgency ──────────────────────────────────────────────────

  String _formatDateTime(String? ts) {
    if (ts == null || ts.isEmpty) return '';
    try {
      String fixed = ts.trim();
      if (fixed.contains(' ') && !fixed.contains('T')) {
        fixed = fixed.replaceFirst(' ', 'T');
      }
      final date = DateTime.parse(fixed);
      final day = date.day.toString().padLeft(2, '0');
      final month = date.month.toString().padLeft(2, '0');
      final year = date.year;
      final hour12 = date.hour > 12
          ? date.hour - 12
          : date.hour == 0
              ? 12
              : date.hour;
      final minute = date.minute.toString().padLeft(2, '0');
      final period = date.hour >= 12 ? 'PM' : 'AM';
      return '$day/$month/$year • $hour12:$minute $period';
    } catch (_) {
      return '';
    }
  }

  /// Returns human-readable elapsed time ("5 min", "1h 12m") with urgency color.
  /// Graduated urgency: < 10min calm, 10-25min warning, > 25min urgent.
  Map<String, dynamic> _elapsedWithUrgency(DateTime? dt) {
    if (dt == null) {
      return {'text': '—', 'color': AppColors.textDisabled};
    }

    final diff = DateTime.now().difference(dt);
    final mins = diff.inMinutes;

    Color color;
    if (mins < 10) {
      color = AppColors.success; // Calm — order is fresh
    } else if (mins < 25) {
      color = AppColors.warning; // Warning — should be moving soon
    } else {
      color = AppColors.error; // Urgent — overdue
    }

    String text;
    if (mins < 60) {
      text = '$mins min';
    } else {
      final hours = diff.inHours;
      final remainingMins = mins - (hours * 60);
      text = '${hours}h ${remainingMins}m';
    }

    return {'text': text, 'color': color};
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildFilterBar(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildTabContent('Ready'),
                _buildTabContent('Accepted'),
                _buildTabContent('Delivered'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: AppColors.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Exact AppTypography.appBarTitle token — matches HomePage
          const Text('Delivery Management', style: AppTypography.appBarTitle),
          Text('Room Service Orders', style: AppTypography.appBarSubtitle),
        ],
      ),
    );
  }

  // ── Tab bar ───────────────────────────────────────────────────────────────
  //
  // FIX: The previous Row(Icon + Text + Badge) layout overflowed on narrow
  // screens because three tabs each needed ~130dp but only had ~112dp.
  //
  // Solution: vertical layout matching _KpiTile's compact column pattern.
  // Count (large) on top, label (small caps) below — exactly how the KPI
  // grid communicates status. No horizontal content to overflow.
  //
  // Design tokens sourced from KpiCommandGrid / ExecutiveHeaderCard:
  //   borderRadius: 16 (matches _KpiTile)
  //   shadow: AppColors.shadow, blurRadius 8, offset (0,3) (matches _KpiTile)
  //   AnimatedContainer 200ms (matches _KpiTile duration)
  //   border: 1px AppColors.border.withOpacity(0.5) unselected,
  //           2px accentColor selected (matches _KpiTile exactly)

  Widget _buildFilterBar() {
    final configs = [
      {
        'label': 'Ready',
        'count': readyOrders.length,
        'icon': Icons.room_service_rounded,
        'accent': AppColors.orange,
        'bg': AppColors.orangeLight,
      },
      {
        'label': 'Accepted',
        'count': acceptedOrders.length,
        'icon': Icons.delivery_dining_rounded,
        'accent': AppColors.info,
        'bg': AppColors.infoLight,
      },
      {
        'label': 'Delivered',
        'count': deliveredOrders.length,
        'icon': Icons.check_circle_rounded,
        'accent': AppColors.success,
        'bg': AppColors.successLight,
      },
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: configs.asMap().entries.map((entry) {
          final i = entry.key;
          final cfg = entry.value;
          final label = cfg['label'] as String;
          final count = cfg['count'] as int;
          final icon = cfg['icon'] as IconData;
          final accent = cfg['accent'] as Color;
          final bg = cfg['bg'] as Color;
          final isSelected = selectedFilter == label;

          return Expanded(
            child: Padding(
              // 6px gap between tiles; no outer padding (Expanded handles width)
              padding: EdgeInsets.only(
                left: i == 0 ? 0 : 4,
                right: i == 2 ? 0 : 4,
              ),
              child: GestureDetector(
                onTap: () {
                  setState(() => selectedFilter = label);
                  _tabController.animateTo(i);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    // Selected: light accent tint; unselected: white surface
                    color: isSelected
                        ? accent.withOpacity(0.08)
                        : AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isSelected
                          ? accent
                          : AppColors.border.withOpacity(0.5),
                      width: isSelected ? 2 : 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.shadow,
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Icon in tinted circle (same pattern as _KpiTile icon box)
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isSelected ? accent : bg,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          icon,
                          size: 16,
                          color: isSelected ? Colors.white : accent,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Count — dominant numeric like _KpiTile
                      Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: isSelected ? accent : AppColors.textPrimary,
                          height: 1.0,
                        ),
                      ),
                      const SizedBox(height: 3),
                      // Label — small caps, secondary
                      Text(
                        label,
                        style: AppTypography.caption.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: isSelected ? accent : AppColors.textSecondary,
                          letterSpacing: 0.4,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTabContent(String filter) {
    // Resolve the correct list for this tab regardless of selectedFilter,
    // so each TabBarView child is always independently correct.
    List<Map<String, dynamic>> orders;
    switch (filter) {
      case 'Ready':
        orders = readyOrders;
        break;
      case 'Accepted':
        orders = acceptedOrders;
        break;
      case 'Delivered':
        orders = deliveredOrders;
        break;
      default:
        orders = readyOrders;
    }

    if (isLoading) {
      return ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: 5,
        itemBuilder: (_, __) => const SkeletonFoodOrderCard(),
      );
    }

    if (errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: AppColors.error),
              const SizedBox(height: 12),
              Text(errorMessage!,
                  textAlign: TextAlign.center,
                  style: AppTypography.bodySecondary),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadAllOrders,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (orders.isEmpty) {
      return _buildEmptyState(filter);
    }

    return RefreshIndicator(
      onRefresh: _loadAllOrders,
      color: AppColors.primary,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: orders.length,
        itemBuilder: (context, index) => _buildPremiumOrderCard(orders[index]),
      ),
    );
  }

  // ── Empty states ──────────────────────────────────────────────────────────
  //
  // Pattern matches home_page.dart's _buildEscalatedList() empty state:
  //   Icon 48px, SizedBox(height:12), Text body style — same scale.
  // Icon circle matches the padding/shape used in ExecutiveHeaderCard badge.

  Widget _buildEmptyState(String filter) {
    IconData icon;
    String title;
    String subtitle;
    Color iconColor;
    Color circleBg;

    switch (filter) {
      case 'Ready':
        icon = Icons.task_alt_rounded;
        title = 'All caught up!';
        subtitle = 'No orders waiting to be accepted';
        iconColor = AppColors.success;
        circleBg = AppColors.successLight;
        break;
      case 'Accepted':
        icon = Icons.delivery_dining_rounded;
        title = 'No active deliveries';
        subtitle = 'Orders will appear here once accepted';
        iconColor = AppColors.info;
        circleBg = AppColors.infoLight;
        break;
      case 'Delivered':
        icon = Icons.check_circle_outline_rounded;
        title = 'No deliveries yet';
        subtitle = 'Completed orders will show here';
        iconColor = AppColors.textDisabled;
        circleBg = AppColors.surfaceAlt;
        break;
      default:
        icon = Icons.room_service_rounded;
        title = 'No orders';
        subtitle = '';
        iconColor = AppColors.textDisabled;
        circleBg = AppColors.surfaceAlt;
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Circle icon — same 48px icon size as home_page empty states
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: circleBg, shape: BoxShape.circle),
            child: Icon(icon, size: 48, color: iconColor),
          ),
          const SizedBox(height: 16),
          Text(title,
              style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(subtitle,
                style: AppTypography.bodySecondary,
                textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }

  /// Premium order card — Room number as visual anchor, receipt-style items,
  /// graduated urgency colors, confident action buttons
  Widget _buildPremiumOrderCard(Map<String, dynamic> order) {
    final items = order['items'] as List;
    final uiStatus = order['uiStatus'] as String;
    final guestName = (order['guestName'] ?? '').toString();
    final roomNo = (order['roomNumber'] ?? '—').toString();
    final orderNo = (order['orderNumber'] ?? '—').toString();
    final orderTime = order['orderTime'] as String?;
    final orderTimeDt = order['_orderTimeDt'] as DateTime?;

    // Color scheme per status
    Color statusColor;
    Color roomBgColor;
    Color roomTextColor;

    switch (uiStatus) {
      case 'Ready':
        statusColor = AppColors.orange;
        roomBgColor = AppColors.orangeLight;
        roomTextColor = AppColors.orange;
        break;
      case 'Accepted':
        statusColor = AppColors.info;
        roomBgColor = AppColors.infoLight;
        roomTextColor = AppColors.info;
        break;
      case 'Delivered':
        statusColor = AppColors.success;
        roomBgColor = AppColors.successLight;
        roomTextColor = AppColors.success;
        break;
      default:
        statusColor = AppColors.textDisabled;
        roomBgColor = AppColors.surfaceAlt;
        roomTextColor = AppColors.textSecondary;
    }

    // Graduated urgency for Ready orders
    final urgency = _elapsedWithUrgency(orderTimeDt);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderLight, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadow,
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row: Room badge + Status + Order# + Time ──────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Compact Room badge matching HomePage style
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: roomBgColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Room ',
                          style: TextStyle(
                              fontSize: 12,
                              color: roomTextColor.withOpacity(0.8),
                              fontWeight: FontWeight.w600)),
                      Text(
                        roomNo,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: roomTextColor),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // Status + Order# + Time column
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _statusPill(uiStatus, statusColor),
                    const SizedBox(height: 4),
                    Text(
                      '#$orderNo',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    // Formatted timestamp (DD/MM/YYYY • H:MM AM/PM)
                    if (orderTime != null && orderTime.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.access_time_rounded,
                              size: 11, color: AppColors.textSecondary),
                          const SizedBox(width: 3),
                          Text(
                            DateFormatter.formatDateTimeAmPm(orderTime),
                            style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                  ],
                ),
              ],
            ),

            // ── Guest name (if present) ───────────────────────────────────
            if (guestName.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                      color: AppColors.surfaceAlt, shape: BoxShape.circle),
                  child: const Icon(Icons.person_rounded,
                      size: 12, color: AppColors.textSecondary),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    guestName,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ],

            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Divider(height: 1, color: AppColors.borderLight),
            ),

            // ── Items header ──────────────────────────────────────────────
            const Row(children: [
              Icon(Icons.receipt_long_rounded,
                  size: 12, color: AppColors.textSecondary),
              SizedBox(width: 4),
              Text('Order Items',
                  style: TextStyle(
                      fontSize: 10,
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5)),
            ]),
            const SizedBox(height: 6),

            // ── Receipt-style items list ──────────────────────────────────
            ...items.map<Widget>((item) {
              final isVeg = resolveIsVeg(item['is_veg']);
              final name = (item['name'] ?? '').toString();
              final qty = item['qty'];
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    vegIndicator(isVeg),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                            height: 1.2),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                          color: AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(6)),
                      child: Text('×$qty',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary)),
                    ),
                  ],
                ),
              );
            }),

            const SizedBox(height: 4),
            _buildTimelineToggle(order),
            if (_expandedTimelineOrders.contains(orderNo))
              _buildDeliveryLifecycleStepper(order),

            // ── Action buttons ───────────────────────────────────────────
            const SizedBox(height: 8),
            if (uiStatus == 'Ready')
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      _actionLoadingOrderNo == orderNo ? null : () => _acceptOrder(order),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _actionLoadingOrderNo == orderNo
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_rounded, size: 16),
                            SizedBox(width: 6),
                            Text('Accept Order',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 13)),
                          ],
                        ),
                ),
              ),
            if (uiStatus == 'Accepted')
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      _actionLoadingOrderNo == orderNo ? null : () => _deliverOrder(order),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _actionLoadingOrderNo == orderNo
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.task_alt_rounded, size: 16),
                            SizedBox(width: 6),
                            Text('Mark as Delivered',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 13)),
                          ],
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineToggle(Map<String, dynamic> order) {
    final orderNo = (order['orderNumber'] ?? '').toString();
    final expanded = _expandedTimelineOrders.contains(orderNo);
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => setState(() {
          if (expanded) {
            _expandedTimelineOrders.remove(orderNo);
          } else {
            _expandedTimelineOrders.add(orderNo);
          }
        }),
        icon: Icon(
          Icons.timeline_rounded,
          size: 16,
          color: expanded ? AppColors.primary : AppColors.textSecondary,
        ),
        label: Text(expanded ? 'Hide timeline' : 'View timeline'),
        style: TextButton.styleFrom(
          foregroundColor: expanded ? AppColors.primary : AppColors.textSecondary,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  DateTime? _firstTimelineDate(Map<String, dynamic> raw, List<String> keys) {
    for (final key in keys) {
      final value = raw[key]?.toString();
      final parsed = _parseOrderTime(value);
      if (parsed != null) return parsed;
    }
    return null;
  }

  /// Delivery follows the food-order lifecycle, but begins at hand-off:
  /// Placed -> Ready for Room Service -> Accepted -> Delivered.
  /// Each timestamp is optional because older enterprise responses may not
  /// expose all history fields yet.
  Widget _buildDeliveryLifecycleStepper(Map<String, dynamic> order) {
    final raw = Map<String, dynamic>.from(order['raw'] as Map? ?? const {});
    final status = (order['uiStatus'] ?? order['status'] ?? '').toString();
    final createdAt = _firstTimelineDate(raw, const [
          'created_at', 'order_time', 'placed_time',
        ]) ??
        (order['_orderTimeDt'] as DateTime?);
    final readyAt = _firstTimelineDate(raw, const [
      'summary_ready_time', 'ready_time', 'food_ready_at', 'status_updated_time',
    ]);
    final acceptedAt = _firstTimelineDate(raw, const [
      'room_service_accepted_at', 'accepted_time', 'accepted_at',
    ]);
    final deliveredAt = _firstTimelineDate(raw, const [
      'summary_delivered_time', 'delivered_time', 'delivered_at',
    ]);

    var activeStage = 1; // Ready is the first state shown in Delivery Management.
    if (status == 'Accepted' || acceptedAt != null) activeStage = 2;
    if (status == 'Delivered' || deliveredAt != null) activeStage = 3;

    String time(DateTime? value, int stage) {
      if (value != null) return DateFormatter.formatDateTimeOnlyAmPm(value);
      return activeStage > stage ? 'Done' : (activeStage == stage ? 'Ongoing' : 'Pending');
    }

    final steps = <Map<String, dynamic>>[
      {'title': 'Placed', 'time': time(createdAt, 0), 'icon': Icons.receipt_long_rounded, 'color': AppColors.primary},
      {'title': 'Ready', 'time': time(readyAt, 1), 'icon': Icons.room_service_rounded, 'color': AppColors.orange},
      {'title': 'Accepted', 'time': time(acceptedAt, 2), 'icon': Icons.delivery_dining_rounded, 'color': AppColors.info},
      {'title': 'Delivered', 'time': time(deliveredAt, 3), 'icon': Icons.done_all_rounded, 'color': AppColors.success},
    ];

    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Delivery Timeline',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          const SizedBox(height: 14),
          Stack(
            alignment: Alignment.topCenter,
            children: [
              Positioned(
                top: 11,
                left: 28,
                right: 28,
                child: Container(height: 2, color: AppColors.borderLight),
              ),
              Positioned(
                top: 11,
                left: 28,
                right: 28,
                child: FractionallySizedBox(
                  widthFactor: (activeStage / 3).clamp(0.0, 1.0),
                  child: Container(height: 2, color: AppColors.primary),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List<Widget>.generate(steps.length, (index) {
                  final step = steps[index];
                  final done = index <= activeStage;
                  final color = step['color'] as Color;
                  return Expanded(
                    child: Column(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: done ? color : Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: done ? color : AppColors.borderLight, width: 2),
                          ),
                          child: Icon(step['icon'] as IconData,
                              size: 13, color: done ? Colors.white : AppColors.textDisabled),
                        ),
                        const SizedBox(height: 6),
                        Text(step['title'] as String,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800,
                                color: done ? AppColors.textPrimary : AppColors.textSecondary)),
                        const SizedBox(height: 2),
                        Text(step['time'] as String,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 9, color: AppColors.textSecondary),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  );
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.35), width: 1.5),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontWeight: FontWeight.w800, fontSize: 11),
      ),
    );
  }
}
