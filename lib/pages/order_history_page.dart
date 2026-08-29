// lib/pages/order_history_page.dart
import 'package:flutter/material.dart';
import '../services/food_order_service.dart';
import '../models/order_history_analytics_model.dart';
import '../utils/order_grouping.dart';
import '../widgets/operational_metric_tile.dart';
import '../widgets/hourly_analytics_chart.dart';
import '../widgets/timeline_order_card.dart';
import '../widgets/order_history_detail_sheet.dart';
import '../theme/app_typography.dart';
import '../theme/app_colors.dart';

class OrderHistoryPage extends StatefulWidget {
  const OrderHistoryPage({super.key});

  @override
  State<OrderHistoryPage> createState() => _OrderHistoryPageState();
}

class _OrderHistoryPageState extends State<OrderHistoryPage> {
  final FoodOrderService _service = FoodOrderService();
  final TextEditingController _searchController = TextEditingController();

  bool isLoading = true;
  DateTime selectedDate = DateTime.now();
  String selectedPreset = 'Today'; // Today, Yesterday, This Week, Custom
  String selectedFilter = 'All'; // All, Delivered, Cancelled

  Map<String, dynamic> summary = {};
  List<Map<String, dynamic>> allOrders = [];
  OrderHistoryAnalyticsModel? analytics;

  bool isAnalyticsExpanded = true;
  String searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadData(date: selectedDate);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData({DateTime? date}) async {
    setState(() => isLoading = true);

    try {
      // Single v1 call — service returns all orders and filters by date
      // internally when [date] is provided. Weekly aggregates come from the
      // same response's summary object (derived from the full result set).
      final result = await _service.getOrderSummary(date: date);

      if (!mounted) return;

      if (result["success"] == true) {
        final rawRows = List<Map<String, dynamic>>.from(result["orders"] ?? []);

        // Group flat item rows into one entry per order_number — the same
        // collapsing that FoodOrdersPage does so each card represents one
        // order with all its items, not one card per menu item.
        final grouped = groupFoodOrderRows(rawRows);

        // Preserve the flattened status / display fields that analytics and
        // the timeline card expect, pulling them from the group's raw map.
        // Explicitly convert raw to Map<String, dynamic> so widgets that
        // read order['raw'] never receive a _Map<dynamic, dynamic> type error.
        allOrders = grouped.map<Map<String, dynamic>>((g) {
          final rawDynamic = g['raw'];
          final raw = rawDynamic is Map
              ? Map<String, dynamic>.from(rawDynamic)
              : <String, dynamic>{};
          final statusVal = (raw['order_status'] ?? raw['status'] ?? g['status'] ?? '').toString();
          final orderTime = raw['created_at'] ?? raw['order_time'];
          return {
            ...g,
            'raw': raw,   // always Map<String, dynamic>
            // Ensure keys that analytics + TimelineOrderCard read are present
            'orderNumber':  g['orderNo']   ?? raw['order_number'] ?? '-',
            'roomNumber':   g['room']      ?? raw['room_number']  ?? '-',
            'guestName':    g['guest']     ?? raw['guest_name']   ?? 'Guest',
            'status':       _statusText(statusVal),
            'cancelReason': g['cancelReason'] ?? raw['cancel_reason'] ?? '',
            'orderTime':    orderTime?.toString() ?? '',
            'createdAt':    g['createdAt'] ?? (orderTime != null ? DateTime.tryParse(orderTime.toString()) : null),
          };
        }).toList();

        analytics = OrderHistoryAnalyticsModel.fromOrders(allOrders);

        // Weekly summary aggregates are always present in the response,
        // regardless of the date filter applied to the orders list.
        summary["weeklyTotal"]     = result["summary"]?["weeklyTotal"]     ?? 0;
        summary["weeklyCancelled"] = result["summary"]?["weeklyCancelled"] ?? 0;
      }

      setState(() => isLoading = false);
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _selectPreset(String preset) async {
    final now = DateTime.now();
    DateTime targetDate = now;

    if (preset == 'Yesterday') {
      targetDate = now.subtract(const Duration(days: 1));
    } else if (preset == 'Custom') {
      final picked = await showDatePicker(
        context: context,
        firstDate: DateTime.now().subtract(const Duration(days: 30)),
        lastDate: DateTime.now(),
        initialDate: selectedDate,
      );
      if (picked != null) {
        targetDate = picked;
      } else {
        return;
      }
    }

    setState(() {
      selectedPreset = preset;
      selectedDate = targetDate;
    });

    await _loadData(date: targetDate);
  }

  List<Map<String, dynamic>> get _filteredOrders {
    // 1. Date Filter
    List<Map<String, dynamic>> filtered = allOrders.where((o) {
      DateTime? dt;
      try {
        final raw = o["createdAt"] ?? o["raw"]?["order_time"];
        dt = raw is DateTime ? raw : DateTime.tryParse(raw.toString());
      } catch (_) {}

      if (dt == null) return true;

      if (selectedPreset == 'This Week') {
        final now = DateTime.now();
        final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
        return dt.isAfter(startOfWeek.subtract(const Duration(days: 1)));
      }

      return dt.year == selectedDate.year &&
          dt.month == selectedDate.month &&
          dt.day == selectedDate.day;
    }).toList();

    // 2. Status Filter
    if (selectedFilter == 'Cancelled') {
      filtered = filtered
          .where((o) => (o["status"] ?? "").toString().toUpperCase() == "CANCELLED" || (o["status"] ?? "").toString().toUpperCase() == "CANCELED")
          .toList();
    } else if (selectedFilter == 'Delivered') {
      filtered = filtered
          .where((o) => (o["status"] ?? "").toString().toUpperCase() == "DELIVERED")
          .toList();
    }

    // 3. Search Query Filter
    if (searchQuery.trim().isNotEmpty) {
      final q = searchQuery.toLowerCase().trim();
      filtered = filtered.where((o) {
        final room    = (o["roomNumber"] ?? o["room"]    ?? "").toString().toLowerCase();
        final orderNo = (o["orderNumber"] ?? o["orderNo"] ?? "").toString().toLowerCase();
        final guest   = (o["guestName"]   ?? o["guest"]  ?? "").toString().toLowerCase();
        // After grouping, items is a list of {name, qty, …}. Search across all names.
        final items   = (o["items"] as List? ?? []);
        final itemMatch = items.any((i) =>
            (i["name"] ?? "").toString().toLowerCase().contains(q));
        // Fallback for ungrouped rows (legacy)
        final singleItem = (o["foodItem"] ?? o["name"] ?? "").toString().toLowerCase();

        return room.contains(q) || orderNo.contains(q) || guest.contains(q) ||
            itemMatch || singleItem.contains(q);
      }).toList();
    }

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final displayOrders = _filteredOrders;

    return Scaffold(
      backgroundColor: AppColors.bgLight,
      appBar: AppBar(
        title: const Text('Order History & Audit', style: AppTypography.appBarTitle),
        actions: [
          IconButton(
            icon: Icon(
              isAnalyticsExpanded ? Icons.analytics_rounded : Icons.analytics_outlined,
              color: AppColors.primary,
            ),
            tooltip: 'Toggle Analytics',
            onPressed: () => setState(() => isAnalyticsExpanded = !isAnalyticsExpanded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _loadData(date: selectedDate),
        color: AppColors.primary,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Search Bar
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.grey.shade200),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.02),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: (val) => setState(() => searchQuery = val),
                  decoration: InputDecoration(
                    hintText: 'Search Room #, Order ID, Guest, Item...',
                    hintStyle: const TextStyle(fontSize: 13, color: Colors.black38),
                    prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary, size: 20),
                    suffixIcon: searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => searchQuery = '');
                            },
                          )
                        : null,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // 2. Date Preset Chips Bar
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: ['Today', 'Yesterday', 'This Week', 'Custom'].map((preset) {
                    final isSelected = selectedPreset == preset;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          preset == 'Custom' && selectedPreset == 'Custom'
                              ? '${selectedDate.day}/${selectedDate.month}/${selectedDate.year}'
                              : preset,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            color: isSelected ? Colors.white : AppColors.textPrimary,
                          ),
                        ),
                        selected: isSelected,
                        selectedColor: AppColors.primary,
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            color: isSelected ? AppColors.primary : Colors.grey.shade300,
                          ),
                        ),
                        onSelected: (_) => _selectPreset(preset),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),

              // 3. KPI Metrics Carousel
              if (analytics != null) ...[
                SizedBox(
                  height: 118,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      SizedBox(
                        width: 140,
                        child: OperationalMetricTile(
                          label: 'Total Orders',
                          value: '${analytics!.totalOrders}',
                          icon: Icons.shopping_bag_outlined,
                          color: AppColors.primary,
                          subtitle: '100%',
                          isSelected: selectedFilter == 'All',
                          onTap: () => setState(() => selectedFilter = 'All'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 140,
                        child: OperationalMetricTile(
                          label: 'Kitchen SLA',
                          // Show '--' when no orders have prep data yet
                          value: analytics!.avgPrepMinutes > 0
                              ? '${analytics!.avgPrepMinutes}m'
                              : '--',
                          icon: Icons.timer_outlined,
                          color: AppColors.success,
                          // subtitle = % of orders meeting ≤15 min target
                          subtitle: analytics!.avgPrepMinutes > 0
                              ? '${analytics!.kitchenSlaPercent}% ≤15m'
                              : 'No data',
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 140,
                        child: OperationalMetricTile(
                          label: 'Delivery SLA',
                          // Show '--' when no delivered orders exist in range
                          value: analytics!.avgDeliveryMinutes > 0
                              ? '${analytics!.avgDeliveryMinutes}m'
                              : '--',
                          icon: Icons.local_shipping_outlined,
                          color: Colors.indigo,
                          subtitle: analytics!.avgDeliveryMinutes > 0
                              ? 'Avg ready→door'
                              : 'No delivered orders',
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 140,
                        child: OperationalMetricTile(
                          label: 'Cancelled',
                          value: '${analytics!.cancelledCount}',
                          icon: Icons.cancel_outlined,
                          color: AppColors.error,
                          subtitle: 'Audit',
                          isSelected: selectedFilter == 'Cancelled',
                          onTap: () => setState(() => selectedFilter = 'Cancelled'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // 4. Collapsible Hourly Peak Chart
              if (isAnalyticsExpanded && analytics != null) ...[
                HourlyAnalyticsChart(hourlyVolume: analytics!.hourlyVolume),
                const SizedBox(height: 20),
              ],

              // 5. Timeline Feed Header & Filter Chips
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${displayOrders.length} Orders Found',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: ['All', 'Delivered', 'Cancelled'].map((f) {
                      final isSelected = selectedFilter == f;
                      return Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: InkWell(
                          onTap: () => setState(() => selectedFilter = f),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: isSelected ? AppColors.primary.withValues(alpha: 0.1) : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              f,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                color: isSelected ? AppColors.primary : AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // 6. Chronological Order List
              if (isLoading)
                ...List.generate(4, (_) => _shimmerPlaceholder())
              else if (displayOrders.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: const Column(
                    children: [
                      Icon(Icons.history_toggle_off_rounded, size: 48, color: Colors.black26),
                      SizedBox(height: 12),
                      Text(
                        'No matching orders found',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                )
              else
                ...displayOrders.map(
                  (o) => TimelineOrderCard(
                    order: o,
                    onTap: () => OrderHistoryDetailSheet.show(context, o),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shimmerPlaceholder() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      height: 90,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
    );
  }

  // ── Status text normaliser (mirrors FoodOrderService._statusText) ────────
  static String _statusText(String s) {
    switch (s.trim().toUpperCase()) {
      case 'ACCEPTED':
      case 'PREPARING': return 'Preparing';
      case 'READY':     return 'Ready';
      case 'DELIVERED': return 'Delivered';
      case 'CANCELLED':
      case 'CANCELED':  return 'Cancelled';
      default:          return 'Pending';
    }
  }
}
