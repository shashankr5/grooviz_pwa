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
        elevation: 1,
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
                Expanded(child: _summaryTile('Total Orders', weeklyTotal)),
                const SizedBox(width: 12),
                Expanded(child: _summaryTile('Cancelled', weeklyCancelled, AppColors.error)),
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
                      Colors.red, // red for cancelled
                    ),
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
    final max = data
        .map((d) => _orderCountForDate(d))
        .fold<int>(1, (a, b) => a > b ? a : b);

    return _cardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Orders (This Week)',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: data.map((d) {
              final height = (_orderCountForDate(d) / max) * 80;

              return SizedBox(
                width: 30,
                child: Column(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 500),
                      height: height,
                      width: 16,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _weekLabels[d.weekday - 1],
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _orderCard(Map<String, dynamic> o) {
    final cancelled = o['status'] == 'Cancelled';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: _boxDecoration,
      child: Row(
        children: [
          Icon(Icons.room_service_outlined,
              color: cancelled ? AppColors.error : AppColors.secondary,
              ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Room ${o["roomNumber"]}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(o['guestName'],
                    style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Text(
            o['status'],
            style: TextStyle(
              fontSize: 12,
              color: cancelled ? AppColors.error : AppColors.secondary,
              fontWeight: FontWeight.bold,
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

  Widget _summaryTile(String label, int value, [Color? color]) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _boxDecoration,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: color ?? AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
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