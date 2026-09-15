// lib/pages/tasks_page.dart
//
// REDESIGNED TASKS PAGE:
//  • Date Preset Filter at Top (Today, Yesterday, This Week, Custom date picker)
//    - Matches Order History Page design & interaction patterns.
//    - Uniformly drives tasks list, KPI metrics, and F&B operations analytics.
//  • Role-Based Scoping:
//    - Staff (role_id 6 / 'Staff'): Shows ONLY their assigned/accepted tasks.
//      Dedicated Staff Personal Summary & simplified view.
//    - Managing Director (role_id 8 / 'Managing Director' / 'MD'): Full enterprise
//      access across all departments with department switching.
//    - Other roles (Supervisor, Dept Head, Manager): Scoped to their assigned
//      departments (from user session / users_dept).
//  • F&B Operations:
//    - Local filter pills removed; driven directly by the global top filter.
//  • Clean, modern, responsive UI with search, KPI metric cards, department
//    benchmarking, drill-downs, and bottom sheets.

import 'dart:async';
import 'package:flutter/material.dart';
import '../services/home_service.dart';
import '../services/profile_service.dart';
import '../services/food_order_service.dart';
import '../services/midnight_notifier.dart';
import '../services/websocket_service.dart';
import '../utils/user_session_helper.dart';
import '../utils/date_formatter.dart';

import '../theme/app_typography.dart';
import '../theme/app_colors.dart';
import '../components/skeleton_loader.dart';
import '../pages/ticket_details_page.dart';

// ── Role helpers ──────────────────────────────────────────────────────────────

bool _isManagingDirector(int? roleId, [String? roleName]) {
  if (roleId == 8) return true;
  if (roleName != null) {
    final r = roleName.toLowerCase();
    if (r.contains('managing director') || r == 'md') return true;
  }
  return false;
}

bool _isGmOrAdmin(int? roleId, [String? roleName]) {
  if (_isManagingDirector(roleId, roleName)) return true;
  if (roleId != null && (roleId == 1 || roleId == 2)) return true;
  if (roleName != null) {
    final r = roleName.toLowerCase();
    if (r.contains('admin') || r.contains('general manager') || r == 'gm') return true;
  }
  return false;
}

bool _isStaff(int? roleId, [String? roleName]) {
  if (roleId == 6) return true;
  if (roleName != null && roleName.toLowerCase().trim() == 'staff') return true;
  // If no roleId or explicit role, default to staff for safety
  if (roleId == null && (roleName == null || roleName.isEmpty)) return true;
  return false;
}

bool _isSupervisorOrAbove(int? roleId, [String? roleName]) {
  if (_isGmOrAdmin(roleId, roleName) || _isManagingDirector(roleId, roleName)) return true;
  if (roleId != null && roleId <= 5) return true;
  if (roleName != null) {
    const hierarchy = ['Supervisor', 'Department Head', 'Manager', 'General Manager', 'Admin', 'Managing Director'];
    return hierarchy.any((h) => roleName.toLowerCase().contains(h.toLowerCase()));
  }
  return false;
}

bool _isSupervisorOrAboveByName(String? role) {
  if (role == null) return false;
  final r = role.toLowerCase();
  return r.contains('supervisor') ||
      r.contains('department head') ||
      r.contains('dept head') ||
      r.contains('manager') ||
      r.contains('admin') ||
      r.contains('director');
}

// ── Title resolver ────────────────────────────────────────────────────────────
String _resolveTitle(Map<String, dynamic> task) {
  final name = task['task_name']?.toString() ?? '';
  if (name.isNotEmpty) return name;
  final question = task['question']?.toString() ?? '';
  if (question.isNotEmpty) return question;
  return (task['title']?.toString() ?? 'Service Request');
}

// ─────────────────────────────────────────────────────────────────────────────

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => TasksPageState();
}

class TasksPageState extends State<TasksPage> {
  void refreshData() {
    _onRefresh();
  }

  StreamSubscription<void>? _midnightSub;
  StreamSubscription<Map<String, dynamic>>? _wsSubscription;

  final HomeService _homeService = HomeService();
  final FoodOrderService _foodOrderService = FoodOrderService();
  final TextEditingController _searchController = TextEditingController();

  // ── Session ───────────────────────────────────────────────────────────────
  String       _userRole       = '';
  int?         _userId;
  int?         _userRoleId;
  
  // ── Filter Bar (Order History Style) ──────────────────────────────────────
  String   _selectedPreset = 'Today'; // Today, Yesterday, This Week, Custom
  DateTime _selectedDate   = DateTime.now();
  String   _searchQuery    = '';

  // ── Available dept options for filter dropdown ────────────────────────────
  List<String> _availableFilterDepts = [];

  // ── Task Data State ───────────────────────────────────────────────────────
  bool    _statsLoading   = true;
  String? _statsError;
  int     totalTasks      = 0;
  int     openTasks       = 0;
  int     completedTasks  = 0;
  int     inProgressTasks = 0;
  int     escalatedTasks  = 0;

  List<dynamic> _allRawTasks  = []; // All tasks fetched from server
  List<dynamic> _allTasks     = []; // Role + Date + Dept filtered tasks

  // ── Team Performance & SLA Metrics ────────────────────────────────────────
  Map<String, Map<String, dynamic>> _deptPerformance      = {};
  List<Map<String, dynamic>>        _reportDepts          = [];
  List<Map<String, dynamic>>        _weeklyReportDepts    = [];

  // ── F&B Analytics & Live Orders ───────────────────────────────────────────
  Map<String, dynamic>       _overallSummary      = {};
  List<Map<String, dynamic>> _weeklyFood          = [];
  List<Map<String, dynamic>> _foodOrders          = [];
  bool                       _isFbUser            = false;

  // ── Occupancy Data ────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _weeklyGuests        = [];
  List<Map<String, dynamic>> _monthlyGuests       = [];
  bool                       _isOccupancyExpanded = false;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _init();
    _setupWebSocketListener();
    _midnightSub = MidnightNotifier.instance.onMidnight.listen((_) {
      if (mounted) _onRefresh();
    });
  }

  void _setupWebSocketListener() {
    _wsSubscription = WebSocketService().stream.listen((event) {
      if (!mounted) return;
      final payload = (event['data'] is Map)
          ? Map<String, dynamic>.from(event['data'] as Map)
          : event;
      final type = (event['type'] ?? payload['type'] ?? '').toString().toUpperCase();
      
      if (type == 'NEW_SERVICE_TASK'        ||
          type == 'NEW_SERVICE_REQUEST'     ||
          type == 'SERVICE_TASK_ACCEPTED'   ||
          type == 'SERVICE_REQUEST_ACCEPTED'||
          type == 'TASK_ACCEPTED'           ||
          type == 'TASK_CLOSED'             ||
          type == 'TASK_REASSIGNED'         ||
          type == 'TASK_UPDATED'            ||
          type == 'SERVICE_TASK_UPDATED'    ||
          type == 'SERVICE_REQUEST_UPDATED' ||
          type == 'SERVICE_STATUS_CHANGED'  ||
          type == 'TICKET_UPDATED'          ||
          type == 'ESCALATION_ALERT'        ||
          type == 'NOTE_ADDED'              ||
          type == 'TASK_NOTE_ADDED') {
        _onRefresh();
      }
    });
  }

  @override
  void dispose() {
    _midnightSub?.cancel();
    _wsSubscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    final role   = await UserSessionHelper.getRole();
    final roleId = await UserSessionHelper.getRoleId();
    final userId = await UserSessionHelper.getUserId();
    final depts  = await UserSessionHelper.getDepartments();
    
    if (!mounted) return;

    final derivedRoleId = roleId ?? _deriveRoleId(role);

    setState(() {
      _userRole       = role ?? '';
      _userRoleId     = derivedRoleId;
      _userId         = userId;

      _availableFilterDepts = List.from(depts)..sort();
    });

    await Future.wait([
      _loadAllTasksAndStats(),
      _loadFoodOrders(),
      _loadOperationsReport(),
      if (_isSupervisorOrAbove(_userRoleId, _userRole)) _loadTeamPerformance(),
    ]);
  }

  int? _deriveRoleId(String? role) {
    if (role == null) return null;
    final r = role.toLowerCase().trim();
    if (r == 'admin') return 1;
    if (r == 'general manager' || r == 'gm') return 2;
    if (r == 'manager') return 3;
    if (r == 'department head' || r == 'dept head') return 4;
    if (r == 'supervisor') return 5;
    if (r == 'staff') return 6;
    if (r == 'managing director' || r == 'md') return 8;
    return null;
  }

  Future<void> _loadOperationsReport() async {
    try {
      final report = await _homeService.getServiceOperationsReport();
      if (report['success'] == true && mounted) {
        final overall = report['overall'] as Map<String, dynamic>? ?? {};
        final weeklyFood = (report['weeklyFood'] as List? ?? []).cast<Map<String, dynamic>>();
        final weeklyGuests = (report['weeklyGuests'] as List? ?? []).cast<Map<String, dynamic>>();
        final monthlyGuests = (report['monthlyGuests'] as List? ?? []).cast<Map<String, dynamic>>();

        final depts = (report['departments'] as List? ?? []).cast<Map<String, dynamic>>();
        final weeklyDepts = (report['weeklyDepartments'] as List? ?? []).cast<Map<String, dynamic>>();

        setState(() {
          _overallSummary = overall;
          _weeklyFood = weeklyFood;
          _reportDepts = depts;
          _weeklyReportDepts = weeklyDepts;
          if (weeklyGuests.isNotEmpty) {
            _weeklyGuests = weeklyGuests;
          }
          if (monthlyGuests.isNotEmpty) {
            _monthlyGuests = monthlyGuests;
          }
        });
        _applyTaskFilters();
      }
    } catch (_) {}
  }

  Future<void> _loadFoodOrders() async {
    try {
      final result = await _foodOrderService.getFoodOrders();
      if (result['success'] == true && mounted) {
        final active = (result['orders'] as List? ?? []).cast<Map<String, dynamic>>();
        final delivered = (result['deliveredOrders'] as List? ?? []).cast<Map<String, dynamic>>();
        final cancelled = (result['cancelledOrders'] as List? ?? []).cast<Map<String, dynamic>>();

        List<Map<String, dynamic>> combined = [...active, ...delivered, ...cancelled];

        if (combined.isEmpty) {
          try {
            final summaryResult = await _foodOrderService.getOrderSummary();
            if (summaryResult['success'] == true && summaryResult['orders'] is List) {
              combined = (summaryResult['orders'] as List).cast<Map<String, dynamic>>();
            }
          } catch (_) {}
        }

        setState(() {
          _foodOrders = combined;
        });
      }
    } catch (_) {}
  }

  // ── Helper to check if task is assigned to current user ───────────────────
  bool _isTaskAssignedToUser(Map<String, dynamic> task) {
    if (_userId == null) return false;
    final raw = task['raw'] as Map<String, dynamic>? ?? task;
    
    final acceptedByUserId = raw['accepted_by_user_id'] ?? task['accepted_by_user_id'];
    if (acceptedByUserId != null && acceptedByUserId.toString() == _userId.toString()) {
      return true;
    }
    
    final assignedTo = raw['assigned_to'] ?? task['assigned_to'];
    if (assignedTo != null && assignedTo.toString() == _userId.toString()) {
      return true;
    }
    
    return false;
  }

  // ── Date parsing & matching helpers ───────────────────────────────────────
  DateTime? _parseTaskDate(Map<String, dynamic> task) {
    try {
      final raw = task['raw'] as Map<String, dynamic>? ?? task;
      final val = task['created_at'] ??
          raw['created_at'] ??
          task['task_created_at'] ??
          raw['task_created_at'] ??
          task['time'] ??
          task['createdAt'];
      if (val is DateTime) return val;
      if (val != null) {
        return DateTime.tryParse(val.toString());
      }
    } catch (_) {}
    return null;
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _isDateInCurrentWeek(DateTime dt) {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
    final sunday = monday.add(const Duration(days: 7));
    return (dt.isAfter(monday.subtract(const Duration(seconds: 1))) && dt.isBefore(sunday));
  }

  bool _matchesDateFilter(DateTime? dt) {
    if (dt == null) return true; // Include if date cannot be parsed

    if (_selectedPreset == 'Today') {
      return _isSameDay(dt, DateTime.now());
    } else if (_selectedPreset == 'Yesterday') {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      return _isSameDay(dt, yesterday);
    } else if (_selectedPreset == 'This Week') {
      return _isDateInCurrentWeek(dt);
    } else if (_selectedPreset == 'Custom') {
      return _isSameDay(dt, _selectedDate);
    }
    return true;
  }

  // ── Main Task Loader & Filter Engine ──────────────────────────────────────

  Future<void> _loadAllTasksAndStats() async {
    if (!mounted) return;
    setState(() {
      _statsLoading = true;
      _statsError   = null;
    });

    try {
      final tasksResult = await _homeService.getTasks();
      
      if (!mounted) return;

      if (tasksResult['success'] == true) {
        final rawTasks = (tasksResult['tasks'] as List?) ?? [];
        _allRawTasks = rawTasks;
        _applyTaskFilters();
      } else {
        setState(() {
          _statsLoading = false;
          _statsError   = tasksResult['message'] as String? ?? 'Failed to load tasks.';
          _allRawTasks  = [];
          _allTasks     = [];
          totalTasks    = 0;
          openTasks     = 0;
          completedTasks = 0;
          inProgressTasks = 0;
          escalatedTasks = 0;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statsLoading = false;
          _statsError   = 'Failed to connect. Please pull down to refresh.';
        });
      }
    }
  }

  void _applyTaskFilters() {
    final isStaffUser = _isStaff(_userRoleId, _userRole);
    final isMdUser = _isManagingDirector(_userRoleId, _userRole);
    final isGmOrAdminUser = _isGmOrAdmin(_userRoleId, _userRole);

    final userDeptNames = _availableFilterDepts
        .map((d) => d.toLowerCase().trim())
        .toSet();

    List<dynamic> filtered = _allRawTasks.where((task) {
      if (task is! Map<String, dynamic>) return false;
      final raw = task['raw'] as Map<String, dynamic>? ?? task;

      // 1. Role Scoping
      if (isStaffUser) {
        // Staff: ONLY show their assigned/accepted tasks
        if (!_isTaskAssignedToUser(task)) return false;
      } else if (!isMdUser && !isGmOrAdminUser && userDeptNames.isNotEmpty) {
        // Other roles: Scoped to their assigned departments
        final dept = (raw['department_name'] ?? task['department_name'] ?? task['department'] ?? '')
            .toString()
            .toLowerCase()
            .trim();
        if (dept.isNotEmpty && !userDeptNames.contains(dept)) {
          return false;
        }
      }

      // 2. Date Preset Filter
      final taskDate = _parseTaskDate(task);
      if (!_matchesDateFilter(taskDate)) {
        return false;
      }

      // 3. Search Query Filter
      if (_searchQuery.trim().isNotEmpty) {
        final q = _searchQuery.toLowerCase().trim();
        final title = _resolveTitle(task).toLowerCase();
        final room = (task['room_number'] ?? task['room'] ?? raw['room_number'] ?? '').toString().toLowerCase();
        final guest = (task['guest'] ?? raw['guest_name'] ?? '').toString().toLowerCase();
        final dept = (raw['department_name'] ?? task['department_name'] ?? '').toString().toLowerCase();
        final staff = (raw['accepted_by_user_name'] ?? raw['closed_by_user_name'] ?? task['assignedTo'] ?? '').toString().toLowerCase();
        
        if (!title.contains(q) &&
            !room.contains(q) &&
            !guest.contains(q) &&
            !dept.contains(q) &&
            !staff.contains(q)) {
          return false;
        }
      }

      return true;
    }).toList();

    // Calculate metrics from the filtered tasks
    int calculatedTotal = filtered.length;
    int calculatedOpen = 0;
    int calculatedCompleted = 0;
    int calculatedInProgress = 0;
    int calculatedEscalated = 0;

    for (final task in filtered) {
      if (task is! Map<String, dynamic>) continue;
      final raw = task['raw'] as Map<String, dynamic>? ?? task;

      // Use the mapped 'status' field first (already normalized by home_service
      // _statusText). Fall back to raw['status'] for tasks not through _mapTasks.
      // Do NOT use task_flag as a status — it may be 'Escalated' etc.
      final rawStatus = (task['status'] ?? raw['status'] ?? '').toString().trim();
      final statusNorm = rawStatus.toLowerCase();

      final isEsc = (task['is_escalated'] == 1 ||
          task['is_escalated'] == true ||
          raw['is_escalated'] == 1 ||
          raw['escalation_instance_id'] != null ||
          task['escalation_instance_id'] != null);

      if (isEsc) calculatedEscalated++;

      // Exhaustive status bucketing — must cover every value _statusText produces.
      if (statusNorm == 'closed' || statusNorm == 'completed') {
        calculatedCompleted++;
      } else if (statusNorm == 'in progress' ||
                 statusNorm == 'inprogress' ||
                 statusNorm == 'in_progress' ||
                 statusNorm == 'assigned' ||
                 statusNorm == 'accepted') {
        calculatedInProgress++;
      } else {
        // 'open', 'pending', '', unknown — all treated as Open
        calculatedOpen++;
      }
    }

    _recomputeDeptPerformance();

    // Cumulative sum across all departments for non-staff roles
    if (!_isStaff(_userRoleId, _userRole) && _deptPerformance.isNotEmpty) {
      int sumTotal = 0;
      int sumOpen = 0;
      int sumInProg = 0;
      int sumClosed = 0;
      int sumEsc = 0;

      for (final d in _deptPerformance.values) {
        final tot = (d['total_assigned'] as int?) ?? 0;
        final cl  = (d['total_closed'] as int?) ?? 0;
        final op  = (d['open_tasks'] as int?) ?? (tot - cl).clamp(0, 9999);
        final ip  = (d['in_progress_tasks'] as int?) ?? 0;
        final es  = (d['total_escalated'] as int?) ?? 0;

        sumTotal  += tot;
        sumOpen   += op;
        sumInProg += ip;
        sumClosed += cl;
        sumEsc    += es;
      }

      if (sumTotal > 0) {
        calculatedTotal      = sumTotal;
        calculatedOpen       = sumOpen;
        calculatedInProgress = sumInProg;
        calculatedCompleted  = sumClosed;
        calculatedEscalated  = sumEsc;
      }
    }

    setState(() {
      _allTasks       = filtered;
      totalTasks      = calculatedTotal;
      openTasks       = calculatedOpen;
      completedTasks  = calculatedCompleted;
      inProgressTasks = calculatedInProgress;
      escalatedTasks  = calculatedEscalated;
      _statsLoading   = false;
      _statsError     = null;
    });
  }

  double _extractTaskPrice(Map<String, dynamic> task) {
    final raw = task['raw'] as Map<String, dynamic>? ?? task;
    final candidates = [
      task['total_price'],
      task['totalPrice'],
      task['price'],
      task['amount'],
      task['total_amount'],
      task['grand_total'],
      task['food_price'],
      task['order_amount'],
      raw['total_price'],
      raw['totalPrice'],
      raw['price'],
      raw['amount'],
      raw['total_amount'],
      raw['grand_total'],
      raw['food_price'],
      raw['order_amount'],
    ];
    for (final c in candidates) {
      if (c != null) {
        final v = (c is num) ? c.toDouble() : double.tryParse(c.toString());
        if (v != null && v > 0) return v;
      }
    }
    return 0.0;
  }

  double? _extractTaskResolutionMins(Map<String, dynamic> task) {
    try {
      final raw = task['raw'] as Map<String, dynamic>? ?? task;
      final direct = task['time_taken'] ??
          raw['time_taken'] ??
          task['duration_hours'] ??
          raw['duration_hours'] ??
          task['duration'] ??
          task['average_time_taken'] ??
          raw['average_time_taken'] ??
          task['avg_resolution_minutes'] ??
          raw['avg_resolution_minutes'];
      if (direct != null) {
        final v = (direct is num) ? direct.toDouble() : double.tryParse(direct.toString());
        if (v != null && v > 0) {
          return v;
        }
      }

      final closedVal = task['closed_at'] ??
          raw['closed_at'] ??
          task['completed_at'] ??
          raw['completed_at'] ??
          task['resolved_at'];
      final createdVal = task['created_at'] ??
          raw['created_at'] ??
          task['task_created_at'] ??
          raw['task_created_at'];

      if (closedVal != null && createdVal != null) {
        final closedDt = closedVal is DateTime ? closedVal : DateTime.tryParse(closedVal.toString());
        final createdDt = createdVal is DateTime ? createdVal : DateTime.tryParse(createdVal.toString());

        if (closedDt != null && createdDt != null && closedDt.isAfter(createdDt)) {
          final diffMins = closedDt.difference(createdDt).inMinutes;
          if (diffMins > 0) return diffMins.toDouble();
        }
      }
    } catch (_) {}
    return null;
  }

  String _normalizeDeptName(String name) {
    return name
        .toLowerCase()
        .replaceAll('&', 'and')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  void _recomputeDeptPerformance() {
    final isStaffUser = _isStaff(_userRoleId, _userRole);
    if (isStaffUser) return;

    final isMdUser = _isManagingDirector(_userRoleId, _userRole);
    final isGmOrAdminUser = _isGmOrAdmin(_userRoleId, _userRole);
    final userDeptNames = _availableFilterDepts
        .map((d) => _normalizeDeptName(d))
        .toSet();

    final Map<String, Map<String, dynamic>> map = {};

    // 1. Seed from report departments (from operations report API)
    final reportList = (_selectedPreset == 'This Week' && _weeklyReportDepts.isNotEmpty)
        ? _weeklyReportDepts
        : _reportDepts;

    for (final rd in reportList) {
      final dName = (rd['department_name'] ?? rd['name'] ?? '').toString().trim();
      if (dName.isEmpty) continue;
      final normName = _normalizeDeptName(dName);
      if (!isMdUser && !isGmOrAdminUser && userDeptNames.isNotEmpty && !userDeptNames.contains(normName)) {
        continue;
      }
      final total = (rd['total_tasks'] as num?)?.toInt() ?? 0;
      final open = (rd['open_tasks'] as num?)?.toInt() ?? 0;
      final inProg = (rd['in_progress_tasks'] as num?)?.toInt() ?? 0;
      final closed = (rd['closed_tasks'] as num?)?.toInt() ?? 0;
      final esc = (rd['escalation_count'] ?? rd['escalated_tasks'] as num?)?.toInt() ?? 0;
      final avgTimeRaw = (rd['average_time_taken'] ?? rd['avg_time'] ?? rd['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
      final rev = (rd['total_amount'] ?? rd['amount'] ?? rd['total_price'] ?? rd['price'] as num?)?.toDouble() ?? 0.0;

      map[dName] = {
        'department_name': dName,
        'department_id': rd['department_id'],
        'total_assigned': total,
        'open_tasks': open,
        'in_progress_tasks': inProg,
        'total_closed': closed,
        'total_escalated': esc,
        'avg_resolution_minutes': avgTimeRaw,
        'escalation_rate_pct': total > 0 ? (esc / total * 100) : 0.0,
        'revenue': rev,
      };
    }

    // 2. Aggregate live counts, revenue, and closed task resolution durations
    final Map<String, Map<String, int>> liveCounts = {};
    final Map<String, double> liveRevenue = {};
    final Map<String, List<double>> liveDurations = {};

    for (final task in _allRawTasks) {
      if (task is! Map<String, dynamic>) continue;
      final raw = task['raw'] as Map<String, dynamic>? ?? task;
      final dName = (raw['department_name'] ?? task['department_name'] ?? task['department'] ?? 'General').toString().trim();
      if (dName.isEmpty) continue;
      final normName = _normalizeDeptName(dName);
      if (!isMdUser && !isGmOrAdminUser && userDeptNames.isNotEmpty && !userDeptNames.contains(normName)) {
        continue;
      }

      // Check date preset filter
      final dt = _parseTaskDate(task);
      if (!_matchesDateFilter(dt)) continue;

      if (!liveCounts.containsKey(dName)) {
        liveCounts[dName] = {'total': 0, 'open': 0, 'in_progress': 0, 'closed': 0, 'escalated': 0};
        liveDurations[dName] = [];
      }

      liveCounts[dName]!['total'] = liveCounts[dName]!['total']! + 1;

      final status = (task['status'] ?? task['task_flag'] ?? raw['status'] ?? '').toString().toLowerCase();
      final isEsc = (task['is_escalated'] == 1 ||
          task['is_escalated'] == true ||
          task['task_flag'] == 'Escalated' ||
          raw['is_escalated'] == 1 ||
          raw['escalation_instance_id'] != null);

      if (isEsc) liveCounts[dName]!['escalated'] = liveCounts[dName]!['escalated']! + 1;

      if (status == 'closed' || status == 'completed') {
        liveCounts[dName]!['closed'] = liveCounts[dName]!['closed']! + 1;
        final dur = _extractTaskResolutionMins(task);
        if (dur != null && dur > 0) {
          liveDurations[dName]!.add(dur);
        }
      } else if (status == 'in progress' || status == 'assigned' || status == 'accepted') {
        liveCounts[dName]!['in_progress'] = liveCounts[dName]!['in_progress']! + 1;
      } else {
        liveCounts[dName]!['open'] = liveCounts[dName]!['open']! + 1;
      }

      final price = _extractTaskPrice(task);
      if (price > 0) {
        liveRevenue[dName] = (liveRevenue[dName] ?? 0.0) + price;
      }
    }

    // Merge F&B revenue if available
    final fbFiltered = _foodOrders.where((o) => _matchesDateFilter(_parseFoodOrderDate(o))).toList();
    double fbRevenue = fbFiltered.fold<double>(0.0, (s, o) => s + _extractFoodOrderPrice(o));
    if (fbRevenue == 0) {
      final overallAmt = (_overallSummary['total_food_amount'] ?? _overallSummary['total_amount'] ?? 0) as num;
      if (overallAmt > 0) fbRevenue = overallAmt.toDouble();
    }

    // 3. Merge live counts into map (using normalized department key lookup)
    for (final entry in liveCounts.entries) {
      final liveName = entry.key;
      final counts = entry.value;
      final normLive = _normalizeDeptName(liveName);

      // Find matching key in map
      String? targetKey;
      for (final existingKey in map.keys) {
        if (_normalizeDeptName(existingKey) == normLive) {
          targetKey = existingKey;
          break;
        }
      }

      final durations = liveDurations[liveName] ?? [];
      final liveAvgMins = durations.isNotEmpty
          ? (durations.reduce((a, b) => a + b) / durations.length)
          : null;

      if (targetKey != null) {
        if (counts['total']! > 0) {
          map[targetKey]!['total_assigned'] = counts['total']!;
          map[targetKey]!['open_tasks'] = counts['open']!;
          map[targetKey]!['in_progress_tasks'] = counts['in_progress']!;
          map[targetKey]!['total_closed'] = counts['closed']!;
          map[targetKey]!['total_escalated'] = counts['escalated']!;
          map[targetKey]!['escalation_rate_pct'] = (counts['escalated']! / counts['total']! * 100);
          if ((liveRevenue[liveName] ?? 0.0) > 0) {
            map[targetKey]!['revenue'] = liveRevenue[liveName]!;
          }
          if (liveAvgMins != null && liveAvgMins > 0) {
            map[targetKey]!['avg_resolution_minutes'] = liveAvgMins;
          }
        }
      } else {
        // Look up in report list for fallback avg_time
        double fallbackAvg = liveAvgMins ?? 0.0;
        if (fallbackAvg <= 0) {
          for (final rd in reportList) {
            if (_normalizeDeptName((rd['department_name'] ?? rd['name'] ?? '').toString()) == normLive) {
              final val = (rd['average_time_taken'] ?? rd['avg_time'] ?? rd['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
              fallbackAvg = val;
              break;
            }
          }
        }
        if (fallbackAvg <= 0 && (_overallSummary['average_time_taken'] as num? ?? 0) > 0) {
          fallbackAvg = (_overallSummary['average_time_taken'] as num).toDouble();
        }

        map[liveName] = {
          'department_name': liveName,
          'department_id': null,
          'total_assigned': counts['total']!,
          'open_tasks': counts['open']!,
          'in_progress_tasks': counts['in_progress']!,
          'total_closed': counts['closed']!,
          'total_escalated': counts['escalated']!,
          'avg_resolution_minutes': fallbackAvg,
          'escalation_rate_pct': counts['total']! > 0 ? (counts['escalated']! / counts['total']! * 100) : 0.0,
          'revenue': liveRevenue[liveName] ?? 0.0,
        };
      }
    }

    // Attach F&B revenue to Food/Beverage/Room Service department if applicable
    for (final deptName in map.keys) {
      final isFbDept = ['f&b', 'food', 'beverage', 'dining', 'kitchen', 'restaurant', 'room service']
          .any((kw) => deptName.toLowerCase().contains(kw));
      if (isFbDept && ((map[deptName]!['revenue'] as num?)?.toDouble() ?? 0.0) == 0.0 && fbRevenue > 0) {
        map[deptName]!['revenue'] = fbRevenue;
      }
    }

    // 4. Ensure non-zero avg resolution time if overall summary is available
    final overallAvgMins = (_overallSummary['average_time_taken'] as num?)?.toDouble() ?? 0.0;

    for (final deptName in map.keys) {
      final curAvg = (map[deptName]!['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
      if (curAvg <= 0) {
        // Try to find from report list
        final norm = _normalizeDeptName(deptName);
        for (final rd in reportList) {
          if (_normalizeDeptName((rd['department_name'] ?? rd['name'] ?? '').toString()) == norm) {
            final val = (rd['average_time_taken'] ?? rd['avg_time'] ?? rd['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
            if (val > 0) {
              map[deptName]!['avg_resolution_minutes'] = val;
              break;
            }
          }
        }
      }
      if (((map[deptName]!['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0) <= 0 &&
          (map[deptName]!['total_closed'] as int? ?? 0) > 0 &&
          overallAvgMins > 0) {
        map[deptName]!['avg_resolution_minutes'] = overallAvgMins;
      }
    }

    _deptPerformance = map;
  }

  // ── Team Performance Loader ───────────────────────────────────────────────

  Future<void> _loadTeamPerformance() async {
    if (!mounted) return;

    final result = await _homeService.getTeamPerformance(
      month: _selectedDate.month,
      year:  _selectedDate.year,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      final rows = (result['team'] as List? ?? []).cast<Map<String, dynamic>>();

      final Map<String, Map<String, dynamic>> deptsMap = {};

      for (final r in rows) {
        final assigned = (r['total_assigned'] as int?) ?? 0;
        final closed   = (r['total_closed']   as int?) ?? 0;
        final esc      = (r['total_escalated'] as int?) ?? 0;
        final mins     = (r['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
        final dept     = (r['department_name'] ?? 'General').toString();

        if (!deptsMap.containsKey(dept)) {
          deptsMap[dept] = {
            'department_name': dept,
            'department_id': r['department_id'],
            'total_assigned': 0,
            'total_closed': 0,
            'total_escalated': 0,
            'total_mins_weighted': 0.0,
            'staff_count': 0,
          };
        }
        deptsMap[dept]!['total_assigned'] = (deptsMap[dept]!['total_assigned'] as int) + assigned;
        deptsMap[dept]!['total_closed']   = (deptsMap[dept]!['total_closed'] as int) + closed;
        deptsMap[dept]!['total_escalated'] = (deptsMap[dept]!['total_escalated'] as int) + esc;
        deptsMap[dept]!['total_mins_weighted'] = (deptsMap[dept]!['total_mins_weighted'] as double) + (mins * closed);
        deptsMap[dept]!['staff_count']    = (deptsMap[dept]!['staff_count'] as int) + 1;
      }

      for (final d in deptsMap.values) {
        final a = d['total_assigned'] as int;
        final c = d['total_closed'] as int;
        final e = d['total_escalated'] as int;
        final mw = d['total_mins_weighted'] as double;
        d['escalation_rate_pct'] = a > 0 ? (e / a * 100) : 0.0;
        d['avg_resolution_minutes'] = c > 0 ? (mw / c) : 0.0;
      }

      // Populate department lists if MD or GM/Admin
      if (_isManagingDirector(_userRoleId, _userRole) || _isGmOrAdmin(_userRoleId, _userRole)) {
        final allDepts = rows
            .map((r) => (r['department_name'] ?? '').toString())
            .where((d) => d.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
        if (allDepts.isNotEmpty) {
          setState(() => _availableFilterDepts = allDepts);
        }
      }

      // Merge into _deptPerformance
      for (final entry in deptsMap.entries) {
        if (_deptPerformance.containsKey(entry.key)) {
          _deptPerformance[entry.key]!['avg_resolution_minutes'] = entry.value['avg_resolution_minutes'];
          _deptPerformance[entry.key]!['escalation_rate_pct'] = entry.value['escalation_rate_pct'];
        }
      }

      setState(() {
        _weeklyFood   = (result['weeklyFood'] as List<Map<String, dynamic>>? ?? []);
        _weeklyGuests = (result['weeklyGuests'] as List<Map<String, dynamic>>? ?? []);

        final fbKeywords = ['f&b', 'food', 'beverage', 'restaurant', 'kitchen', 'dining'];
        _isFbUser = _isGmOrAdmin(_userRoleId, _userRole) ||
            _isManagingDirector(_userRoleId, _userRole) ||
            _availableFilterDepts.any((d) => fbKeywords.any((kw) => d.toLowerCase().contains(kw)));
      });
    }
  }

  void _selectPreset(String preset) async {
    final now = DateTime.now();
    DateTime targetDate = now;

    if (preset == 'Yesterday') {
      targetDate = now.subtract(const Duration(days: 1));
    } else if (preset == 'Custom') {
      final picked = await showDatePicker(
        context: context,
        firstDate: DateTime.now().subtract(const Duration(days: 90)),
        lastDate: DateTime.now(),
        initialDate: _selectedDate,
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
        targetDate = picked;
      } else {
        return;
      }
    }

    setState(() {
      _selectedPreset = preset;
      _selectedDate   = targetDate;
    });

    _applyTaskFilters();

    if (_isSupervisorOrAbove(_userRoleId, _userRole)) {
      _loadTeamPerformance();
    }
  }

  String _formatAvgResolutionTime(double mins) {
    if (mins <= 0) return '—';
    if (mins < 60) {
      final m = mins.round();
      return m == 1 ? '1 min' : '$m mins';
    }
    final h = mins / 60.0;
    final str = h.toStringAsFixed(1);
    return str.endsWith('.0') ? '${h.toStringAsFixed(0)}h' : '${str}h';
  }

  // ── Refresh ───────────────────────────────────────────────────────────────

  Future<void> _onRefresh() async {
    try {
      await ProfileService().getProfile();
      final role   = await UserSessionHelper.getRole();
      final roleId = await UserSessionHelper.getRoleId();
      final userId = await UserSessionHelper.getUserId();
      final depts  = await UserSessionHelper.getDepartments();
      
      if (mounted) {
        final derivedRoleId = roleId ?? _deriveRoleId(role);
        setState(() {
          _userRole             = role ?? '';
          _userRoleId           = derivedRoleId;
          _userId               = userId;
          _availableFilterDepts = List.from(depts)..sort();
        });
      }
    } catch (_) {}

    await Future.wait([
      _loadAllTasksAndStats(),
      _loadFoodOrders(),
      _loadOperationsReport(),
      if (_isSupervisorOrAbove(_userRoleId, _userRole)) _loadTeamPerformance(),
    ]);
  }

  // ── Bottom sheets ─────────────────────────────────────────────────────────

  void _showFilteredTasksSheet(String filterKey, String title) {
    final filtered = _allTasks.where((task) {
      if (task is! Map<String, dynamic>) return false;
      final raw = task['raw'] as Map<String, dynamic>? ?? task;
      final statusNorm = (task['status'] ?? raw['status'] ?? '').toString().trim().toLowerCase();
      final isEsc = (task['is_escalated'] == 1 ||
          task['is_escalated'] == true ||
          raw['is_escalated'] == 1 ||
          raw['escalation_instance_id'] != null ||
          task['escalation_instance_id'] != null);

      if (filterKey == 'completed') {
        return statusNorm == 'closed' || statusNorm == 'completed';
      } else if (filterKey == 'inProgress') {
        return statusNorm == 'in progress' ||
               statusNorm == 'inprogress' ||
               statusNorm == 'in_progress' ||
               statusNorm == 'assigned' ||
               statusNorm == 'accepted';
      } else if (filterKey == 'escalated') {
        return isEsc;
      } else if (filterKey == 'open') {
        return statusNorm == 'open' ||
               statusNorm == 'pending' ||
               statusNorm.isEmpty ||
               (!['closed','completed','in progress','inprogress','in_progress','assigned','accepted']
                   .contains(statusNorm));
      }
      return true;
    }).toList();


    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        maxChildSize:     0.95,
        minChildSize:     0.4,
        builder: (_, controller) => Container(
          decoration: const BoxDecoration(
            color:        Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              _buildSheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '$title (${filtered.length})',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textSecondary),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.borderLight),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.assignment_outlined, size: 48, color: Colors.grey.shade300),
                            const SizedBox(height: 12),
                            Text('No $title tasks found', style: AppTypography.bodySecondary),
                          ],
                        ),
                      )
                    : ListView.separated(
                        controller: controller,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const Divider(
                          height: 1, color: AppColors.borderLight, indent: 16, endIndent: 16,
                        ),
                        itemBuilder: (_, i) =>
                            _buildActivityRow(filtered[i] as Map<String, dynamic>),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAllTasksSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        maxChildSize:     0.95,
        minChildSize:     0.4,
        builder: (_, controller) => Container(
          decoration: const BoxDecoration(
            color:        Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              _buildSheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'All Tasks (${_allTasks.length})',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textSecondary),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.borderLight),
              Expanded(
                child: ListView.separated(
                  controller: controller,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _allTasks.length,
                  separatorBuilder: (_, __) => const Divider(
                    height: 1, color: AppColors.borderLight, indent: 16, endIndent: 16,
                  ),
                  itemBuilder: (_, i) =>
                      _buildActivityRow(_allTasks[i] as Map<String, dynamic>),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSheetHandle() {
    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 4),
      width: 38,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.grey.shade300,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  // ── Main UI Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgLight,
      appBar: _buildAppBar(),
      body: _statsLoading && _allTasks.isEmpty
          ? const Center(child: SkeletonLoader())
          : _statsError != null && _allTasks.isEmpty
              ? RefreshIndicator(
                  onRefresh: _onRefresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(32),
                    children: [
                      SizedBox(height: MediaQuery.of(context).size.height * 0.15),
                      Icon(Icons.wifi_off_rounded, size: 52, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      Text(
                        _statsError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: TextButton(
                          onPressed: _onRefresh,
                          child: const Text('Try Again', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _onRefresh,
                  color: AppColors.primary,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 1. Top Filter Controls (Search + Date Preset Bar + Dept Chip)
                        _buildTopFilterSection(),

                        // 3. Stat Cards
                        _buildStatCards(),

                        // 4. Staff Personal Summary (Staff role)
                        if (_isStaff(_userRoleId, _userRole))
                          _buildStaffPersonalSummary(),

                        // 5. Department Benchmark Section (Supervisor+, MD, GM)
                        if (!_isStaff(_userRoleId, _userRole) && _deptPerformance.isNotEmpty)
                          _buildDepartmentPerformanceSection(),

                        // 7. F&B Analytics Section (Driven by top global date filter)
                        if (_isFbUser || _weeklyFood.isNotEmpty || _foodOrders.isNotEmpty)
                          _buildFoodAnalyticsSection(),

                        // 8. Occupancy vs. Workload (MD, GM, Admin)
                        if ((_isManagingDirector(_userRoleId, _userRole) || _isGmOrAdmin(_userRoleId, _userRole)) &&
                            _weeklyGuests.isNotEmpty)
                          _buildOccupancyCorrelationSection(),

                        // 10. Motivation Banner
                        _buildMotivationBanner(),

                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ),
    );
  }

  // ── App Bar ───────────────────────────────────────────────────────────────

  AppBar _buildAppBar() {
    final isMd = _isManagingDirector(_userRoleId, _userRole);
    final isGm = _isGmOrAdmin(_userRoleId, _userRole);
    final isStaffUser = _isStaff(_userRoleId, _userRole);

    String title = 'My Tasks';
    if (isMd) {
      title = 'Director Dashboard';
    } else if (isGm) {
      title = 'Executive Dashboard';
    } else if (!isStaffUser) {
      title = 'Operations & Tasks';
    }

    String subtitle = 'Department Operations & Live Queue';
    if (isMd) {
      subtitle = 'Enterprise Operations & Live Overview';
    } else if (isGm) {
      subtitle = 'Property Operations & Live Tracking';
    } else if (isStaffUser) {
      subtitle = 'Your Daily Tasks & Performance';
    }

    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTypography.appBarTitle),
          Text(subtitle, style: AppTypography.appBarSubtitle),
        ],
      ),
      actions: const [],
    );
  }

  // ── Top Filter Section (Order History style) ──────────────────────────────

  Widget _buildTopFilterSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Search Bar
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey.shade200),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: TextField(
              controller: _searchController,
              onChanged: (val) {
                setState(() => _searchQuery = val);
                _applyTaskFilters();
              },
              decoration: InputDecoration(
                hintText: _isStaff(_userRoleId, _userRole)
                    ? 'Search your tasks, room #, guest...'
                    : 'Search Room #, Task ID, Guest, Staff, Dept...',
                hintStyle: const TextStyle(fontSize: 13, color: Colors.black38),
                prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                          _applyTaskFilters();
                        },
                      )
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 2. Date Preset Chips Row (Today, Yesterday, This Week, Custom)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: ['Today', 'Yesterday', 'This Week', 'Custom'].map((preset) {
                final isSelected = _selectedPreset == preset;
                String label = preset;
                if (preset == 'Custom' && _selectedPreset == 'Custom') {
                  label = '${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}';
                }

                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (preset == 'Custom') ...[
                          Icon(
                            Icons.calendar_today_rounded,
                            size: 13,
                            color: isSelected ? Colors.white : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            color: isSelected ? Colors.white : AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    selected: isSelected,
                    selectedColor: AppColors.primary,
                    backgroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(
                        color: isSelected ? AppColors.primary : Colors.grey.shade300,
                      ),
                    ),
                    onSelected: (_) => _selectPreset(preset),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ── Stat Cards ────────────────────────────────────────────────────────────

  Widget _buildStatCards() {
    final isStaffUser = _isStaff(_userRoleId, _userRole);

    final cards = [
      _StatCardData(
        count:       '$totalTasks',
        label:       isStaffUser ? 'Assigned' : 'Total',
        icon:        Icons.assignment_outlined,
        accentColor: AppColors.primary,
        filterStatus: null,
      ),
      _StatCardData(
        count:       '$openTasks',
        label:       'Open',
        icon:        Icons.inbox_outlined,
        accentColor: const Color(0xFF1976D2),
        filterStatus: 'open',
      ),
      _StatCardData(
        count:       '$inProgressTasks',
        label:       'In Progress',
        icon:        Icons.timelapse_outlined,
        accentColor: AppColors.orange,
        filterStatus: 'inProgress',
      ),
      _StatCardData(
        count:       '$completedTasks',
        label:       'Completed',
        icon:        Icons.check_circle_outline,
        accentColor: AppColors.success,
        filterStatus: 'completed',
      ),
      if (escalatedTasks > 0)
        _StatCardData(
          count:       '$escalatedTasks',
          label:       'Escalated',
          icon:        Icons.warning_amber_rounded,
          accentColor: Colors.amber.shade800,
          filterStatus: 'escalated',
        ),
    ];

    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        physics: const BouncingScrollPhysics(),
        itemCount: cards.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) => SizedBox(
          width: 96,
          child: _buildStatCard(cards[i]),
        ),
      ),
    );
  }

  Widget _buildStatCard(_StatCardData d) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        if (d.filterStatus != null) {
          _showFilteredTasksSheet(d.filterStatus!, d.label);
        } else {
          _showAllTasksSheet();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderLight),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: d.accentColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(d.icon, size: 15, color: d.accentColor),
            ),
            const SizedBox(height: 6),
            Text(
              d.count,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: d.accentColor,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              d.label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
                height: 1.15,
              ),
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  // ── Staff Personal Summary ────────────────────────────────────────────────

  Widget _buildStaffPersonalSummary() {
    final completionPct = totalTasks > 0 ? (completedTasks / totalTasks) : 0.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderLight),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Your Task Completion Rate',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  '${(completionPct * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppColors.success,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: completionPct.clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: AppColors.borderLight,
                valueColor: const AlwaysStoppedAnimation<Color>(AppColors.success),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$completedTasks of $totalTasks tasks completed for this period',
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  // ── Department-wise Breakdown Table ──────────────────────────────────────

  Widget _buildDepartmentPerformanceSection() {
    final fbKeywords = ['f&b', 'food', 'beverage', 'dining', 'kitchen', 'restaurant'];
    final hasAnyRevenue = _deptPerformance.entries
        .where((e) => !fbKeywords.any((kw) => e.key.toLowerCase().contains(kw)))
        .any((e) => ((e.value['revenue'] as num?)?.toDouble() ?? 0.0) > 0);

    final filteredEntries = _deptPerformance.entries
        .where((entry) {
          final dn = entry.key.toLowerCase();
          return !fbKeywords.any((kw) => dn.contains(kw));
        })
        .toList()
      ..sort((a, b) {
        final totalA = (a.value['total_assigned'] as int?) ?? 0;
        final totalB = (b.value['total_assigned'] as int?) ?? 0;
        if (totalB != totalA) return totalB.compareTo(totalA);

        final openA = (a.value['open_tasks'] as int?) ?? 0;
        final openB = (b.value['open_tasks'] as int?) ?? 0;
        if (openB != openA) return openB.compareTo(openA);

        return a.key.compareTo(b.key);
      });

    if (filteredEntries.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Section Header ──────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.table_chart_rounded, size: 16, color: AppColors.primary),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Department Benchmarks',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Vertical Card Stack ─────────────────────────────────────────
          ...filteredEntries.map((entry) {
            final deptName = entry.key;
            final d = entry.value;

            final total      = (d['total_assigned'] as int?) ?? 0;
            final closed     = (d['total_closed'] as int?) ?? 0;
            final open       = (d['open_tasks'] as int?) ?? (total - closed).clamp(0, 9999);
            final inProgress = (d['in_progress_tasks'] as int?) ?? 0;
            final escalated  = (d['total_escalated'] as int?) ?? 0;
            final avgMins    = (d['avg_resolution_minutes'] as num?)?.toDouble() ??
                (((d['avg_resolution_hours'] as num?)?.toDouble() ?? 0.0) * 60.0);
            final rev        = (d['revenue'] as num?)?.toDouble() ?? 0.0;

            final avgStr = _formatAvgResolutionTime(avgMins);
            final completionPct = total > 0 ? (closed / total).clamp(0.0, 1.0) : 0.0;

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: AppColors.borderLight,
                  width: 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.035),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Card Header: Dept Name + Avg resolution ────────
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            deptName,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        if (avgMins > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.timer_outlined, size: 12, color: AppColors.textSecondary),
                                const SizedBox(width: 4),
                                Text(
                                  'Avg $avgStr',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (escalated > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF2F2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('⚠️', style: TextStyle(fontSize: 10)),
                                const SizedBox(width: 3),
                                Text(
                                  '$escalated',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFFDC2626),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),

                    const SizedBox(height: 10),

                    // ── Completion Progress Bar ────────────────────────
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: completionPct,
                              minHeight: 5,
                              backgroundColor: AppColors.borderLight,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                completionPct >= 0.8
                                    ? AppColors.success
                                    : completionPct >= 0.5
                                        ? AppColors.orange
                                        : AppColors.primary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${(completionPct * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: completionPct >= 0.8
                                ? AppColors.success
                                : completionPct >= 0.5
                                    ? AppColors.orange
                                    : AppColors.primary,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // ── Stats Row ──────────────────────────────────────
                    Row(
                      children: [
                        _buildDeptStatChip(
                          label: 'Total',
                          value: '$total',
                          color: AppColors.textPrimary,
                          bg: const Color(0xFFF8FAFC),
                        ),
                        const SizedBox(width: 6),
                        _buildDeptStatChip(
                          label: 'Open',
                          value: '$open',
                          color: open > 0 ? AppColors.primary : AppColors.textSecondary,
                          bg: open > 0 ? AppColors.primary.withValues(alpha: 0.08) : const Color(0xFFF8FAFC),
                        ),
                        const SizedBox(width: 6),
                        _buildDeptStatChip(
                          label: 'In Progress',
                          value: '$inProgress',
                          color: inProgress > 0 ? AppColors.orange : AppColors.textSecondary,
                          bg: inProgress > 0 ? AppColors.orange.withValues(alpha: 0.08) : const Color(0xFFF8FAFC),
                        ),
                        const SizedBox(width: 6),
                        _buildDeptStatChip(
                          label: 'Closed',
                          value: '$closed',
                          color: closed > 0 ? AppColors.success : AppColors.textSecondary,
                          bg: closed > 0 ? AppColors.success.withValues(alpha: 0.08) : const Color(0xFFF8FAFC),
                        ),
                        if (hasAnyRevenue && rev > 0) ...[
                          const SizedBox(width: 6),
                          _buildDeptStatChip(
                            label: 'Revenue',
                            value: '₹${rev >= 1000 ? '${(rev / 1000).toStringAsFixed(1)}k' : rev.toStringAsFixed(0)}',
                            color: AppColors.success,
                            bg: AppColors.success.withValues(alpha: 0.08),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildDeptStatChip({
    required String label,
    required String value,
    required Color color,
    required Color bg,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  // ── F&B Analytics Section (Driven by top global date filter) ──────────────

  double _extractFoodOrderPrice(Map<String, dynamic> o) {
    final raw = o['raw'] as Map<String, dynamic>? ?? {};

    final candidates = [
      o['totalPrice'],
      o['total_price'],
      o['totalAmount'],
      o['total_amount'],
      o['amount'],
      o['grand_total'],
      o['food_price'],
      o['price'],
      o['item_total'],
      o['item_total_price'],
      o['item_price'],
      raw['total_price'],
      raw['total_amount'],
      raw['totalAmount'],
      raw['amount'],
      raw['grand_total'],
      raw['food_price'],
      raw['price'],
      raw['item_price'],
      raw['item_total'],
      raw['item_total_price'],
    ];

    for (final c in candidates) {
      if (c != null) {
        final val = (c is num) ? c.toDouble() : double.tryParse(c.toString());
        if (val != null && val > 0) {
          final qty = (o['quantity'] ?? o['qty'] ?? raw['quantity'] ?? raw['qty'] ?? 1) as num? ?? 1;
          if (c == o['price'] || c == o['food_price'] || c == raw['food_price'] || c == raw['price'] || c == raw['item_price']) {
            return val * qty.toDouble();
          }
          return val;
        }
      }
    }

    final items = (o['items'] ?? raw['items']) as List? ?? [];
    double sum = 0.0;
    for (final item in items) {
      if (item is Map) {
        final qty = (item['qty'] ?? item['quantity'] ?? 1) as num? ?? 1;
        final p = item['total_price'] ?? item['total_amount'] ?? item['amount'] ?? item['price'] ?? item['food_price'] ?? item['item_price'] ?? 0;
        final priceVal = (p is num) ? p.toDouble() : (double.tryParse(p.toString()) ?? 0.0);
        sum += (priceVal * (item['total_price'] != null || item['total_amount'] != null ? 1 : qty.toDouble()));
      }
    }
    return sum;
  }

  DateTime? _parseFoodOrderDate(Map<String, dynamic> o) {
    final raw = o['raw'] as Map<String, dynamic>? ?? {};
    final candidates = [
      raw['created_at'],
      raw['order_time'],
      raw['order_date'],
      raw['date'],
      o['createdAt'],
      o['order_time'],
      o['created_at'],
      o['orderTime'],
    ];

    for (final c in candidates) {
      if (c is DateTime) return c;
      if (c != null) {
        final str = c.toString().trim();
        if (str.isNotEmpty) {
          final parsed = DateTime.tryParse(str);
          if (parsed != null) return parsed;
          try {
            if (str.contains(' ')) {
              final datePart = str.split(' ').first;
              final parsedDate = DateTime.tryParse(datePart);
              if (parsedDate != null) return parsedDate;
            }
          } catch (_) {}
        }
      }
    }
    return null;
  }

  Widget _buildFoodAnalyticsSection() {
    final filteredOrders = _foodOrders.where((o) {
      final dt = _parseFoodOrderDate(o);
      return _matchesDateFilter(dt);
    }).toList();

    int totalOrders = filteredOrders.length;
    double totalRevenue = filteredOrders.fold<double>(0.0, (s, o) => s + _extractFoodOrderPrice(o));

    // Fallback to server operations report if live orders list is empty or returned 0
    if (totalRevenue == 0) {
      if (_selectedPreset == 'This Week' && _weeklyFood.isNotEmpty) {
        for (final r in _weeklyFood) {
          totalOrders += (r['total_orders'] as num?)?.toInt() ?? 0;
          final amt = (r['total_revenue'] ?? r['total_amount'] ?? r['amount'] ?? 0) as num;
          totalRevenue += amt.toDouble();
        }
      } else if (_selectedPreset == 'Today' || _selectedPreset == 'Yesterday' || _selectedPreset == 'This Week') {
        final overallOrders = (_overallSummary['total_food_orders'] as num?)?.toInt() ?? 0;
        final overallAmt = (_overallSummary['total_food_amount'] ?? _overallSummary['total_amount'] ?? 0) as num;
        if (overallAmt > 0) {
          if (totalOrders == 0) totalOrders = overallOrders;
          totalRevenue = overallAmt.toDouble();
        }
      }
    }

    final periodLabel = _selectedPreset == 'Custom'
        ? '${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}'
        : _selectedPreset;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderLight),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.restaurant_menu_rounded, size: 16, color: Color(0xFFD97706)),
                      ),
                      const SizedBox(width: 8),
                      const Flexible(
                        child: Text(
                          'F&B Operations',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    periodLabel,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFD97706),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _buildFoodKpi(
                  label: 'Orders',
                  value: '$totalOrders',
                  icon: Icons.receipt_long_rounded,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 10),
                _buildFoodKpi(
                  label: 'Total Revenue',
                  value: '₹${totalRevenue.toStringAsFixed(totalRevenue.truncateToDouble() == totalRevenue ? 0 : 2)}',
                  icon: Icons.currency_rupee_rounded,
                  color: AppColors.success,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFoodKpi({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: AppColors.textSecondary, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  // ── Occupancy & Guest Movement Section ───────────────────────────────────

  Widget _buildOccupancyCorrelationSection() {
    final list = _weeklyGuests.isNotEmpty ? _weeklyGuests : _monthlyGuests;
    if (list.isEmpty) return const SizedBox.shrink();

    final sorted = [...list]
      ..sort((a, b) => (a['week_start']?.toString() ?? a['date']?.toString() ?? '')
          .compareTo(b['week_start']?.toString() ?? b['date']?.toString() ?? ''));
    final records = sorted.take(6).toList();
    if (records.isEmpty) return const SizedBox.shrink();

    final latest = records.last;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderLight),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 3)),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6366F1).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.hotel_rounded, size: 16, color: Color(0xFF6366F1)),
                      ),
                      const SizedBox(width: 8),
                      const Flexible(
                        child: Text(
                          'Occupancy & Guest Movement',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                if (records.length > 1)
                  IconButton(
                    icon: Icon(
                      _isOccupancyExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      color: AppColors.textSecondary,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _isOccupancyExpanded = !_isOccupancyExpanded),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _buildOccupancyQuickStat(latest),
            if (_isOccupancyExpanded && records.length > 1) ...[
              const SizedBox(height: 14),
              const Divider(height: 1, color: AppColors.borderLight),
              const SizedBox(height: 10),
              const Text(
                'Weekly Historical Movement',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              ...records.reversed.map((w) {
                final wCi = (w['total_checkins'] ?? w['checkin_count'] ?? w['checkins'] as num?)?.toInt() ?? 0;
                final wCo = (w['total_checkouts'] ?? w['checkout_count'] ?? w['checkouts'] as num?)?.toInt() ?? 0;
                final wInHouse = (w['total_guests'] ?? w['guest_count'] ?? w['stayover'] as num?)?.toInt() ?? (wCi - wCo).clamp(0, 9999);
                final rawLabel = (w['week_start'] ?? w['date'] ?? w['period'] ?? '').toString();
                // Format to app style DD/MM/YY; if it's a range show week_end too
                final weekEnd = (w['week_end'] ?? '').toString();
                final formattedStart = DateFormatter.formatDateOnly(rawLabel);
                final formattedEnd   = weekEnd.isNotEmpty ? DateFormatter.formatDateOnly(weekEnd) : '';
                final label = formattedStart == '—' || formattedStart.isEmpty
                    ? (rawLabel.isNotEmpty ? rawLabel : 'Period')
                    : (formattedEnd.isNotEmpty && formattedEnd != '—'
                        ? '$formattedStart – $formattedEnd'
                        : formattedStart);

                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.borderLight),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('In: $wCi', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.success)),
                            const SizedBox(width: 8),
                            Text('Out: $wCo', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFFE11D48))),
                            const SizedBox(width: 8),
                            Text('Guests: $wInHouse', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6366F1))),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOccupancyQuickStat(Map<String, dynamic> data) {
    final ci = (data['total_checkins'] ?? data['checkin_count'] ?? data['checkins'] as num?)?.toInt() ?? 0;
    final co = (data['total_checkouts'] ?? data['checkout_count'] ?? data['checkouts'] as num?)?.toInt() ?? 0;
    final inHouse = (data['total_guests'] ?? data['guest_count'] ?? data['in_house_guests'] ?? data['stayover'] as num?)?.toInt() ??
        (ci - co).clamp(0, 9999);
    final occRate = (data['occupancy_rate'] ?? data['occupancy_pct'] as num?)?.toDouble() ?? 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF6366F1).withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Expanded(child: _buildOccupancyStat('Check-ins', '$ci', Icons.login_rounded, AppColors.success)),
          Container(width: 1, height: 32, color: AppColors.borderLight),
          Expanded(child: _buildOccupancyStat('Check-outs', '$co', Icons.logout_rounded, const Color(0xFFE11D48))),
          Container(width: 1, height: 32, color: AppColors.borderLight),
          Expanded(child: _buildOccupancyStat('In-House', '$inHouse', Icons.people_alt_rounded, const Color(0xFF6366F1))),
          if (occRate > 0) ...[
            Container(width: 1, height: 32, color: AppColors.borderLight),
            Expanded(child: _buildOccupancyStat('Occupancy', '${occRate.toStringAsFixed(0)}%', Icons.pie_chart_outline_rounded, AppColors.orange)),
          ],
        ],
      ),
    );
  }

  Widget _buildOccupancyStat(String label, String value, IconData icon, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(height: 3),
        Text(
          value,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color, height: 1.1),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 10, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  // ── Single Activity Row ───────────────────────────────────────────────────

  Widget _buildActivityRow(Map<String, dynamic> task) {
    final raw = task['raw'] as Map<String, dynamic>? ?? task;

    final isEsc = (task['is_escalated'] == 1 ||
        task['is_escalated'] == true ||
        task['task_flag'] == 'Escalated' ||
        raw['is_escalated'] == 1 ||
        raw['escalation_instance_id'] != null);

    final status = (task['status'] ?? task['task_flag'] ?? raw['status'] ?? 'Open').toString();

    Color statusColor;
    Color statusBg;
    if (isEsc) {
      statusColor = Colors.amber.shade800;
      statusBg    = Colors.amber.shade50;
    } else if (status.toLowerCase() == 'closed' || status.toLowerCase() == 'completed') {
      statusColor = AppColors.success;
      statusBg    = AppColors.successLight;
    } else if (status.toLowerCase() == 'in progress' || status.toLowerCase() == 'assigned') {
      statusColor = AppColors.orange;
      statusBg    = AppColors.orangeLight;
    } else {
      statusColor = AppColors.primary;
      statusBg    = AppColors.primaryLight;
    }

    final rawRoom = (task['room_number'] ?? task['room'] ?? raw['room_number'] ?? '—').toString();
    final room = (rawRoom == '0' || rawRoom == '000' || rawRoom == 'null' || rawRoom.isEmpty) ? 'Gen' : rawRoom;

    final rawTitle = _resolveTitle(task);
    final title = rawTitle.replaceFirst(RegExp(r'^Order\s+#[A-Z0-9]+\s*-\s*', caseSensitive: false), '');

    final guest    = (task['guest'] ?? raw['guest_name'] ?? '').toString().trim();
    final deptName = (raw['department_name'] ?? task['department_name'] ?? '').toString().trim();
    final timeStr  = (task['created_at'] ?? raw['created_at'] ?? task['time'] ?? '').toString();
    final timeAgo  = _timeAgo(timeStr);

    String handledBy = '';
    final acceptedBy = (raw['accepted_by_user_name'] ?? task['assignedTo'] ?? '').toString().trim();
    final closedBy   = (raw['closed_by_user_name'] ?? '').toString().trim();
    if (status.toLowerCase() == 'closed' && closedBy.isNotEmpty) {
      handledBy = closedBy;
    } else if (acceptedBy.isNotEmpty && acceptedBy != '-' && int.tryParse(acceptedBy) == null) {
      handledBy = acceptedBy;
    }

    final canTap = _isSupervisorOrAboveByName(_userRole);

    return InkWell(
      onTap: canTap
          ? () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TicketDetailPage(task: task, userRole: _userRole),
                ),
              );
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Room badge
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: statusBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  room,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: statusColor,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Title & meta
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      // Status chip
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                        decoration: BoxDecoration(
                          color: statusBg,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          isEsc ? 'Escalated' : status,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: statusColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (deptName.isNotEmpty) ...[
                        Text(
                          deptName,
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(width: 6),
                        const Text('·', style: TextStyle(color: Colors.grey)),
                        const SizedBox(width: 6),
                      ],
                      if (guest.isNotEmpty) ...[
                        Text(
                          guest,
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                        ),
                        const SizedBox(width: 6),
                        const Text('·', style: TextStyle(color: Colors.grey)),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        timeAgo,
                        style: const TextStyle(fontSize: 10.5, color: Colors.grey),
                      ),
                    ],
                  ),
                  if (handledBy.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.person_outline_rounded, size: 12, color: AppColors.primary),
                        const SizedBox(width: 4),
                        Text(
                          handledBy,
                          style: const TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _timeAgo(String timeStr) {
    if (timeStr.isEmpty) return '';
    try {
      final dt = DateTime.tryParse(timeStr);
      if (dt == null) return timeStr;
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return '${diff.inDays}d ago';
    } catch (_) {
      return timeStr;
    }
  }

  // ── Motivation Banner ─────────────────────────────────────────────────────

  Widget _buildMotivationBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.12)),
        ),
        child: Row(
          children: [
            const Text('✨', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _isStaff(_userRoleId, _userRole)
                    ? 'Great work! Resolving service tickets promptly elevates guest satisfaction.'
                    : 'Streamline team velocity and SLA response to maintain 5-star operations.',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

}

// ─────────────────────────────────────────────────────────────────────────────
// Data classes
// ─────────────────────────────────────────────────────────────────────────────

class _StatCardData {
  final String   count;
  final String   label;
  final IconData icon;
  final Color    accentColor;
  final String?  filterStatus;

  const _StatCardData({
    required this.count,
    required this.label,
    required this.icon,
    required this.accentColor,
    this.filterStatus,
  });
}
