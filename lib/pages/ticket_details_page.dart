// ticket_details_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/dialog_helpers.dart';
import '../services/home_service.dart';
import '../utils/user_session_helper.dart';
import '../utils/app_colors.dart';
import '../utils/app_snackbar.dart';

// Role hierarchy helper (mirrors home_page.dart)
const _roleHierarchy = [
  'Staff', 'Supervisor', 'Department Head', 'Manager', 'General Manager', 'Admin',
];
bool _isManagerRole(String? role) {
  if (role == null) return false;
  return _roleHierarchy.indexOf(role) >= 2;
}

class TicketDetailPage extends StatefulWidget {
  final Map<String, dynamic> task;
  final String userRole;
  final VoidCallback onClose;
  final Function(Map<String, dynamic> updatedTask)? onReassign;

  const TicketDetailPage({
    super.key,
    required this.task,
    this.userRole = "",
    required this.onClose,
    this.onReassign,
  });

  @override
  State<TicketDetailPage> createState() => _TicketDetailPageState();
}

class _TicketDetailPageState extends State<TicketDetailPage> {
  late Map<String, dynamic> task;
  int? loggedInUserId;

  Map<String, dynamic>? _reassignedStaff;

  /// Phone number resolved for the currently assigned staff member.
  /// Starts from raw data; falls back to a staff-list lookup in initState.
  String _resolvedPhone = "";
  bool   _phoneLoading  = false;

  late Timer _ticker;

  @override
  void initState() {
    super.initState();
    task = Map<String, dynamic>.from(widget.task);
    _loadUserId();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // Seed from raw immediately, then try to resolve from staff list
    final raw = task["raw"] as Map<String, dynamic>? ?? {};
    _resolvedPhone = raw["assigned_to_phone"] as String? ?? "";
    if (_resolvedPhone.isEmpty) _fetchAssignedPhone();
  }

  /// Looks up the assigned staff member's phone via the staff list API.
  Future<void> _fetchAssignedPhone() async {
    final raw          = task["raw"] as Map<String, dynamic>? ?? {};
    final assignedToId = raw["assigned_to"]?.toString() ?? "";
    if (assignedToId.isEmpty) return;

    setState(() => _phoneLoading = true);
    try {
      final result = await HomeService().getStaffList();
      if (!mounted) return;
      if (result["success"] == true) {
        final staffList = List<Map<String, dynamic>>.from(result["staff"] as List? ?? []);
        for (final s in staffList) {
          final sid = s["userId"]?.toString() ?? s["id"]?.toString() ?? "";
          if (sid == assignedToId) {
            final phone = s["phone"] as String? ?? "";
            if (phone.isNotEmpty) {
              setState(() {
                _resolvedPhone = phone;
                // Also write back so reassign flow picks it up
                task["raw"]["assigned_to_phone"] = phone;
              });
            }
            break;
          }
        }
      }
    } catch (_) {
      // Silent — call button stays shown, will fail gracefully on tap
    } finally {
      if (mounted) setState(() => _phoneLoading = false);
    }
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  Future<void> _loadUserId() async {
    loggedInUserId = await UserSessionHelper.getUserId();
    if (mounted) setState(() {});
  }

  // ── Escalation ─────────────────────────────────────────────────────────────

  int? _escalationOverdueSeconds() {
    final raw     = task["raw"] as Map<String, dynamic>? ?? {};
    final escMins = raw["escalation_time_minutes"];
    if (escMins == null) return null;
    final minutes = int.tryParse(escMins.toString());
    if (minutes == null || minutes <= 0) return null;
    final acceptedAtStr = raw["accepted_at"] as String? ?? raw["updated_at"] as String? ?? "";
    if (acceptedAtStr.isEmpty) return null;
    final acceptedAt = _parseTs(acceptedAtStr);
    final deadline   = acceptedAt.add(Duration(minutes: minutes));
    final diff       = DateTime.now().difference(deadline);
    return diff.inSeconds > 0 ? diff.inSeconds : null;
  }

  int? _escalationRemainingSeconds() {
    final raw     = task["raw"] as Map<String, dynamic>? ?? {};
    final escMins = raw["escalation_time_minutes"];
    if (escMins == null) return null;
    final minutes = int.tryParse(escMins.toString());
    if (minutes == null || minutes <= 0) return null;
    final acceptedAtStr = raw["accepted_at"] as String? ?? raw["updated_at"] as String? ?? "";
    if (acceptedAtStr.isEmpty) return null;
    final acceptedAt = _parseTs(acceptedAtStr);
    final deadline   = acceptedAt.add(Duration(minutes: minutes));
    final remaining  = deadline.difference(DateTime.now()).inSeconds;
    return remaining > 0 ? remaining : null;
  }

  String _formatDuration(int seconds, {bool isOverdue = false}) {
    final suffix = isOverdue ? ' overdue' : ' left';
    if (seconds < 60)   return '${seconds}s$suffix';
    if (seconds < 3600) return '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s$suffix';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return '${h}h ${m}m$suffix';
  }

  // ── Timestamp helpers ──────────────────────────────────────────────────────

  DateTime _parseTs(String ts) {
    try {
      String f = ts.trim();
      if (f.contains(' ') && !f.contains('T')) f = f.replaceFirst(' ', 'T');
      return DateTime.parse(f);
    } catch (_) {
      return DateTime.now();
    }
  }

  /// Returns formatted date/time matching reference: "29/04/2026 · 7:15 PM"
  String _formatDateTime(String ts) {
    if (ts.isEmpty) return "";
    final dt = _parseTs(ts);

    final dd   = dt.day.toString().padLeft(2, '0');
    final mm   = dt.month.toString().padLeft(2, '0');
    final yyyy = dt.year.toString();

    final hour12  = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute  = dt.minute.toString().padLeft(2, '0');
    final amPm    = dt.hour < 12 ? 'AM' : 'PM';

    return "$dd/$mm/$yyyy · $hour12:$minute $amPm";
  }

  /// Not used for display anymore — kept for potential future use
  String _timeAgoShort(String ts) {
    if (ts.isEmpty) return "";
    final dt   = _parseTs(ts);
    final diff = DateTime.now().difference(dt);
    if (diff.isNegative || diff.inSeconds < 5) return "Just now";
    if (diff.inSeconds < 60)  return "${diff.inSeconds}s ago";
    if (diff.inMinutes < 60)  return "${diff.inMinutes}m ago";
    if (diff.inHours   < 24)  return "${diff.inHours}h ago";
    return "${diff.inDays}d ago";
  }

  // ── Phone call ─────────────────────────────────────────────────────────────

  Future<void> _callPhone(String phone) async {
    // Strip spaces/dashes so the tel: URI is clean
    final cleaned = phone.replaceAll(RegExp(r'[\s\-()]+'), '');
    final uri = Uri(scheme: 'tel', path: cleaned);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        AppSnackBar.show(context, "Cannot open dialler for $phone", isError: true);
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final status    = (task["status"] ?? "").toString();
    final statusClr = AppColors.statusColor(status);
    final raw       = task["raw"] as Map<String, dynamic>? ?? {};
    final createdAt = raw["created_at"] as String? ?? task["created_at"] as String? ?? "";
    final note      = task["note"] as String? ?? raw["note_text"] as String? ?? "";

    final assignedToName  = task["assignedTo"] as String? ?? raw["assigned_to_name"]  as String? ?? "-";
    final assignedToPhone = _resolvedPhone.isNotEmpty
        ? _resolvedPhone
        : (raw["assigned_to_phone"] as String? ?? _reassignedStaff?["phone"] as String? ?? "");
    final assignedByName  = raw["assigned_by_name"]  as String? ?? "";

    final overdueSecs   = _escalationOverdueSeconds();
    final remainingSecs = _escalationRemainingSeconds();
    final isEscalated   = overdueSecs != null;
    final hasEscTimer   = overdueSecs != null || remainingSecs != null;
    final isManager     = _isManagerRole(widget.userRole);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: CustomScrollView(
          slivers: [
            // ── App bar ───────────────────────────────────────────────
            SliverAppBar(
              pinned: true,
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: AppColors.textPrimary),
                onPressed: () => Navigator.pop(context),
              ),
              title: const Text(
                "Task Detail",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
              ),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: _StatusChip(status: status, color: statusClr),
                ),
              ],
            ),

            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // ── Escalation banner ─────────────────────────────
                    if (hasEscTimer && status == "In Progress") ...[
                      _EscalationBanner(
                        isEscalated:    isEscalated,
                        overdueSecs:    overdueSecs,
                        remainingSecs:  remainingSecs,
                        assignedName:   assignedToName,
                        assignedPhone:  assignedToPhone,
                        isManager:      isManager,
                        formatDuration: _formatDuration,
                        onCall:         _callPhone,
                      ),
                      const SizedBox(height: 12),
                    ],

                    // ── Hero card ─────────────────────────────────────
                    _HeroCard(
                      task:        task,
                      createdAt:   createdAt,
                      formattedDateTime: _formatDateTime(createdAt),
                      timeAgoShort: _timeAgoShort(createdAt),
                      statusColor: statusClr,
                    ),

                    const SizedBox(height: 12),

                    // ── Assignment card ───────────────────────────────
                    _AssignmentCard(
                      assignedToName:  assignedToName,
                      assignedToPhone: assignedToPhone,
                      assignedByName:  assignedByName,
                      reassignedStaff: _reassignedStaff,
                      phoneLoading:    _phoneLoading,
                      onCall:          _callPhone,
                    ),

                    // ── Note ─────────────────────────────────────────
                    if (note.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _NoteCard(note: note),
                    ],

                    const SizedBox(height: 20),

                    // ── Actions ───────────────────────────────────────
                    _buildActions(context, status, raw, isManager),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Action area ────────────────────────────────────────────────────────────

  Widget _buildActions(BuildContext context, String status, Map<String, dynamic> raw, bool isManager) {
    final isClosed       = status.toLowerCase() == "closed";
    final assignedToId   = int.tryParse("${raw["assigned_to"]}");
    final isAssignedToMe = assignedToId == loggedInUserId;

    if (isClosed) return _ClosedBanner();

    final canAct = isAssignedToMe || isManager;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _OutlineActionButton(
                icon: Icons.edit_note_rounded,
                label: "Add Note",
                enabled: isAssignedToMe,
                onTap: () => _addNotes(context),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _OutlineActionButton(
                icon: Icons.swap_horiz_rounded,
                label: "Reassign",
                enabled: canAct,
                onTap: () => _reassign(context),
              ),
            ),
          ],
        ),

        if (isAssignedToMe) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _closeTicket(context),
              icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
              label: const Text(
                "Close Ticket",
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],

        if (!canAct)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.info_outline_rounded, size: 13, color: AppColors.textDisabled),
                SizedBox(width: 5),
                Text(
                  "Assigned to another team member",
                  style: TextStyle(fontSize: 12, color: AppColors.textDisabled),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ── Action handlers ────────────────────────────────────────────────────────

  Future<void> _closeTicket(BuildContext context) async {
    final confirmed = await showConfirmSheet(
      context,
      title: "Close Ticket",
      message: "Are you sure you want to close this ticket? This action cannot be undone.",
      confirmLabel: "Close Ticket",
      cancelLabel: "Cancel",
      icon: Icons.check_circle_outline_rounded,
      confirmColor: AppColors.primary,
    );
    if (confirmed != true || !mounted) return;
    _showLoader();
    final result = await HomeService().closeServiceRequest(
        serviceRequestId: task["raw"]["service_request_id"]);
    if (!mounted) return;
    Navigator.pop(context);
    if (!result["success"]) {
      AppSnackBar.show(context, "Failed to close ticket", isError: true);
      return;
    }
    setState(() {
      task["status"] = "Closed";
      task["statusColor"] = AppColors.success;
    });
    AppSnackBar.show(context, "Ticket closed successfully");
    widget.onClose();
  }

  Future<void> _addNotes(BuildContext context) async {
    final text = await showAddNotesSheet(context);
    if (text == null || text.isEmpty || !mounted) return;
    _showLoader();
    final result = await HomeService().addNote(
        serviceRequestId: task["raw"]["service_request_id"], noteText: text);
    if (!mounted) return;
    Navigator.pop(context);
    if (!result["success"]) {
      AppSnackBar.show(context, "Failed to add note", isError: true);
      return;
    }
    AppSnackBar.show(context, "Note added successfully");
  }

  Future<void> _reassign(BuildContext context) async {
    _showLoader();
    final staffResult = await HomeService().getStaffList();
    if (!mounted) return;
    Navigator.pop(context);
    if (!staffResult["success"]) {
      AppSnackBar.show(context, "Failed to load staff", isError: true);
      return;
    }

    final staffList = List<Map<String, dynamic>>.from(staffResult["staff"]);

    // Sort alphabetically: department first, then name within department
    staffList.sort((a, b) {
      final deptA = (a["department"] as String? ?? "").toLowerCase();
      final deptB = (b["department"] as String? ?? "").toLowerCase();
      final deptCmp = deptA.compareTo(deptB);
      if (deptCmp != 0) return deptCmp;
      final nameA = (a["name"] as String? ?? "").toLowerCase();
      final nameB = (b["name"] as String? ?? "").toLowerCase();
      return nameA.compareTo(nameB);
    });

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _ReassignWithCallSheet(
        staffList: staffList,
        onSelect: (staff) async {
          Navigator.pop(context);
          _showLoader();
          final apiResult = await HomeService().reassignTicket(
            ticketId:       task["raw"]["service_request_id"],
            assignedUserId: staff["userId"],
          );
          if (!mounted) return;
          Navigator.pop(context);
          if (!apiResult["success"]) {
            AppSnackBar.show(context, "Reassign failed", isError: true);
            return;
          }
          setState(() {
            task["assignedTo"]               = apiResult["updatedTask"]["assigned_to_name"] ?? "-";
            task["raw"]["assigned_to_phone"] = staff["phone"] ?? "";
            task["raw"]["assigned_to_name"]  = apiResult["updatedTask"]["assigned_to_name"] ?? "-";
            task["raw"]["assigned_by_name"]  = apiResult["updatedTask"]["assigned_by_name"] ?? "";
            _reassignedStaff = staff;
            _resolvedPhone   = staff["phone"] as String? ?? "";
          });
          AppSnackBar.show(context, "Reassigned to ${staff["name"]}");
          widget.onReassign?.call(apiResult["updatedTask"]);
        },
        onCall: _callPhone,
      ),
    );
  }

  void _showLoader() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(strokeWidth: 3, color: AppColors.primary),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Escalation banner widget
// ─────────────────────────────────────────────────────────────────────────────

class _EscalationBanner extends StatelessWidget {
  final bool     isEscalated;
  final int?     overdueSecs;
  final int?     remainingSecs;
  final String   assignedName;
  final String   assignedPhone;
  final bool     isManager;
  final String   Function(int, {bool isOverdue}) formatDuration;
  final Future<void> Function(String) onCall;

  const _EscalationBanner({
    required this.isEscalated,
    required this.overdueSecs,
    required this.remainingSecs,
    required this.assignedName,
    required this.assignedPhone,
    required this.isManager,
    required this.formatDuration,
    required this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    final color = isEscalated ? AppColors.error : AppColors.warning;
    final icon  = isEscalated ? Icons.warning_amber_rounded : Icons.timer_outlined;
    final label = isEscalated
        ? formatDuration(overdueSecs!, isOverdue: true)
        : formatDuration(remainingSecs!, isOverdue: false);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isEscalated ? "Escalated" : "Escalation Timer",
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: color),
                ),
                Text(
                  label,
                  style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.8), fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          if (isManager && isEscalated && assignedPhone.isNotEmpty)
            GestureDetector(
              onTap: () => onCall(assignedPhone),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.call_rounded, size: 14, color: Colors.white),
                    const SizedBox(width: 5),
                    Text(
                      assignedName.isNotEmpty ? assignedName.split(' ').first : "Call",
                      style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reassign bottom sheet — no task title, sorted staff, department grouping
// ─────────────────────────────────────────────────────────────────────────────

class _ReassignWithCallSheet extends StatelessWidget {
  final List<Map<String, dynamic>> staffList;
  final Future<void> Function(Map<String, dynamic>) onSelect;
  final Future<void> Function(String) onCall;

  const _ReassignWithCallSheet({
    required this.staffList,
    required this.onSelect,
    required this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    // Build department-grouped list for display
    final List<_StaffListItem> items = [];
    String? currentDept;

    for (final staff in staffList) {
      final dept = staff["department"] as String? ?? "";
      if (dept != currentDept) {
        items.add(_StaffListItem(isDivider: true, dept: dept));
        currentDept = dept;
      }
      items.add(_StaffListItem(isDivider: false, staff: staff));
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.88,
      expand: false,
      builder: (_, controller) => Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header — just the title, no task name
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(
              children: [
                const Text(
                  "Reassign Task",
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    "${staffList.length} staff",
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.primary),
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1, color: AppColors.borderLight),

          Expanded(
            child: ListView.builder(
              controller: controller,
              itemCount: items.length,
              padding: const EdgeInsets.only(top: 8, bottom: 20),
              itemBuilder: (_, i) {
                final item = items[i];

                // Department header divider
                if (item.isDivider) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            item.dept ?? "",
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textSecondary,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Expanded(child: Divider(height: 1, color: AppColors.borderLight)),
                      ],
                    ),
                  );
                }

                final staff  = item.staff!;
                final name   = staff["name"]  as String? ?? "-";
                final phone  = staff["phone"] as String? ?? "";
                final initials = name.trim().isNotEmpty
                    ? name.trim().split(' ').map((w) => w[0]).take(2).join().toUpperCase()
                    : "?";

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.borderLight),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: AppColors.primaryLight,
                          child: Text(
                            initials,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                        ),

                        // Call button
                        if (phone.isNotEmpty)
                          GestureDetector(
                            onTap: () => onCall(phone),
                            child: Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: AppColors.successLight,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.call_rounded, size: 16, color: AppColors.success),
                            ),
                          ),

                        // Assign button
                        GestureDetector(
                          onTap: () => onSelect(staff),
                          child: Container(
                            margin: const EdgeInsets.only(right: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              "Assign",
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
                            ),
                          ),
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
}

/// Helper model for grouped list rendering
class _StaffListItem {
  final bool isDivider;
  final String? dept;
  final Map<String, dynamic>? staff;

  _StaffListItem({required this.isDivider, this.dept, this.staff});
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final String status;
  final Color  color;
  const _StatusChip({required this.status, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(status, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11)),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  final Map<String, dynamic> task;
  final String createdAt;
  final String formattedDateTime;
  final String timeAgoShort;
  final Color  statusColor;

  const _HeroCard({
    required this.task,
    required this.createdAt,
    required this.formattedDateTime,
    required this.timeAgoShort,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    final room      = task["room"]?.toString() ?? "-";
    final title     = task["title"] as String? ?? "";
    final guestName = (task["raw"]?["guest_name"] ?? task["guest_name"] ?? "") as String;
    final deptName  = (task["raw"]?["department_name"] ?? task["department"] ?? "") as String;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _MiniPill("Room $room", AppColors.warningLight, AppColors.warning),
              const SizedBox(width: 8),
              if (deptName.isNotEmpty) _MiniPill(deptName, AppColors.primaryLight, AppColors.accent),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
              height: 1.25,
            ),
          ),
          if (guestName.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.person_outline_rounded, size: 14, color: AppColors.textSecondary),
                const SizedBox(width: 5),
                Text(
                  guestName,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          const Divider(height: 1, color: AppColors.borderLight),
          const SizedBox(height: 10),

          // ── Date/time row — calendar icon + DD/MM/YYYY · h:mm AM/PM ──
          Row(
            children: [
              const Icon(Icons.calendar_today_rounded, size: 13, color: AppColors.textDisabled),
              const SizedBox(width: 5),
              Text(
                formattedDateTime,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textDisabled,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Assignment card — redesigned
// Shows: "Assigned to" with person circle icon + call button (theme color)
//        "Assigned by" with person circle icon (no call button)
// ─────────────────────────────────────────────────────────────────────────────

class _AssignmentCard extends StatelessWidget {
  final String assignedToName;
  final String assignedToPhone;
  final String assignedByName;
  final Map<String, dynamic>? reassignedStaff;
  final bool   phoneLoading;
  final Future<void> Function(String) onCall;

  const _AssignmentCard({
    required this.assignedToName,
    required this.assignedToPhone,
    required this.assignedByName,
    required this.reassignedStaff,
    required this.phoneLoading,
    required this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Assigned To ──────────────────────────────────────────────
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.person_rounded, size: 20, color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Assigned to",
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      assignedToName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),

              // Call button — always shown; shows spinner while phone is loading
              GestureDetector(
                onTap: phoneLoading || assignedToPhone.isEmpty
                    ? null
                    : () => onCall(assignedToPhone),
                child: Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: assignedToPhone.isNotEmpty
                        ? AppColors.primaryLight
                        : AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: phoneLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.primary,
                          ),
                        )
                      : Icon(
                          Icons.call_rounded,
                          size: 18,
                          color: assignedToPhone.isNotEmpty
                              ? AppColors.primary
                              : AppColors.textDisabled,
                        ),
                ),
              ),
            ],
          ),

          // ── Assigned By ──────────────────────────────────────────────
          if (assignedByName.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Divider(height: 1, color: AppColors.borderLight),
            const SizedBox(height: 14),
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person_rounded, size: 20, color: AppColors.textSecondary),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Assigned by",
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      assignedByName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  final String note;
  const _NoteCard({required this.note});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.15)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.sticky_note_2_outlined, size: 16, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Note",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(note, style: const TextStyle(fontSize: 13, color: AppColors.textPrimary, height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ClosedBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.successLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.25)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_rounded, size: 16, color: AppColors.success),
          SizedBox(width: 8),
          Text(
            "Ticket Closed",
            style: TextStyle(color: AppColors.success, fontWeight: FontWeight.w700, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _OutlineActionButton extends StatelessWidget {
  final IconData icon;
  final String   label;
  final bool     enabled;
  final VoidCallback onTap;
  const _OutlineActionButton({required this.icon, required this.label, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: enabled ? 1.0 : 0.4,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: AppColors.primary),
              const SizedBox(width: 7),
              Text(
                label,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  final String text;
  final Color  bg;
  final Color  fg;
  const _MiniPill(this.text, this.bg, this.fg);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}