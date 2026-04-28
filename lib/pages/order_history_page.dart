//order_history_page.dart
import 'package:flutter/material.dart';
import '../services/food_order_service.dart';
import '../utils/app_colors.dart';

class OrderHistoryPage extends StatefulWidget {

  const OrderHistoryPage({super.key});

  @override
  State<OrderHistoryPage> createState() => _OrderHistoryPageState();
}

class _OrderHistoryPageState extends State<OrderHistoryPage>
    with SingleTickerProviderStateMixin {

  final FoodOrderService _service = FoodOrderService();

  bool isLoading = true;
  DateTime selectedDate = DateTime.now();
  bool showCancelledOnly = false;

  Map<String, dynamic> summary = {};
  List<Map<String, dynamic>> allOrders = [];

  late AnimationController _controller;

  DateTime _normalize(DateTime d) => DateTime(d.year, d.month, d.day);
  static const List<String> _weekLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  List<DateTime> _currentWeek() {
    final today = _normalize(DateTime.now());

    // Find Monday of current week
    final monday = today.subtract(Duration(days: today.weekday - 1));

    return List.generate(7, (i) => monday.add(Duration(days: i)));
  }

  int _orderCountForDate(DateTime date) {
    return allOrders.where((o) {
      final dt = DateTime.tryParse(o["raw"]["order_time"]);
      if (dt == null) return false;

      return dt.year == date.year &&
          dt.month == date.month &&
          dt.day == date.day;
    }).length;
  }

  int get weeklyTotal => summary["weeklyTotal"] ?? 0;

  int get dailyTotal => summary["dailyTotal"] ?? 0;

  int get weeklyCancelled => summary["weeklyCancelled"] ?? 0;


  int get dailyCancelled => summary["dailyCancelled"] ?? 0;


  @override
  void initState() {
    super.initState();
    _loadSummary(date: selectedDate);
  }

  Future<void> _loadSummary({DateTime? date}) async {
    setState(() => isLoading = true);

    try {
      final results = await Future.wait([
        _service.getOrderSummary(date: date), // daily
        _service.getOrderSummary(),           // weekly
      ]);

      if (!mounted) return;

      final dailyResult = results[0];
      final weeklyResult = results[1];

      setState(() {
        summary.clear();

        // ✅ DAILY DATA
        if (dailyResult["success"] == true) {
        final orders =
            List<Map<String, dynamic>>.from(dailyResult["orders"] ?? []);

        allOrders = orders;

        // ✅ normalize selected date
        final selected = _normalize(selectedDate);

        // ✅ calculate total orders (IMPORTANT: unique orderNumber)
        final todayOrders = orders.where((o) {
          final dt = DateTime.tryParse(o["raw"]["order_time"]);
          if (dt == null) return false;

          return dt.year == selected.year &&
              dt.month == selected.month &&
              dt.day == selected.day;
        }).toList();

        // 🔥 FIX: count UNIQUE orders (not items)
        final uniqueOrderNumbers = todayOrders
            .map((o) => o["orderNumber"])
            .toSet();

        summary["dailyTotal"] = uniqueOrderNumbers.length;

        // ✅ cancelled count
        summary["dailyCancelled"] = todayOrders.where((o) {
          return (o["status"] ?? "").toString().toUpperCase() == "CANCELLED";
        }).length;
        }

        // ✅ WEEKLY DATA
        if (weeklyResult["success"] == true) {
          summary["weeklyTotal"] =
              weeklyResult["summary"]?["weeklyTotal"] ?? 0;

          summary["weeklyCancelled"] =
              weeklyResult["summary"]?["weeklyCancelled"] ?? 0;
        }

        isLoading = false;
      });
    } catch (e) {
      setState(() => isLoading = false);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now(),
      initialDate: selectedDate,
    );

    if (picked != null) {
      selectedDate = picked;
      showCancelledOnly = false;
      await _loadSummary(date: picked);
    }
  }

  @override
  Widget build(BuildContext context) {

    final filteredByDate = allOrders.where((o) {
      final dt = DateTime.tryParse(o["raw"]["order_time"]);
      if (dt == null) return false;

      return dt.year == selectedDate.year &&
          dt.month == selectedDate.month &&
          dt.day == selectedDate.day;
    }).toList();

    final orders = showCancelledOnly
        ? filteredByDate.where((o) =>
    (o["status"] ?? "").toString().toUpperCase() == "CANCELLED"
    ).toList()
        : filteredByDate;


    return Scaffold(
      backgroundColor: AppColors.bgLight,
      appBar: AppBar(
        title: const Text(
          'Order History',
          style: TextStyle(color: AppColors.textPrimary),
        ),        
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 2,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            /// WEEKLY SUMMARY
            const Text(
              'Weekly Summary',
              style: TextStyle(
                fontSize: 17, 
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
                ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _summaryTile(
                  'Total Orders',
                  weeklyTotal,
                  icon: Icons.shopping_bag_outlined,
                  color: AppColors.primary,
                )),
                const SizedBox(width: 12),
                Expanded(child: _summaryTile(
                  'Cancelled',
                  weeklyCancelled,
                  icon: Icons.cancel_outlined,
                  color: AppColors.error,
                )),
              ],
            ),

            const SizedBox(height: 20),
            _weeklyBarChart(),
            const SizedBox(height: 28),

            /// DATE PICKER
            GestureDetector(
              onTap: _pickDate,
              child: _cardContainer(
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today_outlined, size: 18, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Text(
                      '${selectedDate.day}/${selectedDate.month}/${selectedDate.year}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                    const Spacer(),
                    const Icon(Icons.chevron_right, color: AppColors.textSecondary),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            /// TODAY SUMMARY
            const Text(
              "Today's Summary",
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            /// TODAY'S SUMMARY (50:50, like weekly)
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => showCancelledOnly = false),
                    child: _summaryTile(
                      'Total Orders',
                      dailyTotal,
                      icon: Icons.shopping_bag_outlined,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 12), // optional gap
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => showCancelledOnly = true),
                    child: _summaryTile(
                      'Cancelled',
                      dailyCancelled,
                      icon: Icons.cancel_outlined,
                      color: AppColors.error,
                    )
                  ),
                ),
              ],
            ),


            const SizedBox(height: 24),

            /// ORDERS LIST
            Text(
              showCancelledOnly ? 'Cancelled Orders' : "Today's Orders",
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            if (isLoading)
              ...List.generate(3, (_) => _shimmerCard())
            else if (orders.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No orders available',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              )
            else
              ...orders.map(
                    (o) => GestureDetector(
                  onTap: () => _showOrderDetails(o),
                  child: _orderCard(o),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// ================== ORDER DETAILS ==================

  void _showOrderDetails(Map<String, dynamic> o) {
    final orderedAt = DateTime.tryParse(o["raw"]["order_time"]);
    final cancelledReason = o['cancelReason'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Order Details',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            _detailRow('Room', o['roomNumber'].toString()),
            _detailRow('Guest', o['guestName']),
            _detailRow('Status', o['status']),

            if (orderedAt != null)
              _detailRow('Order Time', _formatTime(orderedAt)),

            // ✅ item-level info (summary API is flat)
            _detailRow('Item', o['foodItem']),
            _detailRow('Quantity', o['quantity'].toString()),

            // ✅ cancellation reason (only if cancelled)
            if (o['status'] == 'Cancelled' && cancelledReason != null)
              _detailRow('Reason', cancelledReason.toString()),
          ],
        ),
      ),
    );
  }

  DateTime? _parseDate(dynamic value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  String _formatTime(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  /// ================== UI HELPERS ==================

  Widget _weeklyBarChart() {
    final data = _currentWeek();
    final counts = data.map((d) => _orderCountForDate(d)).toList();
    final max = counts.fold<int>(1, (a, b) => a > b ? a : b);
    final today = _normalize(DateTime.now());

    return _cardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Orders (This Week)',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: List.generate(data.length, (i) {
              final d = data[i];
              final count = counts[i];
              final isToday = _normalize(d) == today;

              final barHeight =
                  max > 0 ? (count / max) * 80.0 : 4.0;

              return Expanded(
                child: Column(
                  children: [
                    // 🔼 FIXED HEIGHT BAR AREA
                    SizedBox(
                      height: 110, // 🔥 IMPORTANT: fixed height
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (count > 0)
                            Text(
                              '$count',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isToday
                                    ? AppColors.primary
                                    : AppColors.textSecondary,
                              ),
                            ),
                          const SizedBox(height: 4),
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 500),
                            height: barHeight.clamp(4.0, 90.0),
                            width: 18,
                            decoration: BoxDecoration(
                              color: isToday
                                  ? AppColors.primary
                                  : AppColors.primary.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // 🔽 LABEL (fixed baseline)
                    const SizedBox(height: 6),
                    Text(
                      _weekLabels[d.weekday - 1],
                      style: TextStyle(
                        fontSize: 12,
                        color: isToday
                            ? AppColors.primary
                            : AppColors.textSecondary,
                        fontWeight:
                            isToday ? FontWeight.w700 : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _orderCard(Map<String, dynamic> o) {
    final status = (o['status'] ?? '').toString().toLowerCase();

    final isCancelled = status == 'cancelled';
    final isDelivered = status == 'delivered';

    final color = isCancelled
        ? AppColors.error
        : isDelivered
            ? AppColors.secondary
            : Colors.orange;

    final orderedAt = DateTime.tryParse(o["raw"]["order_time"] ?? "");

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: _boxDecoration,
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.room_service_outlined, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Room ${o["roomNumber"]}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  o['guestName'] ?? '',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
                if (orderedAt != null)
                  Text(
                    _formatTime(orderedAt),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              o['status'],
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(color: Colors.grey)),
          ),
          Expanded(
            child: Text(value,
                style:
                const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _summaryTile(
    String label,
    int value, {
    IconData? icon,
    Color? color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _boxDecoration,
      child: Row(
        children: [
          if (icon != null)
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: (color ?? AppColors.primary).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color ?? AppColors.primary, size: 20),
            ),
          if (icon != null) const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$value',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: color ?? AppColors.textPrimary,
                ),
              ),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _shimmerCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      height: 70,
      decoration: _boxDecoration.copyWith(
        color: Colors.grey.shade300,
      ),
    );
  }

  Widget _cardContainer({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _boxDecoration,
      child: child,
    );
  }

  BoxDecoration get _boxDecoration => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: AppColors.border),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.03),
        blurRadius: 8,
      ),
    ],
  );
}