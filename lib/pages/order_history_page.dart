// lib/pages/order_history_page.dart
import 'package:flutter/material.dart';
import '../services/food_order_service.dart';
import '../models/order_history_analytics_model.dart';
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
      final results = await Future.wait([
        _service.getOrderSummary(date: date),
        _service.getOrderSummary(),
      ]);

      if (!mounted) return;

      final dailyResult = results[0];
      final weeklyResult = results[1];

      if (dailyResult["success"] == true) {
        final orders = List<Map<String, dynamic>>.from(dailyResult["orders"] ?? []);
        allOrders = orders;
        analytics = OrderHistoryAnalyticsModel.fromOrders(orders);
      }

      if (weeklyResult["success"] == true) {
        summary["weeklyTotal"] = weeklyResult["summary"]?["weeklyTotal"] ?? 0;
        summary["weeklyCancelled"] = weeklyResult["summary"]?["weeklyCancelled"] ?? 0;
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
        final room = (o["roomNumber"] ?? o["room"] ?? "").toString().toLowerCase();
        final orderNo = (o["orderNumber"] ?? o["orderNo"] ?? "").toString().toLowerCase();
        final guest = (o["guestName"] ?? o["guest"] ?? "").toString().toLowerCase();
        final item = (o["foodItem"] ?? o["name"] ?? "").toString().toLowerCase();

        return room.contains(q) || orderNo.contains(q) || guest.contains(q) || item.contains(q);
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
                          value: '${analytics!.avgPrepMinutes}m',
                          icon: Icons.timer_outlined,
                          color: AppColors.success,
                          subtitle: '${analytics!.kitchenSlaPercent}%',
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 140,
                        child: OperationalMetricTile(
                          label: 'Delivery SLA',
                          value: '${analytics!.avgDeliveryMinutes}m',
                          icon: Icons.local_shipping_outlined,
                          color: Colors.indigo,
                          subtitle: 'Target <15m',
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
}
