// lib/pages/delivery_page.dart
//
// PREMIUM REDESIGN — Room Service Delivery Management
//
// Visual hierarchy: Room number is the anchor → Guest → Items → Time/Actions
// Motion: Smooth tab transitions, animated state changes, micro-interactions
// Polish: Graduated urgency colors, tailored empty states, receipt-style items
//
// Accepts optional [initialFilter] for deep-linking into Ready/Accepted/Delivered.
//
// DATA SOURCES (dual-source approach):
//  • Ready tab   → FoodOrderService.getFoodOrders() (status == "Ready")
//    This is the authoritative source for orders waiting for delivery acceptance.
//  • Accepted tab → TaskService.getAllServices() service requests with status "In Progress"
//    filtered by question starting with "Food order #..."
//  • Delivered tab → Same service requests with status "Closed"
//
// Both APIs are fetched in parallel. This ensures Ready orders always appear
// regardless of whether food_order_summary_id is present in the service request rows.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/task_service.dart';
import '../services/food_order_service.dart';
import '../services/order_alert_service.dart';
import '../services/task_alert_service.dart';
import '../services/alert_reload_coordinator.dart';
import '../services/notification_constants.dart';
import '../utils/order_grouping.dart';
import '../utils/app_snackbar.dart';
import '../utils/date_formatter.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../components/skeleton_loader.dart';

// ── Shared veg helpers ────────────────────────────────────────────────────────

bool resolveIsVeg(dynamic isVegFlag, [String name = '']) {
  if (isVegFlag == null) {
    final lowerName = name.toLowerCase();
    return lowerName.contains('veg') &&
        !lowerName.contains('non-veg') &&
        !lowerName.contains('non veg') &&
        !lowerName.contains('nonveg');
  }
  final v = isVegFlag.toString().trim().toLowerCase();
  if (v == '1' || v == 'true' || v == 'veg') return true;
  if (v == '0' || v == 'false' || v == 'non-veg' || v == 'nonveg') {
    return false;
  }
  return false;
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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool isLoading = true;
  String? errorMessage;
  late String selectedFilter;
  late TabController _tabController;
  bool _didPause = false;

  final List<Map<String, dynamic>> readyOrders = [];
  final List<Map<String, dynamic>> acceptedOrders = [];
  final List<Map<String, dynamic>> deliveredOrders = [];
  final Set<String> _expandedTimelineOrders = <String>{};

  StreamSubscription<void>? _deliverySub;
  StreamSubscription<void>? _foodOrderSub;

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
    WidgetsBinding.instance.addObserver(this);
    _deliverySub = TaskAlertService.onNewDelivery.listen((_) {
      if (mounted) _loadAllOrders();
    });
    // ORDER_DELIVERED fires notifyNewFoodOrder() — catch it here so the
    // Delivered tab updates automatically on all devices.
    _foodOrderSub = OrderAlertService.onNewOrder.listen((_) {
      if (mounted) _loadAllOrders();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _deliverySub?.cancel();
    _foodOrderSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _didPause = true;
      return;
    }
    if (state == AppLifecycleState.resumed && mounted) {
      if (!_didPause) return;
      _didPause = false;
      _loadAllOrders();
    }
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

  // ── Non-zero int resolver ────────────────────────────────────────────────
  int? _nonZeroInt(dynamic v) {
    if (v == null) return null;
    final n = v is int ? v : int.tryParse(v.toString());
    if (n == null || n <= 0) return null;
    return n;
  }

  // ── Parse order time ──────────────────────────────────────────────────────
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

  // ── Build order from service request ──────────────────────────────────────
  Map<String, dynamic> _buildOrderFromServiceRequest(Map<String, dynamic> sr) {
    final foodSummaryId = _nonZeroInt(sr['food_order_summary_id']);
    final srId = _nonZeroInt(sr['service_request_id']);
    final srStatus = (sr['status'] ?? 'Open').toString().toLowerCase();

    // Extract food order details from service request fields
    // The service request contains food order data in its fields
    final roomNo = (sr['room_number'] ?? sr['requested_room'] ?? '—').toString();
    final guestName = (sr['guest_name'] ?? sr['name'] ?? 'Guest').toString();
    final guestPhone = (sr['customer_number'] ?? sr['sender'] ?? '').toString();
    final question = (sr['question'] ?? '').toString();

    // Parse items from order_items_json if available
    List<Map<String, dynamic>> items = [];
    final orderItemsJson = sr['order_items_json'];
    if (orderItemsJson != null) {
      try {
        final decoded = orderItemsJson is String
            ? jsonDecode(orderItemsJson)
            : orderItemsJson;
        if (decoded is List) {
          items = decoded.whereType<Map>().map((e) {
            final itemName = (e['food_name'] ?? e['name'] ?? 'Item').toString();
            return {
              'name': itemName,
              'qty': e['quantity'] ?? e['qty'] ?? 1,
              'price': e['price'] ?? e['total_price'] ?? 0,
              'is_veg': e['is_veg'] ?? e['isVeg'],
            };
          }).toList();
        }
      } catch (_) {}
    }

    // If no items from JSON, create a default item from the question
    if (items.isEmpty && question.isNotEmpty) {
      items.add({
        'name': question.replaceFirst(RegExp(r'^Food order #\w+ is ready for delivery to room \w+\.?\s*'), ''),
        'qty': 1,
        'price': 0,
        'is_veg': null,
      });
    }

    // Resolve order number: prefer food_order_number from the joined summary,
    // then extract from the question field, then fall back to SR-id.
    String orderNumber = (sr['food_order_number'] ?? sr['order_number'] ?? '').toString().trim();
    if (orderNumber.isEmpty) {
      final match = RegExp(r'Food order #(\S+)', caseSensitive: false).firstMatch(question);
      orderNumber = match?.group(1)?.replaceAll(RegExp(r'[.,;:!?]+$'), '') ?? 'SR-$srId';
    }
    final createdAt = sr['created_at'] ?? sr['timestamp'];

    // Determine UI status based on SR status
    String uiStatus;
    if (srStatus == 'closed' || srStatus == 'delivered') {
      uiStatus = 'Delivered';
    } else if (srStatus == 'in progress') {
      uiStatus = 'Accepted';
    } else {
      uiStatus = 'Ready';
    }

    return {
      'summaryId': foodSummaryId,
      'serviceRequestId': srId,
      'orderNumber': orderNumber,
      'roomNumber': roomNo,
      'guestName': guestName,
      'guestPhone': guestPhone,
      'items': items,
      'totalAmount': sr['grand_total'] ?? 0,
      'uiStatus': uiStatus,
      'status': srStatus,
      'orderTime': createdAt?.toString(),
      '_orderTimeDt': _parseOrderTime(createdAt?.toString()),
      'raw': Map<String, dynamic>.from(sr),
      'accepted_at': sr['accepted_at'],
      'accepted_by_user_name': sr['accepted_by_user_name'],
      'assigned_to': sr['assigned_to'],
    };
  }

  // ── Build order from food order (for delivered orders) ────────────────────
  Map<String, dynamic> _buildOrderFromFoodOrder(Map<String, dynamic> foodOrder) {
    final raw = foodOrder['raw'] is Map
        ? Map<String, dynamic>.from(foodOrder['raw'])
        : foodOrder;

    final summaryId = _nonZeroInt(foodOrder['summaryId']) ??
        _nonZeroInt(raw['summary_id']) ??
        _nonZeroInt(raw['food_summary_id']);

    final orderNo = (foodOrder['orderNumber'] ?? foodOrder['orderNo'] ?? '').toString();
    final roomNo = (foodOrder['roomNumber'] ?? foodOrder['roomNo'] ?? raw['room_number'] ?? '—').toString();
    final guestName = (foodOrder['guestName'] ?? foodOrder['customerName'] ?? raw['guest_name'] ?? 'Guest').toString();
    final guestPhone = (foodOrder['guestPhone'] ?? raw['guest_phone'] ?? raw['customer_number'] ?? '').toString();

    final items = (foodOrder['items'] as List? ?? []).map((it) {
      if (it is Map) {
        final itemName = (it['name'] ?? it['food_name'] ?? 'Item').toString();
        final vegFlag = it['is_veg'] ?? it['isVeg'];
        return {
          'name': itemName,
          'qty': it['qty'] ?? it['quantity'] ?? 1,
          'price': it['price'] ?? it['total_price'] ?? 0,
          'is_veg': vegFlag,
        };
      }
      return {'name': it.toString(), 'qty': 1, 'price': 0, 'is_veg': null};
    }).toList();

    final readyTime = raw['summary_ready_time'] ?? raw['ready_time'] ?? foodOrder['orderTime'] ?? raw['created_at'];

    return {
      'summaryId': summaryId,
      'serviceRequestId': null,
      'orderNumber': orderNo,
      'roomNumber': roomNo,
      'guestName': guestName,
      'guestPhone': guestPhone,
      'items': items,
      'totalAmount': foodOrder['totalAmount'] ?? raw['grand_total'] ?? raw['total_price'] ?? 0,
      'uiStatus': 'Delivered',
      'status': 'delivered',
      'orderTime': readyTime?.toString(),
      '_orderTimeDt': _parseOrderTime(readyTime?.toString()),
      'raw': raw,
    };
  }

  Future<void> _loadAllOrders() async {
    if (mounted) {
      setState(() {
        isLoading = readyOrders.isEmpty && acceptedOrders.isEmpty;
        errorMessage = null;
      });
    }

    try {
      // ── 1. Fetch food orders + service requests in parallel ───────────────
      // Ready orders come from get_food_orders_mobile1 (status == "Ready").
      // Accepted + Delivered come from get_all_services_mobile1 service requests
      // whose question contains a food order reference (department_type == "service"
      // and question starts with "Food order #").
      final results = await Future.wait([
        FoodOrderService().getFoodOrders(),
        TaskService().getAllServices(),
      ]);
      if (!mounted) return;

      final foodResult = results[0];
      final svcResult  = results[1];

      // ── 2. Ready tab — directly from food orders API ──────────────────────
      // get_food_orders_mobile1 returns status == "Ready" for orders waiting
      // for delivery staff to accept. This is the authoritative source.
      // Orders are grouped by orderNumber (one card per order, all items combined)
      // using the same groupFoodOrderRows() utility as the food page.
      //
      // After grouping, each Ready order is matched to its service request
      // (created when the order was marked Ready) by extracting the order number
      // from the SR question field. This gives us the serviceRequestId needed
      // for accept_service_request_mobile1.
      List<Map<String, dynamic>> ready = [];
      if (foodResult['success'] == true) {
        final orders = foodResult['orders'] as List? ?? [];
        final rawReady = orders.where((o) {
          final status = (o['status'] ?? '').toString().toUpperCase();
          return status == 'READY';
        }).toList();

        // Group multi-item orders — same logic as FoodOrdersPage
        final grouped = groupFoodOrderRows(rawReady);

        // Build two lookups from service requests:
        //  summaryIdToSrId   — summaryId → srId for OPEN SRs (Ready tab: can still be accepted)
        //  acceptedSummaryIds — summaryIds of SRs already In Progress / Closed
        //
        // An order whose summaryId is in acceptedSummaryIds has already been
        // accepted by a delivery staff member — exclude it from the Ready list
        // even though get_food_orders_mobile1 still returns it as "Ready"
        // (accept_service_request never updates order_status_summary).
        final Map<int, int> summaryIdToSrId = {};
        final Set<int>    acceptedSummaryIds = {};
        final Set<String> acceptedOrderNos   = {};
        if (svcResult['success'] == true) {
          final services = svcResult['services'] as List? ?? [];
          for (final svc in services) {
            if (svc is! Map) continue;
            final status        = (svc['status'] ?? '').toString().toLowerCase();
            final foodSummaryId = _nonZeroInt(svc['food_order_summary_id']);
            final srId          = _nonZeroInt(svc['service_request_id']);

            // Extract order number from question as a fallback key when FK is null
            final question     = (svc['question'] ?? '').toString();
            final orderNoMatch = RegExp(r'food order #(\S+)', caseSensitive: false)
                .firstMatch(question);
            final questionOrderNo = orderNoMatch?.group(1)?.trim() ?? '';

            if (status == 'open' || status == 'pending') {
              // Only Open SRs can be accepted from the Ready tab
              if (foodSummaryId != null && srId != null) {
                summaryIdToSrId[foodSummaryId] = srId;
              }
            } else {
              // Already accepted (In Progress) or closed — hide from Ready tab
              if (foodSummaryId != null) acceptedSummaryIds.add(foodSummaryId);
              if (questionOrderNo.isNotEmpty) acceptedOrderNos.add(questionOrderNo);
            }
          }
        }

        ready = grouped.where((g) {
          // Exclude orders already accepted (SR is In Progress or Closed).
          // Check both FK and order number — covers cases where food_order_summary_id
          // was not populated on the SR row by accept_service_request_mobile1.
          final summaryId = g['summaryId'] as int?;
          if (summaryId != null && acceptedSummaryIds.contains(summaryId)) {
            return false;
          }
          final orderNo = (g['orderNo'] ?? '').toString();
          if (orderNo.isNotEmpty && acceptedOrderNos.contains(orderNo)) {
            return false;
          }
          return true;
        }).map((g) {
          final raw        = g['raw'] as Map? ?? {};
          final createdAt  = g['createdAt'] as DateTime?;
          final orderNo    = (g['orderNo'] ?? '').toString();
          final orderTime  = createdAt?.toIso8601String() ??
              raw['created_at']?.toString() ??
              raw['order_time']?.toString();

          // Resolve serviceRequestId: try FK first, fall back to question order number
          final summaryId = g['summaryId'] as int?;
          int? srId = summaryId != null ? summaryIdToSrId[summaryId] : null;
          // Fallback: look up by order number extracted from question
          if (srId == null && orderNo.isNotEmpty) {
            // Find the Open SR whose question contains this order number
            if (svcResult['success'] == true) {
              final services = svcResult['services'] as List? ?? [];
              for (final svc in services) {
                if (svc is! Map) continue;
                final status = (svc['status'] ?? '').toString().toLowerCase();
                if (status != 'open' && status != 'pending') continue;
                final q = (svc['question'] ?? '').toString();
                if (q.toLowerCase().contains(orderNo.toLowerCase())) {
                  srId = _nonZeroInt(svc['service_request_id']);
                  break;
                }
              }
            }
          }

          // items from groupFoodOrderRows use 'name'/'qty'/'instructions'/'isVeg'
          // delivery card expects 'name'/'qty'/'is_veg' — remap once
          final items = (g['items'] as List<Map<String, dynamic>>)
              .map((it) => {
                    'name':   it['name'],
                    'qty':    it['qty'],
                    'price':  0,
                    'is_veg': it['isVeg'] ?? it['is_veg'],
                  })
              .toList();

          return {
            'summaryId':        summaryId,
            'serviceRequestId': srId,   // matched via food_order_summary_id FK
            'orderNumber':      orderNo,
            'roomNumber':       (g['room'] ?? '—').toString(),
            'guestName':        (g['guest'] ?? 'Guest').toString(),
            'guestPhone':       (raw['guest_phone'] ?? raw['customer_number'] ?? '').toString(),
            'items':            items,
            'totalAmount':      raw['total_price'] ?? 0,
            'uiStatus':         'Ready',
            'status':           'ready',
            'orderTime':        orderTime,
            '_orderTimeDt':     createdAt,
            'raw':              Map<String, dynamic>.from(raw),
            'etaTapCount':      g['etaTapCount'] ?? 0,
            'finalEtaTime':     raw['final_eta_time']?.toString(),
            'finalEtaDuration': 0,
          };
        }).toList()
          ..sort((a, b) {
            final aT = a['_orderTimeDt'] as DateTime?;
            final bT = b['_orderTimeDt'] as DateTime?;
            if (aT == null && bT == null) return 0;
            if (aT == null) return 1;
            if (bT == null) return -1;
            return bT.compareTo(aT);
          });
      }

      // ── 3. Accepted + Delivered — from service requests ───────────────────
      // Food delivery SRs are identified by question starting with "Food order #"
      // or by department_type matching room service food delivery.
      List<Map<String, dynamic>> accepted = [];
      List<Map<String, dynamic>> delivered = [];

      if (svcResult['success'] == true) {
        final services = svcResult['services'] as List? ?? [];

        final foodDeliverySRs = services.where((svc) {
          if (svc is! Map) return false;
          final question = (svc['question'] ?? '').toString();
          final deptType = (svc['department_type'] ?? '').toString().toLowerCase();
          // Match SRs created by the food order ready trigger:
          // question == "Food order #ORD... is ready for delivery to room ..."
          final isFood = question.toLowerCase().startsWith('food order #') ||
              (svc['food_order_summary_id'] != null &&
               svc['food_order_summary_id'].toString() != '0' &&
               svc['food_order_summary_id'].toString() != 'null');
          return isFood;
        }).cast<Map<String, dynamic>>().toList();

        final acceptedSRs = foodDeliverySRs.where((sr) {
          final status = (sr['status'] ?? '').toString().toLowerCase();
          return status == 'in progress' || status == 'inprogress';
        }).toList();

        final closedSRs = foodDeliverySRs.where((sr) {
          final status = (sr['status'] ?? '').toString().toLowerCase();
          return status == 'closed' || sr['closed'] == 1 || sr['closed'] == true;
        }).toList();

        accepted = acceptedSRs
            .map((sr) => _buildOrderFromServiceRequest(sr))
            .toList()
          ..sort((a, b) {
            final aT = a['_orderTimeDt'] as DateTime?;
            final bT = b['_orderTimeDt'] as DateTime?;
            if (aT == null && bT == null) return 0;
            if (aT == null) return 1;
            if (bT == null) return -1;
            return bT.compareTo(aT);
          });

        delivered = closedSRs.map((sr) {
          final order = _buildOrderFromServiceRequest(sr);
          order['uiStatus'] = 'Delivered';
          return order;
        }).toList()
          ..sort((a, b) {
            final aT = a['_orderTimeDt'] as DateTime?;
            final bT = b['_orderTimeDt'] as DateTime?;
            if (aT == null && bT == null) return 0;
            if (aT == null) return 1;
            if (bT == null) return -1;
            return bT.compareTo(aT);
          });
      }

      setState(() {
        readyOrders
          ..clear()
          ..addAll(ready);
        acceptedOrders
          ..clear()
          ..addAll(accepted);
        deliveredOrders
          ..clear()
          ..addAll(delivered);
      });

      // Delivery alert fires only for Ready orders that haven't been accepted yet.
      TaskAlertService.resetDeliveryCount(ready.length, reconcileAlert: true);
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  // ── Derived lists ─────────────────────────────────────────────────────────

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

  void _showGenericError([String? message]) {
    if (!mounted) return;
    AppSnackBar.show(
        context, message ?? 'Something went wrong. Please try again.', isError: true);
  }

  /// ACCEPT ORDER — always uses accept_service_request_mobile1.
  /// Ready orders are matched to their SR during _loadAllOrders() via the
  /// order number in the SR question field.
  Future<void> _acceptOrder(Map<String, dynamic> order) async {
    final orderNo = (order['orderNumber'] ?? '').toString();
    if (_actionLoadingOrderNo != null || orderNo.isEmpty) {
      _showGenericError();
      return;
    }

    final serviceRequestId = _nonZeroInt(order['serviceRequestId']);

    if (serviceRequestId == null) {
      _showGenericError('This order has no delivery request yet. The kitchen may not have marked it ready properly. Please contact your supervisor.');
      return;
    }

    setState(() => _actionLoadingOrderNo = orderNo);

    try {
      final res = await TaskService().acceptServiceRequest(
        serviceRequestId: serviceRequestId,
      );

      if (!mounted) return;

      if (res['success'] != true) {
        // Lambda timeout: accept may have gone through — reload to verify
        if (res['timedOut'] == true) {
          AppSnackBar.show(context, 'Accepted — verifying status...');
          await _loadAllOrders();
          if (!mounted) return;
          setState(() {
            selectedFilter = 'Accepted';
            _tabController.animateTo(1);
          });
          return;
        }
        final msg = res['message']?.toString().toLowerCase() ?? '';
        // SP rejected the request — classify by message rather than
        // showing a raw server error to the user.
        final alreadyAccepted = msg.contains('already accepted');
        final notFound        = msg.contains('not found');
        final alreadyClosed   = msg.contains('already closed') || msg.contains('closed');

        if (alreadyAccepted) {
          // Race: someone else accepted it first — reload silently, switch to Accepted.
          await _loadAllOrders();
          if (!mounted) return;
          setState(() { selectedFilter = 'Accepted'; _tabController.animateTo(1); });
          return;
        }
        if (notFound || alreadyClosed) {
          // Stale data: reload silently.
          await _loadAllOrders();
          return;
        }
        // Any other SP error — show verbatim.
        _showGenericError(res['message']?.toString().isNotEmpty == true
            ? res['message']!.toString()
            : 'Failed to accept order');
        return;
      }

      AppSnackBar.show(context, 'Order accepted ✅');
      await TaskAlertService.stopOneDeliveryAlert();

      // Optimistically move to Accepted tab then reload
      setState(() {
        readyOrders.removeWhere((o) => o['orderNumber'] == orderNo);
        final updatedOrder = Map<String, dynamic>.from(order);
        updatedOrder['uiStatus'] = 'Accepted';
        acceptedOrders.insert(0, updatedOrder);
        selectedFilter = 'Accepted';
        _tabController.animateTo(1);
      });

      await _loadAllOrders();
    } finally {
      if (mounted) setState(() => _actionLoadingOrderNo = null);
    }
  }

  Future<void> _deliverOrder(Map<String, dynamic> order) async {
    final confirm = await _showDeliverConfirmSheet(order);
    if (confirm != true) return;

    final orderNo = (order['orderNumber'] ?? '').toString();

    if (_actionLoadingOrderNo != null || orderNo.isEmpty) {
      _showGenericError();
      return;
    }

    final raw = order['raw'] as Map? ?? const {};

    // summaryId resolution — check every field name the raw map might use.
    // Ready orders:    order['summaryId'] set from groupFoodOrderRows summaryId field.
    // Accepted orders: raw comes from service_request row which carries
    //                  food_order_summary_id (the FK set when the SR was created).
    final summaryId = _nonZeroInt(order['summaryId'])
        ?? _nonZeroInt(raw['food_order_summary_id'])
        ?? _nonZeroInt(raw['summary_id'])
        ?? _nonZeroInt(raw['food_summary_id']);

    final serviceRequestId = _nonZeroInt(order['serviceRequestId'])
        ?? _nonZeroInt(raw['service_request_id']);

    if (serviceRequestId == null) {
      _showGenericError('Order ID not found. Please refresh and try again.');
      return;
    }

    setState(() => _actionLoadingOrderNo = orderNo);

    try {
      // ── Step 1: close_service_request (marks SR as Closed/Delivered) ───────
      final serviceResult = await TaskService().closeService(
        serviceRequestId: serviceRequestId,
      );

      if (!mounted) return;

      if (serviceResult['success'] != true) {
        // Lambda cold-start timeout: the close may have succeeded server-side.
        if (serviceResult['timedOut'] == true) {
          AppSnackBar.show(context, 'Delivery marked — verifying status...');
          await _loadAllOrders();
          if (!mounted) return;
          setState(() {
            selectedFilter = 'Delivered';
            _tabController.animateTo(2);
          });
          return;
        }
        _showGenericError(
            serviceResult['message']?.toString() ??
            'Failed to mark order as delivered.');
        return;
      }

      // ── Step 2: update_food_order (moves order_status_summary to Delivered) ─
      // This is mandatory — close_service only closes the service_request row
      // and never touches order_status_summary. Without this call the food order
      // stays stuck at "Ready" on the kitchen screen.
      if (summaryId != null) {
        await FoodOrderService().updateFoodOrderStatus(
          summaryId: summaryId,
          status: 'Delivered',
        );
        if (!mounted) return;
        // Non-fatal if it fails — service request is already closed server-side.
        // Reload will reflect the true state; no extra toast needed here.
      }

      if (!mounted) return;
      AppSnackBar.show(context, 'Order delivered successfully 🎉');

      await _loadAllOrders();

      if (!mounted) return;
      setState(() {
        selectedFilter = 'Delivered';
        _tabController.animateTo(2);
      });
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
                        final isVeg = resolveIsVeg(item['is_veg'] ?? item['isVeg'], name);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              vegIndicator(isVeg),
                              const SizedBox(width: 7),
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
          const Text('Delivery Management', style: AppTypography.appBarTitle),
          Text('Room Service Orders', style: AppTypography.appBarSubtitle),
        ],
      ),
    );
  }

  // ── Tab bar ───────────────────────────────────────────────────────────────

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
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Loading delivery orders...',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 10,
                itemBuilder: (_, __) => const SkeletonFoodOrderCard(),
              ),
            ),
          ],
        ),
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

  /// Order card — visually and structurally identical to FoodOrdersPage._buildOrderCard()
  Widget _buildPremiumOrderCard(Map<String, dynamic> order) {
    final items = order['items'] as List;
    final uiStatus = order['uiStatus'] as String;
    final guestName = (order['guestName'] ?? '').toString();
    final roomNo = (order['roomNumber'] ?? '—').toString();
    final orderNo = (order['orderNumber'] ?? '—').toString();
    final orderTime = order['orderTime'] as String?;
    final isTimelineExpanded = _expandedTimelineOrders.contains(orderNo);

    // Color scheme per status
    Color statusColor;
    switch (uiStatus) {
      case 'Ready':
        statusColor = AppColors.orange;
        break;
      case 'Accepted':
        statusColor = AppColors.info;
        break;
      case 'Delivered':
        statusColor = AppColors.success;
        break;
      default:
        statusColor = AppColors.textDisabled;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header Row: Order number + date on left, status chip on right ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '#$orderNo',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (orderTime != null && orderTime.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              const Icon(Icons.calendar_today_rounded,
                                  size: 11, color: AppColors.textDisabled),
                              const SizedBox(width: 3),
                              Text(
                                DateFormatter.formatDateTimeAmPm(orderTime),
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  _buildStatusChip(uiStatus, statusColor),
                ],
              ),
              const SizedBox(height: 12),

              // ── Guest name + Room + Timeline toggle ──
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: const BoxDecoration(
                      color: AppColors.surfaceAlt,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.person_rounded,
                        size: 13, color: AppColors.textSecondary),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: RichText(
                      overflow: TextOverflow.ellipsis,
                      text: TextSpan(
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary),
                        children: [
                          TextSpan(text: guestName.isNotEmpty ? guestName : 'Guest'),
                          if (roomNo != '—' && roomNo.isNotEmpty)
                            TextSpan(
                              text: '  ·  Room $roomNo',
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.textDisabled),
                            ),
                        ],
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      setState(() {
                        if (_expandedTimelineOrders.contains(orderNo)) {
                          _expandedTimelineOrders.remove(orderNo);
                        } else {
                          _expandedTimelineOrders.add(orderNo);
                        }
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isTimelineExpanded ? AppColors.primaryLight : AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isTimelineExpanded
                              ? AppColors.primary.withValues(alpha: 0.3)
                              : AppColors.borderLight,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.timeline_rounded,
                            size: 13,
                            color: isTimelineExpanded ? AppColors.primary : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            "Timeline",
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: isTimelineExpanded ? AppColors.primary : AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            isTimelineExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                            size: 14,
                            color: isTimelineExpanded ? AppColors.primary : AppColors.textSecondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              if (isTimelineExpanded) ...[
                const SizedBox(height: 8),
                _buildDeliveryLifecycleStepper(order),
              ],

              const Divider(height: 16, color: AppColors.borderLight),

              // ── Order Items Header ──
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

              // ── Order Items List ──
              ...items.map<Widget>((item) {
                final name = (item['name'] ?? '').toString();
                final isVeg = resolveIsVeg(item['is_veg'], name);
                final qty = item['qty'];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      vegIndicator(isVeg),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text(
                          '$qty',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary),
                        ),
                      ),
                    ],
                  ),
                );
              }),

              // ── Action Buttons ──
              if (uiStatus == 'Ready') ...[
                const SizedBox(height: 12),
                _actionButton(
                  text: 'Accept Order',
                  icon: Icons.check_circle_rounded,
                  color: AppColors.success,
                  isLoading: _actionLoadingOrderNo == orderNo,
                  onTap: () => _acceptOrder(order),
                ),
              ] else if (uiStatus == 'Accepted') ...[
                const SizedBox(height: 12),
                _actionButton(
                  text: 'Mark as Delivered',
                  icon: Icons.task_alt_rounded,
                  color: AppColors.primary,
                  isLoading: _actionLoadingOrderNo == orderNo,
                  onTap: () => _deliverOrder(order),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _actionButton({
    required String text,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
    bool isLoading = false,
  }) {
    return GestureDetector(
      onTap: isLoading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(13),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isLoading)
              const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            else ...[
              Icon(icon, color: Colors.white, size: 16),
              const SizedBox(width: 6),
              Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ],
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
  Widget _buildDeliveryLifecycleStepper(Map<String, dynamic> order) {
    final raw = Map<String, dynamic>.from(order['raw'] as Map? ?? const {});
    final status = (order['uiStatus'] ?? order['status'] ?? '').toString();
    final createdAt = _firstTimelineDate(raw, const [
          'food_order_created_at', 'created_at', 'order_time', 'placed_time',
        ]) ??
        (order['_orderTimeDt'] as DateTime?);
    final readyAt = _firstTimelineDate(raw, const [
      'food_order_ready_time', 'summary_ready_time', 'ready_time', 'food_ready_at', 'status_updated_time',
    ]);
    final acceptedAt = _firstTimelineDate(raw, const [
      'room_service_accepted_at', 'accepted_time', 'accepted_at',
    ]);
    final deliveredAt = _firstTimelineDate(raw, const [
      'food_order_delivered_time', 'summary_delivered_time', 'delivered_time', 'delivered_at', 'closed_at',
    ]);

    var activeStage = 1;
    if (status == 'Accepted' || acceptedAt != null) activeStage = 2;
    if (status == 'Delivered' || deliveredAt != null) activeStage = 3;

    String time(DateTime? value, int stage) {
      if (value != null) return DateFormatter.formatDateTimeOnlyAmPm(value);
      return activeStage == stage ? 'Ongoing' : 'Pending';
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