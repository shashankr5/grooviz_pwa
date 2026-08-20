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
import '../services/profile_service.dart';
import '../services/task_alert_service.dart';
import '../utils/user_session_helper.dart';
import '../utils/report_pdf_helper.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:printing/printing.dart';
import 'dart:typed_data';
import 'package:dio/dio.dart';

import '../theme/app_typography.dart';
import '../theme/app_colors.dart';
import '../components/skeleton_loader.dart';
import 'ticket_details_page.dart';

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

  // ── Escalation stream ─────────────────────────────────────────────────────
  StreamSubscription<int>? _escSub;

  static const _monthNames = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _init();
    _escSub = TaskAlertService.onEscalation.listen((count) {
      if (mounted) setState(() => escalatedTasks = count);
    });
  }

  @override
  void dispose() {
    _escSub?.cancel();
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
      });
    } else {
      if (mounted) setState(() => _teamLoading = false);
    }
  }

  // ── Dept filter helpers ───────────────────────────────────────────────────

  List<Map<String, dynamic>> _applyDeptFilter(
      List<Map<String, dynamic>> rows) {
    if (_selectedDept == null) return rows;
    return rows.where((r) {
      return (r['department_name'] ?? '').toString() == _selectedDept;
    }).toList();
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
                    // ── Team list — Supervisor+ ──────────────────────────────
                    if (_isSupervisorOrAbove(_userRoleId)) ...[
                      _buildTeamSectionHeader(),
                      _buildTeamList(),
                    ],
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
    final showEscalated = escalatedTasks > 0 || _isManagementOnly(_userRoleId);

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
      if (showEscalated)
        _StatCardData(
          count:       '$escalatedTasks',
          label:       'Escalated',
          icon:        Icons.warning_amber_rounded,
          accentColor: AppColors.error,
          highlight:   escalatedTasks > 0,
          filterStatus: 'escalated',
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
                            Row(
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

  // ── Team List ─────────────────────────────────────────────────────────────

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
          decoration: BoxDecoration(color: Colors.white,
              borderRadius: BorderRadius.circular(16)),
          child: const Column(children: [
            Icon(Icons.people_outline, size: 36, color: AppColors.textDisabled),
            SizedBox(height: 8),
            Text('No team data for this period',
                style: AppTypography.bodySecondary),
          ]),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: _teamRows.asMap().entries.map((e) {
          return Padding(
            padding: EdgeInsets.only(bottom: e.key < _teamRows.length - 1 ? 8 : 0),
            child: _buildTeamRow(e.value),
          );
        }).toList(),
      ),
    );
  }


  Widget _buildTeamRow(Map<String, dynamic> row) {
    final name      = (row['full_name']          ?? '—').toString();
    final dept      = (row['department_name']    ?? '').toString();
    final roleName  = (row['role_name']          ?? '').toString();
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

    final subtitle  = _isManagementOnly(_userRoleId)
        ? (dept.isNotEmpty ? dept : roleName)
        : (dept.isNotEmpty && roleName.isNotEmpty ? '$roleName · $dept' : roleName);

    final initials = name.trim().split(' ')
        .where((s) => s.isNotEmpty)
        .take(2)
        .map((s) => s[0].toUpperCase())
        .join();

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _StaffDrillDownPage(
            userId:   userId,
            userName: name,
            deptName: dept,
            month:    _selectedMonth,
            year:     _selectedYear,
            userRole: _userRole,
          ),
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: hasEsc
              ? Border.all(
                  color: AppColors.error.withValues(alpha: 0.25),
                  width: 1.0,
                )
              : Border.all(color: AppColors.borderLight),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Top row: avatar + name + chevron ──────────────────────────
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: hasEsc
                        ? AppColors.error.withValues(alpha: 0.1)
                        : AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    initials.isNotEmpty ? initials : '?',
                    style: TextStyle(
                      color: hasEsc ? AppColors.error : AppColors.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary
                                .withValues(alpha: 0.8),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (hasEsc)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
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

  bool                       _isLoading  = true;
  Map<String, dynamic>       _summaryRow = {};
  List<Map<String, dynamic>> _tasks      = [];

  static const _monthNames = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);

    final result = await _homeService.getTeamPerformance(
      targetUserId: widget.userId,
      month:        widget.month,
      year:         widget.year,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      final team      = (result['team']      as List? ?? []);
      final drillDown = (result['drillDown'] as List? ?? []);

      List<Map<String, dynamic>> taskList = drillDown
          .map((t) => Map<String, dynamic>.from(t as Map))
          .toList();

      if (taskList.isEmpty) {
        final tasksResult = await _homeService.getTasks();
        if (tasksResult['success'] == true) {
          final all = (tasksResult['tasks'] as List? ?? [])
              .cast<Map<String, dynamic>>();
          taskList = all.where((t) {
            final assignedRaw = t['raw'] as Map?;
            if (assignedRaw == null) return false;
            final assignedId = assignedRaw['assigned_to'];
            return assignedId?.toString() == widget.userId.toString();
          }).toList();
        }
      }

      setState(() {
        _summaryRow = team.isNotEmpty
            ? Map<String, dynamic>.from(team.first)
            : {};
        _tasks     = taskList;
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
    }
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

  @override
  Widget build(BuildContext context) {
    final month = _monthNames[widget.month];

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.userName, style: AppTypography.appBarTitle),
          Text('${widget.deptName} — $month ${widget.year}',
              style: AppTypography.appBarSubtitle),
        ]),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSummaryCards(),
                    const SizedBox(height: 20),
                    _buildTaskList(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildSummaryCards() {
    final total   = (_summaryRow['total_assigned']        as int?) ?? 0;
    final closed  = (_summaryRow['total_closed']          as int?) ?? 0;
    final esc     = (_summaryRow['total_escalated']       as int?) ?? 0;
    final avgMins = (_summaryRow['avg_resolution_minutes'] as num?)?.toDouble() ?? 0.0;
    final avgStr  = avgMins <= 0
        ? '—'
        : avgMins < 60
            ? '${avgMins.toStringAsFixed(0)} min'
            : '${(avgMins / 60).toStringAsFixed(1)} hrs';

    final escRate = total > 0 ? (esc / total * 100) : 0.0;
    final escSubtext = total > 0 ? '${escRate.toStringAsFixed(1)}% rate' : '0%';

    final cards = [
      _DrillCard(value: '$total',  label: 'Assigned',
          color: AppColors.primary, icon: Icons.assignment_outlined),
      _DrillCard(value: '$closed', label: 'Closed',
          color: AppColors.success, icon: Icons.check_circle_outline),
      _DrillCard(value: '$esc',    label: 'Escalated\n($escSubtext)',
          color:     esc > 0 ? AppColors.error : AppColors.textDisabled,
          icon:      Icons.warning_amber_outlined,
          highlight: esc > 0),
      _DrillCard(value: avgStr,    label: 'Avg Time',
          color: AppColors.info, icon: Icons.timer_outlined),
    ];

    return Row(
      children: cards.asMap().entries.map((e) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(left: e.key == 0 ? 0 : 8),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
              decoration: BoxDecoration(
                color: e.value.highlight ? AppColors.errorLight : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: e.value.highlight
                    ? Border.all(color: AppColors.error.withValues(alpha: 0.3))
                    : null,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 8, offset: const Offset(0, 3))],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(e.value.icon, size: 18, color: e.value.color),
                const SizedBox(height: 5),
                Text(e.value.value,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                        color: e.value.color)),
                const SizedBox(height: 2),
                Text(e.value.label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 10,
                        color: AppColors.textSecondary),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildTaskList() {
    if (_tasks.isEmpty) {
      return Container(
        width:   double.infinity,
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(color: Colors.white,
            borderRadius: BorderRadius.circular(16)),
        child: const Column(children: [
          Icon(Icons.task_alt, size: 40, color: AppColors.textDisabled),
          SizedBox(height: 8),
          Text('No tasks in this period',
              style: AppTypography.bodySecondary),
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${_tasks.length} Tasks',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
              color: AppColors.textPrimary)),
      const SizedBox(height: 10),
      ...(_tasks.map(_buildTaskRow)),
    ]);
  }

  Widget _buildTaskRow(Map<String, dynamic> task) {
    final isEsc = (task['is_escalated'] == 1 ||
        task['is_escalated'] == true ||
        task['task_flag'] == 'Escalated' ||
        task['escalation_instance_id'] != null ||
        task['escalation_status'] != null);
    final status =
        (task['task_flag'] ?? task['status'] ?? 'Open').toString();
    final rawRoom = (task['room_number'] ??
            task['room_id'] ??
            task['room'] ??
            '—')
        .toString();
    final room = (rawRoom == '0' || rawRoom == '000' || rawRoom == 'null' || rawRoom.isEmpty) ? 'General' : rawRoom;

    // FIX 1: Use _resolveTitle() in drill-down rows too and strip order prefix
    final rawTitle = _resolveTitle(task);
    final title = rawTitle.replaceFirst(RegExp(r'^Order\s+#[A-Z0-9]+\s*-\s*', caseSensitive: false), '');
    final created = _fmtDate((task['created_at'] ?? '').toString());
    final stageName = (task['current_stage_name'] ?? task['stage_name'] ?? '').toString();
    final escLevel = task['escalation_level_reached'] ?? task['escalation_level'];

    final statusColor =
        isEsc ? AppColors.error : AppColors.statusColor(status);

    final canTap = _isSupervisorOrAboveByName(widget.userRole);

    final card = Container(
      margin:  const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: isEsc
            ? Border.all(color: AppColors.error.withValues(alpha: 0.35), width: 1.3)
            : null,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 7, offset: const Offset(0, 2))],
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color:        isEsc ? AppColors.errorLight : AppColors.warningLight,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(room,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13,
                  color: isEsc ? AppColors.error : AppColors.warning)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Row(children: [
              Text(created,
                  style: const TextStyle(fontSize: 11, color: AppColors.textDisabled)),
              if (stageName.isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: AppColors.errorLight,
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(stageName,
                      style: const TextStyle(color: AppColors.error, fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ),
              ] else if (escLevel != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: AppColors.errorLight,
                      borderRadius: BorderRadius.circular(6)),
                  child: Text('L$escLevel',
                      style: const TextStyle(color: AppColors.error, fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ]),
          ]),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8)),
          child: Text(isEsc ? 'Escalated' : status,
              style: TextStyle(color: statusColor, fontWeight: FontWeight.w700,
                  fontSize: 11)),
        ),
        if (canTap) ...[
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded,
              size: 16, color: AppColors.textDisabled),
        ],
      ]),
    );

    if (!canTap) return card;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TicketDetailPage(
            task:     task,
            userRole: widget.userRole,
            onClose:  () => setState(() {}),
            onReassign: (_) => setState(() {}),
            onNoteAdded: (note) {
              setState(() {
                final srId = task["service_request_id"] ??
                    (task["raw"] is Map ? task["raw"]["service_request_id"] : null);
                final idx = _tasks.indexWhere((t) {
                  final tid = t["service_request_id"] ??
                      (t["raw"] is Map ? t["raw"]["service_request_id"] : null);
                  return tid != null && tid == srId;
                });
                if (idx != -1) {
                  _tasks[idx]["note"] = note;
                  if (_tasks[idx]["raw"] is Map) {
                    (_tasks[idx]["raw"] as Map)["note"] = note;
                  }
                }
              });
            },
          ),
        ),
      ),
      child: card,
    );
  }
}

class _DrillCard {
  final String   value;
  final String   label;
  final Color    color;
  final IconData icon;
  final bool     highlight;

  const _DrillCard({
    required this.value,
    required this.label,
    required this.color,
    required this.icon,
    this.highlight = false,
  });
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