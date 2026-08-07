// home_page.dart
//
// CHANGES IN THIS VERSION:
//  • _roleLoaded guard — bool _roleLoaded = false added. Set to true at end
//    of _loadUserRole(). Loading gate changed from !_deptLoaded to
//    !_deptLoaded || !_roleLoaded so Manager/GM/Admin never flash "All"
//    before defaulting to "Escalated".
//  • 60s escalation timer — Timer? _escalationTimer added. Started in
//    initState, cancelled in dispose. Calls triggerEscalationCheck() every
//    60 seconds as a client-side fallback for the SQS self-enqueue loop.
//  • Escalation stream refresh — _escalationSub now also calls
//    _loadEscalationBadge() to re-fetch the authoritative count from the
//    server, and calls _loadEscalatedTasks() if the Escalated filter is
//    currently selected so the list stays live.
//  • Escalated tasks sort to top — filteredTasks default case now sorts
//    escalated tasks first before the date sort.
//  • onReassign clears escalation flags instantly — tasks[idx]["is_escalated"],
//    ["alert_pending"], and the matching raw map keys are zeroed immediately
//    on return from TicketDetailPage so the red border clears without a reload.

import 'dart:async';
import 'package:flutter/material.dart';
import '../services/home_service.dart';
import '../services/session_change_service.dart';
import '../services/task_alert_service.dart';
import '../services/escalation_service.dart';
import '../utils/date_formatter.dart';
import '../utils/user_session_helper.dart';
import '../utils/app_snackbar.dart';
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
import '../services/notification_handler.dart';
import '../services/notification_constants.dart';

// ── Role helpers ─────────────────────────────────────────────────────────────

const _roleHierarchy = [
  'Staff', 'Supervisor', 'Department Head', 'Manager', 'General Manager', 'Admin',
];

bool _isManagerRole(String? role) {
  if (role == null) return false;
  return _roleHierarchy.indexOf(role) >= 3; // Manager, GM, Admin
}

bool _isSupervisorOrAbove(String? role) {
  if (role == null) return false;
  return _roleHierarchy.indexOf(role) >= 1; // Supervisor+
}

// ─────────────────────────────────────────────────────────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> with WidgetsBindingObserver {
  void refreshData() {
    _loadTasks();
    _loadEscalationBadge();
    if (_isSupervisorOrAbove(userRole)) {
      _loadEscalatedTasks();
    }
    _loadDeliveryCounts();
  }

  String selectedFilter     = "All";
  String selectedDateFilter = "All Days";
  String userName       = "";
  String userRole       = "";
  String enterpriseName = "";
  int?   loggedInUserId;

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

  // CHANGE: 60s escalation timer — client-side fallback for the SQS
  // self-enqueue loop. Calls triggerEscalationCheck() every 60 seconds.
  // If SQS is already working reliably, this can be removed without
  // breaking anything (the SP is idempotent).
  Timer? _escalationTimer;

  // ── Scroll-to-top/bottom FAB ─────────────────────────────────────────────
  final ScrollController _scrollController = ScrollController();
  // true  → user is near the bottom → button scrolls to top   (↑ icon)
  // false → user is near the top    → button scrolls to bottom (↓ icon)
  bool _scrollAtBottom = false;
  // Only show the FAB once there is actually content to scroll.
  bool _showScrollFab  = false;

  int get currentSectionCount {
    if (selectedFilter == "Escalated") {
      return _searchQuery.isEmpty
          ? escalatedTasks.length
          : escalatedTasks.where((t) => _matchesQuery(t, _searchQuery)).length;
    }
    return filteredTasks.length;
  }

  @override
  void initState() {
    super.initState();
    localNotifications.cancel(NotifId.serviceTask);
    localNotifications.cancel(NotifId.escalation);
    updateGroupSummary();
    // FIX-9 (Bug 9): Reload on app resume. This is a safety net — the real
    // fix is that WebSocketService().connect() must actually be called
    // (see login_page.dart) so onNewTask/onNewDelivery fire live. Resume
    // reload additionally covers the case where the socket dropped while
    // backgrounded and hasn't finished reconnecting yet.
    WidgetsBinding.instance.addObserver(this);
    _loadUserId();
    _loadUserName();
    _loadUserRole();
    _loadTasks();
    _loadUserDepartments(); // triggers _loadDeliveryCounts() internally when isRoomServiceUser = true
    _loadEscalationBadge();
    _subscribeToAlerts();

    // CHANGE: Start periodic escalation check every 60 seconds,
    // but ONLY for Manager / GM / Admin — staff don't need to hit
    // checkAndEscalate. Role is loaded asynchronously, so we wait for it
    // in _loadUserRole() before deciding whether to start the timer.
    // (Timer start moved into _loadUserRole() callback below.)

    // Scroll FAB listener — only rebuilds when the relevant booleans flip.
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos    = _scrollController.position;
    final offset = pos.pixels;
    final max    = pos.maxScrollExtent;

    // Show the FAB only while the user is in the "middle" of the list —
    // hidden at the top edge and hidden at the bottom edge.
    const edge   = 80.0; // px from top/bottom where the FAB disappears
    final show   = max > edge * 2 && offset > edge && offset < max - edge;
    // Point toward the farther end — ↑ when past midpoint, ↓ before midpoint.
    final atBtm  = offset >= max / 2;

    if (show != _showScrollFab || atBtm != _scrollAtBottom) {
      setState(() {
        _showScrollFab  = show;
        _scrollAtBottom = atBtm;
      });
    }
  }

  /// Jump to the top and reset FAB state when the user switches filters.
  void _resetScroll() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    // Reset FAB state immediately — the scroll listener will confirm once
    // the frame settles, but this prevents a 1-frame flicker of the wrong icon.
    setState(() {
      _scrollAtBottom = false;
      _showScrollFab  = false;
    });
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
        _loadEscalationBadge();
      }
    });

    _newDeliverySub = TaskAlertService.onNewDelivery.listen((_) {
      if (mounted && isRoomServiceUser) _loadDeliveryCounts();
    });

    // Badge count stream — from EscalationService, not TaskAlertService.
    _escalationSub = EscalationService.instance.onBadgeUpdate.listen((count) {
      if (mounted) {
        setState(() => _escalationBadgeCount = count);
      }
    });

    // List refresh stream — always reload, no selectedFilter guard.
    // Previously this only ran when selectedFilter == "Escalated",
    // leaving the list stale when the user was on another filter tab.
    _escalationListSub = EscalationService.instance.onListRefresh.listen((_) {
      if (mounted) _loadEscalatedTasks();
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
    _escalationTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
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
      // Only reload when the app genuinely returned from background (paused
      // was observed). Notification-shade pulls fire inactive→resumed
      // without ever hitting paused — ignore those.
      if (!_didPause) return;
      _didPause = false;
      _loadTasks();
      if (isRoomServiceUser) _loadDeliveryCounts();
      _loadEscalationBadge();
      if (selectedFilter == "Escalated") _loadEscalatedTasks();
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
      if (_isManagerRole(userRole)) {
        selectedFilter = "Escalated";
      }
      _roleLoaded = true;
    });
    if (_isManagerRole(userRole)) {
      _loadEscalatedTasks();
      // Start 60s periodic check ONLY for Manager / GM / Admin.
      _escalationTimer?.cancel();
      _escalationTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => EscalationService.instance.triggerCheck(),
      );
    }
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

  Future<void> _loadEscalationBadge() async {
    final count = await EscalationService.instance.getBadgeCount();
    if (!mounted) return;
    setState(() => _escalationBadgeCount = count.clamp(0, 9999));
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

  Future<void> _loadEscalatedTasks() async {
    final result = await HomeService().getEscalatedTasks();
    if (!mounted) return;
    if (result["success"] == true) {
      setState(() {
        escalatedTasks = List<Map<String, dynamic>>.from(result["tasks"]);
      });
    }
  }

  Future<void> _loadTasks() async {
    setState(() {
      _isLoading    = true;
      _errorMessage = null;
    });

    final result = await HomeService().getTasks();
    if (!mounted) return;

    if (result["success"] != true) {
      setState(() {
        _errorMessage = result["message"] as String? ?? "Unable to load tasks.";
        _isLoading    = false;
      });
      return;
    }

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
        "assignedTo":  t["raw"]?["assigned_to_name"] ?? "-",
      }).toList();
      _isLoading = false;
    });

    final openCount = tasks.where((t) => t["status"] == "Open").length;
    TaskAlertService.resetServiceCount(openCount);
  }

  // ── Delivery order grouping (mirrors DeliveryPage._groupOrders) ──────────
  // Groups raw per-item rows by orderNumber and parses the timestamp.
  // Returns null for _orderTimeDt when the timestamp is absent/malformed
  // so we never mistake a missing timestamp for a very old order.

  DateTime? _parseOrderTime(String? ts) {
    if (ts == null || ts.trim().isEmpty) return null;
    try {
      String fixed = ts.trim();
      if (fixed.contains(' ') && !fixed.contains('T')) {
        fixed = fixed.replaceFirst(' ', 'T');
      }
      return DateTime.tryParse(fixed);
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> _groupDeliveryOrders(
      List<Map<String, dynamic>> apiOrders) {
    final Map<String, Map<String, dynamic>> grouped = {};
    for (final o in apiOrders) {
      final orderNo = o['orderNumber'];
      if (orderNo == null) continue;
      if (!grouped.containsKey(orderNo)) {
        final dt = _parseOrderTime(o['orderTime']?.toString());
        grouped[orderNo] = {
          'orderNumber':  orderNo,
          'roomNumber':   o['roomNumber'],
          'guestName':    o['guestName'],
          'status':       o['status'],
          'items':        <Map<String, dynamic>>[],
          'orderTime':    o['orderTime'],
          '_orderTimeDt': dt,
          'raw':          o['raw'],
        };
      }
      (grouped[orderNo]!['items'] as List).add({
        'name':   o['foodItem'],
        'qty':    o['quantity'],
        'is_veg': o['raw']?['is_veg'] ?? o['is_veg'],
      });
    }
    return grouped.values.toList();
  }

  Future<void> _loadDeliveryCounts() async {
    if (!mounted) return;
    // Only show skeleton on the very first load — subsequent live updates
    // should update counts silently without flashing the skeleton.
    if (_readyOrderCount == 0 && _acceptedOrderCount == 0 && _deliveredOrderCount == 0) {
      setState(() => _deliveryCountsLoading = true);
    }

    final readyResult     = await HomeService().getReadyOrdersForRoomService();
    final acceptedResult  = await HomeService().getAcceptedOrdersForRoomService();
    final deliveredResult = await HomeService().getDeliveredOrdersForRoomService();

    if (!mounted) return;

    final rawReady     = (readyResult['orders']     as List?)?.cast<Map<String, dynamic>>() ?? [];
    final rawAccepted  = (acceptedResult['orders']  as List?)?.cast<Map<String, dynamic>>() ?? [];
    final rawDelivered = (deliveredResult['orders'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    // Group before counting — each group = one order, not one line-item.
    final groupedReady     = _groupDeliveryOrders(rawReady);
    final groupedAccepted  = _groupDeliveryOrders(rawAccepted);
    final groupedDelivered = _groupDeliveryOrders(rawDelivered);

    // Oldest ready order: sort ascending by timestamp, skip orders whose
    // timestamp could not be parsed (null) to avoid surfacing stale data.
    final ordersWithTime = groupedReady
        .where((o) => (o['_orderTimeDt'] as DateTime?) != null)
        .toList()
      ..sort((a, b) {
        final da = a['_orderTimeDt'] as DateTime;
        final db = b['_orderTimeDt'] as DateTime;
        return da.compareTo(db); // oldest first
      });

    setState(() {
      _readyOrderCount        = groupedReady.length;
      _acceptedOrderCount     = groupedAccepted.length;
      _deliveredOrderCount    = groupedDelivered.length;
      _oldestReadyOrder       = ordersWithTime.isNotEmpty ? ordersWithTime.first : null;
      _deliveryCountsLoading  = false;
    });

    TaskAlertService.resetDeliveryCount(_readyOrderCount);
  }

  // ── Accept task ───────────────────────────────────────────────────────────

  Future<void> _acceptTask(Map<String, dynamic> task) async {
    final taskId       = task["raw"]?["service_request_id"] ?? task["task_id"] ?? task["id"];
    final departmentId = task["raw"]?["department_id"] ?? task["department_id"];
    final enterpriseId = task["raw"]?["enterprise_id"] ?? task["enterprise_id"];
    if (taskId == null) return;

    final intId = int.tryParse(taskId.toString()) ?? 0;
    setState(() => _acceptingTaskId = intId);

    final result = await HomeService().acceptTask(
      taskId:       intId,
      departmentId: departmentId ?? 0,
      enterpriseId: enterpriseId ?? 0,
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

    await TaskAlertService.stopOneServiceAlert();
    await _loadTasks();
    _loadEscalationBadge(); // drop badge immediately
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
      final createdAt = t["raw"]?["created_at"] ?? "";
      final date      = _parseTimestamp(createdAt);
      switch (selectedDateFilter) {
        case "Today":     return isToday(date);
        case "Yesterday": return isYesterday(date);
        case "Older":     return !isToday(date) && !isYesterday(date);
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
    final options = ["All Days", "Today", "Yesterday", "Older"];
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
              final isSelected = selectedDateFilter == opt;
              return InkWell(
                onTap: () {
                  setState(() => selectedDateFilter = opt);
                  Navigator.pop(context);
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
                      Text(opt,
                          style: AppTypography.bodyPrimary.copyWith(
                            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                            color: isSelected ? AppColors.primary : AppColors.textPrimary,
                          )),
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
      floatingActionButton: _showScrollFab
          ? FloatingActionButton.small(
              onPressed: () {
                _scrollController.animateTo(
                  _scrollAtBottom ? 0 : _scrollController.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeInOut,
                );
              },
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              elevation: 4,
              tooltip: _scrollAtBottom ? 'Back to top' : 'Jump to bottom',
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              child: Icon(
                _scrollAtBottom
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 22,
              ),
            )
          : null,
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: AppColors.error),
          const SizedBox(height: 12),
          Text(_errorMessage ?? "Something went wrong",
              style: AppTypography.bodySecondary),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loadTasks,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text("Retry"),
          ),
        ],
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
                if (filter == "Escalated") _loadEscalatedTasks();
                _resetScroll();
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
                                selectedDateFilter,
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

          // Task list — Escalated or normal TimelineTaskCard
          if (selectedFilter == "Escalated")
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
                              _loadEscalatedTasks();
                              _loadEscalationBadge(); // drop badge immediately
                              _resolveEscalationForTask(task);
                            },
                            onReassign: (updatedTask) {
                              setState(() {
                                final idx = tasks.indexWhere((t) =>
                                    t["raw"]["service_request_id"] ==
                                    updatedTask["service_request_id"]);
                                if (idx != -1) {
                                  tasks[idx]["assignedTo"] =
                                      updatedTask["assigned_to_name"] ?? "-";
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
                                  }
                                }
                              });
                              // Refresh escalated list + stop pulse engine.
                              _loadEscalatedTasks();
                              _loadEscalationBadge(); // drop badge immediately
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

  Widget _buildEscalatedList() {
    final displayList = _searchQuery.isEmpty
        ? escalatedTasks
        : escalatedTasks.where((t) => _matchesQuery(t, _searchQuery)).toList();

    if (displayList.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(children: [
            Icon(
                _searchQuery.isEmpty
                    ? Icons.check_circle_outline_rounded
                    : Icons.search_off_rounded,
                size: 48,
                color: _searchQuery.isEmpty
                    ? AppColors.success
                    : AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(
              _searchQuery.isEmpty
                  ? "No escalated tasks"
                  : "No matching escalated tasks",
              style: AppTypography.bodySecondary,
            ),
          ]),
        ),
      );
    }

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
                  onClose:  () => _loadEscalatedTasks(),
                  onNoteAdded: (note) {
                    setState(() {
                      final idx = escalatedTasks.indexWhere((t) =>
                          t["service_request_id"] ==
                          task["service_request_id"]);
                      if (idx != -1) escalatedTasks[idx]["note"] = note;
                    });
                  },
                ),
              ),
            ).then((_) => _loadEscalatedTasks()),
            child: _buildEscalatedCard(task),
          ),
        );
      },
    );
  }

  // ── Escalated task card ───────────────────────────────────────────────────

  Widget _buildEscalatedCard(Map<String, dynamic> task) {
    final room             = (task["room_number"] ?? task["room"] ?? task["requested_room"] ?? "-").toString();
    final requestId        = (task["service_request_id"] ?? task["task_id"] ?? task["id"] ?? "").toString();
    final guestName        = (task["guest_name"] ?? task["guest"] ?? task["full_name"] ?? "").toString();
    final title            = (task["name"] ?? task["title"] ?? task["service_name"] ?? "Service Request").toString();
    final originalAssignee = (task["original_assignee_name"] ?? task["original_assignee"] ?? task["assigned_to_name"] ?? "-").toString();
    final escalatedTo      = (task["escalated_to_name"] ?? task["escalated_to"] ?? task["notified_user_name"] ?? "-").toString();
    final overdueMins      = (task["overdue_minutes"] ?? task["overdueMinutes"] ?? task["age_minutes"] ?? 0) as int;
    final deptName         = (task["department_name"] ?? task["department"] ?? "").toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.error.withOpacity(0.4), width: 1.5),
        boxShadow: [
          BoxShadow(color: AppColors.error.withOpacity(0.08),
              blurRadius: 12, offset: const Offset(0, 3)),
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
                      color: AppColors.errorLight,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.warning_amber_rounded,
                        size: 16, color: AppColors.error),
                  ),
                  const SizedBox(width: 7),
                  _pill("Room $room", AppColors.warningLight, textColor: AppColors.warning),
                  if (requestId.isNotEmpty && requestId != "0") ...[
                    const SizedBox(width: 6),
                    _pill("#$requestId", AppColors.bg, textColor: AppColors.textSecondary),
                  ],
                ]),
                _escalatedPill(),
              ],
            ),
            const SizedBox(height: 8),
            Text(title,
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
            if (deptName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text("🏢 $deptName",
                    style: const TextStyle(color: AppColors.textSecondary,
                        fontSize: 12, fontWeight: FontWeight.w500)),
              ),

            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.timer_off_rounded, size: 13, color: AppColors.error),
              const SizedBox(width: 4),
              Text("$overdueMins min overdue",
                  style: const TextStyle(color: AppColors.error,
                      fontSize: 12, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 4),
            Text("Originally: $originalAssignee",
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            if (escalatedTo != "-")
              Text("Escalated to: $escalatedTo",
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 8),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textDisabled),
          ],
        ),
      ),
    );
  }

  Widget _escalatedPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.errorLight,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.error.withOpacity(0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 5, height: 5,
            decoration: const BoxDecoration(color: AppColors.error, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        const Text("Escalated",
            style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w700, fontSize: 11)),
      ]),
    );
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
                    _pill("Escalated", AppColors.errorLight, textColor: AppColors.error),
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
            if (task["isAccepted"] == true)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.person_rounded, 
                          size: 14, color: AppColors.success),
                      const SizedBox(width: 4),
                      Text(task["assignedTo"] ?? "-",
                          style: const TextStyle(color: AppColors.success,
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

