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
import '../services/task_alert_service.dart';
import '../utils/user_session_helper.dart';

import '../theme/app_typography.dart';
import '../theme/app_colors.dart';
import '../theme/app_border.dart';
import '../theme/app_durations.dart';
import '../theme/app_spacing.dart';
import '../constants/app_strings.dart';
import '../components/app_badge.dart';
import '../components/app_card.dart';
import '../components/app_dialog.dart';
import '../components/skeleton_loader.dart';
import 'ticket_details_page.dart';

// ── Role helpers ──────────────────────────────────────────────────────────────

bool _isGmOrAdmin(int? roleId)         => roleId != null && (roleId == 1 || roleId == 2);
bool _isManager(int? roleId)           => roleId == 3;
bool _isDeptHead(int? roleId)          => roleId == 4;
bool _isSupervisor(int? roleId)        => roleId == 5;
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
  String       _userRole   = '';
  int?         _userId;
  int?         _userRoleId;
  List<String> _myDepts    = [];

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
    if (!mounted) return;

    setState(() {
      _userRole   = role ?? '';
      _userRoleId = roleId ?? _deriveRoleId(role);
      _userId     = userId;
      _myDepts    = depts;

      if (_isDeptScopedRole(_userRoleId)) {
        _availableFilterDepts = List.from(depts)..sort();
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

      setState(() {
        totalTasks      = (selfRow['total_assigned']  as int?) ?? 0;
        completedTasks  = (selfRow['total_closed']    as int?) ?? 0;
        escalatedTasks  = (selfRow['total_escalated'] as int?) ?? escalatedTasks;
        inProgressTasks = (totalTasks - completedTasks).clamp(0, 9999);
        _allTasks       = allTasksList;
        _recentTasks    = allTasksList.take(5).toList();
        _hasMoreTasks   = allTasksList.length > 5;
        _statsLoading   = false;
        _statsError     = null;
      });
    } else {
      // FIX-10 (Bug 10): show the error and clear stale figures instead of
      // silently leaving the previous month's numbers on screen next to a
      // newly-selected month — this was the "wrong month" bug.
      if (mounted) {
        setState(() {
          _statsLoading   = false;
          _statsError     = result['message'] as String? ??
              'Failed to load activity. Please check your connection.';
          totalTasks      = 0;
          completedTasks  = 0;
          inProgressTasks = 0;
          _allTasks       = [];
          _recentTasks    = [];
          _hasMoreTasks   = false;
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

      if (_isManagementOnly(_userRoleId)) {
        int totAssigned = 0, totClosed = 0, totEscalated = 0;
        for (final r in rows) {
          totAssigned  += (r['total_assigned']  as int?) ?? 0;
          totClosed    += (r['total_closed']    as int?) ?? 0;
          totEscalated += (r['total_escalated'] as int?) ?? 0;
        }
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
        _teamRowsAll = rows;
        _teamRows    = _applyDeptFilter(rows);
        _teamLoading = false;
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

  int? _deptIdForName(String name) {
    for (final r in _teamRowsAll) {
      if ((r['department_name'] ?? '').toString() == name) {
        return r['department_id'] as int?;
      }
    }
    return null;
  }

  void _onDeptSelected(String? dept) {
    if (_selectedDept == dept) return;
    setState(() {
      _selectedDept = dept;
      _teamRows = _applyDeptFilter(_teamRowsAll);
    });
  }

  // ── Refresh ───────────────────────────────────────────────────────────────

  Future<void> _onRefresh() async {
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
        showAllOption: !_isDeptScopedRole(_userRoleId),
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
      final isEsc = (task['is_escalated'] ?? 0) == 1 ||
          task['task_flag'] == 'Escalated';
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
                      const SizedBox(height: 60),
                      Icon(Icons.wifi_off_rounded,
                          size: 48, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      Text(
                        _statsError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: TextButton(
                          onPressed: _loadMyStats,
                          child: const Text('Try Again'),
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
                    _buildStatCards(),
                    if (_isSupervisorOrAbove(_userRoleId)) ...[
                      _buildTeamSectionHeader(),
                      _buildTeamList(),
                    ],
                    if (!_isManagementOnly(_userRoleId))
                      _buildRecentActivity(),
                    _buildMotivationBanner(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }

  // ── App Bar ───────────────────────────────────────────────────────────────

  AppBar _buildAppBar() {
    final subtitle = _isSupervisorOrAbove(_userRoleId) && _userRole.isNotEmpty
        ? '$_userRole — ${_monthNames[_selectedMonth]} $_selectedYear'
        : 'Your performance overview';

    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('My Tasks', style: AppTypography.appBarTitle),
          Text(subtitle, style: AppTypography.appBarSubtitle),
        ],
      ),
    );
  }

  // ── Month Tile ────────────────────────────────────────────────────────────

  Widget _buildMonthTile() {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: _showMonthPickerSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
              blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.calendar_month_outlined, size: 18,
                color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${_monthNames[_selectedMonth]} $_selectedYear',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary),
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 18,
                color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  // ── Dept Tile ─────────────────────────────────────────────────────────────

  Widget _buildDeptTile() {
    final label = _selectedDept ?? 'All Departments';
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: _showDeptFilterSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
              blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.business_outlined, size: 18,
                color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary),
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 18,
                color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  // ── Stat Cards ────────────────────────────────────────────────────────────

  Widget _buildStatCards() {
    final showEscalated =
        escalatedTasks > 0 || _isManagementOnly(_userRoleId);

    final cards = [
      _StatCardData(
        count:        '$totalTasks',
        label:        _isManagementOnly(_userRoleId) ? 'Team Total' : 'Total Tasks',
        icon:         Icons.assignment_outlined,
        iconBg:       AppColors.primary.withOpacity(0.1),
        iconColor:    AppColors.primary,
        accentColor:  AppColors.primary,
        // Total card shows all tasks — no status filter
        filterStatus: null,
      ),
      _StatCardData(
        count:        '$completedTasks',
        label:        'Completed',
        icon:         Icons.check_circle_outline,
        iconBg:       AppColors.successLight,
        iconColor:    AppColors.success,
        accentColor:  AppColors.success,
        // FIX 3: Tap opens sheet filtered to Closed tasks
        filterStatus: 'completed',
      ),
      _StatCardData(
        count:        '$inProgressTasks',
        label:        'In Progress',
        icon:         Icons.timelapse_outlined,
        iconBg:       const Color(0xFFF0F1FF),
        iconColor:    AppColors.primary,
        accentColor:  AppColors.primary,
        // FIX 3: Tap opens sheet filtered to In Progress tasks
        filterStatus: 'inProgress',
      ),
      if (showEscalated)
        _StatCardData(
          count:        '$escalatedTasks',
          label:        'Escalated',
          icon:         Icons.warning_amber_rounded,
          iconBg:       AppColors.errorLight,
          iconColor:    AppColors.error,
          accentColor:  AppColors.error,
          highlight:    escalatedTasks > 0,
          // FIX 3: Tap opens sheet filtered to escalated tasks
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
    final card = Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
      decoration: BoxDecoration(
        color: d.highlight ? AppColors.errorLight : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: d.highlight
            ? Border.all(color: AppColors.error.withOpacity(0.3))
            : null,
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04),
              blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(color: d.iconBg, shape: BoxShape.circle),
            child: Icon(d.icon, size: 18, color: d.iconColor),
          ),
          const SizedBox(height: 6),
          Text(d.count,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                  color: d.accentColor)),
          const SizedBox(height: 2),
          Text(d.label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
              maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );

    // FIX 3: Only make tappable when filterStatus is set and there are tasks
    // loaded. Management-only roles see aggregated data, not drill-down tasks,
    // so don't attach a tap handler for them.
    if (d.filterStatus == null || _isManagementOnly(_userRoleId)) {
      return card;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _showFilteredTasksSheet(d.filterStatus!, d.label),
      child: card,
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
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary)),
          Row(children: [
            if (!_teamLoading && _teamRows.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color:        AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('${_teamRows.length} staff',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        color: AppColors.primary)),
              ),
            if (_teamLoading)
              const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
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
      child: Container(
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
              blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Column(children: [
          _buildTeamTableHeader(),
          const Divider(height: 1, color: AppColors.borderLight),
          ...(_teamRows.asMap().entries.map((e) {
            final isLast = e.key == _teamRows.length - 1;
            return Column(children: [
              _buildTeamRow(e.value),
              if (!isLast)
                const Divider(height: 1, color: AppColors.borderLight,
                    indent: 16, endIndent: 16),
            ]);
          })),
        ]),
      ),
    );
  }

  Widget _buildTeamTableHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        const Expanded(flex: 3,
            child: Text('Staff',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary))),
        _hCell('Assigned'),
        _hCell('Done'),
        _hCell('Esc'),
        _hCell('Rate'),
      ]),
    );
  }

  Widget _hCell(String label) => SizedBox(
        width: 46,
        child: Text(label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                color: AppColors.textSecondary)),
      );

  Widget _buildTeamRow(Map<String, dynamic> row) {
    final name      = (row['full_name']          ?? '—').toString();
    final dept      = (row['department_name']    ?? '').toString();
    final roleName  = (row['role_name']          ?? '').toString();
    final assigned  = (row['total_assigned']     as int?) ?? 0;
    final closed    = (row['total_closed']       as int?) ?? 0;
    final escalated = (row['total_escalated']    as int?) ?? 0;
    final rate      = row['escalation_rate_pct'] ?? 0.0;
    final rateStr   = rate == 0.0
        ? '0%'
        : '${(rate is double ? rate : (rate as num).toDouble()).toStringAsFixed(1)}%';
    final userId    = (row['user_id'] as int?) ?? 0;

    final escColor = escalated > 0 ? AppColors.error : AppColors.success;

    final subtitle = _isManagementOnly(_userRoleId)
        ? (dept.isNotEmpty ? dept : roleName)
        : roleName;

    return InkWell(
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Expanded(
            flex: 3,
            child: Row(children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.primary.withOpacity(0.1),
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: const TextStyle(color: AppColors.primary,
                      fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(name,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (subtitle.isNotEmpty)
                    Text(subtitle,
                        style: const TextStyle(fontSize: 10,
                            color: AppColors.textSecondary),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
            ]),
          ),
          _mCell('$assigned', AppColors.textSecondary),
          _mCell('$closed',   AppColors.success),
          _mCell('$escalated', escColor),
          _mCell(rateStr,
              escalated > 0 ? AppColors.error : AppColors.textSecondary),
        ]),
      ),
    );
  }

  Widget _mCell(String value, Color color) => SizedBox(
        width: 46,
        child: Text(value,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                color: color)),
      );

  // ── Recent Activity ───────────────────────────────────────────────────────

  Widget _buildRecentActivity() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Recent Activity',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          if (_recentTasks.isEmpty)
            Container(
              width:   double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(color: Colors.white,
                  borderRadius: BorderRadius.circular(18)),
              child: const Column(children: [
                Icon(Icons.task_alt, size: 40, color: AppColors.textSecondary),
                SizedBox(height: 8),
                Text('No recent tasks found',
                    style: AppTypography.bodySecondary),
              ]),
            )
          else
            Container(
              decoration: BoxDecoration(
                color:        Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
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
    final isEsc  = (task['is_escalated'] ?? 0) == 1 ||
        task['task_flag'] == 'Escalated';
    final status = (task['status'] ??
            task['task_flag'] ??
            'Open')
        .toString();
    final displayStatus = isEsc ? 'Escalated' : status;

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

    final room = (task['room_number'] ??
            task['room_id'] ??
            task['room'] ??
            '—')
        .toString();

    // FIX 1: Use _resolveTitle() instead of bare ?? chain.
    final title  = _resolveTitle(task);
    final timeAgo = _timeAgo(
        (task['created_at'] ?? task['time'] ?? '').toString());

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color:        AppColors.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Text(room,
                style: const TextStyle(color: AppColors.primary,
                    fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontSize: 14,
                        fontWeight: FontWeight.w600),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text(timeAgo,
                    style: const TextStyle(fontSize: 12,
                        color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: statusBg,
                borderRadius: BorderRadius.circular(20)),
            child: Text(displayStatus,
                style: TextStyle(color: statusColor,
                    fontWeight: FontWeight.w600, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  String _timeAgo(String ts) {
    if (ts.isEmpty) return '';
    try {
      String s = ts.trim();
      if (s.contains(' ') && !s.contains('T'))
        s = s.replaceFirst(' ', 'T');
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color:        AppColors.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.primary.withOpacity(0.2)),
        ),
        child: Row(children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.star_outline, color: AppColors.primary, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Great work!',
                  style: TextStyle(color: AppColors.primary,
                      fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 2),
              Text('Keep up the good work and complete more tasks.',
                  style: AppTypography.bodySecondary.copyWith(fontSize: 13)),
            ]),
          ),
          const SizedBox(width: 8),
          Icon(Icons.checklist_rtl_outlined,
              color: AppColors.primary.withOpacity(0.4), size: 40),
        ]),
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
  final Color    iconBg;
  final Color    iconColor;
  final Color    accentColor;
  final bool     highlight;
  // FIX 3: Which status filter to apply when this card is tapped.
  // null = not tappable (Total Tasks card for management).
  final String?  filterStatus;

  const _StatCardData({
    required this.count,
    required this.label,
    required this.icon,
    required this.iconBg,
    required this.iconColor,
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
      if (s.contains(' ') && !s.contains('T'))
        s = s.replaceFirst(' ', 'T');
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
    final avgMins = _summaryRow['avg_resolution_minutes'] ?? 0;
    final avgStr  = avgMins == 0
        ? '—'
        : avgMins is double
            ? '${avgMins.toStringAsFixed(0)} min'
            : '$avgMins min';

    final cards = [
      _DrillCard(value: '$total',  label: 'Assigned',
          color: AppColors.primary, icon: Icons.assignment_outlined),
      _DrillCard(value: '$closed', label: 'Closed',
          color: AppColors.success, icon: Icons.check_circle_outline),
      _DrillCard(value: '$esc',    label: 'Escalated',
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
                    ? Border.all(color: AppColors.error.withOpacity(0.3))
                    : null,
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
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
    final isEsc    = (task['is_escalated'] ?? 0) == 1 ||
        task['task_flag'] == 'Escalated';
    final status   =
        (task['task_flag'] ?? task['status'] ?? 'Open').toString();
    final room     = (task['room_number'] ??
            task['room_id'] ??
            task['room'] ??
            '—')
        .toString();

    // FIX 1: Use _resolveTitle() in drill-down rows too.
    final title    = _resolveTitle(task);
    final created  = _fmtDate((task['created_at'] ?? '').toString());
    final escLevel = task['escalation_level_reached'];

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
            ? Border.all(color: AppColors.error.withOpacity(0.35), width: 1.3)
            : null,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
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
              if (escLevel != null) ...[
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
          decoration: BoxDecoration(color: statusColor.withOpacity(0.1),
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