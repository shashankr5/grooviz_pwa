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
import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/task_service.dart';
import '../services/task_alert_service.dart';
import '../services/food_order_service.dart';
import '../utils/order_grouping.dart';
import '../utils/app_snackbar.dart';
import '../utils/date_formatter.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../services/notification_handler.dart';
import '../services/notification_constants.dart';
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

  // Cache for summaryId → serviceRequestId mapping
  final Map<int, int> _summaryIdToSrId = {};
  // Cache for summaryId → service request status ("Open" / "In Progress" / "Closed")
  final Map<int, String> _summaryIdToSrStatus = {};
  // The service request is the authority for the delivery acceptance/closure
  // timestamps. Keep the complete row so those values survive food-order
  // grouping (which intentionally only contains food summary fields).
  final Map<int, Map<String, dynamic>> _summaryIdToService = {};

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

  // ── Non-zero int resolver (mirrors order_grouping.dart helper) ───────────
  // Returns v as a positive int, or null when v is null / 0 / unparseable.
  // Prevents order_id=0 from ever reaching the accept/update APIs.
  int? _nonZeroInt(dynamic v) {
    if (v == null) return null;
    final n = v is int ? v : int.tryParse(v.toString());
    if (n == null || n <= 0) return null;
    return n;
  }

  Future<void> _loadAllOrders() async {
    if (mounted) {
      setState(() {
        isLoading = readyOrders.isEmpty && acceptedOrders.isEmpty;
        errorMessage = null;
      });
    }

    try {
      // ── 1. Fetch food orders ──────────────────────────────────────────
      final result = await FoodOrderService().getFoodOrders();
      if (!mounted) return;
      if (result['success'] != true) {
        setState(() {
          errorMessage = result['message'] as String? ?? 'Unable to load delivery orders.';
        });
        return;
      }

      // ── 2. Fetch service requests to get food_order_summary_id → service_request_id mapping ──
      // Clear caches before rebuilding
      _summaryIdToSrId.clear();
      _summaryIdToSrStatus.clear();
      _summaryIdToService.clear();
      try {
        final svcResult = await TaskService().getAllServices();
        if (svcResult['success'] == true) {
          final services = svcResult['services'] as List? ?? [];
          for (final svc in services) {
            if (svc is! Map) continue;
            final rawSrId = svc['service_request_id'];
            final srId = _nonZeroInt(rawSrId);
            if (srId == null) continue;

            final rawFoodSummaryId = svc['food_order_summary_id'];
            final foodSummaryId = _nonZeroInt(rawFoodSummaryId);
            final srStatus = (svc['status'] ?? 'Open').toString();

            if (foodSummaryId != null) {
              _summaryIdToSrId[foodSummaryId] = srId;
              _summaryIdToSrStatus[foodSummaryId] = srStatus;
              _summaryIdToService[foodSummaryId] =
                  Map<String, dynamic>.from(svc);
            }
          }
        }
      } catch (_) {
        // Non-fatal: if getAllServices fails, tab split falls back to food order status
      }

      // ── 3. Group food orders ──────────────────────────────────────────
      final List rawOrders = (result['orders'] as List? ?? []);
      final grouped = groupFoodOrderRows(rawOrders);

      final List deliveredRaw = (result['deliveredOrders'] as List? ?? []);
      final deliveredGrouped = groupFoodOrderRows(deliveredRaw);

      int _byTimeDesc(Map<String, dynamic> a, Map<String, dynamic> b) {
        final aT = a['_orderTimeDt'] as DateTime?;
        final bT = b['_orderTimeDt'] as DateTime?;
        if (aT == null && bT == null) return 0;
        if (aT == null) return 1;
        if (bT == null) return -1;
        return bT.compareTo(aT);
      }

      Map<String, dynamic> _buildOrder(Map<String, dynamic> g) {
        final order = _fromFoodGroupedOrder(g);
        final summaryId = _nonZeroInt(order['summaryId']);
        if (summaryId != null && _summaryIdToSrId.containsKey(summaryId)) {
          // Inject service-request data into the food-order card. The food
          // summary deliberately remains Ready while a rider is carrying it,
          // so the card's delivery state must come from this linked request.
          if (order['serviceRequestId'] == null) {
            final srId = _summaryIdToSrId[summaryId];
            order['serviceRequestId'] = srId;
          }
          if (order['raw'] is Map) {
            final raw = order['raw'] as Map;
            raw['service_request_id'] = order['serviceRequestId'];
            final service = _summaryIdToService[summaryId];
            if (service != null) {
              for (final key in const [
                'accepted_at',
                'closed_at',
                'accepted_by_user_id',
                'accepted_by_user_name',
                'closed_by_user_id',
                'closed_by_user_name',
                'status',
              ]) {
                raw[key] = service[key];
              }
            }
          }
          final serviceStatus =
              _summaryIdToSrStatus[summaryId]?.trim().toLowerCase();
          final foodStatus = (order['status'] ?? '').toString().toUpperCase();
          if (foodStatus != 'DELIVERED' && serviceStatus == 'in progress') {
            order['uiStatus'] = 'Accepted';
          }
        }
        return order;
      }

      final ready = grouped
          .where((o) {
            final foodStatus = (o['status'] ?? '').toString().toUpperCase();
            if (foodStatus != 'READY') return false;
            // Only show in Ready tab if the SR hasn't been accepted yet.
            // If we have SR status for this order's summaryId, use it.
            final summaryId = _nonZeroInt(o['summaryId'])
                ?? _nonZeroInt((o['raw'] as Map?)?['summary_id']);
            if (summaryId != null && _summaryIdToSrStatus.containsKey(summaryId)) {
              final srStatus = _summaryIdToSrStatus[summaryId]!.toLowerCase();
              // "open" → still waiting for a rider to accept
              return srStatus == 'open';
            }
            // No SR found for this order yet → it belongs in Ready
            return true;
          })
          .map(_buildOrder)
          .toList()
        ..sort(_byTimeDesc);

      final accepted = grouped
          .where((o) {
            final foodStatus = (o['status'] ?? '').toString().toUpperCase();
            if (foodStatus != 'READY') return false;
            // Show in Accepted tab when a rider has accepted the SR.
            final summaryId = _nonZeroInt(o['summaryId'])
                ?? _nonZeroInt((o['raw'] as Map?)?['summary_id']);
            if (summaryId != null && _summaryIdToSrStatus.containsKey(summaryId)) {
              final srStatus = _summaryIdToSrStatus[summaryId]!.toLowerCase();
              return srStatus == 'in progress';
            }
            return false;
          })
          .map(_buildOrder)
          .toList()
        ..sort(_byTimeDesc);

      final delivered = deliveredGrouped
          .map(_buildOrder)
          .toList()
        ..sort(_byTimeDesc);

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

  // ── Grouping & parsing ────────────────────────────────────────────────────

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

  Map<String, dynamic> _fromFoodGroupedOrder(Map<String, dynamic> grouped) {
    final raw = grouped['raw'] is Map ? Map<String, dynamic>.from(grouped['raw']) : grouped;
    final orderNo = (grouped['orderNo'] ?? grouped['orderNumber'] ?? '').toString();

    // Resolve summaryId: prefer the already-resolved value from groupFoodOrderRows,
    // but treat 0 as absent and fall through to raw fields.
    final summaryId = _nonZeroInt(grouped['summaryId'])
        ?? _nonZeroInt(raw['summary_id'])
        ?? _nonZeroInt(raw['food_summary_id']);

    // serviceRequestId should come ONLY from the service_request table.
    final serviceRequestId = _nonZeroInt(raw['service_request_id']); // DO NOT fallback to summaryId

    final roomNo = (grouped['roomNo'] ?? grouped['roomNumber'] ?? grouped['room'] ?? raw['room_number'] ?? raw['room_id'] ?? '—').toString();
    final guestName = (grouped['customerName'] ?? grouped['guestName'] ?? raw['guest_name'] ?? '').toString();
    final guestPhone = (grouped['customerNumber'] ?? raw['guest_phone'] ?? raw['customer_number'] ?? '').toString();
    final status = (grouped['status'] ?? raw['order_status'] ?? '').toString();
    final items = (grouped['items'] as List? ?? []).map((it) {
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
      return {'name': it.toString(), 'qty': 1, 'price': 0, 'is_veg': null, 'isVegKnown': false};
    }).toList();

    final readyTime = raw['summary_ready_time'] ?? raw['ready_time'] ?? grouped['orderTime'] ?? raw['created_at'];

    return {
      'summaryId': summaryId,
      'serviceRequestId': serviceRequestId, // safe – might be null (we'll inject later)
      'orderNumber': orderNo,
      'roomNumber': roomNo,
      'guestName': guestName,
      'guestPhone': guestPhone,
      'items': items,
      'totalAmount': grouped['totalAmount'] ?? raw['grand_total'] ?? raw['total_price'],
      'uiStatus': status.toUpperCase() == 'DELIVERED' ? 'Delivered' : (status.toUpperCase() == 'READY' ? 'Ready' : 'Accepted'),
      'status': status,
      'orderTime': readyTime?.toString(),
      '_orderTimeDt': _parseOrderTime(readyTime?.toString()),
      'raw': raw,
    };
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

  /// ACCEPT ORDER — now uses the correct service request accept API.
  Future<void> _acceptOrder(Map<String, dynamic> order) async {
    final orderNo = (order['orderNumber'] ?? '').toString();
    if (_actionLoadingOrderNo != null || orderNo.isEmpty) {
      _showGenericError();
      return;
    }

    // Extract the service request ID from the order data.
    final serviceRequestId = _nonZeroInt(order['serviceRequestId'])
        ?? _nonZeroInt(order['raw']?['service_request_id']);

    if (serviceRequestId == null) {
      _showGenericError('Service request ID not found. Please refresh and try again.');
      return;
    }

    setState(() => _actionLoadingOrderNo = orderNo);

    try {
      // ✅ Step 1: Accept the service request (delivery workflow only).
      // acceptFoodOrder is kitchen workflow (Pending→Preparing) — do NOT call it here.
      final res = await TaskService().acceptServiceRequest(
        serviceRequestId: serviceRequestId,
      );

      if (!mounted) return;

      if (res['success'] != true) {
        // "already accepted by you" means we own it — treat as success
        final msg = res['message']?.toString() ?? '';
        final alreadyMine = msg.toLowerCase().contains('already accepted by you');
        if (!alreadyMine) {
          _showGenericError(msg.isNotEmpty ? msg : 'Failed to accept order');
          return;
        }
      }

      AppSnackBar.show(context, 'Order accepted ✅');

      // ✅ Step 2: Optimistically move the card to Accepted tab immediately.
      // The food order stays "Ready" in the DB — the split is now driven by
      // SR status (Open vs In Progress), so we update the cached SR status
      // locally so the next rebuild sees it in the right tab.
      final summaryId = _nonZeroInt(order['summaryId'])
          ?? _nonZeroInt(order['raw']?['summary_id'])
          ?? _nonZeroInt(order['raw']?['food_summary_id']);
      if (summaryId != null) {
        _summaryIdToSrStatus[summaryId] = 'In Progress';
      }

      setState(() {
        // Re-bucket: remove from ready, add to accepted
        readyOrders.removeWhere((o) => o['orderNumber'] == orderNo);
        final updatedOrder = Map<String, dynamic>.from(order);
        updatedOrder['uiStatus'] = 'Accepted';
        // Use the server-returned acceptance time; never manufacture a local
        // timestamp for an API-backed delivery event.
        final acceptedAt = res['accepted_at'];
        if (acceptedAt != null && updatedOrder['raw'] is Map) {
          (updatedOrder['raw'] as Map)['accepted_at'] = acceptedAt;
        }
        acceptedOrders.insert(0, updatedOrder);
        selectedFilter = 'Accepted';
        _tabController.animateTo(1);
      });

      // ✅ Step 3: Stop alert count for this accepted order, then reconcile.
      await TaskAlertService.stopOneDeliveryAlert();
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
    final summaryId = _nonZeroInt(order['summaryId'])
        ?? _nonZeroInt(raw['summary_id'])
        ?? _nonZeroInt(raw['id'])
        ?? _nonZeroInt(raw['order_id'])
        ?? _nonZeroInt(raw['food_summary_id']);

    final serviceRequestId = _nonZeroInt(order['serviceRequestId'])
        ?? _nonZeroInt(raw['service_request_id']);

    if (summaryId == null && serviceRequestId == null) {
      _showGenericError('Order ID not found. Please refresh and try again.');
      return;
    }

    setState(() => _actionLoadingOrderNo = orderNo);

    try {
      // A delivery has two persisted states.  The food summary owns the
      // Delivered timestamp; its linked service request owns the delivery
      // workflow state.  Both calls are required, in that order.
      if (summaryId == null || serviceRequestId == null) {
        _showGenericError('Delivery details are incomplete. Please refresh and try again.');
        return;
      }

      final foodResult = await FoodOrderService().updateFoodOrderStatus(
        summaryId: summaryId,
        status: 'Delivered',
      );
      if (foodResult['success'] != true && foodResult['success'] != 1) {
        _showGenericError(foodResult['message']?.toString());
        return;
      }

      var serviceResult = await TaskService().closeService(
        serviceRequestId: serviceRequestId,
      );
      if (serviceResult['success'] != true && serviceResult['success'] != 1) {
        serviceResult = await TaskService().updateServiceRequestStatus(
          serviceRequestId: serviceRequestId,
          status: 'CLOSED',
        );
      }

      if (!mounted) return;

      if (serviceResult['success'] != true && serviceResult['success'] != 1) {
        // The food order is already delivered, so reload to show the server
        // truth; do not claim the complete delivery workflow succeeded.
        await _loadAllOrders();
        _showGenericError(serviceResult['message']?.toString() ??
            'Food order delivered, but its delivery request could not be closed.');
        return;
      }

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
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          children: [
            // Show a loading header
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
            // Show skeleton cards
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

    // Color scheme per status matching FoodOrdersPage
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
              // ── Header Row: Room badge on left, Status + #ORD + Date on right ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.indigo.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          "Room ",
                          style: TextStyle(
                            fontSize: 15,
                            color: Colors.indigo,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          roomNo,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.indigo,
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
                        _buildStatusChip(uiStatus, statusColor),
                        const SizedBox(height: 6),
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
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
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
                ],
              ),
              const SizedBox(height: 12),

              // ── Guest name + Timeline toggle ──
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
                    child: Text(
                      guestName.isNotEmpty ? guestName : "Guest",
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary),
                      overflow: TextOverflow.ellipsis,
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
  /// Each timestamp is optional because older enterprise responses may not
  /// expose all history fields yet.
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
      // The food summary is the source of truth for the Delivered event. The
      // service request is closed immediately afterwards, so closed_at may be
      // a few seconds later and must not replace the food-order timestamp.
      'food_order_delivered_time', 'summary_delivered_time', 'delivered_time', 'delivered_at', 'closed_at',
    ]);

    var activeStage = 1; // Ready is the first state shown in Delivery Management.
    if (status == 'Accepted' || acceptedAt != null) activeStage = 2;
    if (status == 'Delivered' || deliveredAt != null) activeStage = 3;

    String time(DateTime? value, int stage) {
      if (value != null) return DateFormatter.formatDateTimeOnlyAmPm(value);
      // Do not present a synthetic "Done" value as a timestamp. A stage is
      // only timestamped when that timestamp is supplied by its owning API.
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
