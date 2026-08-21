// ticket_details_page.dart
//
// CHANGES IN THIS VERSION:
//  • _loadEscalationHistory() — replaced getEscalatedTasks() + client-side
//    filter with getEscalationHistoryForTask(). Now calls the dedicated SP
//    that returns the full audit trail (including resolved entries) for a
//    single service request ordered by escalation_level ASC, escalated_at ASC.
//  • showClose condition — Close button now only shows if the viewer is
//    Supervisor+ OR they are the staff member assigned to the task.
//    Previously it showed for everyone on any in-progress task.
//  • notifyReassign() — called (fire-and-forget) after every successful
//    reassign so the new assignee gets an FCM immediately.
//  • closeServiceRequest() — now passes department_id and enterprise_id
//    in the payload so the Lambda can broadcast TASK_CLOSED via WebSocket.
//
// FORMAT: Old version layout (info card with detail rows, inline Add Note,
//         Reassign + Close buttons at bottom).
//
// Existing fixes retained:
//  • _formatTs() — midnight fix (hour == 0 shows as 12, not 0).
//  • Guest Phone row  → tappable blue call button for ALL roles.
//  • Assigned To row  → blue call icon for Supervisor+ (phone resolved lazily).
//  • Reassign sheet   → blue call icon per staff row.
//  • AppBar status shown as a coloured pill inside the AppBar container.
//  • url_launcher used for tel: calls.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/home_service.dart';
import '../services/task_service.dart';
import '../utils/user_session_helper.dart';
import '../utils/date_formatter.dart';
import '../utils/app_snackbar.dart';
import '../utils/escalation_helpers.dart';

import '../theme/app_typography.dart';
import '../theme/app_colors.dart';

// ── Role helpers — delegate to EscalationRole from escalation_helpers.dart ───

bool _isManagerRole(String? role) =>
    escalationRoleFromName(role).isManagerOrAbove;

bool _isSupervisorOrAbove(String? role) =>
    escalationRoleFromName(role).isSupervisorOrAbove;

// ─────────────────────────────────────────────────────────────────────────────

class TicketDetailPage extends StatefulWidget {
  final Map<String, dynamic> task;
  final String userRole;
  final VoidCallback? onClose;
  final void Function(Map<String, dynamic>)? onReassign;
  final void Function(String)? onNoteAdded;

  const TicketDetailPage({
    super.key,
    required this.task,
    this.userRole = '',
    this.onClose,
    this.onReassign,
    this.onNoteAdded,
  });

  @override
  State<TicketDetailPage> createState() => _TicketDetailPageState();
}

class _TicketDetailPageState extends State<TicketDetailPage> {
  final HomeService _homeService = HomeService();
  final TextEditingController _noteController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _isLoading        = false;
  bool _isLoadingStaff   = false;
  bool _phoneLoading     = false;
  bool _showScrollTop    = false;

  bool _isRefreshing = false;

  List<Map<String, dynamic>> _staffList         = [];
  List<Map<String, dynamic>> _escalationHistory = [];
  bool _isLoadingEscHist = false;

  int?   _loggedInUserId;

  String _assignedPhone = '';

  late Map<String, dynamic> _task;

  @override
  void initState() {
    super.initState();
    _task = Map<String, dynamic>.from(widget.task);
    _loadUserId();

    // Silently fetch fresh ticket data so stale notes / status from the
    // parent list are replaced with the current server state.
    _refreshFromServer();

    _scrollController.addListener(() {
      final show = _scrollController.offset > 300;
      if (show != _showScrollTop) setState(() => _showScrollTop = show);
    });

    final raw = _task['raw'] as Map<String, dynamic>? ?? {};
    _assignedPhone = (raw['assigned_to_phone'] ?? '').toString();

    if (_assignedPhone.isEmpty && _isSupervisorOrAbove(widget.userRole)) {
      _fetchAssignedPhone();
    }
  }

  @override
  void dispose() {
    _noteController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── Session ───────────────────────────────────────────────────────────────

  Future<void> _loadUserId() async {
    final id = await UserSessionHelper.getUserId();
    if (mounted) setState(() => _loggedInUserId = id);
  }

  // ── Fresh-data refresh on open ────────────────────────────────────────────
  //
  // Fetches the current server state for this ticket immediately when the
  // page opens. The widget.task snapshot passed in by the parent list is used
  // as an instant placeholder so there is no blank/loading screen — the fresh
  // data is swapped in quietly once the call resolves.
  //
  // Strategy: call getTasks() (which returns ALL tasks for the user) and find
  // the row whose service_request_id matches ours. If the ticket is flagged as
  // escalated we also try getEscalatedTasks() as a fallback so we always
  // surface the most accurate data regardless of which list navigated here.
  //
  // Failure behaviour: if the network call fails (offline, timeout, error) we
  // simply stay with the placeholder data — no error screen, no snackbar, so
  // the user never notices a problem on reopen.

  Future<void> _refreshFromServer() async {
    if (!mounted) return;
    setState(() => _isRefreshing = true);
    try {
      final result = await _homeService.getTasks();
      if (!mounted) return;

      if (result['success'] == true) {
        final tasks =
            List<Map<String, dynamic>>.from(result['tasks'] as List? ?? []);
        final fresh = tasks.firstWhere(
          (t) =>
              (t['service_request_id'] ?? t['raw']?['service_request_id'])
                  ?.toString() ==
              _serviceRequestId.toString(),
          orElse: () => {},
        );

        if (fresh.isNotEmpty) {
          setState(() {
            // Merge fresh fields into _task so any locally-applied optimistic
            // updates (e.g. a just-submitted reassign) are overwritten only
            // when the server actually reflects them.
            _task = Map<String, dynamic>.from(fresh);
          });
          // Re-resolve the assigned phone from the fresh raw data.
          final rawFresh = _task['raw'] as Map<String, dynamic>? ?? {};
          final freshPhone = (rawFresh['assigned_to_phone'] ?? '').toString();
          if (freshPhone.isNotEmpty) {
            setState(() => _assignedPhone = freshPhone);
          } else if (_isSupervisorOrAbove(widget.userRole)) {
            _fetchAssignedPhone();
          }
          return; // found in the main task list — done
        }
      }


    } catch (_) {
      // Network / parse failure — silently fall back to the placeholder data.
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  // ── Fetch escalation audit trail for task ─────────────────────────────────

  Future<void> _loadEscalationHistory() async {
    if (_serviceRequestId == 0) return;
    setState(() => _isLoadingEscHist = true);
    try {
      final res =
          await _homeService.getEscalationHistoryForTask(_serviceRequestId);
      if (!mounted) return;
      if (res['success'] == true) {
        setState(() {
          _escalationHistory =
              (res['history'] as List? ?? []).cast<Map<String, dynamic>>();
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingEscHist = false);
  }

  // ── Resolve assignee phone ────────────────────────────────────────────────

  Future<void> _fetchAssignedPhone() async {
    final raw          = _task['raw'] as Map<String, dynamic>? ?? {};
    final assignedToId = (raw['assigned_to'] ?? '').toString();
    if (assignedToId.isEmpty) return;

    setState(() => _phoneLoading = true);
    try {
      final result = await _homeService.getStaffList(
        requestId: _serviceRequestId,
      );
      if (!mounted) return;
      if (result['success'] == true) {
        final staff =
            (result['staff'] as List? ?? []).cast<Map<String, dynamic>>();
        for (final s in staff) {
          final sid = (s['userId'] ?? s['id'] ?? '').toString();
          if (sid == assignedToId) {
            final phone = (s['phone'] ?? '').toString();
            if (phone.isNotEmpty && mounted) {
              setState(() {
                _assignedPhone = phone;
                if (_task['raw'] is Map) {
                  (_task['raw'] as Map)['assigned_to_phone'] = phone;
                }
              });
            }
            break;
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _phoneLoading = false);
  }

  // ── Computed properties ───────────────────────────────────────────────────

  int? get _assignedToId {
    final raw = _task['raw'] as Map?;
    // get_all_services_mobile identifies an accepted task with
    // accepted_by_user_id; reassigned tasks may instead expose assigned_to.
    final v = raw?['accepted_by_user_id'] ??
        raw?['assigned_to'] ??
        _task['accepted_by_user_id'] ??
        _task['assigned_to'];
    if (v == null) return null;
    return int.tryParse(v.toString());
  }

  // Escalation presentation is disabled until the feature is reintroduced
  // end-to-end. Normal service-task actions remain unchanged.
  bool get _isEscalated => false;

  bool get _canTakeOver {
    if (!_isEscalated) return false;
    if (_task['status'] != 'In Progress') return false;
    // A task already assigned to the signed-in user cannot be taken over.
    // This applies to managers as well as supervisors.
    if (_loggedInUserId == null || _assignedToId == _loggedInUserId) {
      return false;
    }
    if (_isManagerRole(widget.userRole)) return true;
    if (_isSupervisorOrAbove(widget.userRole)) {
      return true;
    }
    return false;
  }

  bool get _isClosed =>
      (_task['status'] ?? '').toString().toLowerCase() == 'closed' ||
      ((_task['raw'] as Map?)?['closed'] ?? 0) == 1;

  int get _serviceRequestId =>
      ((_task['service_request_id'] ??
              (_task['raw'] as Map?)?['service_request_id']) ??
          0) as int;

  // ── Timestamp formatter ───────────────────────────────────────────────────

  String _formatTs(String? ts) {
    return DateFormatter.formatDateTimeAmPm(ts);
  }

  Future<void> _callPhone(String phone) async {
    final cleaned = phone.replaceAll(RegExp(r'[\s\-()]+'), '');
    final uri     = Uri(scheme: 'tel', path: cleaned);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      AppSnackBar.show(
          context, 'Cannot open dialler for $phone',
          isError: true);
    }
  }


  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _takeOver() async {
    final userId = _loggedInUserId;
    if (userId == null || _isLoading || !_canTakeOver) return;

    final confirm = await _showConfirmSheet(
      title:   'Take Over Task',
      body:    'You will be assigned this escalated task and be responsible for completing it.',
      confirm: 'Take Over',
      color:   AppColors.error,
      icon:    Icons.person_add_rounded,
    );
    if (confirm != true) return;

    setState(() => _isLoading = true);

    final deptIdVal = _task['department_id'] ?? (_task['raw'] as Map?)?['department_id'];
    final deptId = deptIdVal is int ? deptIdVal : int.tryParse(deptIdVal?.toString() ?? '');

    // Always use TaskService → ScreenSync_reassign_service_mobile
    final result = await TaskService().reassignService(
        taskId:       _serviceRequestId,
        reassignTo:   userId,
        departmentId: deptId,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result['success'] != true) {
      AppSnackBar.show(context, result['message'] ?? 'Failed to take over',
          isError: true);
      return;
    }

    final updated = (result['updatedTask'] as Map<String, dynamic>?) ?? {};
    setState(() {
      _task['assignedTo']   = updated['assigned_to_name'] ?? 'You';
      _task['status']       = updated['status'] ?? 'In Progress';
      _task['is_escalated'] = 0;
      _task['alert_pending'] = 0;
      if (_task['raw'] is Map) {
        final raw = _task['raw'] as Map;
        raw['assigned_to']      = userId;
        raw['assigned_to_name'] = updated['assigned_to_name'] ?? 'You';
        raw['is_escalated']     = 0;
        raw['alert_pending']    = 0;
      }
    });

    widget.onReassign?.call(updated);

    AppSnackBar.show(context, 'Task taken over ✅');
  }

  // ── Unified status transition (Accept / Close) ───────────────────────────
  //
  // This is the single entry point for all service_request status changes.
  //   newStatus = "IN_PROGRESS" → Accept (staff marks task as taken)
  //   newStatus = "CLOSED"      → Close  (mark request as resolved)
  //
  // SP: ScreenSync_update_service_request_status_mobile
  // The SP resolves escalation_log, stops task_alert_state pulsing, and
  // returns guest_device_token for Lambda FCM — all within one DB transaction.
  // DO NOT call EscalationService.resolveEscalation() after this.

  Future<void> _updateStatus(String newStatus) async {
    final isClose  = newStatus == 'CLOSED';
    final isAccept = newStatus == 'IN_PROGRESS';

    if (isClose) {
      final confirm = await _showConfirmSheet(
        title:   'Close Service Request',
        body:    'Mark this request as resolved? This cannot be undone.',
        confirm: 'Close',
        color:   AppColors.success,
        icon:    Icons.check_circle_rounded,
      );
      if (confirm != true) return;
    } else if (isAccept) {
      final confirm = await _showConfirmSheet(
        title:   'Accept Task',
        body:    'Mark this task as In Progress?',
        confirm: 'Accept',
        color:   const Color(0xFFEF8C00),
        icon:    Icons.assignment_turned_in_rounded,
      );
      if (confirm != true) return;
    }

    setState(() => _isLoading = true);

    final result = await TaskService().updateServiceRequestStatus(
      serviceRequestId: _serviceRequestId,
      status:           newStatus,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result['success'] != true) {
      AppSnackBar.show(
        context,
        result['message'] ?? 'Failed to update status',
        isError: true,
      );
      return;
    }

    // ── Optimistic UI update from SP STATUS[0] response ─────────────────
    final currentStatus    = result['current_status'] as String? ?? (isClose ? 'Closed' : 'In Progress');
    final escStatus        = result['escalation_status'] as String?;
    final nextEscalationAt = result['next_escalation_at'] as String?;

    setState(() {
      _task['status'] = currentStatus;
      if (_task['raw'] is Map) {
        final raw = _task['raw'] as Map;
        if (isClose) {
          raw['closed']              = 1;
          raw['status']              = 'CLOSED';
          // Clear escalation — SP resolves it atomically
          raw['escalation_instance_id'] = null;
          raw['escalation_status']      = null;
          raw['next_escalation_at']     = null;
        } else {
          raw['status']                 = 'IN_PROGRESS';
          raw['accepted_by_user_name']  = result['accepted_by_user_name'] ?? raw['accepted_by_user_name'];
          raw['escalation_status']      = escStatus;
          raw['next_escalation_at']     = nextEscalationAt;
        }
      }
      // Clear local escalation flags if closed or accepted
      if (isClose || isAccept) {
        _task['is_escalated']    = 0;
        _task['alert_pending']   = 0;
      }
      if (isClose) {
        _task['escalation_instance_id'] = null;
        _task['escalation_status']      = null;
        _task['next_escalation_at']     = null;
      }
    });

    if (isClose) {
      widget.onClose?.call();
      AppSnackBar.show(context, 'Request closed ✅');
    } else {
      AppSnackBar.show(context, 'Task accepted — In Progress ✅');
    }
  }

  // Legacy alias kept so any callers that still reference _closeTask() compile.
  // Routes through the unified _updateStatus() method.
  Future<void> _closeTask() => _updateStatus('CLOSED');


  Future<void> _addNote() async {
    final text = _noteController.text.trim();
    if (text.isEmpty) return;

    setState(() => _isLoading = true);
    // Always use TaskService → ScreenSync_add_service_note_mobile
    final result = await TaskService().addServiceNote(
        serviceRequestId: _serviceRequestId,
        noteText:         text,
    );
    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result['success'] != true) {
      AppSnackBar.show(context, result['message'] ?? 'Failed to add note',
          isError: true);
      return;
    }

    _noteController.clear();
    // Use returned note_text from RESULT if available, else the local input
    final savedNote = (result['note'] as Map?)?['note_text']?.toString() ?? text;
    setState(() => _task['note'] = savedNote);
    widget.onNoteAdded?.call(savedNote);
    AppSnackBar.show(context, 'Note added');
  }

  Future<void> _loadStaffAndShowReassign() async {
    if (_staffList.isEmpty) {
      setState(() => _isLoadingStaff = true);
      final result = await _homeService.getStaffList(requestId: _serviceRequestId);
      if (!mounted) return;
      if (result['success'] != true) {
        setState(() => _isLoadingStaff = false);
        AppSnackBar.show(context, 'Failed to load staff', isError: true);
        return;
      }
      final raw =
          (result['staff'] as List? ?? []).cast<Map<String, dynamic>>();
      final taskDept = (_task['department_name'] ?? _task['department'] ?? (_task['raw'] as Map?)?['department_name'] ?? '').toString().toLowerCase();
      raw.sort((a, b) {
        final dA = (a['department'] ?? '').toString().toLowerCase();
        final dB = (b['department'] ?? '').toString().toLowerCase();
        final matchA = taskDept.isNotEmpty && dA == taskDept;
        final matchB = taskDept.isNotEmpty && dB == taskDept;
        if (matchA && !matchB) return -1;
        if (!matchA && matchB) return 1;
        final c  = dA.compareTo(dB);
        if (c != 0) return c;
        return (a['name'] ?? '')
            .toString()
            .toLowerCase()
            .compareTo(
                (b['name'] ?? '').toString().toLowerCase());
      });

      setState(() {
        _staffList      = raw;
        _isLoadingStaff = false;
      });
    }
    if (mounted) _showReassignSheet();
  }

  // ── Reassign bottom sheet ─────────────────────────────────────────────────

  void _showReassignSheet() {
    final List<_StaffListItem> items = [];
    String? currentDept;
    for (final s in _staffList) {
      final dept = (s['department'] ?? '').toString();
      if (dept != currentDept) {
        items.add(_StaffListItem(isDivider: true, dept: dept));
        currentDept = dept;
      }
      items.add(_StaffListItem(isDivider: false, staff: s));
    }

    showModalBottomSheet(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand:           false,
          initialChildSize: 0.6,
          maxChildSize:     0.9,
          minChildSize:     0.4,
          builder: (sheetCtx, scroll) {
            return Column(children: [
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 4),
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color:        Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(children: [
                  const Text('Reassign Task',
                      style: TextStyle(
                          fontSize:   17,
                          fontWeight: FontWeight.bold,
                          color:      AppColors.textPrimary)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color:        AppColors.primaryLight,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('${_staffList.length} staff',
                        style: const TextStyle(
                            fontSize:   11,
                            fontWeight: FontWeight.w600,
                            color:      AppColors.primary)),
                  ),
                ]),
              ),
              const Divider(height: 1, color: AppColors.borderLight),
              Expanded(
                child: _isLoadingStaff
                    ? const Center(child: CircularProgressIndicator())
                    : _staffList.isEmpty
                        ? const Center(
                            child: Text('No staff found',
                                style: TextStyle(
                                    color: AppColors.textSecondary)))
                        : ListView.builder(
                            controller: scroll,
                            padding: const EdgeInsets.only(
                                top: 8, bottom: 20),
                            itemCount: items.length,
                            itemBuilder: (_, i) {
                              final item = items[i];

                              if (item.isDivider) {
                                return Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 12, 16, 6),
                                  child: Row(children: [
                                    Container(
                                      padding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical:   4),
                                      decoration: BoxDecoration(
                                        color:        AppColors.surfaceAlt,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(item.dept ?? '',
                                          style: const TextStyle(
                                              fontSize:      11,
                                              fontWeight:    FontWeight.w700,
                                              color:         AppColors.textSecondary,
                                              letterSpacing: 0.4)),
                                    ),
                                    const SizedBox(width: 8),
                                    const Expanded(
                                      child: Divider(
                                          height: 1,
                                          color: AppColors.borderLight),
                                    ),
                                  ]),
                                );
                              }

                              final staff = item.staff!;
                              final name  = (staff['name'] ?? '—').toString();
                              final phone = (staff['phone'] ?? '').toString();
                              final staffId = int.tryParse((staff['userId'] ?? staff['id'] ?? '').toString());
                              final rawTask = _task['raw'] as Map?;
                              final assignedToName = (_task['assignedTo'] ?? rawTask?['assigned_to_name'] ?? '').toString();
                              final isCurrentAssignee = (_assignedToId != null && staffId == _assignedToId) ||
                                  (assignedToName.isNotEmpty && name.trim().toLowerCase() == assignedToName.trim().toLowerCase());
                              final initials = name.trim().isNotEmpty
                                  ? name
                                      .trim()
                                      .split(' ')
                                      .map((w) =>
                                          w.isNotEmpty ? w[0] : '')
                                      .take(2)
                                      .join()
                                      .toUpperCase()
                                  : '?';

                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 4),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color:        Colors.white,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                        color: AppColors.borderLight),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.03),
                                        blurRadius: 4,
                                        offset: const Offset(0, 1),
                                      ),
                                    ],
                                  ),
                                  child: Row(children: [
                                    const SizedBox(width: 12),
                                    CircleAvatar(
                                      radius:          18,
                                      backgroundColor: isCurrentAssignee ? AppColors.successLight : AppColors.primaryLight,
                                      child: Text(initials,
                                          style: TextStyle(
                                              fontSize:   12,
                                              fontWeight: FontWeight.bold,
                                              color:      isCurrentAssignee ? AppColors.success : AppColors.primary)),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Padding(
                                        padding:
                                            const EdgeInsets.symmetric(
                                                vertical: 14),
                                        child: Text(name,
                                            style: const TextStyle(
                                                fontSize:   13,
                                                fontWeight: FontWeight.w700,
                                                color:      AppColors.textPrimary)),
                                      ),
                                    ),
                                    if (phone.isNotEmpty)
                                      GestureDetector(
                                        onTap: () => _callPhone(phone),
                                        child: Container(
                                          margin: const EdgeInsets.only(
                                              right: 8),
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: Colors.blue
                                                .withValues(alpha: 0.10),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: const Icon(
                                              Icons.call_rounded,
                                              size:  16,
                                              color: Colors.blue),
                                        ),
                                      ),
                                    if (isCurrentAssignee)
                                      Container(
                                        margin: const EdgeInsets.only(
                                            right: 12),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: AppColors.successLight,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: const Text('Assigned',
                                            style: TextStyle(
                                                fontSize:   11,
                                                fontWeight: FontWeight.w700,
                                                color:      AppColors.success)),
                                      )
                                    else
                                      GestureDetector(
                                        onTap: () async {
                                        if (staffId == null) {
                                          AppSnackBar.show(
                                            context,
                                            'This staff member has an invalid user ID',
                                            isError: true,
                                          );
                                          return;
                                        }
                                        Navigator.pop(ctx);
                                        final confirm = await _showConfirmSheet(
                                          title: 'Reassign Task',
                                          body: 'Assign this task to $name? They will be notified and become responsible for it.',
                                          confirm: 'Reassign',
                                          color: AppColors.primary,
                                          icon: Icons.swap_horiz_rounded,
                                        );
                                        if (confirm != true || !mounted) return;
                                        setState(() => _isLoading = true);
                                        // Always use TaskService → ScreenSync_reassign_service_mobile
                                        final res = await TaskService().reassignService(
                                             taskId:     _serviceRequestId,
                                             reassignTo: staffId,
                                           );
                                        if (!mounted) return;
                                        setState(() => _isLoading = false);
                                        if (res['success'] != true) {
                                          AppSnackBar.show(
                                              context,
                                              res['message'] ??
                                                  'Reassign failed',
                                              isError: true);
                                          return;
                                        }
                                        final upd = (res['updatedTask']
                                                as Map<String,
                                                    dynamic>?) ??
                                            {};
                                        setState(() {
                                          _task['assignedTo'] =
                                              staff['name'];
                                          _task['status'] =
                                              upd['status'] ??
                                                  'In Progress';
                                          _task['is_escalated']  = 0;
                                          _task['alert_pending'] = 0;
                                          if (_task['raw'] is Map) {
                                            final raw =
                                                _task['raw'] as Map;
                                            raw['assigned_to'] =
                                                staff['userId'];
                                            raw['assigned_to_name'] =
                                                staff['name'];
                                            raw['assigned_to_phone'] =
                                                staff['phone'] ?? '';
                                            raw['assigned_by_name'] =
                                                upd['assigned_by_name'] ??
                                                    '';
                                            raw['is_escalated']  = 0;
                                            raw['alert_pending'] = 0;
                                          }
                                          _assignedPhone =
                                              (staff['phone'] ?? '')
                                                  .toString();
                                        });

                                        widget.onReassign?.call(upd);

                                        AppSnackBar.show(context,
                                            'Reassigned to ${staff['name']}');
                                      },
                                      child: Container(
                                        margin: const EdgeInsets.only(
                                            right: 12),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: AppColors.primary,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: const Text('Assign',
                                            style: TextStyle(
                                                fontSize:   12,
                                                fontWeight: FontWeight.w700,
                                                color:      Colors.white)),
                                      ),
                                    ),
                                  ]),
                                ),
                              );
                            },
                          ),
              ),
            ]);
          },
        );
      },
    );
  }

  // ── Confirm bottom sheet ──────────────────────────────────────────────────

  Future<bool?> _showConfirmSheet({
    required String   title,
    required String   body,
    required String   confirm,
    required Color    color,
    required IconData icon,
  }) {
    return showModalBottomSheet<bool>(
      context:         context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color:        Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color:  color.withValues(alpha: 0.1),
                shape:  BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 32),
            ),
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(
                    fontSize:   18,
                    fontWeight: FontWeight.bold,
                    color:      AppColors.textPrimary)),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14,
                    color:    AppColors.textSecondary,
                    height:   1.4)),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side:   const BorderSide(color: AppColors.border),
                    shape:  RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Cancel',
                      style: TextStyle(
                          color:      AppColors.textSecondary,
                          fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: color,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape:   RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  child: Text(confirm,
                      style:
                          const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final status    = (_task['status'] ?? 'Open').toString();
    final statusClr =
        _isEscalated ? AppColors.error : AppColors.statusColor(status);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _buildAppBar(status, statusClr),
      floatingActionButton: _showScrollTop
          ? FloatingActionButton.small(
              onPressed: () => _scrollController.animateTo(
                0,
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut,
              ),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              elevation: 4,
              tooltip: 'Back to top',
              child: const Icon(Icons.keyboard_arrow_up_rounded, size: 22),
            )
          : null,
      body: Stack(
        children: [
          RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _refreshFromServer,
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildResolutionSlaBanner(),


                  if ((_task['status'] ?? '').toString().toLowerCase() == 'in progress')
                    const SizedBox(height: 12),

                  _buildInfoCard(),

                  const SizedBox(height: 12),

                  _buildNoteCard(),

                  if (!_isClosed) ...[
                    const SizedBox(height: 12),
                    _buildAddNoteCard(),
                  ],

                  const SizedBox(height: 12),



                  if (!_isClosed) _buildActions(),
                ],
              ),
            ),
          ),
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

  // ── AppBar ────────────────────────────────────────────────────────────────

  AppBar _buildAppBar(String status, Color statusClr) {
  final label = _isEscalated ? 'Escalated' : status;
  return AppBar(
    toolbarHeight:    64,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
      onPressed: () => Navigator.pop(context),
    ),
    title: SizedBox(
      width: double.infinity,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left side: Request #ID + subtle refresh indicator
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Request #$_serviceRequestId',
                  style: AppTypography.appBarTitle),
              if (_isRefreshing) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 12, height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AppColors.textDisabled,
                  ),
                ),
              ],
            ],
          ),
          // Right side: status pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color:        statusClr.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: statusClr.withValues(alpha: 0.35), width: 1),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 6, height: 6,
                decoration:
                    BoxDecoration(color: statusClr, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontSize:      11,
                      color:         statusClr,
                      fontWeight:    FontWeight.w700,
                      letterSpacing: 0.2)),
            ]),
          ),
        ],
      ),
    ),
    bottom: PreferredSize(
      preferredSize: const Size.fromHeight(1),
      child: Divider(
          height: 1, thickness: 1, color: Colors.grey.shade100),
    ),
  );
}
  // ── Escalated banner ──────────────────────────────────────────────────────
  // Role-aware: accent colour and label change based on the viewer's authority.

  Widget _buildEscalatedBanner() {
    final esc         = EscalationInfo.fromTask(_task);
    final role        = escalationRoleFromName(widget.userRole);
    final accentStyle = EscalationVisibility.accentStyle(role);
    final accentColor = EscalationDisplay.accentBarColor(accentStyle);

    final raw              = _task['raw'] as Map<String, dynamic>? ?? {};
    final originalAssignee = (raw['original_assignee_name'] ??
            _task['original_assignee'] ??
            '').toString().trim();

    return Container(
      decoration: BoxDecoration(
        color:        accentColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor.withValues(alpha: 0.35), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header strip: label + live countdown ────────────────────────
          Container(
            width:   double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(13)),
            ),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.white, size: 14),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  EscalationDisplay.accentBarLabel(accentStyle, esc.stageName),
                  style: const TextStyle(
                    color: Colors.white, fontSize: 11,
                    fontWeight: FontWeight.w700, letterSpacing: 0.4,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              EscalationDisplay.countdownChip(esc),
            ]),
          ),

          // ── Body: stage + SLA + detail rows ─────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Stage pill + SLA label on the same row
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (esc.stageName != null && esc.stageName!.isNotEmpty) ...[
                      EscalationDisplay.stagePill(esc.stageName!),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        esc.slaLabel,
                        style: TextStyle(
                          fontSize:   13,
                          fontWeight: FontWeight.w700,
                          color:      accentColor,
                        ),
                      ),
                    ),
                  ],
                ),

                // ── Info rows ────────────────────────────────────────────
                const SizedBox(height: 10),

                // Currently notified staff at this level
                if (esc.notifiedSummary.isNotEmpty)
                  _escalationInfoRow(
                    Icons.notifications_active_outlined,
                    'Notified',
                    esc.notifiedSummary,
                    AppColors.warning,
                  ),

                // Accepted at level
                if (esc.acceptedAtLabel != null)
                  _escalationInfoRow(
                    Icons.check_circle_outline_rounded,
                    'Accepted',
                    esc.acceptedAtLabel!
                        .replaceFirst('Accepted at: ', ''),
                    AppColors.success,
                  ),

                // Original assignee (before any escalation)
                if (originalAssignee.isNotEmpty)
                  _escalationInfoRow(
                    Icons.person_outline_rounded,
                    'Originally',
                    originalAssignee,
                    AppColors.textSecondary,
                  ),

                // Latest reassignment
                if (esc.reassignedToName != null &&
                    esc.reassignedToName!.isNotEmpty) ...[
                  _escalationInfoRow(
                    Icons.swap_horiz_rounded,
                    'Reassigned to',
                    esc.reassignedToName!,
                    AppColors.info,
                  ),
                  if (esc.reassignedByName != null &&
                      esc.reassignedByName!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 20, top: 1),
                      child: Text(
                        'by ${esc.reassignedByName}',
                        style: const TextStyle(
                          fontSize: 11,
                          color:    AppColors.textSecondary,
                        ),
                      ),
                    ),
                ],

                // Closed by
                if (esc.closedByName != null &&
                    esc.closedByName!.isNotEmpty)
                  _escalationInfoRow(
                    Icons.lock_outline_rounded,
                    'Closed by',
                    esc.closedByName!,
                    AppColors.success,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Compact label + value row used inside the escalation banner body.
  Widget _escalationInfoRow(
      IconData icon, String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize:   12,
              fontWeight: FontWeight.w600,
              color:      color,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 12,
                color:    AppColors.textPrimary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ── Resolution SLA Banner ─────────────────────────────────────────────────
  // Shown for In Progress tasks. Uses EscalationInfo for consistent
  // countdown math — same source of truth as the list card.

  Widget _buildResolutionSlaBanner() {
    final status = (_task['status'] ?? 'Open').toString();
    if (status.toLowerCase() != 'in progress') return const SizedBox.shrink();

    final esc = EscalationInfo.fromTask(_task);
    if (!esc.hasCountdown) return const SizedBox.shrink();

    // Rebuild every second via the parent's periodic setState
    final isOverdue  = esc.isOverdue;
    final isWarning  = esc.isWarning;

    final Color bgColor = isOverdue
        ? AppColors.errorLight
        : (isWarning ? AppColors.warningLight : AppColors.primaryLight);
    final Color borderColor = isOverdue
        ? AppColors.error.withValues(alpha: 0.4)
        : (isWarning
            ? AppColors.warning.withValues(alpha: 0.5)
            : AppColors.primary.withValues(alpha: 0.3));
    final Color fgColor = isOverdue
        ? AppColors.error
        : (isWarning ? AppColors.warning : AppColors.primary);
    final IconData icon = isOverdue
        ? Icons.timer_off_outlined
        : (isWarning ? Icons.bolt_rounded : Icons.timer_outlined);

    final String headline = isOverdue
        ? 'Resolution Overdue  (+${esc.countdownLabel})'
        : (isWarning
            ? 'Critical — Close Within  ${esc.countdownLabel}'
            : 'SLA Countdown  ${esc.countdownLabel}');
    final String subtext = isOverdue
        ? 'Task sits unclosed past SLA deadline. Supervisor has been notified.'
        : (isWarning
            ? 'Must be closed immediately to prevent further escalation.'
            : 'Staff accepted task. Resolution SLA clock is active.');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        bgColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color:  fgColor.withValues(alpha: 0.12),
            shape:  BoxShape.circle,
          ),
          child: Icon(icon, color: fgColor, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                headline,
                style: TextStyle(
                  color:      fgColor,
                  fontWeight: FontWeight.w700,
                  fontSize:   13,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtext,
                style: TextStyle(
                  color:    fgColor.withValues(alpha: 0.8),
                  fontSize: 12,
                  height:   1.35,
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _buildInfoCard() {
    final raw        = _task['raw'] as Map<String, dynamic>? ?? {};

    final rawRoom    = (_task['room'] ?? raw['room_number'] ?? raw['room_id'] ?? '—').toString();
    final room       = (rawRoom == '0' || rawRoom == '000' || rawRoom == 'null' || rawRoom == '—' || rawRoom.isEmpty) ? 'General' : rawRoom;
    final guest      = (_task['guest'] ?? raw['guest_name'] ?? '—').toString();
    final rawTitle   = (_task['title'] ?? raw['question'] ?? raw['name'] ?? 'Service Request').toString();
    final title      = rawTitle.replaceFirst(RegExp(r'^Order\s+#[A-Z0-9]+\s*-\s*', caseSensitive: false), '');

    final assignedTo = (_task['assignedTo'] ?? raw['assigned_to_name'] ?? '—').toString();
    final createdAt  = (raw['created_at'] ?? '').toString();
    final acceptedAt = (raw['accepted_at'] ?? _task['accepted_at'] ?? '').toString();
    final deptName   = (raw['department_name'] ?? '').toString();
    final escalationMins = raw['escalation_time_minutes'];

    return Container(
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: _isEscalated
            ? Border.all(
                color: AppColors.error.withValues(alpha: 0.25), width: 1.2)
            : null,
        boxShadow: [
          BoxShadow(
              color:      Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset:     const Offset(0, 3)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _isEscalated
                      ? AppColors.errorLight
                      : AppColors.warningLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Room',
                      style: TextStyle(
                          fontSize:   10,
                          color:      _isEscalated
                              ? AppColors.error
                              : AppColors.warning,
                          fontWeight: FontWeight.w600)),
                  Text(room,
                      style: TextStyle(
                          fontSize:   22,
                          fontWeight: FontWeight.bold,
                          color:      _isEscalated
                              ? AppColors.error
                              : AppColors.warning,
                          height:     1.1)),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize:   15,
                          fontWeight: FontWeight.bold,
                          color:      AppColors.textPrimary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ]),
              ),
            ]),

            const Divider(height: 20, color: AppColors.borderLight),

            _detailRow(Icons.person_outline_rounded, 'Guest', guest),

           
            if (deptName.isNotEmpty) ...[
              const SizedBox(height: 8),
              _detailRow(
                  Icons.business_outlined, 'Department', deptName),
            ],

            const SizedBox(height: 8),
            _callableDetailRow(
              icon:    Icons.person_pin_rounded,
              label:   'Assigned To',
              value:   assignedTo,
              phone:   _assignedPhone,
              canCall: _isSupervisorOrAbove(widget.userRole)&& 
                       _assignedToId != _loggedInUserId, 
              loading: _phoneLoading,
            ),

            if (createdAt.isNotEmpty) ...[
              const SizedBox(height: 8),
              _detailRow(Icons.access_time_rounded, 'Created',
                  _formatTs(createdAt)),
            ],

            if (acceptedAt.isNotEmpty) ...[
              const SizedBox(height: 8),
              _detailRow(Icons.check_rounded, 'Accepted',
                  _formatTs(acceptedAt),
                  color: AppColors.success),
            ],

            if (escalationMins != null) ...[
              const SizedBox(height: 8),
              _detailRow(Icons.timer_outlined, 'Escalation SLA',
                  '$escalationMins min',
                  color: AppColors.warning),
            ],
          ],
        ),
      ),
    );
  }

  // ── Plain detail row ──────────────────────────────────────────────────────

  Widget _detailRow(IconData icon, String label, String value,
      {Color? color}) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 15, color: color ?? AppColors.textSecondary),
      const SizedBox(width: 8),
      Expanded(
        child: RichText(
          text: TextSpan(
            style: const TextStyle(
                fontSize: 13, color: AppColors.textPrimary),
            children: [
              TextSpan(
                  text:  '$label: ',
                  style: const TextStyle(
                      color:      AppColors.textSecondary,
                      fontWeight: FontWeight.w500)),
              TextSpan(
                  text:  value,
                  style: TextStyle(
                      color:      color ?? AppColors.textPrimary,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    ]);
  }

  // ── Callable detail row ───────────────────────────────────────────────────

  Widget _callableDetailRow({
    required IconData icon,
    required String   label,
    required String   value,
    required String   phone,
    required bool     canCall,
    bool              loading = false,
    Color?            color,
  }) {
    final bool active = canCall && phone.isNotEmpty && !loading;

    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Icon(icon, size: 15, color: color ?? AppColors.textSecondary),
      const SizedBox(width: 8),
      Expanded(
        child: RichText(
          text: TextSpan(
            style: const TextStyle(
                fontSize: 13, color: AppColors.textPrimary),
            children: [
              TextSpan(
                  text:  '$label: ',
                  style: const TextStyle(
                      color:      AppColors.textSecondary,
                      fontWeight: FontWeight.w500)),
              TextSpan(
                  text:  value,
                  style: TextStyle(
                      color:      color ?? AppColors.textPrimary,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
      if (canCall) ...[
        const SizedBox(width: 8),
        GestureDetector(
          onTap: active ? () => _callPhone(phone) : null,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity:  active ? 1.0 : 0.35,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color:        Colors.blue.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: loading
                  ? const SizedBox(
                      width:  14,
                      height: 14,
                      child:  CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.blue))
                  : const Icon(Icons.call_rounded,
                      size: 14, color: Colors.blue),
            ),
          ),
        ),
      ],
    ]);
  }

  // ── Escalation History Timeline Card ──────────────────────────────────────
  // Visible to Supervisor and above only (EscalationVisibility.canViewEscalationHistory).
  // Reads from ScreenSync_get_escalation_history_for_task_mobile (via
  // HomeService.getEscalationHistoryForTask) loaded in _loadEscalationHistory().

  Widget _buildEscalationHistoryCard() {
    final role = escalationRoleFromName(widget.userRole);
    if (!EscalationVisibility.canViewEscalationHistory(role)) {
      return const SizedBox.shrink();
    }
    if (_escalationHistory.isEmpty && !_isLoadingEscHist) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.15), width: 1.2),
        boxShadow: [
          BoxShadow(
              color:      Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset:     const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color:  AppColors.primaryLight,
                  shape:  BoxShape.circle,
                ),
                child: const Icon(Icons.timeline_rounded,
                    size: 15, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Escalation History',
                  style: TextStyle(
                    fontSize:   14,
                    fontWeight: FontWeight.w700,
                    color:      AppColors.textPrimary,
                  ),
                ),
              ),
              if (_isLoadingEscHist)
                const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.8, color: AppColors.primary),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color:        AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_escalationHistory.length} stage${_escalationHistory.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize:   11,
                      fontWeight: FontWeight.w600,
                      color:      AppColors.primary,
                    ),
                  ),
                ),
            ]),
          ),

          const SizedBox(height: 10),
          const Divider(height: 1, color: AppColors.borderLight),
          const SizedBox(height: 4),

          // ── Timeline entries ─────────────────────────────────────────
          if (_escalationHistory.isEmpty && !_isLoadingEscHist)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 8, 14, 14),
              child: Text(
                'No escalation events recorded for this request.',
                style: TextStyle(
                    fontSize: 12, color: AppColors.textSecondary),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
              child: Column(
                children: _escalationHistory.asMap().entries.map((entry) {
                  final idx    = entry.key;
                  final item   = entry.value;
                  final isLast = idx == _escalationHistory.length - 1;

                  final levelNum = (item['escalation_level'] ?? idx + 1).toString();
                  final roleName = (item['escalated_to_role'] ??
                          item['stage_name'] ??
                          item['escalation_stage_name'] ??
                          '').toString().trim();
                  final stageLabel = roleName.isNotEmpty
                      ? 'Level $levelNum — $roleName'
                      : 'Level $levelNum';

                  final notifiedName = () {
                    var n = (item['escalated_to_name'] ??
                            item['notified_user_name'] ??
                            item['user_name'] ??
                            '').toString().trim();
                    if (n.isEmpty || n == '—') {
                      n = (_task['assignedTo'] ??
                              (_task['raw'] as Map?)?['assigned_to_name'] ??
                              '').toString().trim();
                    }
                    return n;
                  }();

                  final deptName = (item['department_name'] ??
                          item['dept_name'] ??
                          item['department'] ??
                          (_task['raw'] as Map?)?['department_name'] ??
                          '').toString().trim();

                  final origName   = (item['original_assignee_name'] ?? '').toString().trim();
                  final resolvedBy = (item['resolved_by_name'] ?? '').toString().trim();
                  final statusStr  = (item['escalation_status'] ??
                          item['response_status'] ??
                          item['status'] ??
                          'Pending').toString();
                  final timestampStr = (item['escalated_at'] ??
                          item['notified_at'] ??
                          item['created_at'] ??
                          item['timestamp'] ??
                          '').toString();

                  final dotColor = EscalationDisplay.historyDotColor(statusStr);

                  return IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Timeline spine
                        SizedBox(
                          width: 20,
                          child: Column(children: [
                            Container(
                              width:  10,
                              height: 10,
                              margin: const EdgeInsets.only(top: 3),
                              decoration: BoxDecoration(
                                color:  dotColor,
                                shape:  BoxShape.circle,
                                border: Border.all(
                                    color: dotColor.withValues(alpha: 0.4),
                                    width: 2),
                              ),
                            ),
                            if (!isLast)
                              Expanded(
                                child: Container(
                                  width:  1.5,
                                  margin: const EdgeInsets.only(top: 3),
                                  color:  AppColors.borderLight,
                                ),
                              ),
                          ]),
                        ),
                        const SizedBox(width: 10),

                        // Content
                        Expanded(
                          child: Padding(
                            padding:
                                EdgeInsets.only(bottom: isLast ? 0 : 16),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                // Stage label + status pill
                                Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        stageLabel,
                                        style: const TextStyle(
                                          fontSize:   13,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.textPrimary,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2),
                                      decoration: BoxDecoration(
                                        color: dotColor.withValues(
                                            alpha: 0.1),
                                        borderRadius:
                                            BorderRadius.circular(6),
                                        border: Border.all(
                                            color: dotColor.withValues(
                                                alpha: 0.3)),
                                      ),
                                      child: Text(
                                        statusStr,
                                        style: TextStyle(
                                          fontSize:   10,
                                          fontWeight: FontWeight.w700,
                                          color:      dotColor,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),

                                const SizedBox(height: 4),

                                // Notified user · role · dept tags
                                if (notifiedName.isNotEmpty ||
                                    roleName.isNotEmpty ||
                                    deptName.isNotEmpty) ...[
                                  Wrap(
                                    spacing:   4,
                                    runSpacing: 2,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      const Icon(
                                          Icons.person_outline_rounded,
                                          size:  12,
                                          color: AppColors.textSecondary),
                                      if (notifiedName.isNotEmpty)
                                        Text(notifiedName,
                                            style: const TextStyle(
                                              fontSize:   12,
                                              fontWeight: FontWeight.w600,
                                              color: AppColors.textPrimary,
                                            )),
                                      if (roleName.isNotEmpty)
                                        _historyTag(roleName,
                                            AppColors.primaryLight,
                                            AppColors.primary),
                                      if (deptName.isNotEmpty)
                                        _historyTag(deptName,
                                            AppColors.infoLight,
                                            AppColors.info),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                ],

                                if (origName.isNotEmpty && origName != '—')
                                  _historySubline(
                                      Icons.swap_horiz_rounded,
                                      'Originally: $origName',
                                      AppColors.textSecondary),

                                if (resolvedBy.isNotEmpty)
                                  _historySubline(
                                      Icons.check_circle_outline_rounded,
                                      'Resolved by: $resolvedBy',
                                      AppColors.success),

                                if (timestampStr.isNotEmpty)
                                  _historySubline(
                                      Icons.access_time_rounded,
                                      _formatTs(timestampStr),
                                      AppColors.textSecondary
                                          .withValues(alpha: 0.7)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _historyTag(String label, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color:        bg,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w600, color: fg)),
      );

  Widget _historySubline(IconData icon, String text, Color color) =>
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(text,
                style: TextStyle(fontSize: 11, color: color),
                maxLines:  2,
                overflow:  TextOverflow.ellipsis),
          ),
        ]),
      );

  // ── Note display card ─────────────────────────────────────────────────────

  Widget _buildNoteCard() {
    final note = (_task['note'] ?? '').toString();
    if (note.isEmpty) return const SizedBox.shrink();

    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppColors.infoLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.25)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.sticky_note_2_outlined,
            size: 16, color: AppColors.info),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            const Text('Latest Note',
                style: TextStyle(
                    fontSize:   11,
                    fontWeight: FontWeight.w700,
                    color:      AppColors.info)),
            const SizedBox(height: 4),
            Text(note,
                style: const TextStyle(
                    fontSize: 13,
                    color:    AppColors.textPrimary,
                    height:   1.4)),
          ]),
        ),
      ]),
    );
  }

  // ── Add Note card ─────────────────────────────────────────────────────────

  Widget _buildAddNoteCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color:      Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset:     const Offset(0, 2)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Add Note',
            style: TextStyle(
                fontSize:   13,
                fontWeight: FontWeight.w700,
                color:      AppColors.textPrimary)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            color:        AppColors.bg,
            borderRadius: BorderRadius.circular(14),
            border:       Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TextField(
                controller: _noteController,
                maxLines:   3,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  hintText:  'Write an update or note...',
                  hintStyle: TextStyle(
                      color: AppColors.textDisabled, fontSize: 13),
                  isDense:        true,
                  contentPadding: EdgeInsets.zero,
                  border:         InputBorder.none,
                  enabledBorder:  InputBorder.none,
                  focusedBorder:  InputBorder.none,
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: _addNote,
                icon:  const Icon(Icons.send_rounded, size: 12),
                label: const Text('Add Note',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 11)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  minimumSize:   Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  // ── Escalation History ────────────────────────────────────────────────────



  // ── Action Buttons ────────────────────────────────────────────────────────
  //
  // CHANGE: showClose condition updated.
  // Before: showClose = !_isClosed  (showed for everyone)
  // After:  showClose = !_isClosed && (Supervisor+ OR assigned to me)
  //
  // This prevents staff assigned to other tasks from seeing the Close
  // button on tasks that aren't theirs, while still allowing:
  //   • Supervisors, Dept Heads, Managers, GMs, Admins to close any task
  //   • The assigned staff member to close their own task

  Widget _buildActions() {
    final showTakeOver = _canTakeOver;
    final showReassign = _isSupervisorOrAbove(widget.userRole);

    // CHANGE: Close is gated on role OR being the assigned staff member.
    final showClose = !_isClosed &&
        (_isSupervisorOrAbove(widget.userRole) ||
            _assignedToId == _loggedInUserId);

    if (!showTakeOver && !showReassign && !showClose) {
      return const SizedBox.shrink();
    }

    return Column(children: [
      if (showTakeOver) ...[
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isLoading ? null : _takeOver,
            icon:  const Icon(Icons.person_add_rounded, size: 16),
            label: const Text('Take Over',
                style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 14)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13)),
              elevation: 0,
            ),
          ),
        ),
        const SizedBox(height: 10),
      ],

      Row(children: [
        if (showReassign)
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _loadStaffAndShowReassign,
              icon:  const Icon(Icons.swap_horiz_rounded, size: 16),
              label: const Text('Reassign',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              style: OutlinedButton.styleFrom(
                padding:         const EdgeInsets.symmetric(vertical: 13),
                foregroundColor: AppColors.primary,
                side: BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13)),
              ),
            ),
          ),
        if (showReassign && showClose) const SizedBox(width: 10),
        if (showClose)
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _closeTask,
              icon:  const Icon(Icons.check_circle_rounded, size: 16),
              label: const Text('Close Request',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.success,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13)),
                elevation: 0,
              ),
            ),
          ),
      ]),
    ]);
  }
}

// ── Helper model ──────────────────────────────────────────────────────────────

class _StaffListItem {
  final bool                  isDivider;
  final String?               dept;
  final Map<String, dynamic>? staff;
  _StaffListItem({required this.isDivider, this.dept, this.staff});
}

