// food_orders_page.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'order_history_page.dart';
import '../services/food_order_service.dart';
import '../services/home_service.dart';
import '../utils/user_session_helper.dart';
import '../utils/food_order_status.dart';
import '../utils/date_formatter.dart';
import '../utils/app_snackbar.dart';
import '../utils/order_grouping.dart';

import '../theme/app_typography.dart';
import '../theme/app_colors.dart';
import '../components/app_badge.dart';
import '../utils/order_alert_sound.dart';
import '../services/order_alert_service.dart';
import '../services/websocket_service.dart';
import '../services/notification_handler.dart';
import '../services/notification_constants.dart';
import '../components/skeleton_loader.dart';
import '../widgets/kot_preview_sheet.dart';

class FoodOrdersPage extends StatefulWidget {
  const FoodOrdersPage({super.key});

  @override
  State<FoodOrdersPage> createState() => FoodOrdersPageState();
}

class FoodOrdersPageState extends State<FoodOrdersPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {

  void refreshData() {
    _loadFoodOrders();
  }

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

  // ── Rush Hour state (server-backed) ─────────────────────────────────────
  // These are derived from ent_dept_mapping and kept in sync via WebSocket.
  // Never set rushHourActive = true locally without calling _setRushHour().
  bool rushHourActive           = false;
  int  rushExtraMinutesSelected = 0;
  Timer?    _rushTimer;
  DateTime? _rushHourEndsAt;
  bool      _rushHourLoading = false; // prevents double-taps during API call

  // ETA tap limit from enterprise_food_service_rule (loaded from session at init)
  int _maxTapCountFromSession = 5; // safe default; overwritten in initState

  DateTime _normalizeDate(DateTime d) => DateTime(d.year, d.month, d.day);

  String   selectedFilter = 'All';
  DateTime _currentDay    = DateTime.now();

  final FoodOrderService _foodOrderService = FoodOrderService();
  final HomeService      _homeService      = HomeService();

  bool    _isLoading = true;
  bool    _hasError  = false;
  String? _errorMessage;

  StreamSubscription? _wsSubscription;
  StreamSubscription? _orderSubscription;

  final Set<String> _maxDelayReachedOrders = {};

  bool _deliveredLoaded = false;

  static const int _kMaxExtraEta = 14;

  // ====================== WEBSOCKET ======================
  Future<void> _initializeWebSocket() async {
    final ws           = WebSocketService();
    final userId       = await UserSessionHelper.getUserId();
    final enterpriseId = await UserSessionHelper.getEnterpriseId();
    ws.connect(
        userId: userId?.toString(),
        enterpriseId: enterpriseId?.toString());
    await _wsSubscription?.cancel();
    _wsSubscription = ws.stream.listen((event) {
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
          case 'ORDER_ETA_UPDATED':
            _handleSocketEtaUpdate(event['data'] ?? event);
            break;
          // ── NEW: real-time rush hour sync across devices ────────────
          case 'RUSH_HOUR_UPDATED':
            _handleSocketRushHourUpdate(event['data'] ?? event);
            break;
        }
      });
    });
  }

  void _handleSocketNewOrder(dynamic data) {
    if (data == null) return;
    try {
      final newOrders = _groupApiOrders([data]);
      if (newOrders.isEmpty) return;
      final newOrder = newOrders.first;
      if (foodOrders.any((o) => o['orderNo'] == newOrder['orderNo'])) return;
      _addNewOrder(newOrder);
      OrderAlertService.start();
    } catch (e) {
      _loadFoodOrders();
    }
  }

  void _handleSocketUpdate(dynamic data) {
    final orderNo = data['order_number']?.toString() ??
        data['orderNo']?.toString();
    if (orderNo == null || orderNo.isEmpty) return;
    final newStatus =
        (data['new_status'] ?? data['status'] ?? '').toString().toUpperCase();

    if (newStatus == 'DELIVERED') {
      OrderAlertService.stop();
      final index =
          foodOrders.indexWhere((o) => o['orderNo'].toString() == orderNo);
      if (index != -1) {
        setState(() {
          final order = foodOrders.removeAt(index);
          order['status']              = FoodOrderStatus.delivered.label;
          order['raw']['order_status'] = 'DELIVERED';
          deliveredOrders.insert(0, order);
        });
      } else {
        _loadFoodOrders();
      }
      return;
    }

    final index =
        foodOrders.indexWhere((o) => o['orderNo'].toString() == orderNo);

    if (newStatus == 'ACCEPTED') {
      if (index != -1) {
        setState(() {
          foodOrders[index]['status']              = FoodOrderStatus.preparing.label;
          foodOrders[index]['raw']['order_status'] = 'ACCEPTED';
          foodOrders[index]['acceptedAt']          = DateTime.now();
        });
      }
      _loadFoodOrders();
      return;
    }

    if (index == -1) { _loadFoodOrders(); return; }

    if (newStatus == 'CANCELLED') {
      setState(() {
        final order = foodOrders.removeAt(index);
        order['status']              = FoodOrderStatus.cancelled.label;
        order['cancelReason']        = data['cancel_reason'];
        order['raw']['order_status'] = 'CANCELLED';
        cancelledOrders.insert(0, order);
      });
      _loadFoodOrders();
      return;
    }

    setState(() {
      if (newStatus == 'READY') {
        foodOrders[index]['status']              = FoodOrderStatus.ready.label;
        foodOrders[index]['raw']['order_status'] = 'READY';
      } else if (newStatus == 'PREPARING') {
        foodOrders[index]['status']              = FoodOrderStatus.preparing.label;
        foodOrders[index]['raw']['order_status'] = 'PREPARING';
      }
    });
  }

  void _handleSocketEtaUpdate(dynamic data) {
    final orderNo = data['order_number']?.toString();
    if (orderNo == null) return;
    final index =
        foodOrders.indexWhere((o) => o['orderNo'].toString() == orderNo);
    if (index == -1) return;

    final expiresStr = data['eta_expires_at']?.toString() ?? '';
    final tapCount   = (data['eta_tap_count'] as num?)?.toInt() ?? 0;
    final locked     = data['eta_locked'] == true ||
                       data['eta_locked'] == 1    ||
                       data['eta_locked'] == '1';

    setState(() {
      if (expiresStr.isNotEmpty) {
        foodOrders[index]['etaExpiresAt'] = parseOrderDate(expiresStr);
      }
      foodOrders[index]['etaTapCount'] = tapCount;
      foodOrders[index]['etaLocked']   = locked;
      if (locked) _maxDelayReachedOrders.add(orderNo);
    });
  }

  // ── NEW: handle server-broadcast rush hour change ─────────────────────
  // Called when another device toggles rush hour — keeps all devices in sync.
  void _handleSocketRushHourUpdate(dynamic data) {
    final active  = data['rush_hour_active'] == true ||
                    data['rush_hour_active'] == 1    ||
                    data['rush_hour_active'] == '1';
    final endsAt  = data['rush_hour_ends_at']?.toString();
    final extra   = (data['rush_hour_extra_min'] as num?)?.toInt() ?? 10;

    DateTime? parsedEndsAt;
    if (active && endsAt != null && endsAt.isNotEmpty) {
      parsedEndsAt = _parseRushHourEndsAt(endsAt);
    }

    _applyRushHourState(active: active, endsAt: parsedEndsAt, extraMin: extra);
  }

  // ====================== HELPERS ======================
  bool _isValidTransition(String from, String to) {
    if (from == FoodOrderStatus.pending.label &&
        (to == FoodOrderStatus.preparing.label ||
            to == FoodOrderStatus.cancelled.label)) return true;
    if (from == FoodOrderStatus.preparing.label &&
        (to == FoodOrderStatus.ready.label ||
            to == FoodOrderStatus.cancelled.label)) return true;
    if (from == FoodOrderStatus.ready.label &&
        to == FoodOrderStatus.delivered.label) return true;
    return false;
  }

  String _rawStatus(Map<String, dynamic> order) =>
      (order["raw"]?["order_status"] ?? "").toString().toUpperCase();

  final List<String> filters = [
    'All',
    FoodOrderStatus.pending.label,
    FoodOrderStatus.preparing.label,
    FoodOrderStatus.ready.label,
    FoodOrderStatus.delivered.label,
    FoodOrderStatus.cancelled.label,
  ];

  final List<Map<String, dynamic>> foodOrders      = [];
  final List<Map<String, dynamic>> cancelledOrders = [];
  final List<Map<String, dynamic>> deliveredOrders = [];

  final List<String> cancelReasons = [
    'Item unavailable',
    'Kitchen overloaded',
    'Wrong order',
    'Guest requested cancel',
    'Other',
  ];

  int _rushExtraMinutes() => rushExtraMinutesSelected > 0 ? rushExtraMinutesSelected : 10;

  // ====================== DATA LOADING ======================
  Future<void> _loadFoodOrders() async {
    if (mounted) setState(() { _isLoading = true; _hasError = false; });
    final result = await _foodOrderService.getFoodOrders();
    if (!mounted) return;
    if (result["success"] != true) {
      setState(() {
        _hasError     = true;
        _errorMessage = result["message"] ?? "Failed to load orders";
        _isLoading    = false;
      });
      return;
    }

    final active = _groupApiOrders(result["orders"] ?? []);

    final serverCancelled =
        result["cancelledOrders"] as List<Map<String, dynamic>>? ?? [];
    final cancelled = _groupApiOrders(serverCancelled);
    for (final o in cancelled) {
      o["status"]       = FoodOrderStatus.cancelled.label;
      o["cancelReason"] = o["cancelReason"] ??
          o["raw"]?["cancel_reason"] ?? "";
    }

    active.sort((a, b) =>
        (b['createdAt'] as DateTime).compareTo(a['createdAt'] as DateTime));
    cancelled.sort((a, b) =>
        (b['createdAt'] as DateTime).compareTo(a['createdAt'] as DateTime));

    // Fetch delivered orders concurrently so All filter displays pending, preparing, ready, delivered, cancelled
    final deliveredResult = await _homeService.getDeliveredOrdersForRoomService();
    List<Map<String, dynamic>> deliveredGrouped = [];
    if (deliveredResult["success"] == true) {
      deliveredGrouped = _groupApiOrders(deliveredResult["orders"] ?? []);
      for (final o in deliveredGrouped) o["status"] = FoodOrderStatus.delivered.label;
      deliveredGrouped.sort((a, b) =>
          (b['createdAt'] as DateTime).compareTo(a['createdAt'] as DateTime));
    }

    setState(() {
      foodOrders..clear()..addAll(active);
      cancelledOrders..clear()..addAll(cancelled);
      deliveredOrders..clear()..addAll(deliveredGrouped);
      _deliveredLoaded = true;
      _isLoading = false;
    });

    final pendingCount = active
        .where((o) => o['status'] == FoodOrderStatus.pending.label)
        .length;
    OrderAlertService.resetCount(pendingCount);

    // ── Load rush hour state from server after orders are loaded ──────────
    await _loadRushHourState();
  }

  // ── NEW: fetch rush hour state from ent_dept_mapping via the service ──
  Future<void> _loadRushHourState() async {
    try {
      final result = await _foodOrderService.getRushHourState();
      if (!mounted) return;
      if (result["success"] == true) {
        final active  = result["rush_hour_active"] == true ||
                        result["rush_hour_active"] == 1    ||
                        result["rush_hour_active"] == '1';
        final endsAt  = result["rush_hour_ends_at"]?.toString();
        final extra   = (result["rush_hour_extra_min"] as num?)?.toInt() ?? 10;

        DateTime? parsedEndsAt;
        if (active && endsAt != null && endsAt.isNotEmpty) {
          parsedEndsAt = _parseRushHourEndsAt(endsAt);
          // If the server says active but the time has already passed, treat as off
          if (parsedEndsAt.isBefore(DateTime.now())) {
            _applyRushHourState(active: false);
            return;
          }
        }
        _applyRushHourState(active: active, endsAt: parsedEndsAt, extraMin: extra);
      }
    } catch (_) {
      // Non-fatal: UI stays with whatever current state is
    }
  }

  // ── NEW: central method to apply rush hour state (from server or WS) ──
  // Always go through this instead of setting rushHourActive directly.
  void _applyRushHourState({
    required bool active,
    DateTime? endsAt,
    int extraMin = 10,
  }) {
    _rushTimer?.cancel();

    if (!active) {
      if (mounted) {
        setState(() {
          rushHourActive           = false;
          rushExtraMinutesSelected = 0;
          _rushHourEndsAt          = null;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        rushHourActive           = true;
        rushExtraMinutesSelected = extraMin;
        _rushHourEndsAt          = endsAt;
      });
    }

    // Auto-deactivate locally when the timer expires
    if (endsAt != null) {
      final remaining = endsAt.difference(DateTime.now());
      if (!remaining.isNegative) {
        _rushTimer = Timer(remaining, () {
          if (mounted) {
            // Don't call the server again — it will have already expired.
            // Just update local UI; next _loadFoodOrders will re-confirm.
            _applyRushHourState(active: false);
          }
        });
      }
    }
  }

  // ── NEW: tell the server to toggle rush hour ON or OFF ─────────────────
  // Duration is now determined by the server from enterprise_food_service_rule.
  // The old 'durationMinutes' parameter has been removed.
  Future<void> _setRushHour({required bool active}) async {
    if (_rushHourLoading) return;
    if (mounted) setState(() => _rushHourLoading = true);

    try {
      final result = await _foodOrderService.setRushHour(active: active);

      if (!mounted) return;

      if (result["success"] == true) {
        final newActive = result["rush_hour_active"] == true || result["rush_hour_active"] == 1;
        _applyRushHourState(active: newActive);
        // WebSocket broadcast is done server-side; other devices update via WS.
      } else {
        _showError(result["message"]);
      }
    } catch (e) {
      if (mounted) _showError("Failed to update rush hour. Please try again.");
    } finally {
      if (mounted) setState(() => _rushHourLoading = false);
    }
  }

  void _addNewOrder(Map<String, dynamic> order) {
    setState(() {
      if (rushHourActive) {
        final extra         = _rushExtraMinutes();
        order['etaMinutes'] = (order['etaMinutes'] ?? 15) + extra;
        order['extraEta']   = extra;
      }
      foodOrders.insert(0, order);
    });
  }

  // ── _groupApiOrders ───────────────────────────────────────────────────────
  // Delegates to groupFoodOrderRows() (utils/order_grouping.dart) which is the
  // shared implementation used by EntityResolver too, so both callers can never
  // drift apart.  After grouping, this method re-applies page-level ETA lock
  // state (_maxDelayReachedOrders) which only FoodOrdersPage tracks.
  List<Map<String, dynamic>> _groupApiOrders(List apiOrders) {
    final grouped = groupFoodOrderRows(apiOrders);

    // Re-apply page-level ETA lock state that the shared utility doesn't touch.
    for (final order in grouped) {
      final orderNo = order['orderNo']?.toString() ?? '';
      if (_maxDelayReachedOrders.contains(orderNo)) {
        order['etaLocked'] = true;
      }
      if (order['etaLocked'] == true && orderNo.isNotEmpty) {
        _maxDelayReachedOrders.add(orderNo);
      }
    }

    return grouped;
  }

  Future<void> _handleFilterChange(String filter) async {
    if (selectedFilter == filter) return;
    setState(() => selectedFilter = filter);
    if (filter == FoodOrderStatus.delivered.label) {
      await _loadDeliveredOrders();
    } else if (filter == FoodOrderStatus.cancelled.label) {
      await _loadFoodOrders();
    }
  }

  Future<void> _loadDeliveredOrders() async {
    final result = await _homeService.getDeliveredOrdersForRoomService();
    if (!mounted) return;
    if (result["success"] == true) {
      final grouped = _groupApiOrders(result["orders"] ?? []);
      for (final o in grouped) o["status"] = FoodOrderStatus.delivered.label;
      grouped.sort((a, b) =>
          (b['createdAt'] as DateTime).compareTo(a['createdAt'] as DateTime));
      setState(() {
        deliveredOrders..clear()..addAll(grouped);
        _deliveredLoaded = true;
      });
    }
  }

  // ====================== INIT / DISPOSE ======================
  @override
  void initState() {
    super.initState();
    localNotifications.cancel(NotifId.foodOrder);
    updateGroupSummary();
    _initializeWebSocket();
    _loadFoodOrders(); // also calls _loadRushHourState internally
    _pulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _acceptController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350));
    _shakeAnimation = Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(parent: _acceptController, curve: Curves.easeOut));
    _delayBlinkController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
    _delayBlinkAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(
            parent: _delayBlinkController, curve: Curves.easeInOut));
    _blinkController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _blinkAnimation = Tween<double>(begin: 1.0, end: 0.2).animate(
        CurvedAnimation(parent: _blinkController, curve: Curves.easeInOut));
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      setState(() {
        if (!_normalizeDate(now)
            .isAtSameMomentAs(_normalizeDate(_currentDay))) {
          _currentDay = now;
        }
      });
    });
    WidgetsBinding.instance.addObserver(this);
    _orderSubscription = OrderAlertService.onNewOrder.listen((_) {
      if (mounted) _loadFoodOrders();
    });
    // Load max tap count from session (saved at login from enterprise_food_service_rule)
    UserSessionHelper.getMaxTapCount().then((v) {
      if (mounted && v > 0) setState(() => _maxTapCountFromSession = v);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wsSubscription?.cancel();
    _orderSubscription?.cancel();
    _timer.cancel();
    _rushTimer?.cancel();
    _pulseController.dispose();
    _delayBlinkController.dispose();
    _acceptController.dispose();
    _blinkController.dispose();
    OrderAlertSound.stop();
    super.dispose();
  }

  // Guards didChangeAppLifecycleState against notification-shade pulls.
  bool _didPause = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _didPause = true;
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (!_didPause) return; // shade pull: inactive→resumed, skip
      _didPause = false;
      _loadFoodOrders();
    }
  }

  // ====================== ETA / TIMING ======================
  int _remainingSeconds(Map<String, dynamic> order) {
    final expires = order['etaExpiresAt'] as DateTime?;
    if (expires == null) return 0;
    return expires.difference(DateTime.now()).inSeconds;
  }

  double _orderProgress(Map<String, dynamic> order) {
    final accepted = order['acceptedAt'] as DateTime?;
    final expires  = order['etaExpiresAt'] as DateTime?;
    if (accepted == null || expires == null) return 0.0;
    final total = expires.difference(accepted).inSeconds;
    if (total <= 0) return 0.0;
    return (DateTime.now().difference(accepted).inSeconds / total).clamp(0.0, 1.5);
  }

  String _etaText(Map<String, dynamic> order) {
    final status = order['status'] as String;
    if (status == FoodOrderStatus.delivered.label ||
        status == FoodOrderStatus.cancelled.label) return '';
    if (status == FoodOrderStatus.ready.label) return 'Ready';
    final sec = _remainingSeconds(order);
    if (sec >= 0) {
      return 'READY IN ${(sec ~/ 60).toString().padLeft(2, '0')}:${(sec % 60).toString().padLeft(2, '0')}';
    }
    return 'DELAYED BY ${((-sec) ~/ 60) + 1} MIN';
  }

  Color _etaColor(Map<String, dynamic> order) {
    if (order['status'] == FoodOrderStatus.ready.label) return AppColors.success;
    return _remainingSeconds(order) >= 0 ? AppColors.info : AppColors.error;
  }

  String _formattedDateTime(DateTime time) {
    return DateFormatter.formatDateTimeObjectAmPm(time);
  }

  DateTime _parseRushHourEndsAt(String s) {
    if (s.trim().isEmpty) return DateTime.now();
    try {
      var clean = s.trim().replaceFirst(' ', 'T');
      if (clean.endsWith('Z')) {
        clean = clean.substring(0, clean.length - 1);
      }
      return DateTime.parse(clean);
    } catch (_) {
      return DateTime.now();
    }
  }

  String _rushTimeLeftText() {
    if (_rushHourEndsAt == null) return '';
    final diff = _rushHourEndsAt!.difference(DateTime.now());
    if (diff.isNegative) return '0s';
    final s  = diff.inSeconds;
    final h  = s ~/ 3600;
    final mm = (s % 3600) ~/ 60;
    final ss = s % 60;
    if (h > 0) return '${h}h ${mm}m:${ss.toString().padLeft(2, '0')}';
    if (mm > 0) return '${mm}m:${ss.toString().padLeft(2, '0')}';
    return '${ss}s';
  }

  bool _isDelayedOrder(Map<String, dynamic> order) {
    final s = order['status'] as String;
    return (s == FoodOrderStatus.pending.label ||
            s == FoodOrderStatus.preparing.label) &&
        _remainingSeconds(order) < 0;
  }

  bool _isMaxDelayReached(Map<String, dynamic> order) {
    if (order['etaLocked'] == true) return true;
    final tapCount = (order['etaTapCount'] as num?)?.toInt() ?? 0;
    // Use server-configured max from enterprise_food_service_rule (via session).
    // Falls back to 5 if not configured.
    if (tapCount >= _maxTapCountFromSession && _maxTapCountFromSession > 0) return true;
    final orderNo = order['orderNo']?.toString() ?? '';
    if (_maxDelayReachedOrders.contains(orderNo)) return true;
    return (order['extraEta'] ?? 0) as int >= _kMaxExtraEta;
  }

  // ====================== MARK READY ======================
  Future<void> _markReady(Map<String, dynamic> order) async {
    if (order["raw"] == null) { _showError(null); return; }
    if (!_isValidTransition(order['status'], FoodOrderStatus.ready.label)) {
      _showError(null);
      return;
    }
    setState(() {
      order['status']  = FoodOrderStatus.ready.label;
      order['readyAt'] = DateTime.now();
    });
    final summaryId = (order['summaryId'] as num?)?.toInt() ?? 0;
    if (summaryId == 0) {
      _showError("Order ID missing. Please refresh.");
      setState(() { order['status'] = FoodOrderStatus.preparing.label; order.remove('readyAt'); });
      return;
    }
    final result = await _foodOrderService.updateFoodOrderStatus(
        summaryId: summaryId,
        status: FoodOrderStatus.ready.api);
    if (!mounted) return;
    if (result["success"] != true) {
      setState(() {
        order['status'] = FoodOrderStatus.preparing.label;
        order.remove('readyAt');
      });
      _showError(result["message"]);
    } else {
      order["raw"]["order_status"] = "READY";
      await _loadFoodOrders();
      AppSnackBar.show(context, "Order marked Ready");
    }
  }

  Future<void> _handleReadyTap(Map<String, dynamic> order) async {
    final rs = _rawStatus(order);
    if (rs == "DELIVERED" || rs == "CANCELLED") {
      _showError(null);
      await _loadFoodOrders();
      return;
    }
    if (!_isValidTransition(order['status'], FoodOrderStatus.ready.label)) {
      _showError(null);
      return;
    }
    if (order['status'] == FoodOrderStatus.ready.label) return;
    final rem = _remainingSeconds(order);
    if (rem < 0 || _orderProgress(order) < 0.75) {
      final ok = await _showReadyConfirmationSheet(order, rem);
      if (ok == true) _markReady(order);
      return;
    }
    _markReady(order);
  }

  Future<bool?> _showReadyConfirmationSheet(
      Map<String, dynamic> order, int rem) {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 16),
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: rem < 0
                      ? AppColors.errorLight
                      : AppColors.warningLight,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  rem < 0
                      ? Icons.warning_rounded
                      : Icons.check_circle_outline_rounded,
                  color: rem < 0 ? AppColors.error : AppColors.warning,
                  size: 32,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                rem < 0 ? 'Order Delayed' : 'Mark as Ready?',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                rem < 0
                    ? 'This order is delayed. Are you sure you want to mark it as Ready?'
                    : 'Is the order fully prepared and ready for delivery?',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: AppColors.border),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('No',
                          style: TextStyle(
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.success,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: const Text('Yes, Mark Ready',
                          style: TextStyle(fontWeight: FontWeight.w700)),
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

  // ====================== FILTERED ORDERS ======================
  List<Map<String, dynamic>> get _filteredOrders {
    final pending = foodOrders
        .where((o) => (o['status'] ?? '').toString().toLowerCase() == FoodOrderStatus.pending.label.toLowerCase())
        .toList()
      ..sort((a, b) =>
          (b['createdAt'] as DateTime).compareTo(a['createdAt'] as DateTime));
    final preparing = foodOrders
        .where((o) => (o['status'] ?? '').toString().toLowerCase() == FoodOrderStatus.preparing.label.toLowerCase())
        .toList()
      ..sort((a, b) =>
          ((b['acceptedAt'] ?? b['createdAt']) as DateTime)
              .compareTo((a['acceptedAt'] ?? a['createdAt']) as DateTime));
    final ready = foodOrders
        .where((o) => (o['status'] ?? '').toString().toLowerCase() == FoodOrderStatus.ready.label.toLowerCase())
        .toList()
      ..sort((a, b) =>
          (b['createdAt'] as DateTime).compareTo(a['createdAt'] as DateTime));

    final otherActive = foodOrders
        .where((o) {
          final s = (o['status'] ?? '').toString().toLowerCase();
          return s != FoodOrderStatus.pending.label.toLowerCase() &&
                 s != FoodOrderStatus.preparing.label.toLowerCase() &&
                 s != FoodOrderStatus.ready.label.toLowerCase();
        })
        .toList();

    final delivered = [...deliveredOrders]
      ..sort((a, b) =>
          (b['createdAt'] as DateTime).compareTo(a['createdAt'] as DateTime));
    final cancelled = [...cancelledOrders]
      ..sort((a, b) =>
          (b['createdAt'] as DateTime).compareTo(a['createdAt'] as DateTime));

    if (selectedFilter == FoodOrderStatus.pending.label)   return pending;
    if (selectedFilter == FoodOrderStatus.preparing.label) return preparing;
    if (selectedFilter == FoodOrderStatus.ready.label)     return ready;
    if (selectedFilter == FoodOrderStatus.delivered.label) return delivered;
    if (selectedFilter == FoodOrderStatus.cancelled.label) return cancelled;

    return [...pending, ...preparing, ...ready, ...otherActive, ...delivered, ...cancelled];
  }

  // ====================== STATUS HELPERS ======================
  Color _statusChipColor(String status) => AppColors.statusColor(status);

  static const _pending   = 'Pending';
  static const _preparing = 'Preparing';
  static const _ready     = 'Ready';
  static const _delivered = 'Delivered';
  static const _cancelled = 'Cancelled';

  bool _isVeg(dynamic isVegFlag, String name) {
    if (isVegFlag != null) {
      final v = isVegFlag.toString();
      return v == '1' || v == 'true';
    }
    return name.toLowerCase().contains('veg');
  }

  Widget _fssaiIcon(bool isVeg) {
    final c = isVeg ? AppColors.success : AppColors.error;
    return Container(
      width: 14, height: 14,
      decoration: BoxDecoration(border: Border.all(color: c, width: 1.5)),
      child: Center(
        child: Container(
          width: 6, height: 6,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
      ),
    );
  }

  // ====================== COUNTS ======================
  int get _pendingCount =>
      foodOrders.where((o) => o['status'] == FoodOrderStatus.pending.label).length;
  int get _preparingCount =>
      foodOrders.where((o) => o['status'] == FoodOrderStatus.preparing.label).length;
  int get _readyCount =>
      foodOrders.where((o) => o['status'] == FoodOrderStatus.ready.label).length;

  int _countForFilter(String filter) {
    switch (filter) {
      case 'All':
        return _pendingCount + _preparingCount + _readyCount +
               deliveredOrders.length + cancelledOrders.length;
      case _pending:    return _pendingCount;
      case _preparing:  return _preparingCount;
      case _ready:      return _readyCount;
      case _delivered:  return deliveredOrders.length;
      case _cancelled:  return cancelledOrders.length;
      default:          return 0;
    }
  }

  Widget _buildSkeletonFoodOrdersView() {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: 10,
      itemBuilder: (_, __) => const SkeletonFoodOrderCard(),
    );
  }

  // ====================== BUILD ======================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildRushHourBanner(),
          _buildFilterContainers(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(
                      color: AppColors.primary, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  "${_filteredOrders.isNotEmpty ? '${_filteredOrders.length} ' : 'No '}"
                  "${selectedFilter == 'All' ? 'Total' : selectedFilter} Orders",
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? _buildSkeletonFoodOrdersView()
                : _hasError
                    ? Center(
                        child: Text(
                          _errorMessage ?? "Something went wrong",
                          style: const TextStyle(
                              color: AppColors.error,
                              fontWeight: FontWeight.w600),
                        ),
                      )
                    : RefreshIndicator(
                        color: AppColors.primary,
                        onRefresh: _loadFoodOrders,
                        child: _filteredOrders.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: const [
                                  SizedBox(height: 120),
                                  Center(
                                    child: Column(children: [
                                      Icon(Icons.room_service_rounded,
                                          size: 48, color: Colors.black12),
                                      SizedBox(height: 12),
                                      Text("No orders here",
                                          style: TextStyle(
                                              color: AppColors.textDisabled,
                                              fontSize: 15)),
                                    ]),
                                  ),
                                ],
                              )
                            : ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding:
                                    const EdgeInsets.fromLTRB(16, 4, 16, 16),
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

  // ── APP BAR ───────────────────────────────────────────────────
  AppBar _buildAppBar() {
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Food Orders", style: AppTypography.appBarTitle),
          const Text("Manage incoming food orders in real-time",
              style: AppTypography.appBarSubtitle),
        ],
      ),
      actions: [
        IconButton(
          icon: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.bar_chart_rounded,
                color: AppColors.textPrimary, size: 20),
          ),
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => OrderHistoryPage())),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  // ── RUSH HOUR BANNER ─────────────────────────────────────────
  Widget _buildRushHourBanner() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: rushHourActive
            ? AppColors.error.withOpacity(0.08)
            : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: rushHourActive
              ? AppColors.error.withOpacity(0.3)
              : AppColors.border,
        ),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: rushHourActive
                  ? AppColors.error.withOpacity(0.15)
                  : AppColors.surfaceAlt,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.local_fire_department_rounded,
              color: rushHourActive ? AppColors.error : Colors.grey,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  rushHourActive ? "Rush Hour ON" : "Rush Hour",
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: rushHourActive
                        ? AppColors.error
                        : AppColors.textPrimary,
                  ),
                ),
                if (rushHourActive)
                  Text(
                    "+${_rushExtraMinutes()} min ETA • ${_rushTimeLeftText()} left",
                    style: TextStyle(
                        fontSize: 11,
                        color: AppColors.error.withOpacity(0.7)),
                  ),
              ],
            ),
          ),
          // Show a small spinner while the API call is in-flight
          if (_rushHourLoading)
            const SizedBox(
              width: 44, height: 24,
              child: Center(
                child: SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.error),
                ),
              ),
            )
          else
            GestureDetector(
              onTap: () => rushHourActive ? _setRushHour(active: false) : _showRushHourOptions(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 44, height: 24,
                decoration: BoxDecoration(
                  color: rushHourActive
                      ? AppColors.error
                      : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 200),
                  alignment: rushHourActive
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.all(3),
                    width: 18, height: 18,
                    decoration: const BoxDecoration(
                        color: Colors.white, shape: BoxShape.circle),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── FILTER CONTAINERS ─────────────────────────────────────────
  Widget _buildFilterContainers() {
    final filterData = [
      {'label': 'All',      'color': AppColors.primary, 'icon': Icons.all_inclusive_rounded},
      {'label': _pending,   'color': AppColors.warning,  'icon': Icons.hourglass_top_rounded},
      {'label': _preparing, 'color': AppColors.info,     'icon': Icons.restaurant_rounded},
      {'label': _ready,     'color': AppColors.success,  'icon': Icons.check_circle_rounded},
      {'label': _delivered, 'color': AppColors.teal,     'icon': Icons.local_shipping_rounded},
      {'label': _cancelled, 'color': AppColors.error,    'icon': Icons.cancel_rounded},
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 0, 0),
      child: SizedBox(
        height: 78,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: filterData.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          padding: const EdgeInsets.only(right: 16),
          itemBuilder: (_, i) {
            final f          = filterData[i];
            final label      = f['label'] as String;
            final color      = f['color'] as Color;
            final icon       = f['icon'] as IconData;
            final isSelected = selectedFilter == label;
            final count      = _countForFilter(label);

            return GestureDetector(
              onTap: () => _handleFilterChange(label),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 76,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                decoration: BoxDecoration(
                  color: isSelected ? color : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isSelected ? color : AppColors.border,
                    width: 1.5,
                  ),
                  boxShadow: isSelected
                      ? [BoxShadow(
                            color: color.withOpacity(0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 3))]
                      : [BoxShadow(
                            color: Colors.black.withOpacity(0.04),
                            blurRadius: 5,
                            offset: const Offset(0, 1))],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon,
                        color: isSelected ? Colors.white : color, size: 17),
                    const SizedBox(height: 3),
                    Text('$count',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isSelected ? Colors.white : color,
                        )),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: isSelected
                            ? Colors.white.withOpacity(0.85)
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ── ORDER CARD ────────────────────────────────────────────────
  Widget _buildOrderCard(Map<String, dynamic> order, int index) {
    final items     = order['items'] as List;
    final status    = order['status'] as String;
    final isDelayed = _isDelayedOrder(order);
    final chipColor = _statusChipColor(status);

    final instructionsList = items
        .map((i) => (i['instructions'] ?? "").toString().trim())
        .where((i) => i.isNotEmpty)
        .toSet()
        .toList();

    final bool maxDelayReached = _isMaxDelayReached(order);

    return AnimatedBuilder(
      animation: _acceptController,
      builder: (context, child) {
        final double shakeX = _acceptingIndex == index
            ? sin(_shakeAnimation.value * pi * 2) * 3
            : 0;
        return Transform.translate(offset: Offset(shakeX, 0), child: child);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 3)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: isDelayed
                            ? AppColors.error.withOpacity(0.08)
                            : Colors.indigo.shade50,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            "Room ",
                            style: TextStyle(
                              fontSize: 15,
                              color: isDelayed ? AppColors.error : Colors.indigo,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            "${order["room"]}",
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: isDelayed ? AppColors.error : Colors.indigo,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              // KOT print button right before status chip
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => KOTPreviewSheet.show(context, order),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryLight,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.print_rounded, size: 13, color: AppColors.primary),
                                      SizedBox(width: 3),
                                      Text(
                                        "KOT",
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.primary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(child: _buildStatusChip(status, chipColor)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            "#${order["orderNo"]}",
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              const Icon(Icons.calendar_today_rounded,
                                  size: 11, color: AppColors.textDisabled),
                              const SizedBox(width: 3),
                              Text(
                                _formattedDateTime(order['createdAt']),
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Guest name
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.person_rounded,
                          size: 13, color: AppColors.textSecondary),
                    ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(order['guest'],
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),

                const Divider(height: 16, color: AppColors.borderLight),

                // Items header
                const Row(
                  children: [
                    Icon(Icons.restaurant_menu_rounded,
                        size: 13, color: AppColors.textDisabled),
                    SizedBox(width: 5),
                    Text("Order Items",
                        style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textDisabled,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 7),

                // Items list
                ...items.map((i) => Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _fssaiIcon(_isVeg(i['isVeg'], i['name'] ?? '')),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(i['name'],
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text('${i['qty']}',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary)),
                      ),
                    ],
                  ),
                )),

                // Cooking instructions
                if (instructionsList.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.infoLight,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: AppColors.info.withOpacity(0.25)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_rounded,
                            color: AppColors.info, size: 14),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text("Cooking Instructions",
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.info)),
                              const SizedBox(height: 2),
                              ...instructionsList.map((ins) => Text(ins,
                                  style: const TextStyle(
                                      fontSize: 12, height: 1.4))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Cancel reason
                if (status == FoodOrderStatus.cancelled.label &&
                    order['cancelReason'] != null &&
                    (order['cancelReason'] as String).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.errorLight,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: AppColors.error.withOpacity(0.2)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.cancel_rounded,
                            color: AppColors.error, size: 14),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text("Cancelled Reason",
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.error)),
                              const SizedBox(height: 2),
                              Text(order['cancelReason'],
                                  style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 12),

                // ── ACTION BUTTONS ──────────────────────────────────────
                if (status == FoodOrderStatus.pending.label &&
                    userRole == 'Food & Beverage') ...[
                  Row(
                    children: [
                      Expanded(
                        child: _actionButton(
                          text: 'Accept Order',
                          icon: Icons.check_circle_rounded,
                          color: AppColors.success,
                          onTap: () async {
                            if (_acceptingIndex != null) return;
                            final rs = _rawStatus(order);
                            if (rs == "DELIVERED" || rs == "CANCELLED") {
                              _showError(null);
                              await _loadFoodOrders();
                              return;
                            }
                            if (order["raw"] == null) {
                              _showError(null);
                              return;
                            }
                            HapticFeedback.selectionClick();
                            final summaryId = (order['summaryId'] as num?)?.toInt() ?? 0;
                            if (summaryId == 0) {
                              _showError("Order ID missing. Please refresh.");
                              return;
                            }
                            final initialExpires = DateTime.now().add(Duration(
                                minutes: 15 + (rushHourActive ? _rushExtraMinutes() : 0)));
                            setState(() {
                              _acceptingIndex = index;
                              order["status"] = FoodOrderStatus.preparing.label;
                              order["acceptedAt"] = DateTime.now();
                              order["etaExpiresAt"] = initialExpires;
                              order["etaTapCount"] = 0;
                              order["etaLocked"] = false;
                              if (rushHourActive) {
                                final extra = _rushExtraMinutes();
                                order['etaMinutes'] =
                                    (order['etaMinutes'] ?? 15) + extra;
                                order['extraEta'] = extra;
                              }
                            });
                            final result =
                                await _foodOrderService.acceptFoodOrder(
                                    summaryId: summaryId);
                            if (!mounted) return;
                            if (result["success"] != true) {
                              setState(() {
                                order["status"] = FoodOrderStatus.pending.label;
                                order.remove("acceptedAt");
                                order.remove("etaExpiresAt");
                              });
                              _showError(result["message"]);
                            } else {
                              order["raw"]["order_status"] = "ACCEPTED";
                              await OrderAlertService.stopOne();
                              AppSnackBar.show(context, "Order accepted");
                            }
                            setState(() => _acceptingIndex = null);
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _actionButton(
                          text: 'Cancel',
                          icon: Icons.cancel_rounded,
                          color: AppColors.error,
                          onTap: () => _showCancelReasons(order),
                        ),
                      ),
                    ],
                  ),
                ] else if (status == FoodOrderStatus.preparing.label) ...[
                  Row(
                    children: [
                      Expanded(
                        child: AnimatedBuilder(
                          animation: _delayBlinkController,
                          builder: (context, _) {
                            final opacity =
                                isDelayed ? _delayBlinkAnimation.value : 1.0;
                            return Opacity(
                              opacity: opacity,
                              child: _actionButton(
                                text: _etaText(order),
                                icon: _remainingSeconds(order) >= 0
                                    ? Icons.timer_rounded
                                    : Icons.warning_rounded,
                                color: _etaColor(order),
                                onTap: () => _handleReadyTap(order),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 200),
                        opacity: maxDelayReached ? 0.3 : 1.0,
                        child: GestureDetector(
                          onTap: maxDelayReached
                              ? () => _showError(
                                  "Maximum delay reached. Cannot add more time.")
                              : () async {
                                   final summaryId = (order['summaryId'] as num?)?.toInt() ?? 0;
                                   if (summaryId == 0) {
                                     _showError("Order ID missing. Please refresh.");
                                     return;
                                   }
                                   final orderNo   = order['orderNo']?.toString() ?? '';
                                   final prevTaps  = (order['etaTapCount'] as num?)?.toInt() ?? 0;
                                   final newTaps   = prevTaps + 1;

                                   // Optimistic update
                                   setState(() {
                                     order['etaTapCount'] = newTaps;
                                     order['etaLocked']   =
                                         newTaps >= _maxTapCountFromSession &&
                                         _maxTapCountFromSession > 0;
                                     if (order['etaLocked'] == true) {
                                       _maxDelayReachedOrders.add(orderNo);
                                     }
                                   });

                                   final result = await _foodOrderService.tapEta(
                                     summaryId: summaryId,
                                   );

                                   if (!mounted) return;

                                   if (result["success"] != true) {
                                     // Roll back optimistic update
                                     setState(() {
                                       order['etaTapCount'] = prevTaps;
                                       order['etaLocked']   =
                                           prevTaps >= _maxTapCountFromSession &&
                                           _maxTapCountFromSession > 0;
                                       if (order['etaLocked'] != true) {
                                         _maxDelayReachedOrders.remove(orderNo);
                                       }
                                     });
                                     _showError(result["message"]);
                                     return;
                                   }

                                   // Apply server-confirmed tap state
                                   final serverTaps   = (result["etaTapCount"] as num?)?.toInt() ?? newTaps;
                                   final serverEtaStr = result["finalEtaTime"]?.toString() ?? '';
                                   final serverLocked = serverTaps >= _maxTapCountFromSession &&
                                                        _maxTapCountFromSession > 0;

                                   setState(() {
                                     order['etaTapCount'] = serverTaps;
                                     order['etaLocked']   = serverLocked;
                                     if (serverLocked) _maxDelayReachedOrders.add(orderNo);
                                     if (serverEtaStr.isNotEmpty) {
                                       order['etaExpiresAt'] = parseOrderDate(serverEtaStr);
                                     }
                                   });
                                 },
                          child: Container(
                            padding: const EdgeInsets.all(11),
                            decoration: BoxDecoration(
                              color: maxDelayReached
                                  ? AppColors.textDisabled
                                  : AppColors.textPrimary,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              maxDelayReached
                                  ? Icons.block_rounded
                                  : Icons.add_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── STATUS CHIP ───────────────────────────────────────────────
  Widget _buildStatusChip(String label, Color color) {
    return AppBadge(
      label: label,
      color: color,
      backgroundColor: color.withOpacity(0.1),
      small: true,
    );
  }

  Widget _actionButton({
    required String text,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(13),
          boxShadow: [
            BoxShadow(
                color: color.withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, 3)),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 15),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                text,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── MODALS ────────────────────────────────────────────────────
  // Rush hour is now toggled directly — no duration picker.
  // Duration is set server-side from enterprise_food_service_rule.
  void _showRushHourOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text('Enable Rush Hour?',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Text(
                'Rush hour duration and extra ETA are set by your enterprise configuration.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: AppColors.border),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Cancel',
                          style: TextStyle(
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _setRushHour(active: true);
                      },
                      icon: const Icon(Icons.local_fire_department_rounded,
                          size: 16, color: Colors.white),
                      label: const Text('Enable',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.error,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showCancelReasons(Map<String, dynamic> order) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text('Cancel Order',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              Text('Select a reason',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 12),
              ...cancelReasons.map((reason) => InkWell(
                onTap: () async {
                  Navigator.pop(context);
                  if (order["raw"] == null) {
                    _showError(null);
                    return;
                  }
                  final prev = order['status'];
                  setState(() {
                    order['status']       = FoodOrderStatus.cancelled.label;
                    order['cancelReason'] = reason;
                  });
                  final result =
                      await _foodOrderService.updateFoodOrderStatus(
                          summaryId:    (order['summaryId'] as num?)?.toInt() ?? 0,
                          status:       FoodOrderStatus.cancelled.api,
                          cancelReason: reason);
                  if (!mounted) return;
                  if (result["success"] != true) {
                    setState(() {
                      order['status'] = prev;
                      order.remove('cancelReason');
                    });
                    _showError(result["message"]);
                    return;
                  }
                  order["raw"]["order_status"] = "CANCELLED";
                  setState(() {
                    order["raw"]["cancel_reason"] = reason;
                    foodOrders.remove(order);
                    if (!cancelledOrders
                        .any((o) => o['orderNo'] == order['orderNo'])) {
                      cancelledOrders.insert(0, order);
                    }
                  });
                  await OrderAlertService.stopOne();
                  AppSnackBar.show(context, "Order cancelled");
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      vertical: 14, horizontal: 8),
                  decoration: BoxDecoration(
                      border: Border(
                          bottom: BorderSide(color: AppColors.borderLight))),
                  child: Row(
                    children: [
                      Container(
                        width: 8, height: 8,
                        decoration: BoxDecoration(
                          color: AppColors.error.withOpacity(0.5),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(reason,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textPrimary)),
                    ],
                  ),
                ),
              )),
            ],
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
        isError: true);
  }
}

