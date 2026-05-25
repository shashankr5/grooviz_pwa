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
import '../services/task_alert_service.dart';
import 'guest_checkout_page.dart';
import 'ticket_details_page.dart';
import 'profile_page.dart';
import '../utils/user_session_helper.dart';
import '../utils/app_snackbar.dart';
import '../utils/app_colors.dart';

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
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String selectedFilter     = "All";
  String selectedDateFilter = "All Days";
  String userName           = "";
  String userRole           = "";
  int?   loggedInUserId;

  bool  _isLoading       = true;
  bool  _deptLoaded      = false;
  // CHANGE: Added _roleLoaded guard so Manager/GM/Admin never flash "All"
  // before defaulting to the "Escalated" filter. The loading spinner stays
  // up until both dept AND role are resolved.
  bool  _roleLoaded      = false;
  String? _errorMessage;

  bool isRoomServiceUser = false;

  List<Map<String, dynamic>> tasks          = [];
  List<Map<String, dynamic>> escalatedTasks = [];
  int  _escalationBadgeCount = 0;

  // Delivery counts cached from summary cards
  int _readyOrderCount     = 0;
  int _acceptedOrderCount  = 0;
  int _deliveredOrderCount = 0;

  // Alert stream subscriptions
  StreamSubscription<void>? _newTaskSub;
  StreamSubscription<void>? _newDeliverySub;
  StreamSubscription<int>?  _escalationSub;

  // CHANGE: 60s escalation timer — client-side fallback for the SQS
  // self-enqueue loop. Calls triggerEscalationCheck() every 60 seconds.
  // If SQS is already working reliably, this can be removed without
  // breaking anything (the SP is idempotent).
  Timer? _escalationTimer;

  int get currentSectionCount =>
      selectedFilter == "Escalated" ? escalatedTasks.length : filteredTasks.length;

  @override
  void initState() {
    super.initState();
    _loadUserId();
    _loadUserName();
    _loadUserRole();
    _loadTasks();
    _loadUserDepartments();
    _loadDeliveryCounts();
    _loadEscalationBadge();
    _subscribeToAlerts();

    // CHANGE: Start periodic escalation check every 60 seconds.
    _escalationTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => HomeService().triggerEscalationCheck(),
    );
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
      if (mounted) _loadDeliveryCounts();
    });

    // CHANGE: Escalation stream now re-fetches the authoritative badge count
    // from the server (instead of just trusting the WS payload value) and
    // also refreshes the escalated task list if the Escalated filter is active.
    _escalationSub = TaskAlertService.onEscalation.listen((count) {
      if (mounted) {
        setState(() => _escalationBadgeCount = count);
        // Re-fetch real count from server — the WS payload count is a hint,
        // not guaranteed to be current (e.g. if multiple events fire quickly).
        // If the user is already looking at the Escalated tab, refresh it.
        if (selectedFilter == "Escalated") {
          _loadEscalatedTasks();
        }
      }
    });
  }

  @override
  void dispose() {
    _newTaskSub?.cancel();
    _newDeliverySub?.cancel();
    _escalationSub?.cancel();
    // CHANGE: Cancel escalation timer on dispose to prevent memory leaks
    // and avoid calling setState after the widget is removed from the tree.
    _escalationTimer?.cancel();
    super.dispose();
  }

  // ── Loaders ───────────────────────────────────────────────────────────────

  Future<void> _loadUserId() async {
    loggedInUserId = await UserSessionHelper.getUserId();
    if (mounted) setState(() {});
  }

  Future<void> _loadUserName() async {
    final name = await UserSessionHelper.getUserName();
    if (mounted) setState(() { userName = name ?? "User"; });
  }

  Future<void> _loadUserRole() async {
    final role = await UserSessionHelper.getRole();
    if (!mounted) return;
    setState(() {
      userRole = role ?? "";
      // Manager/GM/Admin: default to Escalated view so they land on the
      // most actionable filter immediately.
      if (_isManagerRole(userRole)) {
        selectedFilter = "Escalated";
      }
      // CHANGE: Mark role as loaded — unblocks the loading gate.
      _roleLoaded = true;
    });
    // Load escalated tasks if default filter is Escalated.
    if (_isManagerRole(userRole)) {
      _loadEscalatedTasks();
    }
  }

  Future<void> _loadUserDepartments() async {
    final depts      = await UserSessionHelper.getDepartments();
    final normalized = depts.map((e) => e.toLowerCase().trim()).toList();
    if (!mounted) return;
    setState(() {
      isRoomServiceUser =
          normalized.any((d) => d.contains("room") && d.contains("service"));
      _deptLoaded = true;
    });
  }

  Future<void> _loadEscalationBadge() async {
    final count = await HomeService().getEscalationBadgeCount();
    if (!mounted) return;
    setState(() => _escalationBadgeCount = count);
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
    if (tasks.isEmpty) {
      setState(() {
        _isLoading    = true;
        _errorMessage = null;
      });
    }

    final result = await HomeService().getTasks();
    if (!mounted) return;

    if (result["success"] != true) {
      setState(() {
        _errorMessage = "Unable to load tasks.";
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

  int _distinctOrderCount(List<Map<String, dynamic>> orders) {
    final seen = <dynamic>{};
    for (final o in orders) {
      final orderNo = o["orderNumber"];
      if (orderNo != null) seen.add(orderNo);
    }
    return seen.length;
  }

  Future<void> _loadDeliveryCounts() async {
    final readyResult     = await HomeService().getReadyOrdersForRoomService();
    final acceptedResult  = await HomeService().getAcceptedOrdersForRoomService();
    final deliveredResult = await HomeService().getDeliveredOrdersForRoomService();

    if (!mounted) return;

    final readyOrders     = (readyResult["orders"] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final acceptedOrders  = (acceptedResult["orders"] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final deliveredOrders = (deliveredResult["orders"] as List?)?.cast<Map<String, dynamic>>() ?? [];

    setState(() {
      _readyOrderCount     = _distinctOrderCount(readyOrders);
      _acceptedOrderCount  = _distinctOrderCount(acceptedOrders);
      _deliveredOrderCount = _distinctOrderCount(deliveredOrders);
    });

    TaskAlertService.resetDeliveryCount(_readyOrderCount);
  }

  // ── Accept task ───────────────────────────────────────────────────────────

  Future<void> _acceptTask(Map<String, dynamic> task) async {
    final taskId       = task["raw"]?["service_request_id"];
    final departmentId = task["raw"]?["department_id"] ?? task["department_id"];
    final enterpriseId = task["raw"]?["enterprise_id"] ?? task["enterprise_id"];
    if (taskId == null) return;

    setState(() => _isLoading = true);

    final result = await HomeService().acceptTask(
      taskId:       taskId,
      departmentId: departmentId ?? 0,
      enterpriseId: enterpriseId ?? 0,
    );
    if (!mounted) return;
    setState(() => _isLoading = false);

    if (!result["success"]) {
      _showGenericError();
      return;
    }

    await TaskAlertService.stopOneServiceAlert();
    await _loadTasks();
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
    if (ts.isEmpty) return "";
    final date   = _parseTimestamp(ts);
    final day    = date.day.toString().padLeft(2, '0');
    final month  = date.month.toString().padLeft(2, '0');
    final year   = date.year;
    final hour12 = date.hour > 12 ? date.hour - 12 : date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour >= 12 ? "PM" : "AM";
    return "$day/$month/$year • ${hour12 == 0 ? 12 : hour12}:$minute $period";
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
        // CHANGE: Escalated tasks now sort to the top of the "All" list
        // before the date sort so the most urgent cards are always visible
        // first without the user having to switch to the Escalated filter.
        list = tasks.where((t) => t["status"] != "Closed").toList()
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
    return list.where((t) {
      final createdAt = t["raw"]?["created_at"] ?? "";
      final date      = _parseTimestamp(createdAt);
      switch (selectedDateFilter) {
        case "Today":     return isToday(date);
        case "Yesterday": return isYesterday(date);
        case "Older":     return !isToday(date) && !isYesterday(date);
        default:          return true;
      }
    }).toList();
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
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text("Filter by Date",
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary)),
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
                          style: TextStyle(
                            fontSize: 15,
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

  @override
  Widget build(BuildContext context) {
    // CHANGE: Gate on both _deptLoaded AND _roleLoaded so the loading spinner
    // stays up until the role is resolved. This prevents Manager/GM/Admin
    // from briefly seeing the "All" filter before defaulting to "Escalated".
    if (!_deptLoaded || !_roleLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          _errorMessage != null ? _buildError() : _buildContent(),
          if (_isLoading)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black26,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.white,
      elevation: 0,
      surfaceTintColor: Colors.white,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Hi $userName 👋",
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary)),
          const Text("Here's your task overview",
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        ],
      ),
      actions: [
        if (isRoomServiceUser)
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

  // ── Summary cards ─────────────────────────────────────────────────────────

  Widget _buildTopSummaryCards() {
    final openCount       = tasks.where((t) => t["status"] == "Open").length;
    final inProgressCount = tasks.where((t) => t["status"] == "In Progress").length;
    final closedCount     = tasks.where((t) => t["status"] == "Closed").length;
    final totalTaskCount  = openCount + inProgressCount + closedCount;
    final totalDelivery   = _readyOrderCount + _acceptedOrderCount + _deliveredOrderCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          // Service Tasks card
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => selectedFilter = "All"),
              child: Container(
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(color: AppColors.primary.withOpacity(0.25),
                      blurRadius: 8, offset: const Offset(0, 3))],
                ),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.checklist_rounded, color: Colors.white70, size: 20),
                    const SizedBox(height: 4),
                    Text("$totalTaskCount",
                        style: const TextStyle(color: Colors.white, fontSize: 22,
                            fontWeight: FontWeight.bold, height: 1.1)),
                    const SizedBox(height: 1),
                    const Text("Service Tasks",
                        style: TextStyle(color: Colors.white70, fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Delivery card
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const DeliveryPage())).then((_) {
                if (mounted) _loadDeliveryCounts();
              }),
              child: Container(
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05),
                      blurRadius: 8, offset: const Offset(0, 3))],
                ),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.delivery_dining_rounded, color: AppColors.orange, size: 20),
                    const SizedBox(height: 4),
                    Text("$totalDelivery",
                        style: TextStyle(color: AppColors.orange, fontSize: 22,
                            fontWeight: FontWeight.bold, height: 1.1)),
                    const SizedBox(height: 1),
                    const Text("Delivery",
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
          ),

          // Escalation summary card — Manager/GM/Admin only
          if (_isManagerRole(userRole)) ...[
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTap: () {
                  setState(() => selectedFilter = "Escalated");
                  _loadEscalatedTasks();
                },
                child: Container(
                  height: 80,
                  decoration: BoxDecoration(
                    color: _escalationBadgeCount > 0
                        ? AppColors.error
                        : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [BoxShadow(
                        color: (_escalationBadgeCount > 0
                            ? AppColors.error
                            : Colors.black).withOpacity(0.1),
                        blurRadius: 8, offset: const Offset(0, 3))],
                  ),
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.warning_amber_rounded,
                          color: _escalationBadgeCount > 0
                              ? Colors.white70
                              : AppColors.error,
                          size: 20),
                      const SizedBox(height: 4),
                      Text("$_escalationBadgeCount",
                          style: TextStyle(
                              color: _escalationBadgeCount > 0
                                  ? Colors.white
                                  : AppColors.error,
                              fontSize: 22, fontWeight: FontWeight.bold, height: 1.1)),
                      const SizedBox(height: 1),
                      Text("Escalated",
                          style: TextStyle(
                              color: _escalationBadgeCount > 0
                                  ? Colors.white70
                                  : AppColors.textSecondary,
                              fontSize: 11, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Filter grid ───────────────────────────────────────────────────────────

  Widget _buildTaskFilterGrid() {
    final openCount       = tasks.where((t) => t["status"] == "Open").length;
    final inProgressCount = tasks.where((t) => t["status"] == "In Progress").length;
    final closedCount     = tasks.where((t) => t["status"] == "Closed").length;
    final allCount        = openCount + inProgressCount + closedCount;

    final showEscalated = _isManagerRole(userRole) ||
        (_isSupervisorOrAbove(userRole) && _escalationBadgeCount > 0);

    final filters = [
      {"label": "All",         "count": allCount,               "icon": Icons.all_inclusive_rounded,         "color": AppColors.primary},
      {"label": "Open",        "count": openCount,              "icon": Icons.radio_button_unchecked_rounded, "color": AppColors.info},
      {"label": "In Progress", "count": inProgressCount,        "icon": Icons.timelapse_rounded,              "color": AppColors.orange},
      {"label": "Closed",      "count": closedCount,            "icon": Icons.check_circle_rounded,           "color": AppColors.success},
      if (showEscalated)
        {"label": "Escalated", "count": _escalationBadgeCount,  "icon": Icons.warning_amber_rounded,         "color": AppColors.error},
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: GridView.count(
        crossAxisCount: showEscalated ? 5 : 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.95,
        children: filters.map((f) {
          final isSelected = selectedFilter == f["label"];
          final color      = f["color"] as Color;
          final count      = f["count"] as int;
          return GestureDetector(
            onTap: () {
              setState(() => selectedFilter = f["label"] as String);
              if (f["label"] == "Escalated") _loadEscalatedTasks();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                color: isSelected ? color : Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  if (isSelected)
                    BoxShadow(color: color.withOpacity(0.35),
                        blurRadius: 8, offset: const Offset(0, 3))
                  else
                    BoxShadow(color: Colors.black.withOpacity(0.05),
                        blurRadius: 6, offset: const Offset(0, 1)),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(f["icon"] as IconData,
                      color: isSelected ? Colors.white : color, size: 18),
                  const SizedBox(height: 4),
                  Text("$count",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                          color: isSelected ? Colors.white : color)),
                  Text(f["label"] as String,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                        color: isSelected ? Colors.white70 : AppColors.textSecondary,
                      )),
                ],
              ),
            ),
          );
        }).toList(),
      ),
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
              style: const TextStyle(color: AppColors.textSecondary)),
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
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTopSummaryCards(),
          _buildTaskFilterGrid(),

          // Header row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Service Requests",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary)),
                    Text(
                      "$currentSectionCount ${selectedFilter == 'All' ? 'active' : selectedFilter.toLowerCase()} requests",
                      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                    ),
                  ],
                ),
                if (selectedFilter != "Escalated")
                  GestureDetector(
                    onTap: _showDateFilterSheet,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.calendar_today_rounded, size: 14,
                              color: AppColors.textSecondary),
                          const SizedBox(width: 6),
                          Text(selectedDateFilter,
                              style: const TextStyle(color: AppColors.textPrimary,
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 4),
                          const Icon(Icons.keyboard_arrow_down_rounded, size: 16,
                              color: AppColors.textSecondary),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Task list — Escalated or normal
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
                  child: GestureDetector(
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TicketDetailPage(
                            task:     task,
                            userRole: userRole,
                            onClose: () {
                              setState(() {
                                final idx = tasks.indexWhere((t) =>
                                    t["raw"]["service_request_id"] ==
                                    task["raw"]["service_request_id"]);
                                if (idx != -1) {
                                  tasks[idx]["status"]      = "Closed";
                                  tasks[idx]["statusColor"] = getStatusColor("Closed");
                                  tasks[idx]["isAccepted"]  = false;
                                }
                              });
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
                                  // CHANGE: Clear escalation flags immediately
                                  // so the red border drops without waiting for
                                  // the next task reload.
                                  tasks[idx]["is_escalated"]  = 0;
                                  tasks[idx]["alert_pending"] = 0;
                                  if (tasks[idx]["raw"] is Map) {
                                    final raw = tasks[idx]["raw"] as Map;
                                    raw["is_escalated"]  = 0;
                                    raw["alert_pending"] = 0;
                                  }
                                }
                              });
                            },
                          ),
                        ),
                      );
                      setState(() {});
                    },
                    child: _buildTaskCard(task),
                  ),
                );
              },
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── Escalated task list ───────────────────────────────────────────────────

  Widget _buildEscalatedList() {
    if (escalatedTasks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: Column(children: [
            Icon(Icons.check_circle_outline_rounded, size: 48, color: AppColors.success),
            SizedBox(height: 12),
            Text("No escalated tasks", style: TextStyle(color: AppColors.textSecondary)),
          ]),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: escalatedTasks.length,
      itemBuilder: (context, index) {
        final task = escalatedTasks[index];
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
    final overdueMins      = (task["overdue_minutes"] ?? 0) as int;
    final originalAssignee = task["original_assignee"] as String? ?? "-";
    final escalatedTo      = task["escalated_to"] as String? ?? "-";
    final room             = task["room"] as String? ?? "-";
    final title            = task["title"] as String? ?? "Service Request";
    final guestName        = task["guest"] as String? ?? "";
    final deptName         = task["department_name"] as String? ?? "";

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
                  onPressed: () => _acceptTask(task),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text("Accept",
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 5, height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(status,
            style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11)),
      ]),
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

// ─────────────────────────────────────────────────────────────────────────────
// DeliveryPage
// ─────────────────────────────────────────────────────────────────────────────

class DeliveryPage extends StatefulWidget {
  const DeliveryPage({super.key});

  @override
  State<DeliveryPage> createState() => _DeliveryPageState();
}

class _DeliveryPageState extends State<DeliveryPage> {
  bool    _isLoading = true;
  String? _errorMessage;
  String  selectedFilter = "Ready";

  final List<Map<String, dynamic>> readyOrders     = [];
  final List<Map<String, dynamic>> acceptedOrders  = [];
  final List<Map<String, dynamic>> deliveredOrders = [];

  StreamSubscription<void>? _deliverySub;

  @override
  void initState() {
    super.initState();
    _loadAllOrders();
    _deliverySub = TaskAlertService.onNewDelivery.listen((_) {
      if (mounted) _loadAllOrders();
    });
  }

  @override
  void dispose() {
    _deliverySub?.cancel();
    super.dispose();
  }

  Future<void> _loadAllOrders() async {
    setState(() {
      _isLoading    = true;
      _errorMessage = null;
    });
    try {
      await Future.wait([
        _loadReadyOrders(),
        _loadAcceptedOrders(),
        _loadDeliveredOrders(),
      ]);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadReadyOrders() async {
    final result = await HomeService().getReadyOrdersForRoomService();
    if (!mounted) return;
    if (result["success"] != true) {
      setState(() { _errorMessage = "Unable to load orders."; });
      return;
    }
    final grouped =
        _groupOrders(List<Map<String, dynamic>>.from(result["orders"]));
    setState(() {
      readyOrders
        ..clear()
        ..addAll(grouped.map((o) => {...o, "uiStatus": "Ready"}));
    });
    TaskAlertService.resetDeliveryCount(readyOrders.length);
  }

  Future<void> _loadAcceptedOrders() async {
    final result = await HomeService().getAcceptedOrdersForRoomService();
    if (!mounted) return;
    if (result["success"] != true) return;
    final grouped =
        _groupOrders(List<Map<String, dynamic>>.from(result["orders"]));
    setState(() {
      acceptedOrders
        ..clear()
        ..addAll(grouped.map((o) => {...o, "uiStatus": "Accepted"}));
    });
  }

  Future<void> _loadDeliveredOrders() async {
    final result = await HomeService().getDeliveredOrdersForRoomService();
    if (!mounted) return;
    if (result["success"] != true) return;
    final grouped =
        _groupOrders(List<Map<String, dynamic>>.from(result["orders"]));
    setState(() {
      deliveredOrders
        ..clear()
        ..addAll(grouped.map((o) => {...o, "uiStatus": "Delivered"}));
    });
  }

  DateTime _parseOrderTime(String? ts) {
    if (ts == null || ts.trim().isEmpty) return DateTime(2000);
    try {
      String fixed = ts.trim();
      if (fixed.contains(' ') && !fixed.contains('T')) {
        fixed = fixed.replaceFirst(' ', 'T');
      }
      return DateTime.parse(fixed);
    } catch (_) {
      return DateTime(2000);
    }
  }

  List<Map<String, dynamic>> _groupOrders(
      List<Map<String, dynamic>> apiOrders) {
    final Map<String, Map<String, dynamic>> grouped = {};
    for (final o in apiOrders) {
      final orderNo = o["orderNumber"];
      if (orderNo == null) continue;
      if (!grouped.containsKey(orderNo)) {
        grouped[orderNo] = {
          "orderNumber":  orderNo,
          "roomNumber":   o["roomNumber"],
          "guestName":    o["guestName"],
          "status":       o["status"],
          "items":        [],
          "orderTime":    o["orderTime"],
          "_orderTimeDt": _parseOrderTime(o["orderTime"]?.toString()),
          "raw":          o["raw"],
        };
      }
      grouped[orderNo]!["items"].add({
        "name":   o["foodItem"],
        "qty":    o["quantity"],
        "is_veg": o["raw"]?["is_veg"] ?? o["is_veg"],
      });
    }

    final result = grouped.values.toList();
    result.sort((a, b) {
      final da = a["_orderTimeDt"] as DateTime;
      final db = b["_orderTimeDt"] as DateTime;
      return db.compareTo(da);
    });
    return result;
  }

  List<Map<String, dynamic>> get filteredOrders {
    switch (selectedFilter) {
      case "Ready":     return readyOrders;
      case "Accepted":  return acceptedOrders;
      case "Delivered": return deliveredOrders;
      default:          return readyOrders;
    }
  }

  void _showGenericError() {
    if (!mounted) return;
    AppSnackBar.show(context, "Something went wrong. Please try again.",
        isError: true);
  }

  Future<void> _acceptOrder(Map<String, dynamic> order) async {
    setState(() {
      _isLoading = true;
      selectedFilter = "Accepted";
    });

    final res = await HomeService().updateRoomServiceStatus(
        orderNumber: order["orderNumber"], action: "Accept");

    if (!mounted) return;

    final success = res["success"] == true || res["success"] == 1;
    if (!success) {
      setState(() => _isLoading = false);
      _showGenericError();
      return;
    }

    await TaskAlertService.stopOneDeliveryAlert();
    await _loadAllOrders();
    if (mounted) AppSnackBar.show(context, "Order accepted ✅");
  }

  Future<void> _deliverOrder(Map<String, dynamic> order) async {
    final confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text("Confirm Delivery",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 8),
              const Text("Mark this order as delivered?",
                  style: TextStyle(fontSize: 15, color: AppColors.textSecondary)),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textPrimary,
                        side: const BorderSide(color: AppColors.border),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text("Cancel",
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text("Deliver",
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

    if (confirm != true) return;

    setState(() {
      _isLoading     = true;
      selectedFilter = "Delivered";
    });

    final res = await HomeService().updateRoomServiceStatus(
        orderNumber: order["orderNumber"], action: "Delivered");

    if (!mounted) return;

    final success = res["success"] == true || res["success"] == 1;
    if (!success) {
      setState(() => _isLoading = false);
      _showGenericError();
      return;
    }

    await _loadAllOrders();
    if (mounted) AppSnackBar.show(context, "Order delivered successfully 🎉");
  }

  String formatDateTime(String ts) {
    if (ts.isEmpty) return "";
    try {
      String fixed = ts.trim();
      if (fixed.contains(" ") && !fixed.contains("T")) {
        fixed = fixed.replaceFirst(" ", "T");
      }
      final date   = DateTime.parse(fixed);
      final day    = date.day.toString().padLeft(2, '0');
      final month  = date.month.toString().padLeft(2, '0');
      final year   = date.year;
      final hour12 = date.hour > 12 ? date.hour - 12 : date.hour;
      final minute = date.minute.toString().padLeft(2, '0');
      final period = date.hour >= 12 ? "PM" : "AM";
      return "$day/$month/$year • ${hour12 == 0 ? 12 : hour12}:$minute $period";
    } catch (_) {
      return "";
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text("Delivery Management",
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: AppColors.textPrimary,
      ),
      body: Column(
        children: [
          _buildFilterRow(),
          if (_isLoading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_errorMessage != null)
            Expanded(child: Center(child: Text(_errorMessage!)))
          else if (filteredOrders.isEmpty)
            const Expanded(
                child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.delivery_dining_rounded,
                            size: 48, color: AppColors.textDisabled),
                        SizedBox(height: 12),
                        Text("No orders",
                            style: TextStyle(
                                color: AppColors.textDisabled, fontSize: 15)),
                      ],
                    )))
          else
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadAllOrders,
                color: AppColors.primary,
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: filteredOrders.length,
                  itemBuilder: (context, index) =>
                      _buildOrderCard(filteredOrders[index]),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterRow() {
    final filters = ["Ready", "Accepted", "Delivered"];
    final counts  = [readyOrders.length, acceptedOrders.length, deliveredOrders.length];
    final colors  = [AppColors.orange, AppColors.info, AppColors.success];
    final icons   = [
      Icons.room_service_rounded,
      Icons.delivery_dining_rounded,
      Icons.check_circle_rounded,
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: filters.asMap().entries.map((entry) {
          final i          = entry.key;
          final filter     = entry.value;
          final isSelected = selectedFilter == filter;
          final color      = colors[i];
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => selectedFilter = filter),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: EdgeInsets.symmetric(horizontal: i == 1 ? 4 : 0),
                height: 72,
                decoration: BoxDecoration(
                  color: isSelected ? color : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isSelected ? color : AppColors.border,
                    width: 1.5,
                  ),
                  boxShadow: [
                    if (isSelected)
                      BoxShadow(color: color.withOpacity(0.3),
                          blurRadius: 8, offset: const Offset(0, 3))
                    else
                      BoxShadow(color: Colors.black.withOpacity(0.04),
                          blurRadius: 4, offset: const Offset(0, 1)),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icons[i], color: isSelected ? Colors.white : color, size: 18),
                    const SizedBox(height: 4),
                    Text("${counts[i]}",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                            color: isSelected ? Colors.white : color)),
                    const SizedBox(height: 2),
                    Text(filter,
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                            color: isSelected ? Colors.white.withOpacity(0.85) : color)),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildOrderCard(Map<String, dynamic> order) {
    final items     = order["items"] as List;
    final uiStatus  = order["uiStatus"] as String;
    final guestName = order["guestName"] ?? "";

    Color statusColor;
    Color roomBgColor;
    Color roomTextColor;

    switch (uiStatus) {
      case "Ready":
        statusColor   = AppColors.orange;
        roomBgColor   = Colors.indigo.shade50;
        roomTextColor = Colors.indigo;
        break;
      case "Accepted":
        statusColor   = AppColors.info;
        roomBgColor   = AppColors.infoLight;
        roomTextColor = AppColors.info;
        break;
      case "Delivered":
        statusColor   = AppColors.success;
        roomBgColor   = AppColors.successLight;
        roomTextColor = AppColors.success;
        break;
      default:
        statusColor   = AppColors.textDisabled;
        roomBgColor   = AppColors.surfaceAlt;
        roomTextColor = AppColors.textSecondary;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05),
              blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: roomBgColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Room",
                          style: TextStyle(fontSize: 11, color: roomTextColor,
                              fontWeight: FontWeight.w600)),
                      Text("${order["roomNumber"]}",
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                              color: roomTextColor, height: 1.1)),
                    ],
                  ),
                ),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: statusColor.withOpacity(0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(width: 6, height: 6,
                              decoration: BoxDecoration(color: statusColor,
                                  shape: BoxShape.circle)),
                          const SizedBox(width: 5),
                          Text(uiStatus,
                              style: TextStyle(color: statusColor,
                                  fontWeight: FontWeight.w700, fontSize: 12)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text("#${order["orderNumber"]}",
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 4),
                    Row(children: [
                      const Icon(Icons.access_time_rounded, size: 11,
                          color: AppColors.textSecondary),
                      const SizedBox(width: 3),
                      Text(formatDateTime(order["orderTime"] ?? ""),
                          style: const TextStyle(fontSize: 11,
                              color: AppColors.textSecondary)),
                    ]),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 10),

            if (guestName.isNotEmpty)
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: const BoxDecoration(
                      color: AppColors.surfaceAlt, shape: BoxShape.circle),
                  child: const Icon(Icons.person_rounded, size: 12,
                      color: AppColors.textSecondary),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(guestName,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary),
                      overflow: TextOverflow.ellipsis),
                ),
              ]),

            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Divider(height: 1, color: AppColors.borderLight),
            ),

            const Row(children: [
              Icon(Icons.restaurant_menu_rounded, size: 13, color: AppColors.textDisabled),
              SizedBox(width: 5),
              Text("Order Items",
                  style: TextStyle(fontSize: 11, color: AppColors.textDisabled,
                      fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),

            ...items.map<Widget>((item) {
              final isVeg = resolveIsVeg(item["is_veg"]);
              return Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    vegIndicator(isVeg),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(item["name"] ?? "",
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(7)),
                      child: Text("${item["qty"]}",
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary)),
                    ),
                  ],
                ),
              );
            }),

            const SizedBox(height: 10),

            if (uiStatus == "Ready")
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _acceptOrder(order),
                  icon: const Icon(Icons.check_circle_rounded, size: 16),
                  label: const Text("Accept",
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            if (uiStatus == "Accepted")
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _deliverOrder(order),
                  icon: const Icon(Icons.check_circle_rounded, size: 16),
                  label: const Text("Deliver",
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}