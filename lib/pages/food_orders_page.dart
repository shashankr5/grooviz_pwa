//food_orders_page.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'order_history_page.dart';
import '../services/food_order_service.dart';
import '../services/home_service.dart';
import '../utils/user_session_helper.dart';
import '../utils/food_order_status.dart';
import '../utils/app_snackbar.dart';
import '../utils/order_alert_sound.dart';
import '../utils/app_colors.dart';
import '../services/order_alert_service.dart';
import '../services/websocket_service.dart';


class FoodOrdersPage extends StatefulWidget {
  const FoodOrdersPage({super.key});

  @override
  State<FoodOrdersPage> createState() => _FoodOrdersPageState();
}

class _FoodOrdersPageState extends State<FoodOrdersPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final String userRole = 'Food & Beverage';
  late Timer _timer;
  late AnimationController _pulseController;

  int? _acceptingIndex;
  late AnimationController _delayBlinkController;
  late Animation<double> _delayBlinkAnimation;
  late AnimationController _acceptController;
  late Animation<double> _shakeAnimation;
  late AnimationController _blinkController;
  late Animation<double> _blinkAnimation;

  bool rushHourActive = false;
  int rushExtraMinutesSelected = 0;
  Timer? _rushTimer;
  DateTime? _rushHourEndsAt;

  DateTime _normalizeDate(DateTime d) =>
      DateTime(d.year, d.month, d.day);

  String selectedFilter = 'All';
  DateTime _currentDay = DateTime.now();

  final FoodOrderService _foodOrderService = FoodOrderService();
  final HomeService _homeService = HomeService();

  //  Prevent duplicate WebSocket events
  final Set<String> _processedOrders = {};

  bool _isLoading = true;
  bool _hasError = false;
  String? _errorMessage;

  Timer? _reloadDebounce;
  bool _isReloading = false;
  bool _reloadPending = false;
  DateTime? _lastReloadTime;

  StreamSubscription? _wsSubscription;

  StreamSubscription? _orderSubscription;

  // WEBSOCKET 
  Future<void> _initializeWebSocket() async {
    final ws = WebSocketService();

    final userId = await UserSessionHelper.getUserId();
    final enterpriseId = await UserSessionHelper.getEnterpriseId();

    ws.connect(
      userId: userId?.toString(),
      enterpriseId: enterpriseId?.toString(),
    );

    await _wsSubscription?.cancel();

    _wsSubscription = ws.stream.listen(
      (event) {
        if (!mounted) return;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          final type = (event['type'] ?? '').toString().toUpperCase();

          switch (type) {
            case 'NEW_FOOD_ORDER':
              _handleSocketNewOrder(event['data'] ?? event);
              break;

            case 'ORDER_ACCEPTED':
            case 'ORDER_DELIVERED':
            case 'ORDER_STATUS_CHANGED':
            case 'ORDER_STATUS_UPDATED':
            case 'ORDER_CANCELLED':
              _handleSocketUpdate(event['data'] ?? event);
              break;
          }
        });
      },

      // ✅ NEW: handle socket errors
      onError: (error) {
        print('WebSocket error: $error');
        _scheduleReload(); // fallback sync
      },

      // ✅ NEW: auto reconnect when socket closes
      onDone: () {
        print('WebSocket closed. Reconnecting...');
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            _initializeWebSocket();
          }
        });
      },
    );
  }

  void _handleSocketNewOrder(dynamic data) {
    if (data == null) return;

    try {
      final newOrders = _groupApiOrders([data]);
      if (newOrders.isEmpty) return;

      final newOrder = newOrders.first;

      // prevent duplicates
      if (foodOrders.any((o) => o['orderNo'] == newOrder['orderNo'])) return;

      _addNewOrder(newOrder);

      // 🔥 NEW: each order increments alert count
      OrderAlertService.start();

    } catch (e) {
      print('WS new order error: $e');
      _scheduleReload(); // fallback
    }
  }

  void _handleSocketUpdate(dynamic data) {
    final orderNo =
        data['order_number']?.toString() ?? data['orderNo']?.toString();

    if (orderNo == null || orderNo.isEmpty) return;

    final newStatus =
        (data['new_status'] ?? data['status'] ?? '').toString().toUpperCase();

    // ===== DELIVERED (terminal state) =====
    if (newStatus == 'DELIVERED') {
      OrderAlertService.stop();

      final index =
          foodOrders.indexWhere((o) => o['orderNo'].toString() == orderNo);

      if (index != -1) {
        setState(() {
          final order = foodOrders.removeAt(index);
          order['status'] = FoodOrderStatus.delivered.label;
          order['raw']['order_status'] = 'DELIVERED';
          deliveredOrders.insert(0, order);
        });
      } else {
        _scheduleReload(); // fallback
      }
      return;
    }

    final index =
        foodOrders.indexWhere((o) => o['orderNo'].toString() == orderNo);

    if (index == -1) {
      _scheduleReload(); // fallback sync
      return;
    }

    // ===== ACCEPTED =====
    if (newStatus == 'ACCEPTED') {
      setState(() {
        foodOrders[index]['status'] = FoodOrderStatus.preparing.label;
        foodOrders[index]['raw']['order_status'] = 'ACCEPTED';
        foodOrders[index]['acceptedAt'] = DateTime.now();
      });

      // 🔥 decrement alert count (important fix)
      OrderAlertService.stopOne();
      return;
    }

    // ===== CANCELLED =====
    if (newStatus == 'CANCELLED') {
      setState(() {
        final order = foodOrders.removeAt(index);
        order['status'] = FoodOrderStatus.cancelled.label;
        order['cancelReason'] = data['cancel_reason'];
        order['raw']['order_status'] = 'CANCELLED';
        cancelledOrders.insert(0, order);
      });

      OrderAlertService.stopOne();
      return;
    }

    // ===== READY / PREPARING =====
    setState(() {
      if (newStatus == 'READY') {
        foodOrders[index]['status'] = FoodOrderStatus.ready.label;
        foodOrders[index]['raw']['order_status'] = 'READY';
      } else if (newStatus == 'PREPARING') {
        foodOrders[index]['status'] = FoodOrderStatus.preparing.label;
        foodOrders[index]['raw']['order_status'] = 'PREPARING';
      }
    });
  }

  void _scheduleReload() {
    _reloadPending = true;

    final now = DateTime.now();

    // ⛑ Force reload if too long since last one
    if (_lastReloadTime == null ||
        now.difference(_lastReloadTime!) > const Duration(seconds: 3)) {
      _reloadNow();
      return;
    }

    _reloadDebounce?.cancel();

    _reloadDebounce = Timer(const Duration(milliseconds: 800), () {
      _reloadNow();
    });
  }

  void _reloadNow() async {
    if (_isReloading) {
      _reloadPending = true;
      return;
    }

    _isReloading = true;
    _reloadPending = false;

    await _loadFoodOrders();

    _lastReloadTime = DateTime.now();

    _isReloading = false;

    if (_reloadPending) {
      _scheduleReload();
    }
  }

  bool _isValidTransition(String from, String to) {
    if (from == FoodOrderStatus.pending.label &&
        (to == FoodOrderStatus.preparing.label ||
            to == FoodOrderStatus.cancelled.label)) {
      return true;
    }

    if (from == FoodOrderStatus.preparing.label &&
        (to == FoodOrderStatus.ready.label ||
            to == FoodOrderStatus.cancelled.label)) {
      return true;
    }

    if (from == FoodOrderStatus.ready.label &&
        to == FoodOrderStatus.delivered.label) {
      return true;
    }

    return false;
  }

  String _rawStatus(Map<String, dynamic> order) {
    return (order["raw"]?["order_status"] ?? "").toString().toUpperCase();
  }

  final List<String> filters = [
    'All',
    FoodOrderStatus.pending.label,
    FoodOrderStatus.preparing.label,
    FoodOrderStatus.ready.label,
    FoodOrderStatus.delivered.label,
    FoodOrderStatus.cancelled.label
  ];
  final Map<DateTime, List<Map<String, dynamic>>> orderHistoryByDate = {};

  final List<Map<String, dynamic>> foodOrders = [];

  final List<Map<String, dynamic>> cancelledOrders = [];

  final List<Map<String, dynamic>> deliveredOrders = [];

  final List<String> cancelReasons = [
    'Item unavailable',
    'Kitchen overloaded',
    'Wrong order',
    'Guest requested cancel',
    'Other',
  ];

  int _rushExtraByItems(Map<String, dynamic> order) {
    final int itemCount = (order['items'] as List).length;

    if (itemCount == 1) return 3;
    if (itemCount == 2) return 5;
    if (itemCount >= 3) return 7; // you can make this 10 if needed

    return 0;
  }

  Future<void> _loadFoodOrders() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _hasError = false;
      });
    }

    final result = await _foodOrderService.getFoodOrders();

    if (!mounted) return;

    if (result["success"] != true) {
      setState(() {
        _hasError = true;
        _errorMessage = result["message"] ?? "Failed to load orders";
        _isLoading = false;
      });
      return;
    }

    final List orders = result["orders"] ?? [];

    // Convert API rows → UI cards
    final mappedOrders = _groupApiOrders(orders);

    final List<Map<String, dynamic>> activeOrders = [];
    final List<Map<String, dynamic>> delivered = [];
    final List<Map<String, dynamic>> cancelled = [];

    for (final o in mappedOrders) {
      final raw = o["raw"];
      final rawStatus =
      (raw?["order_status"] ?? "").toString().toUpperCase();

      // 🔐 Always trust backend raw status first
      if (rawStatus == "DELIVERED") {
        o["status"] = FoodOrderStatus.delivered.label;
        delivered.add(o);
        continue;
      }

      if (rawStatus == "CANCELLED") {
        o["status"] = FoodOrderStatus.cancelled.label;
        o["cancelReason"] = raw?["cancel_reason"];
        cancelled.add(o);
        continue;
      }
      // Otherwise active
      activeOrders.add(o);
    }

    setState(() {
      foodOrders
        ..clear()
        ..addAll(activeOrders);

      cancelledOrders
        ..clear()
        ..addAll(cancelled);

      _isLoading = false;
    });

    // ⬇️ load delivered from HomeService
    await _loadDeliveredOrders();
  }

  void _addNewOrder(Map<String, dynamic> order) {
    setState(() {
      if (rushHourActive) {
        order['etaMinutes'] += rushExtraMinutesSelected;
        order['extraEta'] = rushExtraMinutesSelected;

      }
      foodOrders.insert(0, order);
    });
  }

  Future<void> _loadDeliveredOrders() async {
    setState(() => _isLoading = true);

    final result = await _homeService.getDeliveredOrdersForRoomService();

    if (!mounted) return;

    if (result["success"] != true) {
      setState(() => _isLoading = false);
      return;
    }

    final List rawDelivered = result["orders"] ?? [];
    final groupedDelivered = _groupApiOrders(rawDelivered);

    for (final o in groupedDelivered) {
      o["status"] = FoodOrderStatus.delivered.label;
    }

    setState(() {
      deliveredOrders
        ..clear()
        ..addAll(groupedDelivered);

      _isLoading = false;
    });
  }

  List<Map<String, dynamic>> _groupApiOrders(List apiOrders) {
    final Map<String, Map<String, dynamic>> grouped = {};

    for (final o in apiOrders) {
      final orderNo = o["orderNumber"];
      // extract raw once
      final raw = o["raw"];
      // works for normal + delivered
      final createdTime =
          raw?["order_time"] ??
              raw?["delivered_time"] ??
              "";
      if (!grouped.containsKey(orderNo)) {
        grouped[orderNo] = {
          "orderNo": orderNo,
          "room": o["roomNumber"],
          "guest": (o["guestName"] ?? "Guest").toString(),
          "status": o["status"],
          "items": [],
          "raw": raw,
          // ✅ FIXED timestamp
          "createdAt": _safeParseDate(createdTime),
          // acceptedAt only for preparing
          "acceptedAt": o["status"] == FoodOrderStatus.preparing.label
              ? _safeParseDate(createdTime)
              : null,
          "etaMinutes": 15,
          "extraEta": 0,
          "cancelReason": o["cancelReason"],
        };
      }

      grouped[orderNo]!["items"].add({
        "name": o["foodItem"],
        "qty": o["quantity"],
        "instructions": o["cookingInstructions"],
      });
    }
    return grouped.values.toList();
  }

  Future<void> _handleFilterChange(String filter) async {
    if (selectedFilter == filter) return;

    setState(() => selectedFilter = filter);

    if (filter == FoodOrderStatus.delivered.label) {
      await _loadDeliveredOrders();
    } else if (filter == FoodOrderStatus.cancelled.label) {
      _scheduleReload();
    }
  }

  Future<void> _checkAndStopAlertIfNeeded() async {
    final hasPending = foodOrders.any(
      (o) => o['status'] == FoodOrderStatus.pending.label,
    );

    if (!hasPending) {
      await OrderAlertService.stop();
    }
  }
  

  @override
  void initState() {
    super.initState();

    _initializeWebSocket();

    _loadFoodOrders(); 

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _acceptController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );

    _shakeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _acceptController,
        curve: Curves.easeOut,
      ),
    );

    _delayBlinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _delayBlinkAnimation = Tween<double>(
      begin: 1.0,
      end: 0.9,
    ).animate(
      CurvedAnimation(
        parent: _delayBlinkController,
        curve: Curves.easeInOut,
      ),
    );

    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _blinkAnimation = Tween<double>(
      begin: 1.0,
      end: 0.2,
    ).animate(
      CurvedAnimation(
        parent: _blinkController,
        curve: Curves.easeInOut,
      ),
    );

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;

      final now = DateTime.now();
      setState(() {
        // Always rebuild to update timer display
        if (!_normalizeDate(now).isAtSameMomentAs(_normalizeDate(_currentDay))) {
          _currentDay = now;
        }
      });
    });

    WidgetsBinding.instance.addObserver(this);

    _orderSubscription = OrderAlertService.onNewOrder.listen((_) {
      if (!mounted) return;
      _scheduleReload();
    });  
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _orderSubscription?.cancel();
    _timer.cancel();
    _rushTimer?.cancel();
    _pulseController.dispose();
    _delayBlinkController.dispose();
    _acceptController.dispose();
    _blinkController.dispose();
    OrderAlertSound.stop();
    _wsSubscription?.cancel();
    super.dispose();
  }

  int _remainingSeconds(Map<String, dynamic> order) {
    final createdAt = order['createdAt'] as DateTime;
    int etaMin = order['etaMinutes'] as int;
    return createdAt
        .add(Duration(minutes: etaMin))
        .difference(DateTime.now())
        .inSeconds;
  }

  double _orderProgress(Map<String, dynamic> order) {
    final totalSeconds = (order['etaMinutes'] as int) * 60;
    if (totalSeconds <= 0) return 0;

    final elapsedSeconds =
        DateTime.now().difference(order['createdAt']).inSeconds;

    return (elapsedSeconds / totalSeconds).clamp(0.0, 1.5);
  }


  /// READY → visible ONLY in Ready filter
  Future<void> _markReady(Map<String, dynamic> order) async {
    final raw = order["raw"];
    if (raw == null) {
      _showError("Order data missing");
      return;
    }

    if (!_isValidTransition(order['status'], FoodOrderStatus.ready.label)) {
      _showError("Order cannot be marked Ready");
      return;
    }

    final previousStatus = order['status'];

    // Optimistic update
    setState(() {
      order['status'] = FoodOrderStatus.ready.label;
      order['readyAt'] = DateTime.now();
    });

    final result = await _foodOrderService.updateFoodOrderStatus(
      orderNumber: order["orderNo"],
      status: FoodOrderStatus.ready.api,
    );

    if (!mounted) return;

    if (result["success"] != true) {
      setState(() {
        order['status'] = FoodOrderStatus.preparing.label;
        order.remove('readyAt');
      });

      _showError(result["message"]);
    } else {
      // ✅ backend truth
      final backendStatus = result["data"]?["new_status"];
      if (backendStatus != null) {
        order["raw"]["order_status"] = backendStatus;
      }
      // Optional: auto move READY orders out of Preparing list
      _scheduleReload();
      AppSnackBar.show(context, "Order marked Ready");
    }
  }

  Future<void> _handleReadyTap(Map<String, dynamic> order) async {
    final rawStatus = _rawStatus(order);

    if (rawStatus == "DELIVERED" || rawStatus == "CANCELLED") {
      _showError("This order cannot be updated");
      _scheduleReload();
      return;
    }

    if (!_isValidTransition(order['status'], FoodOrderStatus.ready.label)) {
      _showError("Order cannot be marked Ready");
      return;
    }

    if (order['status'] == FoodOrderStatus.ready.label) return;

    final remaining = _remainingSeconds(order);
    final isDelayed = remaining < 0;

    // If delayed → ALWAYS confirm
    if (isDelayed) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Order Delayed'),
          content: const Text(
            'Are you sure you want to mark it as Ready?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('NO'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('YES'),
            ),
          ],
        ),
      );

      if (confirm == true) {
        _markReady(order);
      }

      return;
    }

    // 🟡 If still early (<75%) → confirm
    if (_orderProgress(order) < 0.75) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Mark order as Ready?'),
          content: const Text('Is the order fully prepared?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('NO'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('YES'),
            ),
          ],
        ),
      );

      if (confirm == true) {
        _markReady(order);
      }

      return;
    }

    // 🟢 ≥75% progress → direct
    _markReady(order);
  }

  String _formattedDateTime(DateTime time) {
    final day = time.day.toString().padLeft(2, '0');
    final month = time.month.toString().padLeft(2, '0');
    final year = time.year;

    final hour = time.hour > 12 ? time.hour - 12 : time.hour;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = time.hour >= 12 ? 'PM' : 'AM';

    return '$day/$month/$year • ${hour == 0 ? 12 : hour}:$minute $period';
  }

  DateTime _safeParseDate(String s) {
    try {
      return DateTime.parse(s.replaceFirst(' ', 'T'));
    } catch (_) {
      return DateTime.now();
    }
  }

  String _etaText(Map<String, dynamic> order) {
    final status = order['status'];

    // No ETA or delay text for Delivered or Cancelled
    if (status == FoodOrderStatus.delivered.label ||
        status == FoodOrderStatus.cancelled.label) {
      return '';
    }

    if (status == FoodOrderStatus.ready.label) return 'ORDER READY';

    final sec = _remainingSeconds(order);
    if (sec >= 0) {
      final m = sec ~/ 60;
      final s = sec % 60;
      return 'READY IN ${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }

    return 'DELAYED BY ${(-sec ~/ 60) + 1} MIN';
  }


  Color _etaColor(Map<String, dynamic> order) {
    if (order['status'] == FoodOrderStatus.ready.label) return Colors.green;
    final sec = _remainingSeconds(order);
    return sec >= 0 ? AppColors.accent : AppColors.error;
  }

  String _rushTimeLeftText() {
    if (_rushHourEndsAt == null) return '';

    final diff = _rushHourEndsAt!.difference(DateTime.now());
    if (diff.isNegative) return '0s';

    final totalSeconds = diff.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    // 1+ hours → "3h 45m:00"
    if (hours > 0) {
      return '${hours}h ${minutes}m:${seconds.toString().padLeft(2, '0')}';
    }

    // Under 1 hour → "45m:12"
    if (minutes > 0) {
      return '${minutes}m:${seconds.toString().padLeft(2, '0')}';
    }

    // Last minute → "30s"
    return '${seconds}s';
  }

  /// CORE SORTING + FILTERING LOGIC
  List<Map<String, dynamic>> get _filteredOrders {
    final pending = foodOrders
        .where((o) => o['status'] == FoodOrderStatus.pending.label)
        .toList()
      ..sort((a, b) =>
          (b['createdAt'] as DateTime).compareTo(a['createdAt'] as DateTime));

    final preparing = foodOrders
        .where((o) => o['status'] == FoodOrderStatus.preparing.label)
        .toList()
      ..sort((a, b) =>
          ((b['acceptedAt'] ?? b['createdAt']) as DateTime)
              .compareTo((a['acceptedAt'] ?? a['createdAt']) as DateTime));

    final ready = foodOrders
        .where((o) => o['status'] == FoodOrderStatus.ready.label)
        .toList()
      ..sort((a, b) =>
          (b['createdAt'] as DateTime).compareTo(a['createdAt'] as DateTime));

    final delivered = [...deliveredOrders];

    if (selectedFilter == FoodOrderStatus.pending.label) return pending;
    if (selectedFilter == FoodOrderStatus.preparing.label) return preparing;
    if (selectedFilter == FoodOrderStatus.ready.label) return ready;
    if (selectedFilter == FoodOrderStatus.delivered.label) return delivered;
    if (selectedFilter == FoodOrderStatus.cancelled.label)
      return [...cancelledOrders];

    // ALL
    return [...pending, ...preparing];
  }

  bool _isVeg(String name) => name.toLowerCase().contains('veg');

  Widget _fssaiIcon(bool isVeg) {
    final color = isVeg ? Colors.green : Colors.brown;
    return Container(
      width: 14,
      height: 14,
      decoration:
      BoxDecoration(border: Border.all(color: color, width: 1.5)),
      child: Center(
        child: Container(
          width: 6,
          height: 6,
          decoration:
          BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }

  Widget _buildRushHourBanner() {
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: rushHourActive
          ? AppColors.error.withOpacity(0.08)
          : AppColors.primaryLight,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: rushHourActive
            ? AppColors.error.withOpacity(0.3)
            : AppColors.border,
      ),
    ),
    child: Row(
      children: [
        Icon(
          Icons.local_fire_department,
          size: 18,
          color: rushHourActive
              ? AppColors.error
              : AppColors.textSecondary,
        ),
        const SizedBox(width: 8),

        Expanded(
          child: Text(
            rushHourActive
                ? 'Rush Hour ON • ${_rushTimeLeftText()} left'
                : 'Rush Hour OFF',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: rushHourActive
                  ? AppColors.error
                  : AppColors.textSecondary,
            ),
          ),
        ),

        if (rushHourActive)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.error,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              "ACTIVE",
              style: TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    ),
  );
}

  void _deactivateRushHour() {
    setState(() {
      rushHourActive = false;
      rushExtraMinutesSelected = 0;
      _rushHourEndsAt = null;
    });
    _rushTimer?.cancel();
  }

  String _formatDay(DateTime d) {
    const days = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
    return '${days[d.weekday % 7]} • ${d.day}/${d.month}';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleReload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgLight,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        automaticallyImplyLeading: true,
        title: const Text(
          'Food Orders',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart, color: AppColors.textPrimary),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => OrderHistoryPage()),
              );
            },
          ),
          IconButton(
            icon: Icon(
              Icons.local_fire_department,
              color: rushHourActive ? Colors.red : Colors.grey,
            ),
            onPressed: () {
              if (rushHourActive) {
                _deactivateRushHour();
              } else {
                _showRushHourOptions();
              }
            },
          ),
        ],
      ),      
      body: Column(
        children: [
          _buildRushHourBanner(),

          const SizedBox(height: 8),
          
          SizedBox(
            height: 56,
            child: ListView.separated(
              padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              scrollDirection: Axis.horizontal,
              itemCount: filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final f = filters[i];
                final bool isActive = selectedFilter == f;

                return GestureDetector(
                  onTap: () => _handleFilterChange(f),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: isActive ? AppColors.primary : Colors.white,
                      borderRadius: BorderRadius.circular(25),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(
                      f,
                      style: TextStyle(
                        color: isActive ? Colors.white : AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(
              child: CircularProgressIndicator(),
            )
                : _hasError
                ? Center(
              child: Text(
                _errorMessage ?? "Something went wrong",
                style: const TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
                : RefreshIndicator(
              onRefresh: _loadFoodOrders,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(), // IMPORTANT
                padding: const EdgeInsets.all(16),
                itemCount: _filteredOrders.length,
                itemBuilder: (_, i) =>
                    _buildOrderCard(_filteredOrders[i], i),
              ),
            ),

          ),
        ],
      ),
    );
  }

  Widget _buildOrderCard(Map<String, dynamic> order, int index) {
    final items = order['items'] as List;

    final bool isDelayed =
        (order['status'] == FoodOrderStatus.pending.label ||
            order['status'] == FoodOrderStatus.preparing.label) &&
            _remainingSeconds(order) < 0;

    final instructionsList = items
    .map((i) => (i['instructions'] ?? "").toString().trim())
    .where((i) => i.isNotEmpty)
    .toSet()
    .toList();


    return AnimatedBuilder(
      animation: Listenable.merge([_delayBlinkController, _acceptController]),
      builder: (context, child) {
        final double shakeX =
        _acceptingIndex == index ? sin(_shakeAnimation.value * pi * 2) * 3 : 0;

        final double glowStrength = isDelayed ? 1 + _delayBlinkController.value : 0;

        return Transform.translate(
          offset: Offset(shakeX, 0),
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: isDelayed
                ? Border(
                    left: BorderSide(
                      color: AppColors.error,
                      width: 4,
                    ),
                  )
                : null,

              boxShadow: [
                if (isDelayed)
                  BoxShadow(
                    color: AppColors.error.withOpacity(0.20 + 0.05 * glowStrength),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
              ],
            ),
            child: AnimatedScale(
              scale: isDelayed
                  ? 1.0 + (_delayBlinkController.value * 0.02) // subtle pulse
                  : 1.0,
              duration: const Duration(milliseconds: 300),

              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: child,
              ),
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min, // ← very important
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Room ${order["room"]}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        order['guest'],
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '#${order["orderNo"]}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _formattedDateTime(order['createdAt']),
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Items
            ...items.map((i) {
              final instructions =
                  (i['instructions'] ?? "").toString().trim();

              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _fssaiIcon(_isVeg(i['name'])),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            i['name'],
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${i['qty']}',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),

            const SizedBox(height: 12),

            // ✅ GROUPED COOKING INSTRUCTIONS (like Notes UI but food styled)
            if (instructionsList.isNotEmpty) ...[
              const SizedBox(height: 12),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white, // ✅ white background
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.blue.withOpacity(0.25), // ✅ light blue border
                  ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],                  
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.restaurant_menu,
                      color: Colors.blue, // ✅ blue icon
                      size: 18,
                    ),
                    const SizedBox(width: 10),

                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Cooking Instructions",
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.accent,
                            ),
                          ),
                          const SizedBox(height: 4),

                          ...instructionsList.map(
                            (ins) => Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                ins,
                                style: const TextStyle(
                                  fontSize: 14,
                                  height: 1.3,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14), // ✅ spacing before buttons
            ],

            // Cancel reason block
            if (order['status'] == FoodOrderStatus.cancelled.label &&
                order['cancelReason'] != null &&
                (order['cancelReason'] as String).isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.withOpacity(0.25)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.cancel, color: AppColors.error, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Cancelled Reason',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.red,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            order['cancelReason'],
                            style: const TextStyle(fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Action buttons area
            if (order['status'] == FoodOrderStatus.pending.label &&
                userRole == 'Food & Beverage') ...[
              Row(
                children: [
                  Expanded(
                    child: _actionBar(
                      text: 'ACCEPT',
                      color: AppColors.secondary,
                      onTap: () async {
                        if (_acceptingIndex != null) return;

                        final rawStatus = _rawStatus(order);

                        if (rawStatus == "DELIVERED" || rawStatus == "CANCELLED") {
                          _showError("This order cannot be accepted");
                          _scheduleReload();// sync with backend
                          return;
                        }

                        final raw = order["raw"];
                        if (raw == null) {
                          _showError("Order data missing");
                          return;
                        }

                        HapticFeedback.selectionClick();

                        setState(() {
                          _acceptingIndex = index;
                          order["status"] = FoodOrderStatus.preparing.label;
                          order["acceptedAt"] = DateTime.now();

                          // 🔥 silently increase ETA during rush hour
                          if (rushHourActive) {
                            final extra = _rushExtraByItems(order);

                            order['etaMinutes'] = (order['etaMinutes'] ?? 15) + extra;
                            order['extraEta'] = extra; // optional tracking
                          }
                        });

                        final result = await _foodOrderService.updateFoodOrderStatus(
                          orderNumber: order["orderNo"],
                          status: FoodOrderStatus.preparing.api,
                        );

                        if (!mounted) return;

                        if (result["success"] != true) {
                          setState(() {
                            order["status"] = FoodOrderStatus.pending.label;
                            order.remove("acceptedAt");
                          });

                          _showError(result["message"]);
                        } else {
                          // ✅ SYNC RAW STATUS FROM BACKEND
                          final backendStatus = result["data"]?["new_status"];
                          if (backendStatus != null) {
                            order["raw"]["order_status"] = backendStatus;
                          }                          
                          // STOP alert sound
                          //await OrderAlertSound.stop();
                          await OrderAlertService.stop();

                          AppSnackBar.show(context, "Order accepted");
                        }
                        setState(() => _acceptingIndex = null);
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _actionBar(
                      text: 'CANCEL',
                      color: Colors.red,
                      onTap: () => _showCancelReasons(order),
                    ),
                  ),
                ],
              ),
            ] else if (order['status'] != FoodOrderStatus.cancelled.label &&
                order['status'] != FoodOrderStatus.delivered.label) ...[
              Row(
                children: [
                  Expanded(
                    child: _actionBar(
                      text: _etaText(order),
                      color: _etaColor(order),
                      onTap: order['status'] == FoodOrderStatus.preparing.label
                          ? () => _handleReadyTap(order)
                          : null,
                    ),
                  ),
                  if (order['status'] == FoodOrderStatus.preparing.label) ...[
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: () {
                        final int currentExtra = order['extraEta'] ?? 0;

                        const int maxExtraMinutes = 14; // 7 taps × 2 mins
                        const int stepMinutes = 2;

                        if (currentExtra >= maxExtraMinutes) {
                          _showError("Maximum delay reached");
                          return;
                        }

                        setState(() {
                          order['etaMinutes'] += stepMinutes;
                          order['extraEta'] += stepMinutes;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.textPrimary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.add, color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showRushHourOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Rush Hour Duration',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            _rushOption('30 Minutes', 30),
            _rushOption('1 Hour', 60),
            _rushOption('2 Hours', 120),
            _rushOption('4 Hours', 240),
          ],
        ),
      ),
    );
  }

  Widget _rushOption(String label, int minutes) {
    return ListTile(
      title: Text(label),
      onTap: () {
        Navigator.pop(context);
        _activateRushHour(minutes);
      },
    );
  }

  void _activateRushHour(int durationMinutes) {
    setState(() {
      rushHourActive = true;
      rushExtraMinutesSelected = 5;
      _rushHourEndsAt = DateTime.now().add(
        Duration(minutes: durationMinutes),
      );
    });

    _rushTimer?.cancel();
    _rushTimer = Timer(Duration(minutes: durationMinutes), () {
      if (mounted) {
        _deactivateRushHour();
      }
    });
  }

  void _showCancelReasons(Map<String, dynamic> order) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SizedBox(
            width: double.infinity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Cancel Order',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),

                ...cancelReasons.map(
                      (reason) => InkWell(
                    onTap: () async {
                      Navigator.pop(context);

                      final raw = order["raw"];
                      if (raw == null) {
                        _showError("Order data missing");
                        return;
                      }

                      final previousStatus = order['status'];

                      // Optimistic UI update
                      setState(() {
                        order['status'] = FoodOrderStatus.cancelled.label;
                        order['cancelReason'] = reason;
                      });

                      final result =
                      await _foodOrderService.updateFoodOrderStatus(
                        orderNumber: order["orderNo"],
                        status: FoodOrderStatus.cancelled.api,
                        cancelReason: reason,
                      );

                      if (!mounted) return;

                      // Rollback if backend fails
                      if (result["success"] != true) {
                        setState(() {
                          order['status'] = previousStatus;
                          order.remove('cancelReason');
                        });

                        _showError(result["message"]);
                        return;
                      }

                      // ✅ backend truth
                      final backendStatus = result["data"]?["new_status"];
                      if (backendStatus != null) {
                        order["raw"]["order_status"] = backendStatus;
                      }
                      // Move to cancelled list
                      setState(() {
                        order["raw"]["cancel_reason"] = reason;

                        foodOrders.remove(order);
                        cancelledOrders.insert(0, order);
                      });

                      await _checkAndStopAlertIfNeeded();

                      AppSnackBar.show(context, "Order cancelled");
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: Colors.black12),
                        ),
                      ),
                      child: Text(
                        reason,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionBar({
    required String text,
    required Color color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  void _showError(String? message) {
    if (!mounted) return;

    AppSnackBar.show(
      context,
      message ?? "Something went wrong. Please try again.",
      isError: true,
    );
  }
}