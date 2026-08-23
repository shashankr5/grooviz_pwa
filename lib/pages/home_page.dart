// home_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../services/home_service.dart';
import '../services/task_service.dart';
import '../services/session_change_service.dart';
import '../services/task_alert_service.dart';
import '../services/order_alert_service.dart';
import '../services/escalation_service.dart';
import '../services/profile_service.dart';
import '../services/food_order_service.dart';
import '../services/notification_handler.dart';
import '../services/notification_constants.dart';
import '../utils/date_formatter.dart';
import '../utils/user_session_helper.dart';
import '../utils/app_snackbar.dart';
import '../utils/order_grouping.dart';
import '../utils/escalation_helpers.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../components/app_badge.dart';
import '../components/skeleton_loader.dart';
import '../components/home/executive_header_card.dart';
import '../components/home/kpi_command_grid.dart';
import '../components/home/timeline_task_card.dart';
import '../components/home/delivery_command_card.dart';
import 'delivery_page.dart';
import 'guest_checkout_page.dart';
import 'ticket_details_page.dart';
import 'profile_page.dart';

// ── Role helpers — delegate to EscalationRole from escalation_helpers.dart ───

bool _isManagerRole(String? role) =>
    escalationRoleFromName(role).isManagerOrAbove;

bool _isSupervisorOrAbove(String? role) =>
    escalationRoleFromName(role).isSupervisorOrAbove;

// ─────────────────────────────────────────────────────────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> with WidgetsBindingObserver {
  void refreshData() {
    _loadTasks();
    _loadDeliveryCounts();
  }

  String selectedFilter     = "All";
  String selectedDateFilter = "All Days";
  DateTime? selectedCustomDate;
  String userName       = "";
  String userRole       = "";
  String enterpriseName = "";
  int?   loggedInUserId;
  String _monthName(int month) {
    const months = [
      "Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ];
    return months[month - 1];
  }

  String _getFormattedDateFilterText() {
    if (selectedDateFilter == "Custom" && selectedCustomDate != null) {
      return "${selectedCustomDate!.day} ${_monthName(selectedCustomDate!.month)} ${selectedCustomDate!.year.toString().substring(2)}";
    }
    return selectedDateFilter;
  }

  bool  _isLoading       = true;
  bool  _deptLoaded      = false;
  // CHANGE: Added _roleLoaded guard so Manager/GM/Admin never flash "All"
  // before defaulting to the "Escalated" filter. The loading spinner stays
  // up until both dept AND role are resolved.
  bool  _roleLoaded      = false;
  int?  _acceptingTaskId;
  String? _errorMessage;

  // Guards didChangeAppLifecycleState so notification-shade pulls
  // (inactive → resumed, no paused) never trigger an API refresh.
  // Only set to true when AppLifecycleState.paused is observed,
  // cleared on resumed. A real background→foreground always passes through paused.
  bool _didPause = false;

  bool isFrontOfficeUser = false;
  bool isRoomServiceUser = false;

  List<Map<String, dynamic>> tasks          = [];
  List<Map<String, dynamic>> escalatedTasks = [];
  int  _escalationBadgeCount = 0;

  // Search Bar Filter
  bool _isSearchExpanded = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Delivery counts cached from summary cards
  int _readyOrderCount     = 0;
  int _acceptedOrderCount  = 0;
  int _deliveredOrderCount = 0;
  /// True while the first delivery counts fetch is in flight — shows skeleton.
  bool _deliveryCountsLoading = true;
  /// Oldest grouped Ready order for the DeliveryCommandCard preview row.
  /// Null when no ready orders exist or when timestamp is missing.
  Map<String, dynamic>? _oldestReadyOrder;

  // Alert stream subscriptions
  StreamSubscription<void>? _newTaskSub;
  StreamSubscription<void>? _newDeliverySub;
  StreamSubscription<int>?  _escalationSub;     // badge count
  StreamSubscription<void>? _escalationListSub; // list refresh (always)
  StreamSubscription<String>? _roleChangeSub;

  // Scroll-FAB inactivity timer — hides the FAB after 5s of no scroll.
  Timer? _scrollFabTimer;

  // ── Scroll-to-top/bottom FAB ─────────────────────────────────────────────
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _showScrollFabNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _scrollAtBottomNotifier = ValueNotifier(false);

  int get currentSectionCount {
    return filteredTasks.length;
  }

  @override
  void initState() {
    super.initState();
    localNotifications.cancel(NotifId.serviceTask);
    localNotifications.cancel(NotifId.escalation);
    updateGroupSummary();
    WidgetsBinding.instance.addObserver(this);
    _loadUserId();
    _loadUserName();
    _loadUserRole();
    _loadTasks();
    _loadUserDepartments();
    _subscribeToAlerts();

    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos    = _scrollController.position;
    final offset = pos.pixels;
    final max    = pos.maxScrollExtent;

    // Show FAB only after scrolling past ~3-4 cards (380px) and before bottom edge
    const edge = 380.0;
    final show = max > edge * 1.5 && offset > edge && offset < max - 80.0;
    final atBtm = offset >= max / 2;

    if (atBtm != _scrollAtBottomNotifier.value) {
      _scrollAtBottomNotifier.value = atBtm;
    }

    if (show) {
      if (!_showScrollFabNotifier.value) {
        _showScrollFabNotifier.value = true;
      }
      // Reset the 5-second inactivity timer
      _scrollFabTimer?.cancel();
      _scrollFabTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) {
          _showScrollFabNotifier.value = false;
        }
      });
    } else {
      _scrollFabTimer?.cancel();
      if (_showScrollFabNotifier.value) {
        _showScrollFabNotifier.value = false;
      }
    }
  }


  /// Scroll smoothly down to the Service Requests list header.
  void _scrollToTasksList() {
    if (_scrollController.hasClients) {
      final offset = isRoomServiceUser ? 420.0 : 260.0;
      _scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (loggedInUserId != null) _loadUserName();
  }

  // ── Subscribe to FCM-driven streams ──────────────────────────────────────

  void _subscribeToAlerts() {
    _newTaskSub = TaskAlertService.onNewTask.listen((_) {
      if (mounted) {
        _loadTasks();
      }
    });

    _newDeliverySub = TaskAlertService.onNewDelivery.listen((_) {
      if (mounted && isRoomServiceUser) _loadDeliveryCounts();
    });

    // Badge count stream — from EscalationService, not TaskAlertService.
    _escalationSub = EscalationService.instance.onBadgeUpdate.listen((_) {
      if (mounted) {
        _loadTasks();
      }
    });

    // List refresh stream — always reload, no selectedFilter guard.
    // Previously this only ran when selectedFilter == "Escalated",
    // leaving the list stale when the user was on another filter tab.
    _escalationListSub = EscalationService.instance.onListRefresh.listen((_) {
      if (mounted) _loadTasks();
    });

    _roleChangeSub = SessionChangeService.instance.onRoleChange.listen((_) {
      if (mounted) {
        _loadUserRole();
        _loadUserDepartments();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _newTaskSub?.cancel();
    _newDeliverySub?.cancel();
    _escalationSub?.cancel();
    _escalationListSub?.cancel();
    _roleChangeSub?.cancel();
    _scrollFabTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _showScrollFabNotifier.dispose();
    _scrollAtBottomNotifier.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // FIX-9 (Bug 9): On resume, re-pull tasks/deliveries/badge and make sure
  // the websocket is (re)connected. IndexedStack keeps HomePage alive
  // permanently, so initState never re-fires — this is the only lifecycle
  // hook that catches "backgrounded, dropped socket, resumed" cleanly.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _didPause = true;
      return;
    }
    if (state == AppLifecycleState.resumed && mounted) {
      if (!_didPause) return;
      _didPause = false;
      _loadTasks();
      if (isRoomServiceUser) _loadDeliveryCounts();
    }
  }

  // ── Loaders ───────────────────────────────────────────────────────────────

  Future<void> _loadUserId() async {
    loggedInUserId = await UserSessionHelper.getUserId();
    if (mounted) setState(() {});
  }

  Future<void> _loadUserName() async {
    final name = await UserSessionHelper.getUserName();
    final entName = await UserSessionHelper.getEnterpriseName();
    if (mounted) {
      setState(() {
        userName = name ?? "User";
        if (entName != null && entName.isNotEmpty) {
          enterpriseName = entName;
        }
      });
    }
  }

  Future<void> _loadUserRole() async {
    final role = await UserSessionHelper.getRole();
    if (!mounted) return;
    setState(() {
      userRole = role ?? "";
      // Escalation filtering is disabled; always show the normal task queue.
      if (selectedFilter == "Escalated") selectedFilter = "All";
      _roleLoaded = true;
    });
  }

  Future<void> _loadUserDepartments() async {
    final depts      = await UserSessionHelper.getDepartments();
    final normalized = depts.map((e) => e.toLowerCase().trim()).toList();
    if (!mounted) return;
    setState(() {
      isFrontOfficeUser =
          normalized.any((d) => (d.contains("front") && d.contains("office")) || d.contains("frontoffice"));
      // Match "Room Service", "room service", "roomservice" etc.
      isRoomServiceUser =
          normalized.any((d) => (d.contains("room") && d.contains("service")) || d.contains("roomservice"));
      _deptLoaded = true;
    });
    // Load delivery counts only after we know whether this user is Room
    // Service. Calling _loadDeliveryCounts() from initState races with
    // _loadUserDepartments() and can leave _deliveryCountsLoading = false
    // before isRoomServiceUser is set, producing a blank orange card.
    if (isRoomServiceUser) {
      _loadDeliveryCounts();
    } else {
      // Not a Room Service user — mark loading done so the card is never
      // shown in skeleton state if isRoomServiceUser later becomes true
      // (it won't, but guards future-proofing).
      if (mounted) setState(() => _deliveryCountsLoading = false);
    }
  }



  /// Keeps the legacy KPI count available without restoring SLA cards,
  /// escalation banners, sounds, or notifications.
  void _recalcEscalation() {
    escalatedTasks = tasks.where((task) {
      final raw = task['raw'] as Map? ?? const {};
      return task['is_escalated'] == 1 ||
          task['is_escalated'] == true ||
          raw['is_escalated'] == 1 ||
          raw['is_escalated'] == true ||
          raw['escalation_instance_id'] != null;
    }).toList();
    _escalationBadgeCount = escalatedTasks.length;
  }

  /// Calls sp_resolve_escalation_mobile to stop the pulse engine and escalation
  /// climb for a task after accept / close / reassign.
  /// Non-fatal: main SP already cleared flags; this nulls next_escalation_at.
  Future<void> _resolveEscalationForTask(
    Map<String, dynamic> task, {
    String resolutionType = 'close',
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) return;
      final srId = task['service_request_id']
          ?? task['raw']?['service_request_id'];
      if (srId == null) return;
      await EscalationService.instance.resolveEscalation(
        serviceRequestId: srId is int ? srId : int.tryParse(srId.toString()) ?? 0,
        resolvedByUserId: userId,
        resolutionType:   resolutionType,
      );
    } catch (e) {
      // Non-fatal — log only, never surface to the user.
      // ignore: avoid_print
      print('_resolveEscalationForTask (non-fatal): $e');
    }
  }

  bool _isFoodDeliveryRequest(Map<String, dynamic> request) {
    final foodSummaryId = request['food_order_summary_id'];
    if (foodSummaryId != null &&
        foodSummaryId.toString().trim().isNotEmpty &&
        foodSummaryId.toString() != '0') {
      return true;
    }

    if (request['is_from_order'] == 1 || request['is_from_order'] == true) {
      return true;
    }

    final serviceOrderId = request['service_order_id'];
    if (serviceOrderId != null &&
        serviceOrderId.toString().trim().isNotEmpty &&
        serviceOrderId.toString() != '0') {
      return true;
    }

    final question = (request['question'] ?? '').toString().toLowerCase();
    if (question.contains('food order') || question.contains('ready for delivery')) {
      return true;
    }

    return false;
  }

  Future<void> _loadTasks() async {
    final bool isRecoveringFromError = _errorMessage != null;

    setState(() {
      _isLoading    = true;
      _errorMessage = null;
    });

    if (isRecoveringFromError) {
      try {
        await ProfileService().getProfile();
        await _loadUserName();
        await _loadUserRole();
        await _loadUserDepartments();
      } catch (_) {}
    }

    final result = await HomeService().getTasks();
    if (!mounted) return;

    if (result["success"] != true) {
      setState(() {
        _errorMessage = result["message"] as String? ?? "Unable to load tasks.";
        _isLoading    = false;
      });
      return;
    }

    // Service requests shown AS IS
    final List<Map<String, dynamic>> rawList =
        List<Map<String, dynamic>>.from(result["tasks"]);

    // Deduplicate by service_request_id, preferring rows with a real room
    final Map<int, Map<String, dynamic>> uniqueMap = {};
    for (final t in rawList) {
      final id = t["service_request_id"];
      if (id == null) continue;
      if (!uniqueMap.containsKey(id)) {
        uniqueMap[id] = t;
      } else {
        final existingRoom = uniqueMap[id]!["room"];
        final newRoom      = t["room"];
        if ((existingRoom == null || existingRoom == "-" || existingRoom == "0") &&
            newRoom != null && newRoom != "-" && newRoom != "0") {
          uniqueMap[id] = t;
        }
      }
    }

    final List<Map<String, dynamic>> raw = uniqueMap.values.toList();
    raw.sort((a, b) {
      final da = _parseTimestamp(a["raw"]["created_at"] ?? a["created_at"]);
      final db = _parseTimestamp(b["raw"]["created_at"] ?? b["created_at"]);
      return db.compareTo(da);
    });

    setState(() {
      tasks = raw.map((t) => {
        ...t,
        "isAccepted":  t["status"] == "In Progress",
        "statusColor": getStatusColor(t["status"]),
        "assignedTo":  t["raw"]?["accepted_by_user_name"] ?? t["raw"]?["assigned_to_name"] ?? "-",
      }).toList();

      // Calculate escalatedTasks locally from the main feed list.
      // Only Supervisor+ roles receive the escalation badge and filter —
      // Staff should not see tasks marked escalated at their own level
      // (the scheduler notifies the correct hierarchy level via push).
      _recalcEscalation();

      _isLoading = false;
    });

    final openCount = tasks.where((t) => t["status"] == "Open").length;
    TaskAlertService.resetServiceCount(openCount);
  }

  // ── Delivery order grouping ──────────────────────────────────────────────

  Future<void> _loadDeliveryCounts() async {
    if (!mounted) return;
    if (_readyOrderCount == 0 && _acceptedOrderCount == 0 && _deliveredOrderCount == 0) {
      setState(() => _deliveryCountsLoading = true);
    }

    final foodResult = await FoodOrderService().getFoodOrders();
    if (!mounted) return;

    if (foodResult['success'] == true) {
      final List rawOrders = (foodResult['orders'] as List? ?? []);
      final grouped = groupFoodOrderRows(rawOrders);
      final ready = grouped.where((o) => (o['status'] ?? '').toString().toUpperCase() == 'READY').toList();
      final accepted = grouped.where((o) => (o['status'] ?? '').toString().toUpperCase() == 'PREPARING' || (o['status'] ?? '').toString().toUpperCase() == 'IN PROGRESS').toList();
      final List deliveredRaw = (foodResult['delivered'] as List? ?? []);
      final deliveredGrouped = groupFoodOrderRows(deliveredRaw);

      final ordersWithTime = List<Map<String, dynamic>>.from(ready)
        ..sort((a, b) {
          final da = a['orderDate'] as DateTime? ?? a['etaExpiresAt'] as DateTime? ?? DateTime.now();
          final db = b['orderDate'] as DateTime? ?? b['etaExpiresAt'] as DateTime? ?? DateTime.now();
          return da.compareTo(db); // oldest first
        });

      Map<String, dynamic>? oldestPreview;
      if (ordersWithTime.isNotEmpty) {
        final first = ordersWithTime.first;
        oldestPreview = {
          'orderNumber': first['orderNo'] ?? first['orderNumber'],
          'roomNumber': first['roomNo'] ?? first['roomNumber'] ?? first['room'] ?? '—',
          'guestName': first['customerName'] ?? first['guestName'] ?? '',
          'orderTime': first['orderTime'] ?? first['time'],
          '_orderTimeDt': first['orderDate'] ?? first['etaExpiresAt'],
        };
      }

      setState(() {
        _readyOrderCount       = ready.length;
        _acceptedOrderCount    = accepted.length;
        _deliveredOrderCount   = deliveredGrouped.length;
        _oldestReadyOrder      = oldestPreview;
        _deliveryCountsLoading = false;
      });

      TaskAlertService.resetDeliveryCount(_readyOrderCount);
    } else {
      setState(() => _deliveryCountsLoading = false);
    }
  }

  // ── Accept task ───────────────────────────────────────────────────────────

  Future<void> _acceptTask(Map<String, dynamic> task) async {
    final taskId       = task["raw"]?["service_request_id"] ?? task["task_id"] ?? task["id"];
    final departmentId = task["raw"]?["department_id"] ?? task["department_id"];
    final enterpriseId = task["raw"]?["enterprise_id"] ?? task["enterprise_id"];
    final orderId      = task["raw"]?["order_id"] ?? task["order_id"];
    if (taskId == null) return;

    final intId = int.tryParse(taskId.toString()) ?? 0;
    final parsedOrderId = orderId != null ? int.tryParse(orderId.toString()) : null;
    setState(() => _acceptingTaskId = intId);

    final result = await HomeService().acceptTask(
      taskId:       intId,
      departmentId: departmentId ?? 0,
      enterpriseId: enterpriseId ?? 0,
      orderId:      parsedOrderId,
    );
    if (!mounted) return;
    setState(() => _acceptingTaskId = null);

    if (!result["success"]) {
      final serverMsg = result["message"]?.toString();
      AppSnackBar.show(
        context,
        (serverMsg != null && serverMsg.isNotEmpty)
            ? serverMsg
            : "Failed to accept task. Please try again.",
        isError: true,
      );
      return;
    }

    // Optimistically decrement and stop if count hits zero, keep looping if > 0
    await TaskAlertService.stopOneServiceAlert();
    await OrderAlertService.stopOne();
    await _loadTasks();
    _resolveEscalationForTask(task, resolutionType: 'accept');
    AppSnackBar.show(context, "Task Accepted 🎉");
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Color getStatusColor(String status) => AppColors.statusColor(status);

  void _showGenericError() {
    if (!mounted) return;
    AppSnackBar.show(context, "Something went wrong. Please try again.", isError: true);
  }

  DateTime _parseTimestamp(String? ts) {
    if (ts == null || ts.trim().isEmpty) return DateTime.now();
    try {
      String fixed = ts.trim();
      if (fixed.contains(" ") && !fixed.contains("T")) {
        fixed = fixed.replaceFirst(" ", "T");
      }
      return DateTime.parse(fixed);
    } catch (_) {
      return DateTime.now();
    }
  }

  bool isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year && date.month == now.month && date.day == now.day;
  }

  bool isYesterday(DateTime date) {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    return date.year == yesterday.year &&
        date.month == yesterday.month &&
        date.day == yesterday.day;
  }

  String formatDateTime(String ts) {
    return DateFormatter.formatDateTimeAmPm(ts);
  }

  Color getTaskPriorityColor(String createdAt) {
    final taskTime = _parseTimestamp(createdAt);
    final diff     = DateTime.now().difference(taskTime);
    if (diff.inHours < 1) return AppColors.success;
    if (diff.inHours < 8) return AppColors.warning;
    return AppColors.error;
  }

  // ── Filter ────────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> get filteredTasks {
    List<Map<String, dynamic>> list;
    switch (selectedFilter) {
      case "Open":
        list = tasks.where((t) => t["status"] == "Open").toList();
        break;
      case "In Progress":
        list = tasks.where((t) => t["status"] == "In Progress").toList();
        break;
      case "Closed":
        list = tasks.where((t) => t["status"] == "Closed").toList()
          ..sort((a, b) {
            final da = _parseTimestamp(a["raw"]["created_at"] ?? "");
            final db = _parseTimestamp(b["raw"]["created_at"] ?? "");
            return db.compareTo(da);
          });
        break;
      case "Escalated":
        // Handled separately — returns escalatedTasks list directly.
        return [];
      default:
        // "All" filter includes Open, In Progress, and Closed tasks.
        // Escalated tasks sort to top first before date sorting.
        list = List<Map<String, dynamic>>.from(tasks)
          ..sort((a, b) {
            final aEsc = ((a["is_escalated"] ??
                        (a["raw"] as Map?)?["is_escalated"] ??
                        0) ==
                    1)
                ? 0
                : 1;
            final bEsc = ((b["is_escalated"] ??
                        (b["raw"] as Map?)?["is_escalated"] ??
                        0) ==
                    1)
                ? 0
                : 1;
            // Escalated tasks come first; within each group sort by date desc.
            if (aEsc != bEsc) return aEsc.compareTo(bEsc);
            final da = _parseTimestamp(
                (a["raw"] as Map?)?["created_at"] ?? "");
            final db = _parseTimestamp(
                (b["raw"] as Map?)?["created_at"] ?? "");
            return db.compareTo(da);
          });
    }
    final dateFiltered = list.where((t) {
      final createdAt = (t["raw"]?["created_at"] ?? t["raw"]?["timestamp"] ?? "").toString();
      if (createdAt.isEmpty) return false;
      final date      = _parseTimestamp(createdAt);
      if (selectedDateFilter == "Custom" && selectedCustomDate != null) {
        return date.year == selectedCustomDate!.year &&
               date.month == selectedCustomDate!.month &&
               date.day == selectedCustomDate!.day;
      }
      switch (selectedDateFilter) {
        case "Today":     return isToday(date);
        case "Yesterday": return isYesterday(date);
        default:          return true;
      }
    }).toList();

    if (_searchQuery.isEmpty) return dateFiltered;
    return dateFiltered.where((t) => _matchesQuery(t, _searchQuery)).toList();
  }

  bool _matchesQuery(Map<String, dynamic> t, String q) {
    if (q.isEmpty) return true;
    final cleanQ = q.replaceAll('#', '').toLowerCase();
    final room  = (t['room'] ?? t['room_number'] ?? t['requested_room'] ?? '').toString().toLowerCase();
    final guest = (t['guest'] ?? t['guest_name'] ?? t['full_name'] ?? '').toString().toLowerCase();
    final reqId = (t['service_request_id'] ?? t['task_id'] ?? t['id'] ?? t['raw']?['service_request_id'] ?? '').toString().toLowerCase();
    final title = (t['title'] ?? t['name'] ?? t['service_name'] ?? t['question'] ?? '').toString().toLowerCase();

    return room.contains(cleanQ) ||
           guest.contains(cleanQ) ||
           reqId.contains(cleanQ) ||
           title.contains(cleanQ);
  }

  // ── Date filter bottom sheet ──────────────────────────────────────────────

  void _showDateFilterSheet() {
    final options = ["All Days", "Today", "Yesterday", "Choose Date"];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text("Filter by Date",
                    style: AppTypography.title.copyWith(color: AppColors.textPrimary)),
              ),
            ),
            ...options.map((opt) {
              final isSelected = opt == "Choose Date"
                  ? selectedDateFilter == "Custom"
                  : selectedDateFilter == opt;
              return InkWell(
                onTap: () async {
                  if (opt == "Choose Date") {
                    Navigator.pop(context);
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: selectedCustomDate ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                      builder: (context, child) {
                        return Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: const ColorScheme.light(
                              primary: AppColors.primary,
                              onPrimary: Colors.white,
                              onSurface: AppColors.textPrimary,
                            ),
                          ),
                          child: child!,
                        );
                      },
                    );
                    if (picked != null) {
                      setState(() {
                        selectedDateFilter = "Custom";
                        selectedCustomDate = picked;
                      });
                    }
                  } else {
                    setState(() {
                      selectedDateFilter = opt;
                      selectedCustomDate = null;
                    });
                    Navigator.pop(context);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.primaryLight : Colors.transparent,
                    border: const Border(bottom: BorderSide(color: AppColors.borderLight)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isSelected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: isSelected ? AppColors.primary : AppColors.textDisabled,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        opt == "Choose Date" && selectedCustomDate != null
                            ? "${selectedCustomDate!.day} ${_monthName(selectedCustomDate!.month)} ${selectedCustomDate!.year}"
                            : opt,
                        style: AppTypography.bodyPrimary.copyWith(
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                          color: isSelected ? AppColors.primary : AppColors.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      if (isSelected)
                        const Icon(Icons.check_rounded, color: AppColors.primary, size: 18),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  Widget _buildSkeletonTaskView() {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Expanded(child: SkeletonLoader(height: 72, borderRadius: BorderRadius.all(Radius.circular(16)))),
              SizedBox(width: 8),
              Expanded(child: SkeletonLoader(height: 72, borderRadius: BorderRadius.all(Radius.circular(16)))),
              SizedBox(width: 8),
              Expanded(child: SkeletonLoader(height: 72, borderRadius: BorderRadius.all(Radius.circular(16)))),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: const [
              SkeletonLoader(width: 70, height: 32, borderRadius: BorderRadius.all(Radius.circular(16))),
              SizedBox(width: 8),
              SkeletonLoader(width: 80, height: 32, borderRadius: BorderRadius.all(Radius.circular(16))),
              SizedBox(width: 8),
              SkeletonLoader(width: 90, height: 32, borderRadius: BorderRadius.all(Radius.circular(16))),
            ],
          ),
          const SizedBox(height: 16),
          for (int i = 0; i < 10; i++) const SkeletonTaskCard(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_deptLoaded || !_roleLoaded) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(child: _buildSkeletonTaskView()),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _buildAppBar(),
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: _showScrollFabNotifier,
        builder: (_, showFab, __) {
          return AnimatedScale(
            scale: showFab ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: showFab ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: ValueListenableBuilder<bool>(
                valueListenable: _scrollAtBottomNotifier,
                builder: (_, atBtm, __) {
                  return FloatingActionButton.small(
                    onPressed: () {
                      _scrollController.animateTo(
                        atBtm ? 0 : _scrollController.position.maxScrollExtent,
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeOutCubic,
                      );
                    },
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 4,
                    tooltip: atBtm ? 'Back to top' : 'Jump to bottom',
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    child: Icon(
                      atBtm
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 22,
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
      body: Stack(
        children: [
          _errorMessage != null ? _buildError() : _buildContent(),
          if (_isLoading)
            Positioned.fill(
              child: Container(
                color: AppColors.bg,
                child: _buildSkeletonTaskView(),
              ),
            ),
        ],
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      automaticallyImplyLeading: false,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Ticket Management",
              style: AppTypography.appBarTitle),
          Text("Here's your task overview",
              style: AppTypography.appBarSubtitle),
        ],
      ),
      actions: [
        if (isFrontOfficeUser)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const GuestCheckoutPage())),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.warningLight,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.warning.withOpacity(0.3)),
                ),
                child: Image.asset("assets/icons/checkout_report.png",
                    width: 20, height: 20, color: AppColors.textPrimary),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(50),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const ProfilePage())),
              child: CircleAvatar(
                backgroundColor: AppColors.primary,
                child: Text(
                  userName.isNotEmpty ? userName[0].toUpperCase() : "?",
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Error / content widgets ───────────────────────────────────────────────

  Widget _buildError() {
    final isDeptError = _errorMessage?.toLowerCase().contains('department') ?? false;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDeptError ? AppColors.warningLight : AppColors.errorLight,
                shape: BoxShape.circle,
              ),
              child: Icon(
                isDeptError ? Icons.info_outline_rounded : Icons.error_outline_rounded,
                size: 48,
                color: isDeptError ? AppColors.warning : AppColors.error,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              isDeptError ? "Configuration Required" : "Error Occurred",
              style: AppTypography.title.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage ?? "Something went wrong",
              textAlign: TextAlign.center,
              style: AppTypography.bodySecondary.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadTasks,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                isDeptError ? "Refresh Status" : "Retry",
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    final openCount       = tasks.where((t) => t["status"] == "Open").length;
    final inProgressCount = tasks.where((t) => t["status"] == "In Progress").length;
    final closedCount     = tasks.where((t) => t["status"] == "Closed").length;

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _loadTasks,
      child: SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Executive Header Card
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ExecutiveHeaderCard(
              userName: userName,
              userRole: userRole,
              enterpriseName: enterpriseName,
            ),
          ),

          const SizedBox(height: 16),

          // KPI Command Center 4-Grid Dashboard
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: KpiCommandGrid(
              escalationCount: _escalationBadgeCount,
              openCount: openCount,
              inProgressCount: inProgressCount,
              closedCount: closedCount,
              activeFilter: selectedFilter,
              onFilterSelected: (filter) {
                 setState(() => selectedFilter = filter);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _scrollToTasksList();
                });
              },
            ),
          ),

          const SizedBox(height: 16),

          // ── Delivery Command Card (Room Service users only) ──────────
          if (isRoomServiceUser) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DeliveryCommandCard(
                readyCount:       _readyOrderCount,
                acceptedCount:    _acceptedOrderCount,
                deliveredCount:   _deliveredOrderCount,
                oldestReadyOrder: _oldestReadyOrder,
                isLoading:        _deliveryCountsLoading,
                onNavigate: (initialFilter) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          DeliveryPage(initialFilter: initialFilter),
                    ),
                  ).then((_) {
                    if (mounted) _loadDeliveryCounts();
                  });
                },
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Header row with count & date filter trigger
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selectedFilter == "Escalated"
                            ? "Escalated SLA Requests"
                            : "Service Requests",
                        style: AppTypography.h2.copyWith(fontSize: 18),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "$currentSectionCount ${selectedFilter == 'All' ? 'active' : selectedFilter.toLowerCase()} requests",
                        style: AppTypography.bodySecondary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Expandable Square Search Container
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeInOut,
                      width: _isSearchExpanded ? 140 : 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _isSearchExpanded
                              ? AppColors.primary
                              : AppColors.border,
                        ),
                      ),
                      child: _isSearchExpanded
                          ? Row(
                              children: [
                                const SizedBox(width: 8),
                                GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _searchController.clear();
                                      _searchQuery = '';
                                      _isSearchExpanded = false;
                                    });
                                  },
                                  child: const Icon(Icons.search_rounded,
                                      size: 16, color: AppColors.primary),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: TextField(
                                    controller: _searchController,
                                    autofocus: true,
                                    style: AppTypography.bodyPrimary.copyWith(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500),
                                    decoration: const InputDecoration(
                                      hintText: "Room, Guest, #ID...",
                                      hintStyle: TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textDisabled),
                                      border: InputBorder.none,
                                      isDense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                    onChanged: (val) =>
                                        setState(() => _searchQuery = val.trim()),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _searchController.clear();
                                      _searchQuery = '';
                                      _isSearchExpanded = false;
                                    });
                                  },
                                  child: const Padding(
                                    padding:
                                        EdgeInsets.symmetric(horizontal: 6),
                                    child: Icon(Icons.close_rounded,
                                        size: 14, color: AppColors.textSecondary),
                                  ),
                                ),
                              ],
                            )
                          : InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () =>
                                  setState(() => _isSearchExpanded = true),
                              child: const Center(
                                child: Icon(Icons.search_rounded,
                                    size: 18, color: AppColors.textSecondary),
                              ),
                            ),
                    ),
                    if (!_isSearchExpanded && selectedFilter != "Escalated") ...[
                      const SizedBox(width: 8),
                      // Days Picker Container
                      GestureDetector(
                        onTap: _showDateFilterSheet,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.calendar_today_rounded,
                                  size: 14, color: AppColors.textSecondary),
                              const SizedBox(width: 6),
                              Text(
                                _getFormattedDateFilterText(),
                                style: AppTypography.bodyPrimary.copyWith(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.keyboard_arrow_down_rounded,
                                  size: 16, color: AppColors.textSecondary),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // Task list — Escalated or normal TimelineTaskCard.
          // The Escalated view is only available to Supervisor and above;
          // Staff always see the normal filtered list.
          if (selectedFilter == "Escalated" &&
              EscalationVisibility.canViewEscalatedTab(
                  escalationRoleFromName(userRole)))
            _buildEscalatedList()
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: filteredTasks.length,
              itemBuilder: (context, index) {
                final task = filteredTasks[index];
                return KeyedSubtree(
                  key: ValueKey(task["raw"]["service_request_id"]),
                  child: TimelineTaskCard(
                    task: task,
                    isSupervisor: _isSupervisorOrAbove(userRole),
                    userRole: userRole,
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TicketDetailPage(
                            task: task,
                            userRole: userRole,
                            onClose: () {
                              setState(() {
                                final idx = tasks.indexWhere((t) =>
                                    t["raw"]["service_request_id"] ==
                                    task["raw"]["service_request_id"]);
                                if (idx != -1) {
                                  tasks[idx]["status"] = "Closed";
                                  tasks[idx]["statusColor"] =
                                      getStatusColor("Closed");
                                  tasks[idx]["isAccepted"] = false;
                                  // Clear escalation flags locally so the red
                                  // border disappears instantly without a reload.
                                  tasks[idx]["is_escalated"] = 0;
                                  tasks[idx]["alert_pending"] = 0;
                                  if (tasks[idx]["raw"] is Map) {
                                    (tasks[idx]["raw"] as Map)["is_escalated"] = 0;
                                    (tasks[idx]["raw"] as Map)["alert_pending"] = 0;
                                  }
                                }
                              });
                              // Refresh escalated list so the closed task
                              // disappears from the Escalated tab immediately.
                              setState(() => _recalcEscalation());
                              _resolveEscalationForTask(task);
                            },
                            onReassign: (updatedTask) {
                              setState(() {
                                final idx = tasks.indexWhere((t) =>
                                    t["raw"]["service_request_id"] ==
                                    updatedTask["service_request_id"]);
                                if (idx != -1) {
                                  tasks[idx]["assignedTo"] =
                                      updatedTask["accepted_by_user_name"] ?? updatedTask["assigned_to_name"] ?? "-";
                                  tasks[idx]["status"] =
                                      updatedTask["status"] ?? tasks[idx]["status"];
                                  tasks[idx]["statusColor"] =
                                      getStatusColor(tasks[idx]["status"]);
                                  tasks[idx]["isAccepted"] = true;
                                  tasks[idx]["is_escalated"] = 0;
                                  tasks[idx]["alert_pending"] = 0;
                                  if (tasks[idx]["raw"] is Map) {
                                    final raw = tasks[idx]["raw"] as Map;
                                    raw["is_escalated"] = 0;
                                    raw["alert_pending"] = 0;
                                    raw["accepted_by_user_id"] = updatedTask["accepted_by_user_id"];
                                    raw["accepted_by_user_name"] = updatedTask["accepted_by_user_name"];
                                    raw["assigned_to"] = updatedTask["assigned_to"];
                                    raw["assigned_to_name"] = updatedTask["assigned_to_name"];
                                  }
                                }
                              });
                              // Refresh escalated list + stop pulse engine.
                              setState(() => _recalcEscalation());
                              _resolveEscalationForTask(task, resolutionType: 'reassign');
                            },
                          ),
                        ),
                      );
                      setState(() {});
                    },
                    onAccept: () => _acceptTask(task),
                    isAccepting: _acceptingTaskId == (int.tryParse((task["raw"]?["service_request_id"] ?? task["task_id"] ?? task["id"] ?? 0).toString()) ?? 0),
                  ),
                );
              },
            ),
          const SizedBox(height: 24),
        ],
      ),
    ),
  );
  }

  // ── Escalated task list ───────────────────────────────────────────────────
  // Visible to Supervisor and above. Manager+ see all dept escalations;
  // Supervisors and Dept Heads see only their mapped department.

  Widget _buildEscalatedList() {
    final displayList = _searchQuery.isEmpty
        ? escalatedTasks
        : escalatedTasks.where((t) => _matchesQuery(t, _searchQuery)).toList();

    if (displayList.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
        child: Center(
          child: Column(children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _searchQuery.isEmpty
                    ? AppColors.successLight
                    : AppColors.bgLight,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _searchQuery.isEmpty
                    ? Icons.verified_outlined
                    : Icons.search_off_rounded,
                size: 40,
                color: _searchQuery.isEmpty
                    ? AppColors.success
                    : AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _searchQuery.isEmpty
                  ? 'All clear — no SLA breaches'
                  : 'No matching escalated tasks',
              style: AppTypography.title.copyWith(
                fontSize: 16,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _searchQuery.isEmpty
                  ? 'Every task is within its SLA window.'
                  : 'Try a different room, guest name, or request ID.',
              style: AppTypography.bodySecondary,
              textAlign: TextAlign.center,
            ),
          ]),
        ),
      );
    }

    final role = escalationRoleFromName(userRole);
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: displayList.length,
      itemBuilder: (context, index) {
        final task = displayList[index];
        return KeyedSubtree(
          key: ValueKey(task["service_request_id"]),
          child: GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TicketDetailPage(
                  task:     task,
                  userRole: userRole,
                  onClose:  () => _loadTasks(),
                  onNoteAdded: (note) {
                    setState(() {
                      final idx = escalatedTasks.indexWhere((t) =>
                          t["service_request_id"] == task["service_request_id"]);
                      if (idx != -1) escalatedTasks[idx]["note"] = note;
                    });
                  },
                ),
              ),
            ).then((_) => _loadTasks()),
            child: _buildEscalatedCard(task, role),
          ),
        );
      },
    );
  }

  // ── Escalated task card ───────────────────────────────────────────────────

  Widget _buildEscalatedCard(Map<String, dynamic> task, EscalationRole role) {
    final raw = task['raw'] as Map<String, dynamic>? ?? {};

    final rawRoom     = (task['room_number'] ?? task['room'] ?? task['requested_room'] ?? '-').toString();
    final roomDisplay = (rawRoom == '0' || rawRoom == '000' || rawRoom == '-' ||
            rawRoom == 'null' || rawRoom.isEmpty)
        ? 'General'
        : 'Room $rawRoom';

    final requestId  = (task['service_request_id'] ?? task['task_id'] ?? task['id'] ?? '').toString();
    final guestName  = (task['guest_name'] ?? task['guest'] ?? task['full_name'] ?? '').toString();
    final rawTitle   = (task['name'] ?? task['title'] ?? task['service_name'] ?? 'Service Request').toString();
    final cleanTitle = rawTitle.replaceFirst(
        RegExp(r'^Order\s+#[A-Z0-9]+\s*-\s*', caseSensitive: false), '');
    final deptName   = (raw['department_name'] ?? task['department_name'] ?? task['department'] ?? '').toString();
    final assignedTo = (raw['accepted_by_user_name'] ?? raw['assigned_to_name'] ?? task['assignedTo'] ?? '').toString();
    final status     = (task['status'] ?? 'Open').toString();

    final esc        = EscalationInfo.fromTask(task);
    final accentStyle = EscalationVisibility.accentStyle(role);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
        border:       EscalationDisplay.escalatedBorder(),
        boxShadow:    EscalationDisplay.escalatedShadow(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Accent bar ───────────────────────────────────────────────────
          Container(
            width:   double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 14),
            decoration: BoxDecoration(
              color: EscalationDisplay.accentBarColor(accentStyle),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
            ),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.white, size: 13),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  EscalationDisplay.accentBarLabel(accentStyle, esc.stageName),
                  style: const TextStyle(
                    color:         Colors.white,
                    fontSize:      10,
                    fontWeight:    FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              EscalationDisplay.countdownChip(esc),
            ]),
          ),

          // ── Body ─────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Row 1: Room pill, request ID, escalated pill
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(children: [
                      _pill(roomDisplay, AppColors.primaryLight,
                          textColor: AppColors.primary),
                      if (requestId.isNotEmpty && requestId != '0') ...[
                        const SizedBox(width: 6),
                        _pill('#$requestId', AppColors.bg,
                            textColor: AppColors.textSecondary),
                      ],
                    ]),
                    // Status + escalated pill
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      _statusPill(status, AppColors.statusColor(status)),
                      const SizedBox(width: 6),
                      EscalationDisplay.statusPill(),
                    ]),
                  ],
                ),

                const SizedBox(height: 10),

                // Title
                Text(
                  cleanTitle,
                  style: const TextStyle(
                    fontSize:   15,
                    fontWeight: FontWeight.w700,
                    color:      AppColors.textPrimary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),

                const SizedBox(height: 8),

                // Meta row: guest · dept · stage pill
                Wrap(
                  spacing:   8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (guestName.isNotEmpty && guestName != 'Unknown Guest')
                      _metaChip(Icons.person_outline_rounded, guestName),
                    if (deptName.isNotEmpty)
                      _metaChip(Icons.business_rounded, deptName),
                    if (esc.stageName != null && esc.stageName!.isNotEmpty)
                      EscalationDisplay.stagePill(esc.stageName!),
                  ],
                ),

                const SizedBox(height: 10),
                const Divider(height: 1, color: AppColors.borderLight),
                const SizedBox(height: 10),

                // Footer: SLA label + assigned staff
                Row(children: [
                  Icon(
                    esc.isOverdue
                        ? Icons.timer_off_rounded
                        : Icons.timer_outlined,
                    size: 13,
                    color: esc.isOverdue ? AppColors.error : AppColors.warning,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    esc.slaLabel,
                    style: TextStyle(
                      fontSize:   12,
                      fontWeight: FontWeight.w700,
                      color: esc.isOverdue ? AppColors.error : AppColors.warning,
                    ),
                  ),
                  const Spacer(),
                  if (assignedTo.isNotEmpty && assignedTo != '-') ...[
                    const Icon(Icons.badge_outlined,
                        size: 13, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        assignedTo,
                        style: const TextStyle(
                          fontSize:   12,
                          fontWeight: FontWeight.w500,
                          color:      AppColors.textSecondary,
                        ),
                        maxLines:  1,
                        overflow:  TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Shared small helpers ──────────────────────────────────────────────────

  Widget _metaChip(IconData icon, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 12, color: AppColors.textSecondary),
      const SizedBox(width: 4),
      Text(
        label,
        style: const TextStyle(
          fontSize:   12,
          fontWeight: FontWeight.w500,
          color:      AppColors.textSecondary,
        ),
      ),
    ]);
  }

  // ── Task card ─────────────────────────────────────────────────────────────

  Widget _buildTaskCard(Map<String, dynamic> task) {
    final createdAt   = task["raw"]["created_at"] ?? task["created_at"] ?? "";
    final isEscalated = (task["is_escalated"] ?? task["raw"]?["is_escalated"] ?? 0) == 1;

    IconData categoryIcon = Icons.build_circle_rounded;
    Color iconBg    = AppColors.infoLight;
    Color iconColor = AppColors.info;
    final title = (task["title"] ?? "").toString().toLowerCase();
    if (title.contains("clean") || title.contains("housekeep")) {
      categoryIcon = Icons.cleaning_services_rounded;
      iconBg    = AppColors.successLight;
      iconColor = AppColors.success;
    } else if (title.contains("food") || title.contains("pillow") || title.contains("towel")) {
      categoryIcon = Icons.bed_rounded;
      iconBg    = AppColors.primaryLight;
      iconColor = AppColors.primary;
    } else if (title.contains("ac") || title.contains("electric") || title.contains("light")) {
      categoryIcon = Icons.electrical_services_rounded;
      iconBg    = AppColors.orangeLight;
      iconColor = AppColors.orange;
    }

    final guestName = task["raw"]?["guest_name"] ?? task["guest_name"] ?? "";
    final status    = task["status"] as String;
    final statusClr = isEscalated ? AppColors.error : AppColors.statusColor(status);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: isEscalated
            ? Border.all(color: AppColors.error.withOpacity(0.35), width: 1.5)
            : null,
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05),
              blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: isEscalated ? AppColors.errorLight : iconBg,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(isEscalated ? Icons.warning_amber_rounded : categoryIcon,
                        size: 16, color: isEscalated ? AppColors.error : iconColor),
                  ),
                  const SizedBox(width: 7),
                  _pill("Room ${task["room"]}", AppColors.warningLight,
                      textColor: AppColors.warning),
                  if (isEscalated) ...[
                    const SizedBox(width: 6),
                    EscalationDisplay.statusPill(),
                  ],
                ]),
                _statusPill(isEscalated ? "Escalated" : status, statusClr),
              ],
            ),
            const SizedBox(height: 8),
            Text(task["title"],
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            if (guestName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text("👤 $guestName",
                    style: const TextStyle(color: AppColors.textSecondary,
                        fontSize: 12, fontWeight: FontWeight.w500)),
              ),
            if (task["assignedTo"] != null && task["assignedTo"] != "-" && task["assignedTo"].toString().trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.badge_outlined, 
                        size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text("Assigned: ${task["assignedTo"]}",
                        style: const TextStyle(color: AppColors.textSecondary,
                            fontSize: 12, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.calendar_today_rounded, size: 12,
                  color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Text(formatDateTime(createdAt),
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              const Spacer(),
              if (status == "Open")
                ElevatedButton(
                  onPressed: (_acceptingTaskId == (int.tryParse((task["raw"]?["service_request_id"] ?? task["task_id"] ?? task["id"] ?? 0).toString()) ?? 0))
                      ? null
                      : () => _acceptTask(task),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: (_acceptingTaskId == (int.tryParse((task["raw"]?["service_request_id"] ?? task["task_id"] ?? task["id"] ?? 0).toString()) ?? 0))
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text("Accept",
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                ),
              if (status != "Open")
                const Icon(Icons.chevron_right_rounded, color: AppColors.textDisabled),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _statusPill(String status, Color color) {
    return AppBadge(
      label: status,
      color: color,
      backgroundColor: color.withOpacity(0.1),
      small: true,
    );
  }

  Widget _pill(String text, Color bg, {Color textColor = AppColors.textPrimary}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9)),
      child: Text(text,
          style: TextStyle(color: textColor, fontWeight: FontWeight.w600, fontSize: 11)),
    );
  }
}

// ── Shared helpers ────────────────────────────────────────────────────────────

bool resolveIsVeg(dynamic isVegFlag) {
  if (isVegFlag == null) return false;
  final v = isVegFlag.toString().trim();
  return v == '1' || v == 'true';
}

Widget vegIndicator(bool isVeg) {
  final c = isVeg ? AppColors.success : AppColors.error;
  return Container(
    width: 14, height: 14,
    decoration: BoxDecoration(border: Border.all(color: c, width: 1.5)),
    child: Center(
      child: Container(width: 6, height: 6,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
    ),
  );
}

