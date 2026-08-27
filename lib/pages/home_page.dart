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
import '../utils/app_snackbar.dart' show AppSnackBar;
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
  bool  _roleLoaded      = false;
  int?  _acceptingTaskId;
  String? _errorMessage;

  bool _didPause = false;

  bool isFrontOfficeUser = false;
  bool isRoomServiceUser = false;

  List<Map<String, dynamic>> tasks          = [];
  List<Map<String, dynamic>> escalatedTasks = [];
  int  _escalationBadgeCount = 0;

  bool _isSearchExpanded = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  int _readyOrderCount     = 0;
  int _acceptedOrderCount  = 0;
  int _deliveredOrderCount = 0;
  bool _deliveryCountsLoading = true;
  Map<String, dynamic>? _oldestReadyOrder;

  StreamSubscription<void>? _newTaskSub;
  StreamSubscription<void>? _newDeliverySub;
  StreamSubscription<int>?  _escalationSub;
  StreamSubscription<void>? _escalationListSub;
  StreamSubscription<String>? _roleChangeSub;

  Timer? _scrollFabTimer;
  Timer? _escalationTicker;

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

    _escalationTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && escalatedTasks.isNotEmpty) setState(() {});
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos    = _scrollController.position;
    final offset = pos.pixels;
    final max    = pos.maxScrollExtent;

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

  void _subscribeToAlerts() {
    _newTaskSub = TaskAlertService.onNewTask.listen((_) {
      if (mounted) {
        _loadTasks();
      }
    });

    _newDeliverySub = TaskAlertService.onNewDelivery.listen((_) {
      if (mounted && isRoomServiceUser) _loadDeliveryCounts();
    });

    _escalationSub = EscalationService.instance.onBadgeUpdate.listen((_) {
      if (mounted) {
        _loadTasks();
      }
    });

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
    _escalationTicker?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _showScrollFabNotifier.dispose();
    _scrollAtBottomNotifier.dispose();
    _searchController.dispose();
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
      _loadTasks();
      if (isRoomServiceUser) _loadDeliveryCounts();
    }
  }

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
      isRoomServiceUser =
          normalized.any((d) => (d.contains("room") && d.contains("service")) || d.contains("roomservice"));
      _deptLoaded = true;
    });
    if (isRoomServiceUser) {
      _loadDeliveryCounts();
    } else {
      if (mounted) setState(() => _deliveryCountsLoading = false);
    }
  }

  void _recalcEscalation() {
    escalatedTasks = tasks.where((task) {
      if (_isFoodDeliveryRequest(task)) return false;
      if (task['is_escalated'] == 1 || task['is_escalated'] == true) return true;
      final raw = task['raw'] as Map? ?? const {};
      if (raw['is_escalated'] == 1 || raw['is_escalated'] == true) return true;
      final instanceId = task['escalation_instance_id'] ?? raw['escalation_instance_id'];
      if (instanceId != null && instanceId.toString().isNotEmpty && instanceId.toString() != '0') return true;
      return false;
    }).toList();
    _escalationBadgeCount = escalatedTasks.length;
  }

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
      print('_resolveEscalationForTask (non-fatal): $e');
    }
  }

  bool _isFoodDeliveryRequest(Map<String, dynamic> request) {
    final foodSummaryId = request['food_order_summary_id'] ?? request['raw']?['food_order_summary_id'];
    if (foodSummaryId != null &&
        foodSummaryId.toString().trim().isNotEmpty &&
        foodSummaryId.toString() != '0') {
      return true;
    }

    final question = (request['question'] ?? request['title'] ?? request['raw']?['question'] ?? '').toString().toLowerCase();
    if (question.contains('food order') || 
        question.contains('food delivery') ||
        (question.contains('ready for delivery') && question.contains('food'))) {
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

    final List<Map<String, dynamic>> rawList =
        List<Map<String, dynamic>>.from(result["tasks"]);

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
      }).where((task) => !_isFoodDeliveryRequest(task)).toList();

      _recalcEscalation();
      _isLoading = false;
    });

    final openCount = tasks
        .where((t) => t["status"] == "Open" && !_isFoodDeliveryRequest(t))
        .length;
    TaskAlertService.resetServiceCount(openCount);
  }

  // ── Delivery order grouping ──────────────────────────────────────────────

  // ── Timestamp parser ──────────────────────────────────────────────────────
  DateTime _parseTimestamp(String raw) {
    if (raw.isEmpty) return DateTime(2000);
    try {
      return DateTime.parse(raw).toLocal();
    } catch (_) {
      return DateTime(2000);
    }
  }

  // ── Non-zero int resolver ────────────────────────────────────────────────
  int? _nonZeroInt(dynamic v) {
    if (v == null) return null;
    final n = v is int ? v : int.tryParse(v.toString());
    if (n == null || n <= 0) return null;
    return n;
  }

  // ── FIXED: _loadDeliveryCounts using getAllServices as primary source ──
  Future<void> _loadDeliveryCounts() async {
    if (!mounted) return;
    if (_readyOrderCount == 0 && _acceptedOrderCount == 0 && _deliveredOrderCount == 0) {
      setState(() => _deliveryCountsLoading = true);
    }

    try {
      // ── 1. Fetch SERVICE REQUESTS (primary data source) ──────────────────
      // ✅ FIX: Changed from FoodOrderService.getFoodOrders() to TaskService.getAllServices()
      // This ensures Home page counts match Delivery page counts
      final svcResult = await TaskService().getAllServices();
      if (!mounted) return;
      if (svcResult['success'] != true) {
        setState(() => _deliveryCountsLoading = false);
        return;
      }

      final services = svcResult['services'] as List? ?? [];

      // ── 2. Filter for food delivery service requests ──────────────────────
      final foodDeliverySRs = services.where((svc) {
        if (svc is! Map) return false;
        final foodSummaryId = svc['food_order_summary_id'];
        return foodSummaryId != null &&
            foodSummaryId.toString().trim().isNotEmpty &&
            foodSummaryId.toString() != '0' &&
            foodSummaryId.toString() != 'null';
      }).cast<Map<String, dynamic>>().toList();

      // ── 3. Split by SR status for counts ─────────────────────────────────
      final readyCount = foodDeliverySRs.where((sr) {
        final status = (sr['status'] ?? 'Open').toString().toLowerCase();
        return status == 'open' || status == 'pending';
      }).length;

      final acceptedCount = foodDeliverySRs.where((sr) {
        final status = (sr['status'] ?? '').toString().toLowerCase();
        return status == 'in progress' || status == 'inprogress';
      }).length;

      // ── 4. Get oldest ready order for preview ────────────────────────────
      Map<String, dynamic>? oldestPreview;
      if (foodDeliverySRs.isNotEmpty) {
        final sorted = List<Map<String, dynamic>>.from(foodDeliverySRs)
          ..sort((a, b) {
            final aTime = a['created_at']?.toString() ?? '';
            final bTime = b['created_at']?.toString() ?? '';
            return aTime.compareTo(bTime);
          });

        final oldest = sorted.firstWhere(
          (sr) {
            final status = (sr['status'] ?? 'Open').toString().toLowerCase();
            return status == 'open' || status == 'pending';
          },
          orElse: () => {},
        );

        if (oldest.isNotEmpty) {
          final roomNo = (oldest['room_number'] ?? oldest['requested_room'] ?? '—').toString();
          final guestName = (oldest['guest_name'] ?? oldest['name'] ?? 'Guest').toString();
          final orderNumber = oldest['order_number']?.toString() ?? 'SR-${oldest['service_request_id']}';
          final readyTime = oldest['created_at'] ?? oldest['timestamp'];

          oldestPreview = {
            'orderNumber': orderNumber,
            'roomNumber': roomNo,
            'guestName': guestName,
            'orderTime': readyTime?.toString(),
            '_orderTimeDt': readyTime == null ? null : _parseTimestamp(readyTime.toString()),
          };
        }
      }

      // ── 5. Fetch delivered count from food orders API ────────────────────
      int deliveredCount = 0;
      try {
        final foodResult = await FoodOrderService().getFoodOrders();
        if (foodResult['success'] == true) {
          final deliveredRaw = (foodResult['deliveredOrders'] as List? ?? []);
          deliveredCount = deliveredRaw.length;
        }
      } catch (_) {
        // Non-fatal: if food orders API fails, delivered count shows 0
      }

      setState(() {
        _readyOrderCount = readyCount;
        _acceptedOrderCount = acceptedCount;
        _deliveredOrderCount = deliveredCount;
        _oldestReadyOrder = oldestPreview;
        _deliveryCountsLoading = false;
      });

      TaskAlertService.resetDeliveryCount(readyCount, reconcileAlert: true);
    } catch (e) {
      setState(() => _deliveryCountsLoading = false);
    }
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
    final openCount       = tasks.where((t) => t["status"] == "Open" && !_isFoodDeliveryRequest(t)).length;
    final inProgressCount = tasks.where((t) => t["status"] == "In Progress" && !_isFoodDeliveryRequest(t)).length;
    final closedCount     = tasks.where((t) => t["status"] == "Closed" && !_isFoodDeliveryRequest(t)).length;

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _loadTasks,
      child: SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ExecutiveHeaderCard(
              userName: userName,
              userRole: userRole,
              enterpriseName: enterpriseName,
            ),
          ),

          const SizedBox(height: 16),

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
                                  tasks[idx]["is_escalated"] = 0;
                                  tasks[idx]["alert_pending"] = 0;
                                  if (tasks[idx]["raw"] is Map) {
                                    (tasks[idx]["raw"] as Map)["is_escalated"] = 0;
                                    (tasks[idx]["raw"] as Map)["alert_pending"] = 0;
                                  }
                                }
                              });
                              setState(() => _recalcEscalation());
                              _resolveEscalationForTask(task);
                              if (_wasEscalated(task)) _showEscalationResolvedToast('close');
                            },
                            onReassign: (updatedTask) {
                              setState(() {
                                final idx = tasks.indexWhere((t) =>
                                    t["raw"]["service_request_id"] ==
                                    updatedTask["service_request_id"]);
                                if (idx != -1) {
                                  tasks[idx]["assignedTo"] =
                                      updatedTask["assigned_to_name"] ??
                                      updatedTask["accepted_by_user_name"] ??
                                      updatedTask["assigned_to_user_name"] ?? "-";
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
                                    if (updatedTask["assigned_at"] != null) {
                                      raw["assigned_at"] = updatedTask["assigned_at"];
                                    }
                                  }
                                }
                              });
                              setState(() => _recalcEscalation());
                              _resolveEscalationForTask(task, resolutionType: 'reassign');
                              if (_wasEscalated(task)) _showEscalationResolvedToast('reassign');
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
                  onClose:  () {
                    _showEscalationResolvedToast('close');
                    _loadTasks();
                  },
                  onReassign: (updatedTask) {
                    _showEscalationResolvedToast('reassign');
                    _loadTasks();
                  },
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

    final bool isInProgress = status.toLowerCase() == 'in progress';

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
              if (isInProgress) ...[
                const SizedBox(width: 8),
                EscalationDisplay.countdownChip(esc),
              ],
            ]),
          ),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                    _statusPill(status, AppColors.statusColor(status)),
                  ],
                ),

                const SizedBox(height: 10),

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

                if (isInProgress) ...[
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
                ] else ...[
                  if (assignedTo.isNotEmpty && assignedTo != '-')
                    Row(
                      children: [
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
                    ),
                ],
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
              Text(DateFormatter.formatDateTime(createdAt),
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

  // ── Filtered task list getter ─────────────────────────────────────────────

  List<Map<String, dynamic>> get filteredTasks {
    List<Map<String, dynamic>> list = List.from(tasks);

    if (selectedFilter == "Open") {
      list = list.where((t) => t["status"] == "Open").toList();
    } else if (selectedFilter == "In Progress") {
      list = list.where((t) => t["status"] == "In Progress").toList();
    } else if (selectedFilter == "Closed") {
      list = list.where((t) => t["status"] == "Closed").toList();
    } else if (selectedFilter == "Escalated") {
      list = escalatedTasks;
    }

    if (selectedDateFilter != "All Days") {
      final now = DateTime.now();
      list = list.where((t) {
        final raw = t['raw'] as Map? ?? {};
        final dt = _parseTimestamp(
            (raw['created_at'] ?? t['created_at'] ?? '').toString());
        if (selectedDateFilter == "Today") {
          return dt.year == now.year &&
              dt.month == now.month &&
              dt.day == now.day;
        } else if (selectedDateFilter == "Yesterday") {
          final yesterday = now.subtract(const Duration(days: 1));
          return dt.year == yesterday.year &&
              dt.month == yesterday.month &&
              dt.day == yesterday.day;
        } else if (selectedDateFilter == "Custom" &&
            selectedCustomDate != null) {
          return dt.year == selectedCustomDate!.year &&
              dt.month == selectedCustomDate!.month &&
              dt.day == selectedCustomDate!.day;
        }
        return true;
      }).toList();
    }

    if (_searchQuery.isNotEmpty) {
      list = list.where((t) => _matchesQuery(t, _searchQuery)).toList();
    }

    return list;
  }

  // ── Status colour ─────────────────────────────────────────────────────────

  Color getStatusColor(String? status) {
    switch ((status ?? '').toLowerCase()) {
      case 'open':        return AppColors.warning;
      case 'in progress': return AppColors.info;
      case 'closed':      return AppColors.success;
      case 'escalated':   return AppColors.error;
      default:            return AppColors.textSecondary;
    }
  }

  // ── Escalation helpers ────────────────────────────────────────────────────

  bool _wasEscalated(Map<String, dynamic> task) {
    final raw = task['raw'] as Map? ?? {};
    return task['is_escalated'] == 1 ||
        task['is_escalated'] == true ||
        raw['is_escalated'] == 1 ||
        raw['is_escalated'] == true;
  }

  void _showEscalationResolvedToast(String type) {
    final msg = type == 'reassign'
        ? 'Escalated task reassigned successfully'
        : 'Escalated task closed successfully';
    if (mounted) {
      AppSnackBar.show(context, msg);
    }
  }

  // ── Search query matcher ──────────────────────────────────────────────────

  bool _matchesQuery(Map<String, dynamic> task, String query) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return true;
    final raw   = task['raw'] as Map? ?? {};
    final room  = (task['room'] ?? task['room_number'] ?? raw['room_number'] ?? '').toString().toLowerCase();
    final title = (task['title'] ?? task['name'] ?? raw['request_name'] ?? '').toString().toLowerCase();
    final guest = (task['guest_name'] ?? raw['guest_name'] ?? raw['request_name'] ?? '').toString().toLowerCase();
    final id    = (task['service_request_id'] ?? raw['service_request_id'] ?? '').toString();
    return room.contains(q) || title.contains(q) || guest.contains(q) || id.contains(q);
  }

  // ── Accept task ───────────────────────────────────────────────────────────

  Future<void> _acceptTask(Map<String, dynamic> task) async {
    final taskId = int.tryParse(
        (task["raw"]?["service_request_id"] ??
                task["task_id"] ?? task["id"] ?? 0)
            .toString()) ?? 0;
    if (taskId == 0) return;

    setState(() => _acceptingTaskId = taskId);

    final result = await TaskService().acceptServiceRequest(serviceRequestId: taskId);
    if (!mounted) return;

    setState(() => _acceptingTaskId = null);

    if (result['success'] == true) {
      setState(() {
        final idx = tasks.indexWhere((t) =>
            (t["raw"]?["service_request_id"] ?? t["task_id"] ?? t["id"]) == taskId);
        if (idx != -1) {
          tasks[idx]["status"]     = "In Progress";
          tasks[idx]["isAccepted"] = true;
          tasks[idx]["statusColor"] = getStatusColor("In Progress");
        }
      });
       AppSnackBar.show(context, "Task accepted");
    } else {
       AppSnackBar.show(context,
          result['message'] as String? ?? "Failed to accept task",
          isError: true);
    }
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