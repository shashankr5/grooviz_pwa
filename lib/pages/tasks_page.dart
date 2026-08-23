// tasks_page.dart
//
// CHANGES IN THIS VERSION:
//  • _deriveRoleId() — new helper that maps role name → numeric role_id.
//    Called in _init() when UserSessionHelper.getRoleId() returns null
//    (old sessions that pre-date role_id storage). Prevents the entire
//    team section from being invisible due to a null _userRoleId.
//  • userRole string passed to _StaffDrillDownPage — needed so the
//    drill-down page can gate navigation to TicketDetailPage on role.
//  • _StaffDrillDownPage._buildTaskRow() — wrapped in GestureDetector
//    that navigates to TicketDetailPage when the viewer is Supervisor+.
//    Staff-level viewers see the row but it's not tappable.
//  • FIX 1: _resolveTitle() helper — treats empty task_name same as null
//    so question field is used when task_name is "". Fixes blank titles
//    in Recent Activity and drill-down task rows.
//  • FIX 2: _allTasks / _hasMoreTasks — stores full untruncated task list.
//    Recent Activity shows first 5. "Show all N tasks" button opens a
//    DraggableScrollableSheet with the complete list.
//  • FIX 3: Stat cards (Completed, In Progress, Escalated) are now
//    tappable. Tapping opens a filtered bottom sheet from _allTasks.
//    _StatCardData gains a filterStatus field. _showFilteredTasksSheet()
//    and _showAllTasksSheet() added. _buildActivityRow() extracted as a
//    shared helper used by both the inline list and all sheets.
//
// All existing role-based hierarchy, dept filter, month picker, stat
// cards, team table, and motivation banner unchanged.

import 'dart:async';
import 'package:flutter/material.dart';
import '../services/home_service.dart';
import '../services/task_service.dart';
import '../services/profile_service.dart';
import '../utils/user_session_helper.dart';
import '../utils/report_pdf_helper.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:printing/printing.dart';
import 'dart:typed_data';
import 'package:dio/dio.dart';

import '../theme/app_typography.dart';
import '../theme/app_colors.dart';
import '../components/skeleton_loader.dart';
import '../pages/ticket_details_page.dart';

// ── Role helpers ──────────────────────────────────────────────────────────────

bool _isGmOrAdmin(int? roleId)         => roleId != null && (roleId == 1 || roleId == 2);
bool _isManager(int? roleId)           => roleId == 3;
bool _isDeptHead(int? roleId)          => roleId == 4;
bool _isStaff(int? roleId)             => roleId == 6;
bool _isManagementOnly(int? roleId)    => roleId != null && roleId <= 3;
bool _isSupervisorOrAbove(int? roleId) => roleId != null && roleId <= 5;
bool _isDeptScopedRole(int? roleId)    => roleId == 4 || roleId == 5;

bool _isSupervisorOrAboveByName(String? role) {
  if (role == null) return false;
  const hierarchy = [
    'Staff', 'Supervisor', 'Department Head', 'Manager', 'General Manager', 'Admin',
  ];
  return hierarchy.indexOf(role) >= 1;
}

// ── FIX 1: Title resolver — treats empty string same as null ─────────────────
// The API returns task_name: "" when no name is set. Dart's ?? operator only
// falls through on null, not empty string, so task_name:"" would silently win
// and render a blank title. This helper explicitly checks isNotEmpty.
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

  final HomeService _homeService = HomeService();

  // ── Session ───────────────────────────────────────────────────────────────
  String       _userRole       = '';
  int?         _userId;
  int?         _userRoleId;
  bool         _canSendReports = false;

  // ── Month / dept filter ───────────────────────────────────────────────────
  int     _selectedMonth = DateTime.now().month;
  int     _selectedYear  = DateTime.now().year;
  String? _selectedDept;

  // ── Available dept options for the filter dropdown ────────────────────────
  List<String> _availableFilterDepts = [];

  // ── Personal stats ────────────────────────────────────────────────────────
  bool _statsLoading   = true;
  // FIX-10 (Bug 10): was silently cleared on failure with no error state,
  // so a no-internet fetch left the previous month's data on screen with
  // no indication anything had failed.
  String? _statsError;
  int  totalTasks      = 0;
  int  completedTasks  = 0;
  int  inProgressTasks = 0;
  // Retained as an internal compatibility value for existing analytics code.
  // Escalation is no longer shown or alerted in the client.
  int  escalatedTasks  = 0;

  // FIX 2: _allTasks holds the full untruncated list.
  // _recentTasks is the first 5 shown inline.
  List<dynamic> _recentTasks   = [];
  List<dynamic> _allTasks      = [];
  bool          _hasMoreTasks  = false;

  // ── Team performance ──────────────────────────────────────────────────────
  bool                       _teamLoading = false;
  List<Map<String, dynamic>> _teamRowsAll = [];
  List<Map<String, dynamic>> _teamRows    = [];

  // ── Advanced Performance & SLA Metrics ────────────────────────────────────
  double                            _avgResolutionMinutes = 0.0;
  double                            _escalationRatePct     = 0.0;
  Map<String, Map<String, dynamic>> _deptPerformance      = {};

  // ── RS3: Dept overall benchmark (from getOperationsPerformance) ────────────
  // These supplement the per-user _deptPerformance map with the server-computed
  // overall_department rows (richer data — includes open / overdue fields).
  List<Map<String, dynamic>> _overallDepartments = [];

  // ── RS4/RS5/RS6/RS7: Operations Velocity (enterprise + dept weekly/monthly) ─
  List<Map<String, dynamic>> _weeklyServices      = [];
  List<Map<String, dynamic>> _monthlyServices     = [];
  List<Map<String, dynamic>> _weeklyDepartments   = [];
  List<Map<String, dynamic>> _monthlyDepartments  = [];

  // ── RS12–RS15: F&B Order Analytics ────────────────────────────────────────
  List<Map<String, dynamic>> _weeklyFood          = [];
  List<Map<String, dynamic>> _monthlyFood         = [];
  List<Map<String, dynamic>> _weeklyFoodUsers     = [];
  List<Map<String, dynamic>> _monthlyFoodUsers    = [];

  // ── RS16/RS17: Guest Occupancy ────────────────────────────────────────────
  List<Map<String, dynamic>> _weeklyGuests        = [];
  List<Map<String, dynamic>> _monthlyGuests       = [];

  // ── UI toggle state ───────────────────────────────────────────────────────
  bool _isVelocityExpanded   = true;
  bool _isOccupancyExpanded  = false;
  bool _velocityWeekly       = true; // true = weekly, false = monthly
  bool _isFbUser             = false; // derived after dept load


  static const _monthNames = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    final role   = await UserSessionHelper.getRole();
    final roleId = await UserSessionHelper.getRoleId();
    final userId = await UserSessionHelper.getUserId();
    final depts  = await UserSessionHelper.getDepartments();
    final profile = await UserSessionHelper.getUserProfile();
    final sendReports = profile?['send_reports']?.toString().toUpperCase() ?? 'N';
    if (!mounted) return;

    setState(() {
      _userRole   = role ?? '';
      _userRoleId = roleId ?? _deriveRoleId(role);
      _userId     = userId;
      _canSendReports = sendReports == 'Y';

      _availableFilterDepts = List.from(depts)..sort();
      if (_isDeptScopedRole(_userRoleId)) {
        if (_availableFilterDepts.length == 1) {
          _selectedDept = _availableFilterDepts.first;
        }
      }
    });

    await Future.wait([
      _loadMyStats(),
      if (_isSupervisorOrAbove(_userRoleId)) _loadTeamPerformance(),
    ]);
  }

  int? _deriveRoleId(String? role) {
    switch (role) {
      case 'Admin':            return 1;
      case 'General Manager':  return 2;
      case 'Manager':          return 3;
      case 'Department Head':  return 4;
      case 'Supervisor':       return 5;
      case 'Staff':            return 6;
      default:                 return null;
    }
  }

  // ── Personal stats ────────────────────────────────────────────────────────

  Future<void> _loadMyStats() async {
    if (!mounted) return;
    setState(() {
      _statsLoading = true;
      _statsError   = null;
    });

    if (_isManagementOnly(_userRoleId)) {
      setState(() => _statsLoading = false);
      return;
    }

    final result = await _homeService.getTeamPerformance(
      targetUserId: _userId,
      month: _selectedMonth,
      year:  _selectedYear,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      final teamList  = (result['team']      as List? ?? []);
      final drillDown = (result['drillDown'] as List? ?? []);

      final selfRow = teamList.isNotEmpty
          ? Map<String, dynamic>.from(teamList.first)
          : <String, dynamic>{};

      // FIX 2: Keep the full list in _allTasks; show only first 5 inline.
      List<dynamic> allTasksList = drillDown;

      if (allTasksList.isEmpty && _isStaff(_userRoleId)) {
        final tasksResult = await _homeService.getTasks();
        if (tasksResult['success'] == true) {
          allTasksList = (tasksResult['tasks'] as List?) ?? [];
        }
      }

      final myAvgMins = (selfRow['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
      final myTotAssigned = (selfRow['total_assigned'] as int?) ?? 0;
      final myTotClosed   = (selfRow['total_closed']   as int?) ?? 0;
      final myTotEsc      = (selfRow['total_escalated'] as int?) ?? escalatedTasks;
      final myEscRate     = (selfRow['escalation_rate_pct'] as num?)?.toDouble() ??
          (myTotAssigned > 0 ? (myTotEsc / myTotAssigned * 100) : 0.0);

      setState(() {
        totalTasks            = myTotAssigned;
        completedTasks        = myTotClosed;
        escalatedTasks        = myTotEsc;
        inProgressTasks       = (totalTasks - completedTasks).clamp(0, 9999);
        _avgResolutionMinutes = myAvgMins;
        _escalationRatePct    = myEscRate;
        _allTasks             = allTasksList;
        _recentTasks          = allTasksList.take(5).toList();
        _hasMoreTasks         = allTasksList.length > 5;
        _statsLoading         = false;
        _statsError           = null;
      });
    } else {
      // FIX-10 (Bug 10): show the error and clear stale figures instead of
      // silently leaving the previous month's numbers on screen next to a
      // newly-selected month — this was the "wrong month" bug.
      if (mounted) {
        setState(() {
          _statsLoading         = false;
          _statsError           = result['message'] as String? ??
              'Failed to load activity. Please check your connection.';
          totalTasks            = 0;
          completedTasks        = 0;
          inProgressTasks       = 0;
          escalatedTasks        = 0;
          _avgResolutionMinutes = 0.0;
          _escalationRatePct    = 0.0;
          _allTasks             = [];
          _recentTasks          = [];
          _hasMoreTasks         = false;
        });
      }
    }
  }

  // ── Team performance ──────────────────────────────────────────────────────

  Future<void> _loadTeamPerformance() async {
    if (!mounted) return;
    setState(() => _teamLoading = true);

    final result = await _homeService.getTeamPerformance(
      month: _selectedMonth,
      year:  _selectedYear,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      final rows = (result['team'] as List? ?? [])
          .cast<Map<String, dynamic>>();

      int totAssigned = 0, totClosed = 0, totEscalated = 0;
      double totalMinsWeighted = 0;
      int closedWithMins = 0;
      final Map<String, Map<String, dynamic>> deptsMap = {};

      for (final r in rows) {
        final assigned = (r['total_assigned'] as int?) ?? 0;
        final closed   = (r['total_closed']   as int?) ?? 0;
        final esc      = (r['total_escalated'] as int?) ?? 0;
        final mins     = (r['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
        final dept     = (r['department_name'] ?? 'General').toString();

        totAssigned  += assigned;
        totClosed    += closed;
        totEscalated += esc;
        if (closed > 0 && mins > 0) {
          totalMinsWeighted += (mins * closed);
          closedWithMins    += closed;
        }

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

      final overallAvgMins = closedWithMins > 0 ? (totalMinsWeighted / closedWithMins) : 0.0;
      final overallEscRate = totAssigned > 0 ? (totEscalated / totAssigned * 100) : 0.0;

      double curAvgMins = overallAvgMins;
      double curEscRate = overallEscRate;

      if (_selectedDept != null && deptsMap.containsKey(_selectedDept)) {
        curAvgMins = (deptsMap[_selectedDept]!['avg_resolution_minutes'] as double?) ?? 0.0;
        curEscRate = (deptsMap[_selectedDept]!['escalation_rate_pct'] as double?) ?? 0.0;
      }

      if (_isManagementOnly(_userRoleId)) {
        setState(() {
          totalTasks      = totAssigned;
          completedTasks  = totClosed;
          escalatedTasks  = totEscalated;
          inProgressTasks = (totAssigned - totClosed).clamp(0, 9999);
        });
      }

      if (!_isDeptScopedRole(_userRoleId)) {
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

      setState(() {
        _teamRowsAll          = rows;
        _teamRows             = _applyDeptFilter(rows);
        _deptPerformance      = deptsMap;
        _avgResolutionMinutes = curAvgMins;
        _escalationRatePct    = curEscRate;
        _teamLoading          = false;
        // ── RS3: Overall department benchmark ──────────────────────────────
        _overallDepartments = (result['departments']
                as List<Map<String, dynamic>>? ??
            []);
        // ── RS4/RS5/RS6/RS7: Operations velocity ───────────────────────────
        _weeklyServices     = (result['weeklyServices']    as List<Map<String, dynamic>>? ?? []);
        _monthlyServices    = (result['monthlyServices']   as List<Map<String, dynamic>>? ?? []);
        _weeklyDepartments  = (result['weeklyDepartments'] as List<Map<String, dynamic>>? ?? []);
        _monthlyDepartments = (result['monthlyDepartments']as List<Map<String, dynamic>>? ?? []);
        // ── RS12–RS15: F&B analytics ───────────────────────────────────────
        _weeklyFood         = (result['weeklyFood']        as List<Map<String, dynamic>>? ?? []);
        _monthlyFood        = (result['monthlyFood']       as List<Map<String, dynamic>>? ?? []);
        _weeklyFoodUsers    = (result['weeklyFoodUsers']   as List<Map<String, dynamic>>? ?? []);
        _monthlyFoodUsers   = (result['monthlyFoodUsers']  as List<Map<String, dynamic>>? ?? []);
        // ── RS16/RS17: Guest occupancy ─────────────────────────────────────
        _weeklyGuests       = (result['weeklyGuests']      as List<Map<String, dynamic>>? ?? []);
        _monthlyGuests      = (result['monthlyGuests']     as List<Map<String, dynamic>>? ?? []);
        // ── F&B dept detection ─────────────────────────────────────────────
        // Detect if the user's departments list contains any F&B-style dept.
        // This is used to gate the F&B analytics card visibility.
        final fbKeywords = ['f&b', 'food', 'beverage', 'restaurant', 'kitchen', 'dining'];
        _isFbUser = _isGmOrAdmin(_userRoleId) ||
            _availableFilterDepts.any((d) =>
                fbKeywords.any((kw) => d.toLowerCase().contains(kw)));
      });
    } else {
      if (mounted) setState(() => _teamLoading = false);
    }
  }

  // ── Dept filter helpers ───────────────────────────────────────────────────

  List<Map<String, dynamic>> _applyDeptFilter(
      List<Map<String, dynamic>> rows) {
    // If logged-in user is Supervisor or Dept Head, only show staff subordinates
    final baseRows = _isDeptScopedRole(_userRoleId)
        ? rows.where((r) {
            final role = (r['role_name'] ?? '').toString().toLowerCase();
            final roleId = r['role_id'] as int?;
            return (roleId == 6 || role == 'staff');
          }).toList()
        : rows;

    if (_selectedDept != null) {
      return baseRows.where((r) {
        return (r['department_name'] ?? '').toString() == _selectedDept;
      }).toList();
    }

    // When _selectedDept is null (All Departments), group by user_id
    // to deduplicate staff members across multiple departments:
    final Map<int, Map<String, dynamic>> userMap = {};

    for (final r in baseRows) {
      final int userId = (r['user_id'] as int?) ?? 0;
      if (userId == 0) continue;

      final deptName = (r['department_name'] ?? '').toString().trim();
      final assigned = (r['total_assigned'] as int?) ?? 0;
      final closed   = (r['total_closed']   as int?) ?? 0;
      final esc      = (r['total_escalated'] as int?) ?? 0;
      final mins     = (r['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;

      if (!userMap.containsKey(userId)) {
        userMap[userId] = {
          ...r,
          'departments': <String>[],
          'total_assigned': 0,
          'total_closed': 0,
          'total_escalated': 0,
          '_total_mins_weighted': 0.0,
          '_closed_with_mins': 0,
        };
      }

      final u = userMap[userId]!;
      final depts = u['departments'] as List<String>;
      if (deptName.isNotEmpty && !depts.contains(deptName)) {
        depts.add(deptName);
      }

      u['total_assigned'] = (u['total_assigned'] as int) + assigned;
      u['total_closed']   = (u['total_closed']   as int) + closed;
      u['total_escalated'] = (u['total_escalated'] as int) + esc;
      if (closed > 0 && mins > 0) {
        u['_total_mins_weighted'] = (u['_total_mins_weighted'] as double) + (mins * closed);
        u['_closed_with_mins']    = (u['_closed_with_mins'] as int) + closed;
      }
    }

    for (final u in userMap.values) {
      final a = u['total_assigned'] as int;
      final e = u['total_escalated'] as int;
      final cwm = u['_closed_with_mins'] as int;
      final mw  = u['_total_mins_weighted'] as double;
      u['escalation_rate_pct'] = a > 0 ? (e / a * 100) : 0.0;
      u['avg_resolution_minutes'] = cwm > 0 ? (mw / cwm) : 0.0;
      final depts = u['departments'] as List<String>;
      u['department_name'] = depts.isNotEmpty ? depts.join(', ') : (u['department_name'] ?? '');
    }

    return userMap.values.toList();
  }

  void _onDeptSelected(String? dept) {
    if (_selectedDept == dept) return;
    setState(() {
      _selectedDept = dept;
      _teamRows     = _applyDeptFilter(_teamRowsAll);
      if (dept != null && _deptPerformance.containsKey(dept)) {
        _avgResolutionMinutes = (_deptPerformance[dept]!['avg_resolution_minutes'] as double?) ?? 0.0;
        _escalationRatePct    = (_deptPerformance[dept]!['escalation_rate_pct'] as double?) ?? 0.0;
      } else {
        int totAssigned = 0, totEscalated = 0, closedWithMins = 0;
        double totalMinsWeighted = 0;
        for (final r in _teamRowsAll) {
          final a = (r['total_assigned'] as int?) ?? 0;
          final c = (r['total_closed']   as int?) ?? 0;
          final e = (r['total_escalated'] as int?) ?? 0;
          final m = (r['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
          totAssigned  += a;
          totEscalated += e;
          if (c > 0 && m > 0) {
            totalMinsWeighted += (m * c);
            closedWithMins    += c;
          }
        }
        _avgResolutionMinutes = closedWithMins > 0 ? (totalMinsWeighted / closedWithMins) : 0.0;
        _escalationRatePct    = totAssigned > 0 ? (totEscalated / totAssigned * 100) : 0.0;
      }
    });
  }

  // ── Refresh ───────────────────────────────────────────────────────────────

  Future<void> _onRefresh() async {
    final bool isRecoveringFromError = _statsError != null;

    if (isRecoveringFromError) {
      try {
        await ProfileService().getProfile();
        final role   = await UserSessionHelper.getRole();
        final roleId = await UserSessionHelper.getRoleId();
        final userId = await UserSessionHelper.getUserId();
        final depts  = await UserSessionHelper.getDepartments();
        final profile = await UserSessionHelper.getUserProfile();
        final sendReports = profile?['send_reports']?.toString().toUpperCase() ?? 'N';
        if (mounted) {
          setState(() {
            _userRole   = role ?? '';
            _userRoleId = roleId ?? _deriveRoleId(role);
            _userId     = userId;
            _canSendReports = sendReports == 'Y';
            _availableFilterDepts = List.from(depts)..sort();
            if (_isDeptScopedRole(_userRoleId)) {
              if (_availableFilterDepts.length == 1) {
                _selectedDept = _availableFilterDepts.first;
              }
            }
          });
        }
      } catch (_) {}
    }

    await Future.wait([
      _loadMyStats(),
      if (_isSupervisorOrAbove(_userRoleId)) _loadTeamPerformance(),
    ]);
  }

  // ── Month / year change ───────────────────────────────────────────────────

  void _onMonthChanged(int month) {
    if (_selectedMonth == month) return;
    setState(() => _selectedMonth = month);
    _loadMyStats();
    if (_isSupervisorOrAbove(_userRoleId)) _loadTeamPerformance();
  }

  void _onYearChanged(int year) {
    if (_selectedYear == year) return;
    setState(() => _selectedYear = year);
    _loadMyStats();
    if (_isSupervisorOrAbove(_userRoleId)) _loadTeamPerformance();
  }

  // ── Bottom sheets ─────────────────────────────────────────────────────────

  void _showMonthPickerSheet() {
    final now = DateTime.now();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MonthPickerSheet(
        initialMonth: _selectedMonth,
        initialYear:  _selectedYear,
        maxYear:      now.year,
        onMonthSelected: (month) {
          _onMonthChanged(month);
          Navigator.pop(context);
        },
        onYearChanged: (year) {
          _onYearChanged(year);
          setState(() {});
        },
      ),
    );
  }

  void _showDeptFilterSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DeptFilterSheet(
        selectedDept:  _selectedDept,
        departments:   _availableFilterDepts,
        showAllOption: true,
        onSelected: (dept) {
          _onDeptSelected(dept);
          Navigator.pop(context);
        },
      ),
    );
  }

  // FIX 2: Opens a full-list sheet with all tasks for the period.
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
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    const Text('All Tasks',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary)),
                    const SizedBox(width: 8),
                    _buildCountPill(_allTasks.length),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.borderLight),
              Expanded(
                child: ListView.separated(
                  controller:      controller,
                  itemCount:       _allTasks.length,
                  separatorBuilder: (_, __) => const Divider(
                      height: 1,
                      color: AppColors.borderLight,
                      indent: 16,
                      endIndent: 16),
                  itemBuilder: (ctx, i) =>
                      _buildActivityRow(_allTasks[i] as Map<String, dynamic>),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // FIX 3: Opens a sheet filtered to a specific status category.
  void _showFilteredTasksSheet(String filter, String sheetTitle) {
    final filtered = _allTasks.where((t) {
      final task  = t as Map<String, dynamic>;
      final isEsc = (task['is_escalated'] == 1 ||
          task['is_escalated'] == true ||
          task['task_flag'] == 'Escalated' ||
          task['escalation_instance_id'] != null ||
          task['escalation_status'] != null);
      final status =
          (task['task_flag'] ?? task['status'] ?? 'Open').toString();
      switch (filter) {
        case 'completed':  return status == 'Closed' && !isEsc;
        case 'inProgress': return status == 'In Progress' && !isEsc;
        case 'escalated':  return isEsc;
        default:           return true;
      }
    }).toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        maxChildSize:     0.95,
        minChildSize:     0.35,
        builder: (_, controller) => Container(
          decoration: const BoxDecoration(
            color:        Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              _buildSheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    Text(sheetTitle,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary)),
                    const SizedBox(width: 8),
                    _buildCountPill(filtered.length),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.borderLight),
              if (filtered.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('No tasks',
                      style: AppTypography.bodySecondary),
                )
              else
                Expanded(
                  child: ListView.separated(
                    controller:      controller,
                    itemCount:       filtered.length,
                    separatorBuilder: (_, __) => const Divider(
                        height: 1,
                        color: AppColors.borderLight,
                        indent: 16,
                        endIndent: 16),
                    itemBuilder: (ctx, i) =>
                        _buildActivityRow(filtered[i] as Map<String, dynamic>),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Shared sheet widgets ──────────────────────────────────────────────────

  Widget _buildSheetHandle() => Container(
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        width:  36,
        height: 4,
        decoration: BoxDecoration(
          color:        Colors.grey.shade300,
          borderRadius: BorderRadius.circular(2),
        ),
      );

  Widget _buildCountPill(int count) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color:        AppColors.primaryLight,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text('$count',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.primary)),
      );

  // ── Build ─────────────────────────────────────────────────────────────────

  Widget _buildSkeletonView() {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: SkeletonLoader(height: 44, borderRadius: BorderRadius.circular(14))),
                const SizedBox(width: 10),
                Expanded(child: SkeletonLoader(height: 44, borderRadius: BorderRadius.circular(14))),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: const [
                Expanded(child: SkeletonStatCard()),
                SizedBox(width: 8),
                Expanded(child: SkeletonStatCard()),
                SizedBox(width: 8),
                Expanded(child: SkeletonStatCard()),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: List.generate(
                10,
                (_) => const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: SkeletonTaskCard(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showDeptButton = _isSupervisorOrAbove(_userRoleId) &&
        (_availableFilterDepts.length > 1 || _selectedDept != null);

    return Scaffold(
      backgroundColor: AppColors.bgLight,
      appBar: _buildAppBar(),
      body: _statsLoading
          ? _buildSkeletonView()
          : _statsError != null
              ? RefreshIndicator(
                  onRefresh: _onRefresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(32),
                    children: [
                      SizedBox(height: MediaQuery.of(context).size.height * 0.15),
                      Icon(
                        _statsError!.toLowerCase().contains('department')
                            ? Icons.info_outline_rounded
                            : Icons.wifi_off_rounded,
                        size: 52,
                        color: _statsError!.toLowerCase().contains('department')
                            ? AppColors.warning
                            : Colors.grey.shade400,
                      ),
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
                          onPressed: _loadMyStats,
                          child: Text(
                            _statsError!.toLowerCase().contains('department')
                                ? 'Refresh Status'
                                : 'Try Again',
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
              onRefresh: _onRefresh,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── GM / Admin executive header banner ──────────────────
                    if (_isGmOrAdmin(_userRoleId))
                      _buildExecutiveHeaderBanner(),
                    // ── Filter row ──────────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Row(
                        children: [
                          Expanded(child: _buildMonthTile()),
                          if (showDeptButton) ...[
                            const SizedBox(width: 10),
                            Expanded(child: _buildDeptTile()),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    // ── Stat cards (role-aware layout) ──────────────────────
                    _buildStatCards(),
                    // ── Efficiency strip — Supervisor+ only ─────────────────
                    if (_isSupervisorOrAbove(_userRoleId))
                      _buildEfficiencyMetricsStrip(),
                     // ── Staff personal summary (instead of efficiency strip) ─
                    if (_isStaff(_userRoleId))
                      _buildStaffPersonalSummary(),
                    // ── Department benchmark — multi-dept roles ──────────────
                    if (_isSupervisorOrAbove(_userRoleId) && _deptPerformance.length > 1) ...[
                      _buildDepartmentPerformanceSection(),
                    ],
                    // ── Operations velocity chart — Supervisor+ (RS4/RS5/RS6/RS7)
                    if (_isSupervisorOrAbove(_userRoleId) &&
                        (_weeklyServices.isNotEmpty || _weeklyDepartments.isNotEmpty))
                      _buildOperationsVelocitySection(),
                    // ── F&B analytics — F&B users & GM/Admin (RS12–RS15) ─────
                    if (_isFbUser && (_weeklyFood.isNotEmpty || _weeklyFoodUsers.isNotEmpty))
                      _buildFoodAnalyticsSection(),
                    // ── Team list — Supervisor+ ──────────────────────────────
                    if (_isSupervisorOrAbove(_userRoleId)) ...[
                      _buildTeamSectionHeader(),
                      _buildTeamList(),
                    ],
                    // ── Occupancy vs. workload — GM/Admin (RS16/RS17) ─────────
                    if (_isGmOrAdmin(_userRoleId) && _weeklyGuests.isNotEmpty)
                      _buildOccupancyCorrelationSection(),
                    // ── Recent activity — non-management roles ───────────────
                    if (!_isManagementOnly(_userRoleId))
                      _buildRecentActivity(),
                    // ── Contextual banner ────────────────────────────────────
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
    final isExec = _isGmOrAdmin(_userRoleId);
    final subtitle = _isStaff(_userRoleId)
        ? 'Your performance overview'
        : '${_monthNames[_selectedMonth]} $_selectedYear';

    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isExec ? 'Executive Dashboard' : 'My Tasks',
            style: AppTypography.appBarTitle,
          ),
          Text(subtitle, style: AppTypography.appBarSubtitle),
        ],
      ),
      actions: [
        if (_isSupervisorOrAbove(_userRoleId) && _canSendReports)
          Container(
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: IconButton(
              icon: const Icon(Icons.analytics_outlined, color: AppColors.primary),
              onPressed: _showExportReportDialog,
              tooltip: 'Export PDF Report',
            ),
          ),
      ],
    );
  }

  // ── Executive Header Banner (GM / Admin only) ─────────────────────────────

  Widget _buildExecutiveHeaderBanner() {
    final month  = _monthNames[_selectedMonth];
    final period = '$month $_selectedYear';
    final dept   = _selectedDept ?? 'All Departments';

    return Container(
      margin: const EdgeInsets.only(bottom: 0),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF052D50), Color(0xFF0F4C7A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dept,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Performance Overview · $period',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          // Total count badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
              ),
            ),
            child: Column(
              children: [
                Text(
                  '$totalTasks',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                  ),
                ),
                Text(
                  'Tasks',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showExportReportDialog() async {
    final name = await UserSessionHelper.getUserName() ?? 'Management';
    final enterpriseIdVal = await UserSessionHelper.getEnterpriseId();
    final enterpriseId = enterpriseIdVal != null ? "HT${enterpriseIdVal.toString().padLeft(3, '0')}" : "HT001";
    final tier = 6 - (_userRoleId ?? 6);

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ExportReportBottomSheet(
        userTierLevel: tier,
        departmentName: _selectedDept ?? 'All Departments',
        homeService: _homeService,
        userRole: _userRole,
        userName: name,
        enterpriseId: enterpriseId,
      ),
    );
  }

  // ── Month Tile ────────────────────────────────────────────────────────────

  Widget _buildMonthTile() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _showMonthPickerSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.calendar_month_outlined, size: 15,
                  color: AppColors.primary),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${_monthNames[_selectedMonth]} $_selectedYear',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary),
                  overflow: TextOverflow.ellipsis),
            ),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 16,
                color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  // ── Dept Tile ─────────────────────────────────────────────────────────────

  Widget _buildDeptTile() {
    final label = _selectedDept ?? 'All Departments';
    final isFiltered = _selectedDept != null;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _showDeptFilterSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isFiltered ? AppColors.primary.withValues(alpha: 0.06) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isFiltered ? AppColors.primary.withValues(alpha: 0.4) : AppColors.border,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: isFiltered
                    ? AppColors.primary.withValues(alpha: 0.15)
                    : AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.business_outlined, size: 15,
                  color: isFiltered ? AppColors.primary : AppColors.textSecondary),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isFiltered ? AppColors.primary : AppColors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis),
            ),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 16,
                color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  // ── Stat Cards ────────────────────────────────────────────────────────────

  Widget _buildStatCards() {
    final cards = [
      _StatCardData(
        count:       '$totalTasks',
        label:       _isManagementOnly(_userRoleId) ? 'Team Total' : 'Total Assigned',
        icon:        Icons.assignment_outlined,
        accentColor: AppColors.primary,
        filterStatus: null,
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
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: cards.asMap().entries.map((e) {
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: e.key == 0 ? 0 : 8),
              child: _buildStatCard(e.value),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildStatCard(_StatCardData d) {
    final isTappable = d.filterStatus != null && !_isManagementOnly(_userRoleId);
    final card = Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border(
          left: BorderSide(
            color: d.highlight ? d.accentColor : d.accentColor.withValues(alpha: 0.5),
            width: 3,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: d.accentColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(d.icon, size: 16, color: d.accentColor),
              ),
              if (isTappable) ...[
                const Spacer(),
                Icon(Icons.chevron_right_rounded,
                    size: 14,
                    color: d.accentColor.withValues(alpha: 0.5)),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            d.count,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: d.accentColor,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            d.label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary.withValues(alpha: 0.9),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    if (!isTappable) return card;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _showFilteredTasksSheet(d.filterStatus!, d.label),
      child: card,
    );
  }

  // ── Executive Efficiency Metrics Strip (Supervisor+) ─────────────────────

  Widget _buildEfficiencyMetricsStrip() {
    final avgStr = _avgResolutionMinutes <= 0
        ? '—'
        : _avgResolutionMinutes < 60
            ? '${_avgResolutionMinutes.toStringAsFixed(0)} min'
            : '${(_avgResolutionMinutes / 60).toStringAsFixed(1)} hrs';

    final escRateStr = '${_escalationRatePct.toStringAsFixed(1)}%';
    final isGoodEsc = _escalationRatePct <= 5.0;
    final isWarningEsc = _escalationRatePct > 5.0 && _escalationRatePct <= 15.0;
    final escColor = isGoodEsc
        ? AppColors.success
        : (isWarningEsc ? AppColors.warning : AppColors.error);
    final escLabel = isGoodEsc ? 'Optimal' : (isWarningEsc ? 'Elevated' : 'Critical');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
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
        child: IntrinsicHeight(
          child: Row(
            children: [
              // ── Avg Turnaround ──────────────────────────────────────────
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              AppColors.primary.withValues(alpha: 0.15),
                              AppColors.primary.withValues(alpha: 0.05),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.timer_outlined,
                            size: 20, color: AppColors.primary),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Avg Resolution',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: AppColors.textSecondary.withValues(alpha: 0.8),
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              avgStr,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ── Divider ─────────────────────────────────────────────────
              VerticalDivider(
                width: 1,
                color: AppColors.borderLight,
                indent: 12,
                endIndent: 12,
              ),
              // ── Escalation Rate ──────────────────────────────────────────
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              escColor.withValues(alpha: 0.18),
                              escColor.withValues(alpha: 0.06),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          isGoodEsc
                              ? Icons.trending_down_rounded
                              : Icons.trending_up_rounded,
                          size: 20,
                          color: escColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Escalation Rate',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: AppColors.textSecondary.withValues(alpha: 0.8),
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 3),
                            // This column can be as narrow as ~82px on
                            // smaller phones. Scale the rate and badge as a
                            // unit instead of allowing the Row to overflow.
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Text(
                                    escRateStr,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: escColor,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: escColor.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: Text(
                                      escLabel,
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                        color: escColor,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Staff Personal Summary (shown instead of efficiency strip for Staff) ──

  Widget _buildStaffPersonalSummary() {
    if (totalTasks == 0) return const SizedBox.shrink();
    final pct = totalTasks > 0
        ? (completedTasks / totalTasks * 100).clamp(0.0, 100.0)
        : 0.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.borderLight),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Completion Progress',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary.withValues(alpha: 0.8),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: pct / 100,
                      minHeight: 6,
                      backgroundColor: AppColors.borderLight,
                      valueColor: const AlwaysStoppedAnimation<Color>(AppColors.success),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$completedTasks of $totalTasks completed',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Text(
              '${pct.toStringAsFixed(0)}%',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: AppColors.success,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Department Performance Benchmark Section ──────────────────────────────

  Widget _buildDepartmentPerformanceSection() {
    if (_deptPerformance.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 4,
                      height: 18,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Department Benchmark',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                if (_selectedDept != null)
                  GestureDetector(
                    onTap: () => _onDeptSelected(null),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Show All',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 120,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 16),
              itemCount: _deptPerformance.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final deptName = _deptPerformance.keys.elementAt(index);
                final d = _deptPerformance[deptName]!;
                final isSelected = _selectedDept == deptName;

                final total  = (d['total_assigned']  as int?)    ?? 0;
                final closed = (d['total_closed']    as int?)    ?? 0;
                final esc    = (d['total_escalated'] as int?)    ?? 0;
                final avgM   = (d['avg_resolution_minutes'] as double?) ?? 0.0;
                final escR   = (d['escalation_rate_pct']   as double?) ?? 0.0;
                final closurePct = total > 0 ? (closed / total).clamp(0.0, 1.0) : 0.0;

                final avgMStr = avgM <= 0
                    ? '—'
                    : avgM < 60
                        ? '${avgM.toStringAsFixed(0)}m'
                        : '${(avgM / 60).toStringAsFixed(1)}h';
                final isGoodEsc = escR <= 5.0;
                final escColor = isGoodEsc
                    ? AppColors.success
                    : (escR <= 15.0 ? AppColors.warning : AppColors.error);

                return GestureDetector(
                  onTap: () => _onDeptSelected(isSelected ? null : deptName),
                  child: Container(
                    width: 180,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primary.withValues(alpha: 0.06)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.borderLight,
                        width: isSelected ? 1.5 : 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Dept name + esc badge
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                deptName,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: isSelected
                                      ? AppColors.primary
                                      : AppColors.textPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (esc > 0) ...[
                              const SizedBox(width: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 2),
                                decoration: BoxDecoration(
                                  color: escColor.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  '${escR.toStringAsFixed(0)}%',
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: escColor,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        // Closure progress bar
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: closurePct,
                            minHeight: 4,
                            backgroundColor: AppColors.borderLight,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                                AppColors.success),
                          ),
                        ),
                        const SizedBox(height: 6),
                        // Stats row
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '$closed / $total',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                Text(
                                  'Closed / Total',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: AppColors.textSecondary
                                        .withValues(alpha: 0.8),
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  avgMStr,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: isSelected
                                        ? AppColors.primary
                                        : AppColors.textPrimary,
                                  ),
                                ),
                                Text(
                                  'Avg Time',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: AppColors.textSecondary
                                        .withValues(alpha: 0.8),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Team Section Header ───────────────────────────────────────────────────

  Widget _buildTeamSectionHeader() {
    String baseTitle;
    if (_isGmOrAdmin(_userRoleId) || _isManager(_userRoleId)) {
      baseTitle = 'All Departments';
    } else if (_isDeptHead(_userRoleId)) {
      baseTitle = 'My Department';
    } else {
      baseTitle = 'My Team';
    }
    final title = _selectedDept ?? baseTitle;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 18,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          if (_teamLoading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (_teamRows.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Text(
                '${_teamRows.length} members',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Team List (Hierarchical & Multi-Department Grouping) ───────────────────

  Widget _buildTeamList() {
    if (_teamLoading && _teamRows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_teamRows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Container(
          width:   double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: const Column(children: [
            Icon(Icons.people_outline, size: 36, color: AppColors.textDisabled),
            SizedBox(height: 8),
            Text('No team data for this period',
                style: AppTypography.bodySecondary),
          ]),
        ),
      );
    }

    // 1. If logged-in user is Supervisor or Dept Head -> Only show staff subordinates
    if (_isDeptScopedRole(_userRoleId)) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHierarchySectionHeader(
              title: 'Department Staff Subordinates',
              count: _teamRows.length,
              icon: Icons.people_alt_outlined,
              color: AppColors.primary,
            ),
            const SizedBox(height: 8),
            ..._teamRows.map((row) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _buildTeamRow(row, isLeader: false),
            )),
          ],
        ),
      );
    }

    // 2. If Manager / GM / Admin in "All Departments" mode -> Group by Department Hierarchy
    if (_selectedDept == null) {
      final deptNames = _availableFilterDepts.isNotEmpty
          ? _availableFilterDepts
          : _deptPerformance.keys.toList();

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: deptNames.map((deptName) {
            final deptRows = _teamRowsAll.where((r) {
              return (r['department_name'] ?? '').toString() == deptName;
            }).toList();

            if (deptRows.isEmpty) return const SizedBox.shrink();

            final deptSupervisors = deptRows.where((r) {
              final role = (r['role_name'] ?? '').toString().toLowerCase();
              return role.contains('supervisor') ||
                  role.contains('dept head') ||
                  role.contains('department head') ||
                  role.contains('manager') ||
                  role.contains('general manager');
            }).toList();

            final deptStaff = deptRows.where((r) {
              final role = (r['role_name'] ?? '').toString().toLowerCase();
              return !role.contains('supervisor') &&
                  !role.contains('dept head') &&
                  !role.contains('department head') &&
                  !role.contains('manager') &&
                  !role.contains('general manager');
            }).toList();

            final dPerf = _deptPerformance[deptName] ?? {};
            final dAssigned = (dPerf['total_assigned'] as int?) ?? 0;
            final dClosed   = (dPerf['total_closed']   as int?) ?? 0;
            final dEsc      = (dPerf['total_escalated'] as int?) ?? 0;
            final dAvgMins  = (dPerf['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
            final dAvgStr   = dAvgMins <= 0 ? '—' : '${dAvgMins.toStringAsFixed(0)}m';

            return Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.borderLight),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Department Header + KPI pill summary
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.business_rounded, color: AppColors.primary, size: 18),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              deptName,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            Text(
                              '$dAssigned tasks · $dClosed closed · ⏱️ $dAvgStr${dEsc > 0 ? " · ⚠️ $dEsc SLA" : ""}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppColors.borderLight),
                  const SizedBox(height: 10),

                  // A. Supervisors / Dept Head in this Department
                  if (deptSupervisors.isNotEmpty) ...[
                    Row(
                      children: [
                        const Icon(Icons.shield_outlined, size: 13, color: Color(0xFF6366F1)),
                        const SizedBox(width: 4),
                        Text(
                          'DEPARTMENT HEAD & SUPERVISOR (${deptSupervisors.length})',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: Color(0xFF6366F1),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ...deptSupervisors.map((row) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _buildTeamRow(row, isLeader: true),
                    )),
                    const SizedBox(height: 6),
                  ],

                  // B. Staff Members in this Department
                  if (deptStaff.isNotEmpty) ...[
                    Row(
                      children: [
                        const Icon(Icons.people_alt_outlined, size: 13, color: AppColors.primary),
                        const SizedBox(width: 4),
                        Text(
                          'DEPARTMENT STAFF (${deptStaff.length})',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ...deptStaff.map((row) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _buildTeamRow(row, isLeader: false),
                    )),
                  ],
                ],
              ),
            );
          }).toList(),
        ),
      );
    }

    // 3. If Manager / GM with a specific Department selected
    final supervisors = _teamRows.where((r) {
      final role = (r['role_name'] ?? '').toString().toLowerCase();
      return role.contains('supervisor') ||
          role.contains('dept head') ||
          role.contains('department head') ||
          role.contains('manager') ||
          role.contains('general manager');
    }).toList();

    final staffMembers = _teamRows.where((r) {
      final role = (r['role_name'] ?? '').toString().toLowerCase();
      return !role.contains('supervisor') &&
          !role.contains('dept head') &&
          !role.contains('department head') &&
          !role.contains('manager') &&
          !role.contains('general manager');
    }).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Supervisors & Department Heads Section
          if (supervisors.isNotEmpty) ...[
            _buildHierarchySectionHeader(
              title: 'Supervisors & Department Heads',
              count: supervisors.length,
              icon: Icons.shield_outlined,
              color: const Color(0xFF6366F1),
            ),
            const SizedBox(height: 8),
            ...supervisors.map((row) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _buildTeamRow(row, isLeader: true),
            )),
            const SizedBox(height: 12),
          ],

          // 2. Staff Members Section
          if (staffMembers.isNotEmpty) ...[
            _buildHierarchySectionHeader(
              title: 'Staff Members',
              count: staffMembers.length,
              icon: Icons.people_alt_outlined,
              color: AppColors.primary,
            ),
            const SizedBox(height: 8),
            ...staffMembers.map((row) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _buildTeamRow(row, isLeader: false),
            )),
          ],
        ],
      ),
    );
  }

  Widget _buildHierarchySectionHeader({
    required String title,
    required int count,
    required IconData icon,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: color,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTeamRow(Map<String, dynamic> row, {bool isLeader = false}) {
    final name      = (row['full_name']          ?? '—').toString();
    final dept      = (row['department_name']    ?? '').toString();
    final roleName  = (row['role_name']          ?? (isLeader ? 'Supervisor' : 'Staff')).toString();
    final assigned  = (row['total_assigned']     as int?) ?? 0;
    final closed    = (row['total_closed']       as int?) ?? 0;
    final escalated = (row['total_escalated']    as int?) ?? 0;
    final avgMins   = (row['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
    final avgStr    = avgMins <= 0
        ? '—'
        : avgMins < 60
            ? '${avgMins.toStringAsFixed(0)}m'
            : '${(avgMins / 60).toStringAsFixed(1)}h';
    final rate      = (row['escalation_rate_pct'] as num?)?.toDouble() ??
        (assigned > 0 ? (escalated / assigned * 100) : 0.0);
    final rateStr   = rate == 0.0 ? '0%' : '${rate.toStringAsFixed(1)}%';
    final userId    = (row['user_id'] as int?) ?? 0;
    final closurePct = assigned > 0 ? (closed / assigned).clamp(0.0, 1.0) : 0.0;

    final hasEsc    = escalated > 0;
    final escColor  = hasEsc ? AppColors.error : AppColors.success;

    // Parse list of departments for this user
    final List<String> deptsList = [];
    if (row['departments'] is List) {
      for (final d in (row['departments'] as List)) {
        final s = d.toString().trim();
        if (s.isNotEmpty && !deptsList.contains(s)) deptsList.add(s);
      }
    } else if (dept.contains(',')) {
      for (final d in dept.split(',')) {
        final s = d.trim();
        if (s.isNotEmpty && !deptsList.contains(s)) deptsList.add(s);
      }
    } else if (dept.isNotEmpty) {
      deptsList.add(dept);
    }

    final initials = name.trim().split(' ')
        .where((s) => s.isNotEmpty)
        .take(2)
        .map((s) => s[0].toUpperCase())
        .join();

    final cardAccentColor = isLeader ? const Color(0xFF6366F1) : AppColors.primary;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _StaffDrillDownPage(
            userId:   userId,
            userName: name,
            deptName: deptsList.isNotEmpty ? deptsList.first : dept,
            month:    _selectedMonth,
            year:     _selectedYear,
            userRole: _userRole,
          ),
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: hasEsc
                ? AppColors.error.withValues(alpha: 0.35)
                : (isLeader ? cardAccentColor.withValues(alpha: 0.25) : AppColors.borderLight),
            width: hasEsc || isLeader ? 1.2 : 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Top row: avatar + name + role pill + chevron ──────────────
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: hasEsc
                        ? AppColors.error.withValues(alpha: 0.1)
                        : cardAccentColor.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    initials.isNotEmpty ? initials : '?',
                    style: TextStyle(
                      color: hasEsc ? AppColors.error : cardAccentColor,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: cardAccentColor.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              roleName,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: cardAccentColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // Multi-department badges
                      if (deptsList.isNotEmpty)
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            ...deptsList.take(2).map((d) => Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceAlt,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: AppColors.borderLight),
                              ),
                              child: Text(
                                d,
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            )),
                            if (deptsList.length > 2)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryLight,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '+${deptsList.length - 2} more',
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
                if (hasEsc)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$escalated SLA',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppColors.error,
                      ),
                    ),
                  )
                else
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: AppColors.textDisabled,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            // ── Closure progress bar ───────────────────────────────────────
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: closurePct,
                minHeight: 4,
                backgroundColor: AppColors.borderLight,
                valueColor: AlwaysStoppedAnimation<Color>(
                  closurePct >= 0.8 ? AppColors.success : AppColors.orange,
                ),
              ),
            ),
            const SizedBox(height: 8),
            // ── Metric chips row ───────────────────────────────────────────
            Row(
              children: [
                _metricChip(
                  label: 'Assigned',
                  value: '$assigned',
                  color: AppColors.primary,
                ),
                const SizedBox(width: 6),
                _metricChip(
                  label: 'Done',
                  value: '$closed',
                  color: AppColors.success,
                ),
                const SizedBox(width: 6),
                _metricChip(
                  label: 'Avg',
                  value: avgStr,
                  color: AppColors.info,
                ),
                const Spacer(),
                if (hasEsc)
                  _metricChip(
                    label: 'Rate',
                    value: rateStr,
                    color: escColor,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricChip({
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 8.5,
              color: color.withValues(alpha: 0.8),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }


  // ── Recent Activity ───────────────────────────────────────────────────────

  Widget _buildRecentActivity() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 18,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Recent Activity',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              if (_recentTasks.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_allTasks.length}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (_recentTasks.isEmpty)
            Container(
              width:   double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.borderLight),
              ),
              child: Column(children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.task_alt, size: 28, color: AppColors.primary),
                ),
                const SizedBox(height: 12),
                const Text('No recent tasks found',
                    style: AppTypography.bodySecondary),
              ]),
            )
          else
            Container(
              decoration: BoxDecoration(
                color:        Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10, offset: const Offset(0, 4))],
              ),
              child: Column(
                children: [
                  ListView.separated(
                    shrinkWrap:  true,
                    physics:     const NeverScrollableScrollPhysics(),
                    itemCount:   _recentTasks.length,
                    separatorBuilder: (_, __) => const Divider(height: 1,
                        color: AppColors.borderLight, indent: 16, endIndent: 16),
                    itemBuilder: (ctx, i) =>
                        _buildActivityRow(_recentTasks[i] as Map<String, dynamic>),
                  ),
                  // FIX 2: Show More button when more tasks exist beyond the first 5
                  if (_hasMoreTasks) ...[
                    const Divider(height: 1, color: AppColors.borderLight),
                    InkWell(
                      onTap: _showAllTasksSheet,
                      borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(18)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Show all ${_allTasks.length} tasks',
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.primary),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.expand_more_rounded,
                                size: 16, color: AppColors.primary),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  // FIX 1 + shared: Extracted row builder used by both the inline list
  // and all bottom sheets. Uses _resolveTitle() so question is shown
  // when task_name is empty.
  Widget _buildActivityRow(Map<String, dynamic> task) {
    final isEsc = (task['is_escalated'] == 1 ||
        task['is_escalated'] == true ||
        task['task_flag'] == 'Escalated' ||
        task['escalation_instance_id'] != null ||
        task['escalation_status'] != null);
    final status = (task['status'] ??
            task['task_flag'] ??
            'Open')
        .toString();
    final stageName = (task['current_stage_name'] ?? task['stage_name'] ?? '').toString();
    final escLevel = task['escalation_level_reached'] ?? task['escalation_level'];

    final displayStatus = isEsc
        ? (stageName.isNotEmpty ? stageName : (escLevel != null ? 'Level $escLevel' : 'Escalated'))
        : status;

    Color statusColor;
    Color statusBg;
    if (isEsc) {
      statusColor = AppColors.error;
      statusBg    = AppColors.errorLight;
    } else if (status == 'Closed') {
      statusColor = AppColors.success;
      statusBg    = AppColors.successLight;
    } else if (status == 'In Progress') {
      statusColor = AppColors.orange;
      statusBg    = AppColors.orangeLight;
    } else {
      statusColor = AppColors.primary;
      statusBg    = AppColors.primaryLight;
    }

    final rawRoom = (task['room_number'] ??
            task['room_id'] ??
            task['room'] ??
            '—')
        .toString();
    final room = (rawRoom == '0' || rawRoom == '000' || rawRoom == 'null' || rawRoom.isEmpty) ? 'General' : rawRoom;

    // FIX 1: Use _resolveTitle() and strip #SRV prefix
    final rawTitle = _resolveTitle(task);
    final title = rawTitle.replaceFirst(RegExp(r'^Order\s+#[A-Z0-9]+\s*-\s*', caseSensitive: false), '');
    final timeAgo = _timeAgo(
        (task['created_at'] ?? task['time'] ?? '').toString());

    final canTap = _isSupervisorOrAboveByName(_userRole);

    final rowContent = Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: isEsc
                ? AppColors.error
                : (status == 'Closed'
                    ? AppColors.success
                    : (status == 'In Progress'
                        ? AppColors.orange
                        : AppColors.primary)),
            width: 3,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Room badge
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isEsc
                    ? AppColors.error.withValues(alpha: 0.1)
                    : AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Text(
                room,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isEsc ? AppColors.error : AppColors.primary,
                  fontWeight: FontWeight.w800,
                  fontSize: room.length > 4 ? 9.5 : 11,
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Title + meta
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (timeAgo.isNotEmpty)
                        Text(
                          timeAgo,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary
                                .withValues(alpha: 0.7),
                          ),
                        ),
                      if (isEsc) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: AppColors.error.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'SLA Breach',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.error,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Status pill
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: statusBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                displayStatus,
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ),
            if (canTap) ...[
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right_rounded,
                size: 15,
                color: AppColors.textDisabled,
              ),
            ],
          ],
        ),
      ),
    );

    if (!canTap) return rowContent;

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TicketDetailPage(
              task: task,
              userRole: _userRole,
              onClose: () => _onRefresh(),
              onReassign: (_) => _onRefresh(),
            ),
          ),
        );
      },
      child: rowContent,
    );
  }

  String _timeAgo(String ts) {
    if (ts.isEmpty) return '';
    try {
      String s = ts.trim();
      if (s.contains(' ') && !s.contains('T')) {
        s = s.replaceFirst(' ', 'T');
      }
      final diff = DateTime.now().difference(DateTime.parse(s).toLocal());
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours   < 24) return '${diff.inHours}h ago';
      return '${diff.inDays}d ago';
    } catch (_) {
      return '';
    }
  }

  // ── Motivation Banner ─────────────────────────────────────────────────────

  Widget _buildMotivationBanner() {
    // Data-driven banner: content adapts to actual performance state
    final isCritical = _escalationRatePct > 15.0 && _isSupervisorOrAbove(_userRoleId);
    final isWarning  = _escalationRatePct > 5.0 && _escalationRatePct <= 15.0 && _isSupervisorOrAbove(_userRoleId);
    final isOptimal  = escalatedTasks == 0 && completedTasks > 0;

    final Color bannerColor;
    final Color bannerBg;
    final Color bannerBorder;
    final IconData bannerIcon;
    final String bannerTitle;
    final String bannerBody;

    if (isCritical) {
      bannerColor  = AppColors.error;
      bannerBg     = AppColors.errorLight;
      bannerBorder = AppColors.error.withValues(alpha: 0.25);
      bannerIcon   = Icons.warning_amber_rounded;
      bannerTitle  = 'Attention Required';
      bannerBody   = 'Escalation rate is ${_escalationRatePct.toStringAsFixed(1)}% — review SLA breaches with your team.';
    } else if (isWarning) {
      bannerColor  = AppColors.warning;
      bannerBg     = AppColors.warningLight;
      bannerBorder = AppColors.warning.withValues(alpha: 0.25);
      bannerIcon   = Icons.info_outline_rounded;
      bannerTitle  = 'SLA Watch';
      bannerBody   = 'Escalation rate at ${_escalationRatePct.toStringAsFixed(1)}% — monitor closely to stay in range.';
    } else if (isOptimal) {
      bannerColor  = AppColors.success;
      bannerBg     = AppColors.successLight;
      bannerBorder = AppColors.success.withValues(alpha: 0.25);
      bannerIcon   = Icons.verified_outlined;
      bannerTitle  = 'Excellent Performance';
      bannerBody   = 'Zero SLA escalations this period. Outstanding work!';
    } else {
      bannerColor  = AppColors.primary;
      bannerBg     = AppColors.primary.withValues(alpha: 0.06);
      bannerBorder = AppColors.primary.withValues(alpha: 0.18);
      bannerIcon   = Icons.star_outline_rounded;
      bannerTitle  = 'Keep it up!';
      bannerBody   = 'Complete more tasks and maintain your SLA performance.';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:        bannerBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: bannerBorder),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: bannerColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(bannerIcon, color: bannerColor, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bannerTitle,
                    style: TextStyle(
                      color: bannerColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    bannerBody,
                    style: TextStyle(
                      color: bannerColor.withValues(alpha: 0.8),
                      fontSize: 12,
                      height: 1.4,
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

  // ═══════════════════════════════════════════════════════════════════════════
  // ANALYTICS WIDGETS — Powered by Unused Result Sets RS4–RS17
  // ═══════════════════════════════════════════════════════════════════════════

  // ── Helper: section header with colored accent bar ────────────────────────
  Widget _buildSectionHeader({
    required String title,
    required IconData icon,
    required Color iconColor,
    Widget? trailing,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: iconColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Icon(icon, size: 18, color: iconColor),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing,
        ],
      ],
    );
  }

  // ── Helper: collapse/expand chevron button ────────────────────────────────
  Widget _buildCollapseToggle(bool isExpanded, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
          size: 18,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  // ── Helper: format a week_start/week_end pair into "May 15–21" ─────────────
  String _formatWeekLabel(Map<String, dynamic> row) {
    final ws = row['week_start']?.toString() ?? '';
    final we = row['week_end']?.toString() ?? '';
    try {
      final start = DateTime.parse(ws);
      final end   = we.isNotEmpty ? DateTime.parse(we) : start.add(const Duration(days: 6));
      final months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${months[start.month]} ${start.day}–${end.day}';
    } catch (_) {
      return ws.isEmpty ? '—' : ws.substring(0, ws.length.clamp(0, 10));
    }
  }

  // ── Helper: format minutes into "32m" or "1.5h" ──────────────────────────
  String _fmtMins(dynamic value) {
    final m = (value as num?)?.toDouble() ?? 0.0;
    if (m <= 0) return '—';
    if (m < 60) return '${m.toStringAsFixed(0)}m';
    return '${(m / 60).toStringAsFixed(1)}h';
  }

  // ── Helper: format currency (Indian lakh system) ──────────────────────────
  String _fmtRevenue(dynamic value) {
    final v = (value as num?)?.toDouble() ?? 0.0;
    if (v >= 100000) return '₹${(v / 100000).toStringAsFixed(2)}L';
    if (v >= 1000)   return '₹${(v / 1000).toStringAsFixed(1)}K';
    return '₹${v.toStringAsFixed(0)}';
  }

  // ── Helper: closure rate → color ─────────────────────────────────────────
  Color _closureColor(double pct) {
    if (pct >= 85) return AppColors.success;
    if (pct >= 70) return AppColors.warning;
    return AppColors.error;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 1. OPERATIONS VELOCITY SECTION (RS4/RS5 enterprise + RS6/RS7 dept-scoped)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildOperationsVelocitySection() {
    // Choose data source: dept-scoped when a filter is active, enterprise-wide otherwise.
    final weeklyData  = _selectedDept != null
        ? _weeklyDepartments .where((r) => (r['department_name']?.toString() ?? '') == _selectedDept).toList()
        : _weeklyServices;
    final monthlyData = _selectedDept != null
        ? _monthlyDepartments.where((r) => (r['department_name']?.toString() ?? '') == _selectedDept).toList()
        : _monthlyServices;

    final source = _velocityWeekly ? weeklyData : monthlyData;

    // Aggregate by period (week_start or report_month) — deduplicate across
    // multiple rows for the same period (can occur with dept scoping).
    final Map<String, Map<String, dynamic>> byPeriod = {};
    for (final r in source) {
      final key = (_velocityWeekly
              ? r['week_start']?.toString()
              : r['report_month']?.toString()) ??
          '';
      if (key.isEmpty) continue;
      if (!byPeriod.containsKey(key)) {
        byPeriod[key] = {'_key': key, 'total': 0, 'closed': 0, ...r};
      }
      byPeriod[key]!['total']  = (byPeriod[key]!['total']  as int) +
          ((r['total_tasks']  as num?)?.toInt() ?? (r['total_requests'] as num?)?.toInt() ?? 0);
      byPeriod[key]!['closed'] = (byPeriod[key]!['closed'] as int) +
          ((r['closed_tasks'] as num?)?.toInt() ?? (r['closed_requests'] as num?)?.toInt() ?? 0);
    }

    // Sort descending (latest first) and take the last 6 periods.
    final periods = byPeriod.values.toList()
      ..sort((a, b) => b['_key'].toString().compareTo(a['_key'].toString()));
    final displayPeriods = periods.take(6).toList().reversed.toList();

    final maxTotal = displayPeriods.fold<int>(
        0, (m, r) => (r['total'] as int) > m ? (r['total'] as int) : m);

    final scopeLabel = _selectedDept != null ? _selectedDept! : 'Enterprise';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
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
            // ── Header ────────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: _buildSectionHeader(
                      title: '$scopeLabel Velocity',
                      icon: Icons.trending_up_rounded,
                      iconColor: AppColors.primary,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Weekly / Monthly toggle
                      _buildTogglePill('Weekly', _velocityWeekly, () {
                        setState(() => _velocityWeekly = true);
                      }),
                      const SizedBox(width: 6),
                      _buildTogglePill('Monthly', !_velocityWeekly, () {
                        setState(() => _velocityWeekly = false);
                      }),
                      const SizedBox(width: 8),
                      _buildCollapseToggle(_isVelocityExpanded,
                          () => setState(() => _isVelocityExpanded = !_isVelocityExpanded)),
                    ],
                  ),
                ],
              ),
            ),
            // ── Body ──────────────────────────────────────────────────────────
            if (_isVelocityExpanded) ...[
              const SizedBox(height: 12),
              if (displayPeriods.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Text('No trend data for this period.',
                      style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    children: displayPeriods.map((row) {
                      final total  = row['total']  as int;
                      final closed = row['closed'] as int;
                      final pct    = total > 0 ? (closed / total * 100) : 0.0;
                      final barFraction = maxTotal > 0 ? (total / maxTotal) : 0.0;
                      final closedFraction = total > 0 ? (closed / total) : 0.0;
                      final label = _velocityWeekly
                          ? _formatWeekLabel(row)
                          : (row['_key']?.toString() ?? '');
                      final color = _closureColor(pct);

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                SizedBox(
                                  width: 80,
                                  child: Text(label,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.textSecondary)),
                                ),
                                Expanded(
                                  child: LayoutBuilder(
                                    builder: (ctx, constraints) {
                                      final fullWidth = constraints.maxWidth;
                                      return Stack(
                                        children: [
                                          // Background (total)
                                          Container(
                                            height: 18,
                                            width: fullWidth * barFraction,
                                            decoration: BoxDecoration(
                                              color: AppColors.primaryLight,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                          ),
                                          // Foreground (closed)
                                          Container(
                                            height: 18,
                                            width: fullWidth * barFraction * closedFraction,
                                            decoration: BoxDecoration(
                                              color: color.withValues(alpha: 0.85),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Closure badge
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.10),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '${pct.toStringAsFixed(0)}%',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: color,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '$closed/$total',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              // Legend
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Row(
                  children: [
                    _buildLegendDot(AppColors.primaryLight, 'Total Tasks'),
                    const SizedBox(width: 12),
                    _buildLegendDot(AppColors.success.withValues(alpha: 0.85), 'Closed'),
                    const SizedBox(width: 12),
                    _buildLegendDot(AppColors.warning.withValues(alpha: 0.85), '70–84%'),
                    const SizedBox(width: 12),
                    _buildLegendDot(AppColors.error.withValues(alpha: 0.85), '<70%'),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTogglePill(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? AppColors.primary : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: active ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildLegendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 9.5, color: AppColors.textSecondary)),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 2. F&B ORDER ANALYTICS SECTION (RS12/RS13 weekly/monthly food summary +
  //    RS14/RS15 per-staff food performance)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildFoodAnalyticsSection() {
    // Use weekly data (most operationally relevant); pick the most recent week.
    final foodRows = _weeklyFood.isNotEmpty ? _weeklyFood : _monthlyFood;
    final staffRows = _weeklyFoodUsers.isNotEmpty ? _weeklyFoodUsers : _monthlyFoodUsers;

    // Aggregate across rows (there may be multiple rows per period for different depts).
    int totalOrders  = 0;
    double totalRevenue   = 0.0;
    double totalAcceptMin = 0.0;
    int acceptCount  = 0;

    // Take the most recent period's rows.
    String? latestPeriod;
    for (final r in foodRows) {
      final periodKey = r['week_start']?.toString() ?? r['report_month']?.toString() ?? '';
      if (latestPeriod == null || periodKey.compareTo(latestPeriod) > 0) {
        latestPeriod = periodKey;
      }
    }
    final latestRows = latestPeriod == null ? foodRows : foodRows.where((r) {
      final pk = r['week_start']?.toString() ?? r['report_month']?.toString() ?? '';
      return pk == latestPeriod;
    }).toList();

    for (final r in latestRows) {
      totalOrders  += (r['total_orders'] as num?)?.toInt() ?? 0;
      totalRevenue += (r['total_revenue'] as num?)?.toDouble() ?? 0.0;
      final acceptM = (r['avg_accept_time_minutes'] as num?)?.toDouble() ??
                      (r['avg_acceptance_time'] as num?)?.toDouble() ?? 0.0;
      if (acceptM > 0) { totalAcceptMin += acceptM; acceptCount++; }
    }

    final avgAcceptMins = acceptCount > 0 ? (totalAcceptMin / acceptCount) : 0.0;

    // Top 3 food staff sorted by total orders descending.
    final sortedStaff = [...staffRows]
      ..sort((a, b) => ((b['total_orders'] as num?)?.toInt() ?? 0)
          .compareTo((a['total_orders'] as num?)?.toInt() ?? 0));
    final topStaff = sortedStaff.take(3).toList();

    final periodLabel = latestPeriod != null
        ? (_weeklyFood.isNotEmpty ? _formatWeekLabel({'week_start': latestPeriod, 'week_end': ''}) : latestPeriod)
        : 'Latest';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.borderLight),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 3)),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            _buildSectionHeader(
              title: 'F&B Operations',
              icon: Icons.restaurant_menu_rounded,
              iconColor: const Color(0xFFF59E0B),
              trailing: Container(
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
            ),
            const SizedBox(height: 14),
            // KPI Row: Orders | Revenue | Avg Accept Time
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
                  label: 'Revenue',
                  value: _fmtRevenue(totalRevenue),
                  icon: Icons.currency_rupee_rounded,
                  color: AppColors.success,
                ),
                const SizedBox(width: 10),
                _buildFoodKpi(
                  label: 'Avg Accept',
                  value: _fmtMins(avgAcceptMins),
                  icon: Icons.timer_outlined,
                  color: const Color(0xFFF59E0B),
                ),
              ],
            ),
            // Staff leaderboard
            if (topStaff.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text(
                'TOP RUNNERS THIS WEEK',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              ...topStaff.asMap().entries.map((e) {
                final idx  = e.key;
                final s    = e.value;
                final name = s['full_name']?.toString() ?? s['name']?.toString() ?? '—';
                final orders = (s['total_orders'] as num?)?.toInt() ?? 0;
                final acceptM = (s['avg_accept_time_minutes'] as num?)?.toDouble() ??
                                (s['avg_acceptance_time'] as num?)?.toDouble() ?? 0.0;
                final rankIcons = ['🥇', '🥈', '🥉'];

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Text(rankIcons[idx], style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '$orders orders',
                        style: const TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w700),
                      ),
                      if (acceptM > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.successLight,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _fmtMins(acceptM),
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.success),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }),
            ],
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

  // ═══════════════════════════════════════════════════════════════════════════
  // 3. OCCUPANCY vs. WORKLOAD CORRELATION SECTION (RS16 weekly + RS4 overlay)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildOccupancyCorrelationSection() {
    // Take the last 4 weeks of guest data, sorted ascending for display.
    final sorted = [..._weeklyGuests]
      ..sort((a, b) => (a['week_start']?.toString() ?? '').compareTo(b['week_start']?.toString() ?? ''));
    final weeks = sorted.take(4).toList();

    if (weeks.isEmpty) return const SizedBox.shrink();

    // Compute max values for bar scaling
    int maxCheckIn  = 1;
    int maxRequests = 1;
    for (final w in weeks) {
      final ci  = (w['total_checkins']  as num?)?.toInt() ?? (w['checkin_count'] as num?)?.toInt() ?? 0;
      final req = (w['total_requests'] as num?)?.toInt() ?? (w['service_requests'] as num?)?.toInt() ?? 0;
      if (ci  > maxCheckIn)  maxCheckIn  = ci;
      if (req > maxRequests) maxRequests = req;
    }

    // Derive an insight from the most recent week's trend.
    String insightText = '';
    if (weeks.length >= 2) {
      final latest = weeks.last;
      final prev   = weeks[weeks.length - 2];
      final latestReq = (latest['total_requests'] as num?)?.toInt() ?? (latest['service_requests'] as num?)?.toInt() ?? 0;
      final prevReq   = (prev['total_requests']   as num?)?.toInt() ?? (prev['service_requests']   as num?)?.toInt() ?? 0;
      final latestCI  = (latest['total_checkins'] as num?)?.toInt() ?? (latest['checkin_count']  as num?)?.toInt() ?? 0;
      if (prevReq > 0) {
        final pctChange = ((latestReq - prevReq) / prevReq * 100).round();
        if (pctChange > 15) {
          insightText = 'Service demand up $pctChange% vs last week ($latestCI check-ins). Consider +1–2 Housekeeping associates on peak shifts.';
        } else if (pctChange < -15) {
          insightText = 'Lighter load expected (service demand down ${pctChange.abs()}%). Good window for preventive maintenance.';
        } else {
          insightText = 'Service load steady (${pctChange >= 0 ? '+' : ''}$pctChange% vs last week). Maintain current staffing levels.';
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.borderLight),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 3)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildSectionHeader(
                    title: 'Occupancy & Workload',
                    icon: Icons.hotel_rounded,
                    iconColor: const Color(0xFF6366F1),
                  ),
                  _buildCollapseToggle(_isOccupancyExpanded,
                      () => setState(() => _isOccupancyExpanded = !_isOccupancyExpanded)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // Summary row: most recent week
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: _buildOccupancyQuickStat(weeks.last),
            ),
            if (_isOccupancyExpanded) ...[
              const SizedBox(height: 12),
              // Week-by-week comparison table
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Column(
                  children: [
                    // Column headers
                    Row(
                      children: const [
                        SizedBox(width: 80, child: Text('Week', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.textSecondary))),
                        Expanded(child: Text('Check-ins', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.textSecondary))),
                        Expanded(child: Text('Check-outs', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.textSecondary))),
                        SizedBox(width: 56, child: Text('Requests', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.textSecondary), textAlign: TextAlign.right)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ...weeks.reversed.map((w) {
                      final label = _formatWeekLabel(w);
                      final ci  = (w['total_checkins']  as num?)?.toInt() ?? (w['checkin_count'] as num?)?.toInt() ?? 0;
                      final co  = (w['total_checkouts'] as num?)?.toInt() ?? (w['checkout_count'] as num?)?.toInt() ?? 0;
                      final req = (w['total_requests'] as num?)?.toInt() ?? (w['service_requests'] as num?)?.toInt() ?? 0;
                      final isLatest = w == weeks.last;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: isLatest ? const Color(0xFF6366F1).withValues(alpha: 0.05) : AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(10),
                          border: isLatest ? Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.2)) : null,
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 80,
                              child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                            ),
                            Expanded(child: Text('$ci', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary))),
                            Expanded(child: Text('$co', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                            SizedBox(
                              width: 56,
                              child: Text(
                                '$req',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: req > 0 ? AppColors.primary : AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
            // Insight banner
            if (insightText.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.18)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('💡', style: TextStyle(fontSize: 16)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        insightText,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF4F46E5),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else
              const SizedBox(height: 14),
          ],
        ),
      ),
    );
  }

  Widget _buildOccupancyQuickStat(Map<String, dynamic> week) {
    final ci  = (week['total_checkins']  as num?)?.toInt() ?? (week['checkin_count'] as num?)?.toInt() ?? 0;
    final co  = (week['total_checkouts'] as num?)?.toInt() ?? (week['checkout_count'] as num?)?.toInt() ?? 0;
    final req = (week['total_requests'] as num?)?.toInt() ?? (week['service_requests'] as num?)?.toInt() ?? 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF6366F1).withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildOccupancyStat('Check-ins', '$ci', Icons.login_rounded, AppColors.success),
          Container(width: 1, height: 32, color: AppColors.borderLight),
          _buildOccupancyStat('Check-outs', '$co', Icons.logout_rounded, AppColors.warning),
          Container(width: 1, height: 32, color: AppColors.borderLight),
          _buildOccupancyStat('Requests', '$req', Icons.room_service_rounded, AppColors.primary),
        ],
      ),
    );
  }

  Widget _buildOccupancyStat(String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color)),
        Text(label, style: const TextStyle(fontSize: 9.5, color: AppColors.textSecondary, fontWeight: FontWeight.w500)),
      ],
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Month Picker Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _MonthPickerSheet extends StatefulWidget {
  final int initialMonth;
  final int initialYear;
  final int maxYear;
  final ValueChanged<int> onMonthSelected;
  final ValueChanged<int> onYearChanged;

  const _MonthPickerSheet({
    required this.initialMonth,
    required this.initialYear,
    required this.maxYear,
    required this.onMonthSelected,
    required this.onYearChanged,
  });

  @override
  State<_MonthPickerSheet> createState() => _MonthPickerSheetState();
}

class _MonthPickerSheetState extends State<_MonthPickerSheet> {
  late int _year;
  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  void initState() {
    super.initState();
    _year = widget.initialYear;
  }

  @override
  Widget build(BuildContext context) {
    final now           = DateTime.now();
    final isCurrentYear = _year == now.year;
    final selectedMonth = (widget.initialYear == _year)
        ? widget.initialMonth
        : -1;

    return Container(
      decoration: const BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        top:    8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                  onPressed: _year > now.year - 3
                      ? () => setState(() {
                            _year--;
                            widget.onYearChanged(_year);
                          })
                      : null,
                ),
                Text('$_year',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary)),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios_rounded, size: 18),
                  onPressed: _year < widget.maxYear
                      ? () => setState(() {
                            _year++;
                            widget.onYearChanged(_year);
                          })
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.builder(
              shrinkWrap: true,
              physics:    const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:   3,
                childAspectRatio: 2.5,
                crossAxisSpacing: 8,
                mainAxisSpacing:  8,
              ),
              itemCount: 12,
              itemBuilder: (_, index) {
                final month      = index + 1;
                final isSelected = month == selectedMonth;
                final isDisabled = isCurrentYear && month > now.month;
                return GestureDetector(
                  onTap: isDisabled ? null : () => widget.onMonthSelected(month),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primary
                          : isDisabled
                              ? AppColors.surfaceAlt
                              : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected
                            ? AppColors.primary
                            : isDisabled
                                ? AppColors.borderLight
                                : AppColors.border,
                        width: 1.5,
                      ),
                    ),
                    child: Text(
                      _monthNames[index],
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                        color: isDisabled
                            ? AppColors.textDisabled
                            : isSelected
                                ? Colors.white
                                : AppColors.textPrimary,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Department Filter Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _DeptFilterSheet extends StatelessWidget {
  final String?        selectedDept;
  final List<String>   departments;
  final bool           showAllOption;
  final ValueChanged<String?> onSelected;

  const _DeptFilterSheet({
    required this.selectedDept,
    required this.departments,
    required this.showAllOption,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 16),
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Select Department',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary)),
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding:    const EdgeInsets.symmetric(horizontal: 16),
              children: [
                if (showAllOption)
                  _DeptOptionTile(
                    label:      'All Departments',
                    value:      null,
                    isSelected: selectedDept == null,
                    onTap:      () => onSelected(null),
                  ),
                ...departments.map((dept) => _DeptOptionTile(
                      label:      dept,
                      value:      dept,
                      isSelected: dept == selectedDept,
                      onTap:      () => onSelected(dept),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeptOptionTile extends StatelessWidget {
  final String    label;
  final String?   value;
  final bool      isSelected;
  final VoidCallback onTap;

  const _DeptOptionTile({
    required this.label,
    required this.value,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap:        onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: isSelected ? AppColors.primary : AppColors.textSecondary,
              size:  20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 15,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                      color: AppColors.textPrimary)),
            ),
            if (isSelected)
              const Icon(Icons.check_rounded, color: AppColors.primary, size: 18),
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
  final bool     highlight;
  // Which status filter to apply when this card is tapped.
  // null = not tappable (Total Tasks card for management).
  final String?  filterStatus;

  const _StatCardData({
    required this.count,
    required this.label,
    required this.icon,
    required this.accentColor,
    this.highlight    = false,
    this.filterStatus,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Staff Drill-Down Page
// ─────────────────────────────────────────────────────────────────────────────

class _StaffDrillDownPage extends StatefulWidget {
  final int    userId;
  final String userName;
  final String deptName;
  final int    month;
  final int    year;
  final String userRole;

  const _StaffDrillDownPage({
    required this.userId,
    required this.userName,
    required this.deptName,
    required this.month,
    required this.year,
    required this.userRole,
  });

  @override
  State<_StaffDrillDownPage> createState() => _StaffDrillDownPageState();
}

class _StaffDrillDownPageState extends State<_StaffDrillDownPage> {
  final HomeService _homeService = HomeService();
  final TaskService _taskService = TaskService();

  bool                       _isLoading           = true;
  List<Map<String, dynamic>> _monthlyUserRows     = [];
  List<Map<String, dynamic>> _weeklyUserRows      = [];
  List<Map<String, dynamic>> _monthlyDepts        = [];
  List<Map<String, dynamic>> _allTasks            = [];
  List<String>               _departments         = [];
  String                     _selectedDept        = 'All';
  String?                    _selectedWeekStart;
  String?                    _selectedWeekEnd;
  String                     _statusFilter        = 'All';
  String                     _searchQuery         = '';
  final TextEditingController _searchController   = TextEditingController();

  static const _monthNames = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);

    final result = await _homeService.getOperationsPerformance(
      targetUserId: widget.userId,
      month:        widget.month,
      year:         widget.year,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      final team       = (result['team'] as List? ?? []).cast<Map<String, dynamic>>();
      final weeklyList = (result['weeklyUsers'] as List? ?? []).cast<Map<String, dynamic>>();
      final mDepts     = (result['monthlyDepartments'] as List? ?? []).cast<Map<String, dynamic>>();

      final deptsSet = <String>{};
      for (final r in team) {
        final d = (r['department_name'] ?? '').toString().trim();
        if (d.isNotEmpty) deptsSet.add(d);
      }

      final deptList = deptsSet.toList()..sort();
      if (deptList.length > 1) {
        deptList.insert(0, 'All');
      }

      String initialDept = 'All';
      if (widget.deptName.isNotEmpty && deptList.contains(widget.deptName)) {
        initialDept = widget.deptName;
      } else if (deptList.isNotEmpty) {
        initialDept = deptList.first;
      }

      // Fetch task tickets assigned to or handled by this user
      List<Map<String, dynamic>> taskList = [];
      final tasksResult = await _homeService.getTasks();
      if (tasksResult['success'] == true) {
        final all = (tasksResult['tasks'] as List? ?? []).cast<Map<String, dynamic>>();
        taskList = all.where((t) {
          final raw = t['raw'] as Map? ?? t;
          final assignedId = (raw['assigned_to'] ?? raw['assigned_user_id'])?.toString();
          final acceptedId = raw['accepted_by_user_id']?.toString();
          final closedId   = raw['closed_by_user_id']?.toString();
          final targetStr  = widget.userId.toString();
          return assignedId == targetStr || acceptedId == targetStr || closedId == targetStr;
        }).toList();
      }

      setState(() {
        _monthlyUserRows = team;
        _weeklyUserRows  = weeklyList;
        _monthlyDepts    = mDepts;
        _departments     = deptList;
        _selectedDept    = initialDept;
        _allTasks        = taskList;
        _isLoading       = false;
      });
    } else {
      setState(() => _isLoading = false);
    }
  }

  // ── Metrics Helper ────────────────────────────────────────────────────────
  Map<String, dynamic> _computeCurrentMetrics() {
    int totalAssigned = 0;
    int totalClosed = 0;
    int inProgress = 0;
    int open = 0;
    int overdue = 0;
    int escalated = 0;
    double weightedMins = 0.0;
    int closedWithMins = 0;

    final targetRows = _selectedDept == 'All'
        ? _monthlyUserRows
        : _monthlyUserRows.where((r) => (r['department_name'] ?? '').toString() == _selectedDept);

    for (final r in targetRows) {
      final a = (r['total_assigned'] as num?)?.toInt() ?? 0;
      final c = (r['total_closed']   as num?)?.toInt() ?? 0;
      final p = (r['in_progress_tasks'] as num?)?.toInt() ?? 0;
      final o = (r['open_tasks'] as num?)?.toInt() ?? 0;
      final ov = (r['overdue_tasks'] as num?)?.toInt() ?? 0;
      final e = (r['total_escalated'] as num?)?.toInt() ?? 0;
      final m = (r['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;

      totalAssigned += a;
      totalClosed   += c;
      inProgress    += p;
      open          += o;
      overdue       += ov;
      escalated     += e;
      if (c > 0 && m > 0) {
        weightedMins += (m * c);
        closedWithMins += c;
      }
    }

    final avgMins = closedWithMins > 0 ? (weightedMins / closedWithMins) : 0.0;
    final escRate = totalAssigned > 0 ? (escalated / totalAssigned * 100) : 0.0;

    // Dept Benchmark average resolution time
    double deptAvgMins = 0.0;
    if (_monthlyDepts.isNotEmpty) {
      if (_selectedDept != 'All') {
        final dMatch = _monthlyDepts.firstWhere(
          (d) => (d['department_name'] ?? '').toString() == _selectedDept,
          orElse: () => <String, dynamic>{},
        );
        deptAvgMins = (dMatch['average_time_taken'] ?? dMatch['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
      } else {
        double dTotalM = 0;
        int dCount = 0;
        for (final d in _monthlyDepts) {
          final dm = (d['average_time_taken'] ?? d['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
          if (dm > 0) {
            dTotalM += dm;
            dCount++;
          }
        }
        deptAvgMins = dCount > 0 ? (dTotalM / dCount) : 0.0;
      }
    }

    return {
      'totalAssigned': totalAssigned,
      'totalClosed':   totalClosed,
      'inProgress':    inProgress,
      'open':          open,
      'overdue':       overdue,
      'escalated':     escalated,
      'avgMins':       avgMins,
      'escRate':       escRate,
      'deptAvgMins':   deptAvgMins,
    };
  }

  String _fmtDate(String? ts) {
    if (ts == null || ts.isEmpty) return '—';
    try {
      String s = ts.trim();
      if (s.contains(' ') && !s.contains('T')) {
        s = s.replaceFirst(' ', 'T');
      }
      final d = DateTime.parse(s).toLocal();
      return '${d.day.toString().padLeft(2, '0')}/'
          '${d.month.toString().padLeft(2, '0')}/${d.year}';
    } catch (_) {
      return ts;
    }
  }

  // ── Quick Reassign Dialog ──────────────────────────────────────────────────
  Future<void> _showQuickReassignDialog(Map<String, dynamic> task) async {
    final raw = task['raw'] as Map? ?? task;
    final int? requestId = raw['service_request_id'] is num
        ? (raw['service_request_id'] as num).toInt()
        : int.tryParse(raw['service_request_id']?.toString() ?? '');

    if (requestId == null || requestId == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid service request ID')),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final staffRes = await _homeService.getStaffList(requestId: requestId);
    if (!mounted) return;
    Navigator.pop(context); // Close loading indicator

    if (staffRes['success'] != true || staffRes['staff'] == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(staffRes['message']?.toString() ?? 'Failed to load staff list')),
      );
      return;
    }

    final staffList = (staffRes['staff'] as List).cast<Map<String, dynamic>>();

    if (staffList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No available staff in this department to reassign to.')),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.swap_horiz_rounded, color: AppColors.primary, size: 22),
                const SizedBox(width: 8),
                const Text(
                  'Reassign Task',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  'SR #$requestId',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Select a staff member to take over this service request:',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.45,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: staffList.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.borderLight),
                itemBuilder: (context, i) {
                  final staff = staffList[i];
                  final sName = staff['full_name'] ?? staff['name'] ?? 'Staff Member';
                  final sRole = staff['role_name'] ?? staff['role'] ?? 'Staff';
                  final int sId = (staff['user_id'] as num?)?.toInt() ?? 0;
                  final isCurrent = sId == widget.userId;

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    leading: CircleAvatar(
                      backgroundColor: isCurrent ? AppColors.errorLight : AppColors.primaryLight,
                      child: Text(
                        (sName.toString().isNotEmpty ? sName[0].toUpperCase() : '?'),
                        style: TextStyle(
                          color: isCurrent ? AppColors.error : AppColors.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    title: Text(
                      sName.toString(),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                    subtitle: Text(
                      isCurrent ? '$sRole (Current Assignee)' : sRole.toString(),
                      style: TextStyle(
                        fontSize: 12,
                        color: isCurrent ? AppColors.error : AppColors.textSecondary,
                      ),
                    ),
                    trailing: isCurrent
                        ? null
                        : const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.primary),
                    onTap: isCurrent
                        ? null
                        : () async {
                            Navigator.pop(ctx);
                            final reassignRes = await _taskService.reassignService(
                              taskId: requestId,
                              reassignTo: sId,
                            );
                            if (!mounted) return;
                            if (reassignRes['success'] == true) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: AppColors.success,
                                  content: Text('Task successfully reassigned to $sName!'),
                                ),
                              );
                              _load();
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: AppColors.error,
                                  content: Text(reassignRes['message'] ?? 'Failed to reassign task'),
                                ),
                              );
                            }
                          },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Quick Note Dialog ──────────────────────────────────────────────────────
  Future<void> _showQuickNoteDialog(Map<String, dynamic> task) async {
    final raw = task['raw'] as Map? ?? task;
    final int? requestId = raw['service_request_id'] is num
        ? (raw['service_request_id'] as num).toInt()
        : int.tryParse(raw['service_request_id']?.toString() ?? '');

    if (requestId == null || requestId == 0) return;

    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.edit_note_rounded, color: AppColors.primary),
            SizedBox(width: 8),
            Text('Add Note', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ],
        ),
        content: TextField(
          controller: controller,
          maxLines: 3,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Enter observation or progress update...',
            hintStyle: const TextStyle(fontSize: 13, color: AppColors.textDisabled),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(ctx);

              final res = await _homeService.addNote(
                serviceRequestId: requestId,
                noteText: text,
              );
              if (!mounted) return;

              if (res['success'] == true) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    backgroundColor: AppColors.success,
                    content: Text('Note added successfully!'),
                  ),
                );
                _load();
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: AppColors.error,
                    content: Text(res['message'] ?? 'Failed to add note'),
                  ),
                );
              }
            },
            child: const Text('Save Note'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final month = _monthNames[widget.month];
    final metrics = _computeCurrentMetrics();

    return Scaffold(
      backgroundColor: AppColors.bgLight,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.userName, style: AppTypography.appBarTitle),
            Text('${widget.deptName} · $month ${widget.year}', style: AppTypography.appBarSubtitle),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: AppColors.primary),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. Profile Header & Department Filter
                    _buildProfileHeaderCard(),
                    const SizedBox(height: 14),

                    // 2. Department Selector Bar (if multi-department)
                    if (_departments.length > 1) ...[
                      _buildDepartmentScopeSelector(),
                      const SizedBox(height: 14),
                    ],

                    // 3. 6-KPI Performance Grid with Benchmarks
                    _buildPerformanceKpiGrid(metrics),
                    const SizedBox(height: 16),

                    // 4. Weekly Breakdown Chart (Interactive)
                    if (_weeklyUserRows.isNotEmpty) ...[
                      _buildWeeklyBreakdownSection(),
                      const SizedBox(height: 16),
                    ],

                    // 5. Filterable Task List with Instant Search
                    _buildTaskListSection(),
                  ],
                ),
              ),
            ),
    );
  }

  // ── 1. Profile Header ──────────────────────────────────────────────────────
  Widget _buildProfileHeaderCard() {
    final initials = widget.userName
        .trim()
        .split(' ')
        .where((s) => s.isNotEmpty)
        .take(2)
        .map((s) => s[0].toUpperCase())
        .join();

    String userRoleTitle = widget.userRole.isNotEmpty ? widget.userRole : 'Staff';
    if (_monthlyUserRows.isNotEmpty) {
      final r = _monthlyUserRows.first;
      final dynamicRole = (r['role_name'] ?? '').toString();
      if (dynamicRole.isNotEmpty) userRoleTitle = dynamicRole;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.borderLight),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          // Avatar
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF052D50), Color(0xFF1A5A90)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              initials.isNotEmpty ? initials : '?',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
          ),
          const SizedBox(width: 14),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.userName,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        userRoleTitle,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Live Status Pill
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: AppColors.success,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.success.withValues(alpha: 0.4),
                                blurRadius: 4,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'Active Now',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.success,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 2. Department Scope Selector ───────────────────────────────────────────
  Widget _buildDepartmentScopeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            'DEPARTMENT SCOPE',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: _departments.map((dept) {
              final isSelected = _selectedDept == dept;

              // Task count for this dept
              int count = 0;
              if (dept == 'All') {
                for (final r in _monthlyUserRows) {
                  count += (r['total_assigned'] as num?)?.toInt() ?? 0;
                }
              } else {
                final match = _monthlyUserRows.firstWhere(
                  (r) => (r['department_name'] ?? '').toString() == dept,
                  orElse: () => <String, dynamic>{},
                );
                count = (match['total_assigned'] as num?)?.toInt() ?? 0;
              }

              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() => _selectedDept = dept),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? AppColors.primary : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected ? AppColors.primary : AppColors.border,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isSelected ? 0.1 : 0.03),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          dept == 'All' ? Icons.dashboard_outlined : Icons.business_outlined,
                          size: 14,
                          color: isSelected ? Colors.white : AppColors.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          dept,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                            color: isSelected ? Colors.white : AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.white.withValues(alpha: 0.2)
                                : AppColors.primaryLight,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$count',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: isSelected ? Colors.white : AppColors.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // ── 3. 6-KPI Performance Grid with Benchmarks ─────────────────────────────
  Widget _buildPerformanceKpiGrid(Map<String, dynamic> m) {
    final int total = m['totalAssigned'] as int;
    final int closed = m['totalClosed'] as int;
    final int inProg = m['inProgress'] as int;
    final int open = m['open'] as int;
    final int overdue = m['overdue'] as int;
    final double avgM = m['avgMins'] as double;
    final double deptAvg = m['deptAvgMins'] as double;

    final closurePct = total > 0 ? (closed / total * 100).toStringAsFixed(0) : '0';
    final avgStr = avgM <= 0
        ? '—'
        : avgM < 60
            ? '${avgM.toStringAsFixed(0)} min'
            : '${(avgM / 60).toStringAsFixed(1)} hrs';

    // Benchmark comparison
    String? benchmarkText;
    Color? benchmarkColor;
    if (avgM > 0 && deptAvg > 0) {
      final delta = avgM - deptAvg;
      if (delta <= 0) {
        benchmarkText = '📉 ${( -delta ).toStringAsFixed(0)}m vs Dept Avg (${deptAvg.toStringAsFixed(0)}m)';
        benchmarkColor = AppColors.success;
      } else {
        benchmarkText = '📈 +${delta.toStringAsFixed(0)}m vs Dept Avg (${deptAvg.toStringAsFixed(0)}m)';
        benchmarkColor = AppColors.warning;
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.borderLight),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.analytics_outlined, color: AppColors.primary, size: 18),
              SizedBox(width: 6),
              Text(
                'PERFORMANCE KPIS & BENCHMARK',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 3x2 Grid
          GridView.count(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.15,
            children: [
              // 1. Total
              _buildKpiTile(
                label: 'Assigned',
                value: '$total',
                icon: Icons.assignment_outlined,
                color: AppColors.primary,
                subtext: 'Total load',
              ),
              // 2. Closed
              _buildKpiTile(
                label: 'Closed',
                value: '$closed',
                icon: Icons.check_circle_outline,
                color: AppColors.success,
                subtext: '$closurePct% rate',
              ),
              // 3. In Progress
              _buildKpiTile(
                label: 'In Progress',
                value: '$inProg',
                icon: Icons.timelapse_outlined,
                color: AppColors.orange,
                subtext: 'Active tasks',
              ),
              // 4. Open
              _buildKpiTile(
                label: 'Open',
                value: '$open',
                icon: Icons.markunread_mailbox_outlined,
                color: AppColors.info,
                subtext: 'Pending start',
              ),
              // 5. Overdue
              _buildKpiTile(
                label: 'Overdue',
                value: '$overdue',
                icon: Icons.warning_amber_rounded,
                color: overdue > 0 ? AppColors.error : AppColors.success,
                subtext: overdue > 0 ? 'SLA breach' : '0 Breaches ✅',
                highlight: overdue > 0,
              ),
              // 6. Avg Time
              _buildKpiTile(
                label: 'Avg Time',
                value: avgStr,
                icon: Icons.timer_outlined,
                color: const Color(0xFF6366F1),
                subtext: 'Turnaround',
              ),
            ],
          ),
          if (benchmarkText != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: benchmarkColor!.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.compare_arrows_rounded, size: 14, color: benchmarkColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      benchmarkText,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: benchmarkColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildKpiTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    required String subtext,
    bool highlight = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: highlight ? AppColors.errorLight : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: highlight ? AppColors.error.withValues(alpha: 0.3) : AppColors.borderLight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary.withValues(alpha: 0.9),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: color,
              height: 1.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            subtext,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w500,
              color: color.withValues(alpha: 0.8),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ── 4. Weekly Breakdown Chart ──────────────────────────────────────────────
  Widget _buildWeeklyBreakdownSection() {
    final filteredWeeks = _selectedDept == 'All'
        ? _weeklyUserRows
        : _weeklyUserRows.where((r) => (r['department_name'] ?? '').toString() == _selectedDept).toList();

    if (filteredWeeks.isEmpty) return const SizedBox.shrink();

    // Deduplicate by week_start and filter out empty weeks
    final Map<String, Map<String, dynamic>> byWeek = {};
    for (final w in filteredWeeks) {
      final ws = (w['week_start'] ?? '').toString();
      if (ws.isEmpty) continue;
      if (!byWeek.containsKey(ws)) {
        byWeek[ws] = {
          'week_start': ws,
          'week_end':   w['week_end'] ?? '',
          'total':      0,
          'closed':     0,
          'inProg':     0,
          'open':       0,
        };
      }
      byWeek[ws]!['total']  = (byWeek[ws]!['total']  as int) + ((w['total_tasks'] as num?)?.toInt() ?? 0);
      byWeek[ws]!['closed'] = (byWeek[ws]!['closed'] as int) + ((w['closed_tasks'] as num?)?.toInt() ?? 0);
      byWeek[ws]!['inProg'] = (byWeek[ws]!['inProg'] as int) + ((w['in_progress_tasks'] as num?)?.toInt() ?? 0);
      byWeek[ws]!['open']   = (byWeek[ws]!['open']   as int) + ((w['open_tasks'] as num?)?.toInt() ?? 0);
    }

    // Only non-empty weeks (where total > 0)
    final activeWeeks = byWeek.values.where((w) => (w['total'] as int) > 0).toList();
    if (activeWeeks.isEmpty) return const SizedBox.shrink();

    // Sort descending to grab latest 4 weeks, then sort ascending for chart display
    activeWeeks.sort((a, b) => b['week_start'].toString().compareTo(a['week_start'].toString()));
    final weekList = activeWeeks.take(4).toList()
      ..sort((a, b) => a['week_start'].toString().compareTo(b['week_start'].toString()));

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.borderLight),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.bar_chart_rounded, color: AppColors.primary, size: 18),
                  SizedBox(width: 6),
                  Text(
                    'WEEKLY ACTIVITY TRENDS',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              if (_selectedWeekStart != null)
                GestureDetector(
                  onTap: () => setState(() {
                    _selectedWeekStart = null;
                    _selectedWeekEnd   = null;
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.errorLight,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.close_rounded, size: 12, color: AppColors.error),
                        SizedBox(width: 2),
                        Text(
                          'Clear Filter',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.error),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // Stacked Bars per week
          ...weekList.map((week) {
            final ws = week['week_start'].toString();
            final we = week['week_end'].toString();
            final total = week['total'] as int;
            final closed = week['closed'] as int;
            final inProg = week['inProg'] as int;
            final open = week['open'] as int;

            final isSelected = _selectedWeekStart == ws;

            final closedRatio = total > 0 ? (closed / total).clamp(0.0, 1.0) : 0.0;
            final inProgRatio = total > 0 ? (inProg / total).clamp(0.0, 1.0) : 0.0;
            final openRatio   = total > 0 ? (open / total).clamp(0.0, 1.0) : 0.0;

            final label = '${_fmtDate(ws)} – ${_fmtDate(we)}';

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  setState(() {
                    if (_selectedWeekStart == ws) {
                      _selectedWeekStart = null;
                      _selectedWeekEnd   = null;
                    } else {
                      _selectedWeekStart = ws;
                      _selectedWeekEnd   = we;
                    }
                  });
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.primary.withValues(alpha: 0.06) : AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected ? AppColors.primary : AppColors.borderLight,
                      width: isSelected ? 1.5 : 1.0,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                              color: isSelected ? AppColors.primary : AppColors.textPrimary,
                            ),
                          ),
                          Text(
                            '$total tasks ($closed closed)',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: isSelected ? AppColors.primary : AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Segmented Bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: SizedBox(
                          height: 8,
                          child: total == 0
                              ? Container(color: AppColors.borderLight)
                              : Row(
                                  children: [
                                    if (closedRatio > 0)
                                      Expanded(
                                        flex: (closedRatio * 100).toInt(),
                                        child: Container(color: AppColors.success),
                                      ),
                                    if (inProgRatio > 0)
                                      Expanded(
                                        flex: (inProgRatio * 100).toInt(),
                                        child: Container(color: AppColors.orange),
                                      ),
                                    if (openRatio > 0)
                                      Expanded(
                                        flex: (openRatio * 100).toInt(),
                                        child: Container(color: AppColors.info),
                                      ),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── 5. Filterable Task List with Instant Search ────────────────────────────
  Widget _buildTaskListSection() {
    // Filter tasks
    final filtered = _allTasks.where((task) {
      final raw = task['raw'] as Map? ?? task;

      // Status filter
      final isEsc = (task['is_escalated'] == 1 ||
          task['is_escalated'] == true ||
          task['task_flag'] == 'Escalated' ||
          task['escalation_instance_id'] != null ||
          task['escalation_status'] != null);
      final status = (task['task_flag'] ?? task['status'] ?? 'Open').toString();

      if (_statusFilter == 'Closed' && status != 'Closed') return false;
      if (_statusFilter == 'In Progress' && status != 'In Progress') return false;
      if (_statusFilter == 'Open' && (status != 'Open' && status != 'Pending')) return false;
      if (_statusFilter == 'Escalated' && !isEsc) return false;

      // Search filter
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final title = _resolveTitle(task).toLowerCase();
        final room = (task['room_number'] ?? task['room_id'] ?? task['room'] ?? '').toString().toLowerCase();
        final guest = (task['guest_name'] ?? '').toString().toLowerCase();
        final srId = (raw['service_request_id'] ?? '').toString().toLowerCase();

        if (!title.contains(q) && !room.contains(q) && !guest.contains(q) && !srId.contains(q)) {
          return false;
        }
      }

      // Week filter
      if (_selectedWeekStart != null) {
        final createdAtStr = (task['created_at'] ?? task['timestamp'] ?? '').toString();
        if (createdAtStr.isNotEmpty) {
          try {
            final taskDate = DateTime.parse(createdAtStr.replaceFirst(' ', 'T'));
            final start = DateTime.parse(_selectedWeekStart!);
            final end   = _selectedWeekEnd != null ? DateTime.parse(_selectedWeekEnd!).add(const Duration(days: 1)) : start.add(const Duration(days: 7));
            if (taskDate.isBefore(start) || taskDate.isAfter(end)) return false;
          } catch (_) {}
        }
      }

      return true;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.list_alt_rounded, color: AppColors.primary, size: 18),
                const SizedBox(width: 6),
                Text(
                  'TASKS & SERVICE REQUESTS (${filtered.length})',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Search Bar
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.borderLight),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              const Icon(Icons.search_rounded, size: 18, color: AppColors.textDisabled),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                  style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    hintText: 'Search room, task title, ID...',
                    hintStyle: TextStyle(fontSize: 12.5, color: AppColors.textDisabled),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              if (_searchQuery.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                  child: const Icon(Icons.close_rounded, size: 16, color: AppColors.textDisabled),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // Status Filter Chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: ['All', 'Closed', 'In Progress', 'Open', 'Escalated'].map((st) {
              final isSel = _statusFilter == st;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(st),
                  labelStyle: TextStyle(
                    fontSize: 11,
                    fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                    color: isSel ? Colors.white : AppColors.textSecondary,
                  ),
                  selected: isSel,
                  selectedColor: AppColors.primary,
                  backgroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  side: BorderSide(
                    color: isSel ? AppColors.primary : AppColors.borderLight,
                  ),
                  onSelected: (selected) {
                    if (selected) setState(() => _statusFilter = st);
                  },
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),

        // Task Cards
        if (filtered.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: const Column(
              children: [
                Icon(Icons.task_alt, size: 36, color: AppColors.textDisabled),
                SizedBox(height: 8),
                Text('No tasks match the active filters', style: AppTypography.bodySecondary),
              ],
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) => _buildEnhancedTaskCard(filtered[i]),
          ),
      ],
    );
  }

  // ── Enhanced Task Card with Inline Quick Actions ───────────────────────────
  Widget _buildEnhancedTaskCard(Map<String, dynamic> task) {
    final raw = task['raw'] as Map? ?? task;
    final isEsc = (task['is_escalated'] == 1 ||
        task['is_escalated'] == true ||
        task['task_flag'] == 'Escalated' ||
        task['escalation_instance_id'] != null ||
        task['escalation_status'] != null);
    final status = (task['task_flag'] ?? task['status'] ?? 'Open').toString();

    final rawRoom = (task['room_number'] ?? task['room_id'] ?? task['room'] ?? '—').toString();
    final room = (rawRoom == '0' || rawRoom == '000' || rawRoom == 'null' || rawRoom.isEmpty) ? 'General' : rawRoom;

    final rawTitle = _resolveTitle(task);
    final title = rawTitle.replaceFirst(RegExp(r'^Order\s+#[A-Z0-9]+\s*-\s*', caseSensitive: false), '');
    final created = _fmtDate((task['created_at'] ?? task['timestamp'] ?? '').toString());
    final stageName = (task['current_stage_name'] ?? task['stage_name'] ?? '').toString();
    final escLevel = task['escalation_level_reached'] ?? task['escalation_level'];

    final statusColor = isEsc ? AppColors.error : AppColors.statusColor(status);
    final canManage = _isSupervisorOrAboveByName(widget.userRole);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isEsc ? AppColors.error.withValues(alpha: 0.35) : AppColors.borderLight,
          width: isEsc ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Room, Title, Status
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isEsc ? AppColors.errorLight : AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  room,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: isEsc ? AppColors.error : AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          created,
                          style: const TextStyle(fontSize: 11, color: AppColors.textDisabled),
                        ),
                        if (stageName.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: AppColors.errorLight,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              stageName,
                              style: const TextStyle(
                                color: AppColors.error,
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ] else if (escLevel != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: AppColors.errorLight,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'L$escLevel',
                              style: const TextStyle(
                                color: AppColors.error,
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isEsc ? 'Escalated' : status,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),

          // Inline Note text if present
          if (task['note'] != null && task['note'].toString().isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.comment_outlined, size: 13, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      task['note'].toString(),
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Inline Quick Action Buttons for Managers
          if (canManage) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: AppColors.borderLight),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // 1. Reassign button
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _showQuickReassignDialog(task),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.swap_horiz_rounded, size: 14, color: AppColors.primary),
                        SizedBox(width: 4),
                        Text(
                          'Reassign',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 2. Add Note button
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _showQuickNoteDialog(task),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.borderLight),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_note_rounded, size: 14, color: AppColors.textSecondary),
                        SizedBox(width: 4),
                        Text(
                          'Add Note',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 3. View Full Ticket
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TicketDetailPage(
                          task:       task,
                          userRole:   widget.userRole,
                          onClose:    () => _load(),
                          onReassign: (_) => _load(),
                          onNoteAdded: (_) => _load(),
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'View',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(width: 2),
                        Icon(Icons.chevron_right_rounded, size: 14, color: Colors.white),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ExportReportBottomSheet extends StatefulWidget {
  final int userTierLevel;
  final String departmentName;
  final HomeService homeService;
  final String userRole;
  final String userName;
  final String enterpriseId;

  const _ExportReportBottomSheet({
    required this.userTierLevel,
    required this.departmentName,
    required this.homeService,
    required this.userRole,
    required this.userName,
    required this.enterpriseId,
  });

  @override
  _ExportReportBottomSheetState createState() => _ExportReportBottomSheetState();
}

class _ExportReportBottomSheetState extends State<_ExportReportBottomSheet> {
  String _selectedPeriod = '';
  DateTime? _startDate;
  DateTime? _endDate;
  bool _loading = false;
  List<dynamic>? _fetchedTasks;

  String _formatDateShort(DateTime? dt) {
    if (dt == null) return '';
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return "${dt.day} ${months[dt.month - 1]} ${dt.year}";
  }

  void _selectPeriod(String period) async {
    final now = DateTime.now();
    DateTime start;
    DateTime end;

    if (period == 'Today') {
      start = DateTime(now.year, now.month, now.day);
      end = DateTime(now.year, now.month, now.day, 23, 59, 59);
    } else if (period == 'This Week') {
      final weekday = now.weekday;
      final monday = now.subtract(Duration(days: weekday - 1));
      start = DateTime(monday.year, monday.month, monday.day);
      final sunday = monday.add(const Duration(days: 6));
      end = DateTime(sunday.year, sunday.month, sunday.day, 23, 59, 59);
    } else if (period == 'This Month') {
      start = DateTime(now.year, now.month, 1);
      final nextMonth = DateTime(now.year, now.month + 1, 1);
      end = nextMonth.subtract(const Duration(seconds: 1));
    } else if (period == 'This Quarter') {
      final quarterIndex = ((now.month - 1) / 3).floor();
      final qStartMonth = quarterIndex * 3 + 1;
      start = DateTime(now.year, qStartMonth, 1);
      final qEndMonth = qStartMonth + 3;
      final nextQuarter = DateTime(now.year, qEndMonth, 1);
      end = nextQuarter.subtract(const Duration(seconds: 1));
    } else {
      return;
    }

    setState(() {
      _selectedPeriod = period;
      _startDate = start;
      _endDate = end;
      _loading = true;
      _fetchedTasks = null;
    });

    final result = await widget.homeService.fetchTasksForRange(DateRange(start, end));
    if (!mounted) return;

    setState(() {
      _fetchedTasks = result['tasks'] ?? [];
      _loading = false;
    });
  }

  void _selectCustomRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              onSurface: Color(0xFF1E293B),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked == null) return;

    final start = DateTime(picked.start.year, picked.start.month, picked.start.day);
    final end = DateTime(picked.end.year, picked.end.month, picked.end.day, 23, 59, 59);

    setState(() {
      _selectedPeriod = 'Custom';
      _startDate = start;
      _endDate = end;
      _loading = true;
      _fetchedTasks = null;
    });

    final result = await widget.homeService.fetchTasksForRange(DateRange(start, end));
    if (!mounted) return;

    setState(() {
      _fetchedTasks = result['tasks'] ?? [];
      _loading = false;
    });
  }

  void _generateReport() async {
    if (_startDate == null || _endDate == null || _fetchedTasks == null) return;

    Navigator.pop(context);

    final startStr = "${_startDate!.year}-${_startDate!.month.toString().padLeft(2, '0')}-${_startDate!.day.toString().padLeft(2, '0')}";
    final endStr = "${_endDate!.year}-${_endDate!.month.toString().padLeft(2, '0')}-${_endDate!.day.toString().padLeft(2, '0')}";

    if (widget.userTierLevel >= 3) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(
          child: Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    color: Color(0xFF1976D2),
                    strokeWidth: 3,
                  ),
                  SizedBox(height: 18),
                  Text(
                    'Compiling your report...',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final result = await widget.homeService.generateExecutiveReport(
        startDate: startStr,
        endDate: endStr,
        templateId: 'exec_report_v1',
      );

      Navigator.of(context, rootNavigator: true).pop();

      if (result['success'] == true && result['presignedUrl'] != null) {
        final String presignedUrl = result['presignedUrl'];
        await Printing.layoutPdf(
          onLayout: (format) async {
            final res = await Dio().get<List<int>>(
              presignedUrl,
              options: Options(responseType: ResponseType.bytes),
            );
            return Uint8List.fromList(res.data!);
          },
          name: ReportPdfHelper.getReportFilename(
            enterpriseId: widget.enterpriseId,
            departmentName: widget.departmentName,
            roleLabel: widget.userRole,
            period: _selectedPeriod,
          ),
          dynamicLayout: false,
        );
        // Fallback or secondary launch
        try {
          await launchUrl(Uri.parse(presignedUrl), mode: LaunchMode.externalApplication);
        } catch (_) {}
      } else {
        // Fallback directly to client-side compiled PDF report
        await ReportPdfHelper.exportReport(
          context: context,
          tasks: _fetchedTasks!,
          userRole: widget.userRole,
          userName: widget.userName,
          monthYear: "${_formatDateShort(_startDate)} – ${_formatDateShort(_endDate)}",
          departmentName: widget.departmentName,
          userTierLevel: widget.userTierLevel,
          enterpriseId: widget.enterpriseId,
          periodLabel: _selectedPeriod,
        );
      }
    } else {
      await ReportPdfHelper.exportReport(
        context: context,
        tasks: _fetchedTasks!,
        userRole: widget.userRole,
        userName: widget.userName,
        monthYear: "${_formatDateShort(_startDate)} – ${_formatDateShort(_endDate)}",
        departmentName: widget.departmentName,
        userTierLevel: widget.userTierLevel,
        enterpriseId: widget.enterpriseId,
        periodLabel: _selectedPeriod,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final showMonth = widget.userTierLevel >= 2;
    final showQuarter = widget.userTierLevel >= 3;
    final showCustom = widget.userTierLevel >= 3;
    final hasPreview = _startDate != null && _endDate != null;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Export Report PDF',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E293B),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.grey),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Select the reporting timeframe. Options are automatically filtered by your authorization tier.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildPeriodChip('Today'),
              _buildPeriodChip('This Week'),
              if (showMonth) _buildPeriodChip('This Month'),
              if (showQuarter) _buildPeriodChip('This Quarter'),
              if (showCustom)
                ActionChip(
                  avatar: const Icon(Icons.date_range_outlined, size: 16, color: Color(0xFF1976D2)),
                  label: const Text('Custom Range'),
                  labelStyle: const TextStyle(color: Color(0xFF1976D2), fontWeight: FontWeight.w600, fontSize: 13),
                  backgroundColor: const Color(0xFFE3F2FD),
                  side: BorderSide.none,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                  onPressed: _selectCustomRange,
                ),
            ],
          ),
          const SizedBox(height: 24),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1976D2)),
                  ),
                  SizedBox(width: 12),
                  Text(
                    'Querying database metrics...',
                    style: TextStyle(fontSize: 13, color: Colors.grey, fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            )
          else if (hasPreview)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: const BorderRadius.all(Radius.circular(12)),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 18, color: Color(0xFF1976D2)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${widget.departmentName} · ${_formatDateShort(_startDate)} – ${_formatDateShort(_endDate)} · ${_fetchedTasks?.length ?? 0} tasks',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1E293B),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1976D2),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 48),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
              elevation: 0,
            ),
            onPressed: (_fetchedTasks != null && !_loading) ? _generateReport : null,
            child: const Text(
              'Generate & Export PDF',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeriodChip(String label) {
    final isSelected = _selectedPeriod == label;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => _selectPeriod(label),
      selectedColor: const Color(0xFF1976D2),
      labelStyle: TextStyle(color: isSelected ? Colors.white : const Color(0xFF475569), fontWeight: FontWeight.w600, fontSize: 13),
      backgroundColor: const Color(0xFFF1F5F9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      side: BorderSide.none,
      showCheckmark: false,
    );
  }
}
