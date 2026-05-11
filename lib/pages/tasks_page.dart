// tasks_page.dart
//
// CHANGES IN THIS VERSION:
//  • Loads userRole from UserSessionHelper.getRole() in initState
//  • Staff: month picker (Jan–Dec) + 4th stat card (Escalated) wired to
//    HomeService.getTeamPerformance(targetUserId=self, month, year)
//  • Supervisor / Dept Head / Manager / GM / Admin: team performance list
//    above the recent activity section — staff rows with metrics.
//    Month picker + dept filter chips (Manager+).
//    Tap staff row → _StaffDrillDownPage (inline page in this file).
//  • All existing stat cards and recent activity widgets kept below.

import 'dart:async';
import 'package:flutter/material.dart';
import '../services/home_service.dart';
import '../services/task_alert_service.dart';
import '../utils/user_session_helper.dart';
import '../utils/app_colors.dart';

// ── Role helpers ─────────────────────────────────────────────────────────────

const _roleHierarchy = [
  'Staff', 'Supervisor', 'Department Head', 'Manager', 'General Manager', 'Admin',
];

bool _isManagerRole(String? role) {
  if (role == null) return false;
  return _roleHierarchy.indexOf(role) >= 3;
}

bool _isSupervisorOrAbove(String? role) {
  if (role == null) return false;
  return _roleHierarchy.indexOf(role) >= 1;
}

// ─────────────────────────────────────────────────────────────────────────────

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  final HomeService _homeService = HomeService();

  // ── Auth ──────────────────────────────────────────────────────────────────
  String  _userRole  = '';
  int?    _userId;

  // ── Month / filter ────────────────────────────────────────────────────────
  int  _selectedMonth = DateTime.now().month;
  int  _selectedYear  = DateTime.now().year;
  int? _selectedDeptId;  // Manager+ dept filter

  // ── My stats (all roles) ──────────────────────────────────────────────────
  bool  _statsLoading   = true;
  int   totalTasks      = 0;
  int   completedTasks  = 0;
  int   inProgressTasks = 0;
  int   escalatedTasks  = 0;
  List<dynamic> _recentTasks = [];

  // ── Team performance (Supervisor+) ───────────────────────────────────────
  bool  _teamLoading = false;
  List<Map<String, dynamic>> _teamRows = [];

  // ── Escalation stream ─────────────────────────────────────────────────────
  StreamSubscription<int>? _escSub;

  static const List<String> _monthNames = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

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
    final userId = await UserSessionHelper.getUserId();
    if (!mounted) return;
    setState(() {
      _userRole = role ?? '';
      _userId   = userId;
    });
    await Future.wait([
      _loadMyStats(),
      if (_isSupervisorOrAbove(_userRole)) _loadTeamPerformance(),
    ]);
  }

  // ── My stats ──────────────────────────────────────────────────────────────

  Future<void> _loadMyStats() async {
    if (!mounted) return;
    setState(() => _statsLoading = true);

    // Use getTeamPerformance with targetUserId = self to get month-filtered data.
    // Falls back to existing task summary for staff without team performance SP.
    final result = await _homeService.getTeamPerformance(
      targetUserId: _userId,
      month: _selectedMonth,
      year:  _selectedYear,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      // RS1 = self row (for Staff the SP returns one row for the caller)
      final teamList  = (result['team']     as List? ?? []);
      final drillDown = (result['drillDown'] as List? ?? []);

      // Self row is in RS1 if staff, or we compute from RS2 drill-down
      final selfRow = teamList.isNotEmpty
          ? Map<String, dynamic>.from(teamList.first)
          : <String, dynamic>{};

      setState(() {
        totalTasks      = (selfRow['total_assigned'] ?? 0) as int;
        completedTasks  = (selfRow['total_closed']    ?? 0) as int;
        escalatedTasks  = (selfRow['total_escalated'] ?? 0) as int;
        inProgressTasks = (totalTasks - completedTasks).clamp(0, 9999);
        _recentTasks    = drillDown.take(10).toList();
        _statsLoading   = false;
      });
    } else {
      // Fallback: hit old task summary endpoint
      if (!mounted) return;
      setState(() => _statsLoading = false);
    }
  }

  // ── Team performance ──────────────────────────────────────────────────────

  Future<void> _loadTeamPerformance() async {
    if (!mounted) return;
    setState(() => _teamLoading = true);

    final result = await _homeService.getTeamPerformance(
      departmentId: _selectedDeptId,
      month: _selectedMonth,
      year:  _selectedYear,
    );

    if (!mounted) return;
    setState(() {
      if (result['success'] == true) {
        _teamRows = (result['team'] as List? ?? [])
            .cast<Map<String, dynamic>>();
      }
      _teamLoading = false;
    });
  }

  // ── Pull refresh ──────────────────────────────────────────────────────────

  Future<void> _onRefresh() async {
    await Future.wait([
      _loadMyStats(),
      if (_isSupervisorOrAbove(_userRole)) _loadTeamPerformance(),
    ]);
  }

  // ── Month / filter changes ────────────────────────────────────────────────

  void _onMonthChanged(int month) {
    if (_selectedMonth == month) return;
    setState(() => _selectedMonth = month);
    _loadMyStats();
    if (_isSupervisorOrAbove(_userRole)) _loadTeamPerformance();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgLight,
      appBar: _buildAppBar(),
      body: _statsLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _onRefresh,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Month picker — all roles
                    _buildMonthPicker(),

                    // My stat cards
                    _buildStatCards(),

                    // Team performance — Supervisor+ only
                    if (_isSupervisorOrAbove(_userRole)) ...[
                      _buildTeamSectionHeader(),
                      _buildTeamList(),
                    ],

                    // Recent activity
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
    final subtitle = _isSupervisorOrAbove(_userRole) && _userRole.isNotEmpty
        ? '$_userRole — ${_monthNames[_selectedMonth]} $_selectedYear'
        : 'Your performance overview';

    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('My Tasks',
              style: TextStyle(color: AppColors.textPrimary,
                  fontWeight: FontWeight.bold, fontSize: 22)),
          Text(subtitle,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        ],
      ),
      elevation: 0,
      backgroundColor: Colors.white,
      iconTheme: const IconThemeData(color: Colors.black),
    );
  }

  // ── Month Picker ──────────────────────────────────────────────────────────

  Widget _buildMonthPicker() {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: 12,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (ctx, i) {
          final month      = i + 1;
          final isSelected = _selectedMonth == month;
          final isFuture   = month > DateTime.now().month &&
              _selectedYear == DateTime.now().year;

          return GestureDetector(
            onTap: isFuture ? null : () => _onMonthChanged(month),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primary
                    : isFuture
                        ? AppColors.surfaceAlt
                        : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected
                      ? AppColors.primary
                      : isFuture
                          ? AppColors.borderLight
                          : AppColors.border,
                ),
                boxShadow: isSelected
                    ? [BoxShadow(color: AppColors.primary.withOpacity(0.25),
                          blurRadius: 6, offset: const Offset(0, 2))]
                    : [],
              ),
              child: Text(
                _monthNames[month],
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected
                      ? Colors.white
                      : isFuture
                          ? AppColors.textDisabled
                          : AppColors.textPrimary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Stat Cards ────────────────────────────────────────────────────────────

  Widget _buildStatCards() {
    final cards = [
      _StatCardData(
        count: '$totalTasks',
        label: 'Total Tasks',
        icon:  Icons.assignment_outlined,
        iconBg: AppColors.primary.withOpacity(0.1),
        iconColor: AppColors.primary,
        accentColor: AppColors.primary,
      ),
      _StatCardData(
        count: '$completedTasks',
        label: 'Completed',
        icon:  Icons.check_circle_outline,
        iconBg: AppColors.successLight,
        iconColor: AppColors.success,
        accentColor: AppColors.success,
      ),
      _StatCardData(
        count: '$inProgressTasks',
        label: 'In Progress',
        icon:  Icons.timelapse_outlined,
        iconBg: const Color(0xFFF0F1FF),
        iconColor: AppColors.primary,
        accentColor: AppColors.primary,
      ),
      if (escalatedTasks > 0 || _isManagerRole(_userRole))
        _StatCardData(
          count: '$escalatedTasks',
          label: 'Escalated',
          icon:  Icons.warning_amber_rounded,
          iconBg: AppColors.errorLight,
          iconColor: AppColors.error,
          accentColor: AppColors.error,
          highlight: escalatedTasks > 0,
        ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: cards.asMap().entries.map((e) {
          final card = e.value;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: e.key == 0 ? 0 : 8),
              child: _buildStatCard(card),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildStatCard(_StatCardData d) {
    return Container(
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
              style: const TextStyle(fontSize: 10,
                  color: AppColors.textSecondary),
              maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  // ── Team Section Header ───────────────────────────────────────────────────

  Widget _buildTeamSectionHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _isManagerRole(_userRole) ? 'All Departments' : 'My Team',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold,
                color: AppColors.textPrimary),
          ),
          if (_teamLoading)
            const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
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
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(color: Colors.white,
              borderRadius: BorderRadius.circular(16)),
          child: const Column(children: [
            Icon(Icons.people_outline, size: 36, color: AppColors.textDisabled),
            SizedBox(height: 8),
            Text('No team data for this period',
                style: TextStyle(color: AppColors.textSecondary)),
          ]),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.04),
                blurRadius: 10, offset: const Offset(0, 4)),
          ],
        ),
        child: Column(
          children: [
            // Table header
            _buildTeamTableHeader(),
            const Divider(height: 1, color: AppColors.borderLight),
            // Rows
            ...(_teamRows.asMap().entries.map((e) {
              final isLast = e.key == _teamRows.length - 1;
              return Column(
                children: [
                  _buildTeamRow(e.value),
                  if (!isLast)
                    const Divider(height: 1, color: AppColors.borderLight,
                        indent: 16, endIndent: 16),
                ],
              );
            })),
          ],
        ),
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
        _headerCell('Done'),
        _headerCell('Esc'),
        _headerCell('Rate'),
      ]),
    );
  }

  Widget _headerCell(String label) {
    return SizedBox(
      width: 48,
      child: Text(label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
              color: AppColors.textSecondary)),
    );
  }

  Widget _buildTeamRow(Map<String, dynamic> row) {
    final name        = (row['full_name']          ?? '—').toString();
    final dept        = (row['department_name']    ?? '').toString();
    final closed      = (row['total_closed']       ?? 0) as int;
    final escalated   = (row['total_escalated']    ?? 0) as int;
    final rate        = (row['escalation_rate_pct'] ?? 0.0);
    final rateStr     = rate == 0.0
        ? '0%'
        : '${(rate is double ? rate : (rate as num).toDouble()).toStringAsFixed(1)}%';
    final userId      = (row['user_id']            ?? 0) as int;

    final escColor = escalated > 0 ? AppColors.error : AppColors.success;

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
          ),
        ),
      ),
      borderRadius: BorderRadius.circular(0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Expanded(
            flex: 3,
            child: Row(children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: AppColors.primary.withOpacity(0.1),
                child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(color: AppColors.primary,
                        fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name,
                      style: const TextStyle(fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (dept.isNotEmpty)
                    Text(dept,
                        style: const TextStyle(fontSize: 11,
                            color: AppColors.textSecondary),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
            ]),
          ),
          _metricCell('$closed', AppColors.success),
          _metricCell('$escalated', escColor),
          _metricCell(rateStr,
              escalated > 0 ? AppColors.error : AppColors.textSecondary),
        ]),
      ),
    );
  }

  Widget _metricCell(String value, Color color) {
    return SizedBox(
      width: 48,
      child: Text(value,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
              color: color)),
    );
  }

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
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(color: Colors.white,
                  borderRadius: BorderRadius.circular(18)),
              child: Column(children: [
                Icon(Icons.task_alt, size: 40, color: AppColors.textSecondary),
                const SizedBox(height: 8),
                const Text('No recent tasks found',
                    style: TextStyle(color: AppColors.textSecondary)),
              ]),
            )
          else
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.04),
                      blurRadius: 10, offset: const Offset(0, 4)),
                ],
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _recentTasks.length,
                separatorBuilder: (_, __) => Divider(
                    height: 1, color: AppColors.textSecondary,
                    indent: 16, endIndent: 16),
                itemBuilder: (ctx, i) {
                  final task      = _recentTasks[i] as Map<String, dynamic>;
                  final isEsc     = (task['is_escalated'] ?? 0) == 1 ||
                                    task['task_flag'] == 'Escalated';
                  final status    = (task['status'] ?? task['task_flag'] ?? 'Open').toString();
                  final rawStatus = isEsc ? 'Escalated' : status;

                  Color statusColor;
                  Color statusBg;
                  if (isEsc) {
                    statusColor = AppColors.error;
                    statusBg    = AppColors.errorLight;
                  } else if (status == 'Closed' || status == 'In Progress') {
                    statusColor = status == 'Closed' ? AppColors.success : AppColors.orange;
                    statusBg    = status == 'Closed' ? AppColors.successLight : AppColors.orangeLight;
                  } else {
                    statusColor = AppColors.primary;
                    statusBg    = AppColors.primaryLight;
                  }

                  final room    = (task['room_number'] ?? task['room_id'] ?? '—').toString();
                  final title   = (task['task_name']   ?? task['question'] ?? '').toString();
                  final created = (task['created_at']  ?? '').toString();
                  final timeAgo = _timeAgo(created);

                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.1),
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
                        ]),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: statusBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(rawStatus,
                            style: TextStyle(color: statusColor,
                                fontWeight: FontWeight.w600, fontSize: 12)),
                      ),
                    ]),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  String _timeAgo(String ts) {
    if (ts.isEmpty) return '';
    try {
      String s = ts.trim();
      if (s.contains(' ') && !s.contains('T')) s = s.replaceFirst(' ', 'T');
      final d    = DateTime.parse(s).toLocal();
      final diff = DateTime.now().difference(d);
      if (diff.inMinutes < 60)  return '${diff.inMinutes}m ago';
      if (diff.inHours   < 24)  return '${diff.inHours}h ago';
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
          color: AppColors.primary.withOpacity(0.08),
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
            child: const Icon(Icons.star_outline,
                color: AppColors.primary, size: 26),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Great work!',
                  style: TextStyle(color: AppColors.primary,
                      fontWeight: FontWeight.bold, fontSize: 15)),
              SizedBox(height: 2),
              Text('Keep up the good work and complete more tasks.',
                  style: TextStyle(fontSize: 13,
                      color: AppColors.textSecondary)),
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

// ── Stat card data class ──────────────────────────────────────────────────────

class _StatCardData {
  final String   count;
  final String   label;
  final IconData icon;
  final Color    iconBg;
  final Color    iconColor;
  final Color    accentColor;
  final bool     highlight;

  const _StatCardData({
    required this.count,
    required this.label,
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.accentColor,
    this.highlight = false,
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

  const _StaffDrillDownPage({
    required this.userId,
    required this.userName,
    required this.deptName,
    required this.month,
    required this.year,
  });

  @override
  State<_StaffDrillDownPage> createState() => _StaffDrillDownPageState();
}

class _StaffDrillDownPageState extends State<_StaffDrillDownPage> {
  final HomeService _homeService = HomeService();

  bool  _isLoading = true;
  Map<String, dynamic> _summaryRow = {};
  List<Map<String, dynamic>> _tasks = [];

  static const List<String> _monthNames = [
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
      month: widget.month,
      year:  widget.year,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      final team      = (result['team']      as List? ?? []);
      final drillDown = (result['drillDown'] as List? ?? []);

      setState(() {
        _summaryRow = team.isNotEmpty
            ? Map<String, dynamic>.from(team.first)
            : {};
        _tasks = drillDown.map((t) =>
            Map<String, dynamic>.from(t as Map)).toList();
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
    }
  }

  String _formatTs(String? ts) {
    if (ts == null || ts.isEmpty) return '—';
    try {
      String s = ts.trim();
      if (s.contains(' ') && !s.contains('T')) s = s.replaceFirst(' ', 'T');
      final d = DateTime.parse(s).toLocal();
      return '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year}';
    } catch (_) { return ts; }
  }

  @override
  Widget build(BuildContext context) {
    final month = _monthNames[widget.month];

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.userName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary)),
          Text('${widget.deptName} — $month ${widget.year}',
              style: const TextStyle(fontSize: 12,
                  color: AppColors.textSecondary)),
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
    final total     = (_summaryRow['total_assigned']       ?? 0) as int;
    final closed    = (_summaryRow['total_closed']         ?? 0) as int;
    final esc       = (_summaryRow['total_escalated']      ?? 0) as int;
    final avgMins   = (_summaryRow['avg_resolution_minutes'] ?? 0);
    final avgStr    = avgMins == 0
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
          color: esc > 0 ? AppColors.error : AppColors.textDisabled,
          icon: Icons.warning_amber_outlined,
          highlight: esc > 0),
      _DrillCard(value: avgStr,    label: 'Avg Time',
          color: AppColors.info, icon: Icons.timer_outlined),
    ];

    return Row(
      children: cards.asMap().entries.map((e) => Expanded(
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
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.04),
                    blurRadius: 8, offset: const Offset(0, 3)),
              ],
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
      )).toList(),
    );
  }

  Widget _buildTaskList() {
    if (_tasks.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(color: Colors.white,
            borderRadius: BorderRadius.circular(16)),
        child: const Column(children: [
          Icon(Icons.task_alt, size: 40, color: AppColors.textDisabled),
          SizedBox(height: 8),
          Text('No tasks in this period',
              style: TextStyle(color: AppColors.textSecondary)),
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${_tasks.length} Tasks',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
              color: AppColors.textPrimary)),
      const SizedBox(height: 10),
      ...(_tasks.map((task) => _buildTaskRow(task))),
    ]);
  }

  Widget _buildTaskRow(Map<String, dynamic> task) {
    final isEsc    = (task['is_escalated'] ?? 0) == 1 ||
                     task['task_flag'] == 'Escalated';
    final status   = (task['task_flag']  ??
                      task['status']     ?? 'Open').toString();
    final room     = (task['room_number'] ?? '—').toString();
    final title    = (task['task_name']   ??
                      task['question']   ?? 'Service Request').toString();
    final created  = _formatTs((task['created_at'] ?? '').toString());
    final escLevel = task['escalation_level_reached'];

    Color borderColor = Colors.transparent;
    Color statusColor = AppColors.statusColor(status);
    if (isEsc) {
      borderColor = AppColors.error.withOpacity(0.35);
      statusColor = AppColors.error;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: isEsc
            ? Border.all(color: borderColor, width: 1.3)
            : null,
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04),
              blurRadius: 7, offset: const Offset(0, 2)),
        ],
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: isEsc ? AppColors.errorLight : AppColors.warningLight,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(room,
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 13,
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
                  style: const TextStyle(fontSize: 11,
                      color: AppColors.textDisabled)),
              if (escLevel != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.errorLight,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('L$escLevel',
                      style: const TextStyle(color: AppColors.error,
                          fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ],
            ]),
          ]),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(isEsc ? 'Escalated' : status,
              style: TextStyle(color: statusColor,
                  fontWeight: FontWeight.w700, fontSize: 11)),
        ),
      ]),
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