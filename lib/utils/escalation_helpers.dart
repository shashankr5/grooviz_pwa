// lib/utils/escalation_helpers.dart
//
// Single source of truth for:
//  • Role hierarchy and role-level comparisons
//  • Escalation visibility rules (who sees what based on role + dept)
//  • Escalation data extraction from task maps
//  • Escalation display helpers (labels, colors, SLA countdown)
//
// All escalation UI layers import from here — no more duplicated role
// constants scattered across home_page, ticket_details, timeline_task_card.

import 'dart:convert';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

// ── Role hierarchy ────────────────────────────────────────────────────────────
//
// Index 0 = lowest, 5 = highest.
// Numeric role_id from DB is INVERSE: Staff=6, Admin=1.
// Use escalationRoleFromName() / escalationRoleFromId() to normalise.

enum EscalationRole {
  staff,        // index 0  — DB role_id 6
  supervisor,   // index 1  — DB role_id 5
  deptHead,     // index 2  — DB role_id 4
  manager,      // index 3  — DB role_id 3
  gm,           // index 4  — DB role_id 2
  admin,        // index 5  — DB role_id 1
}

// ── Top-level factory functions (extensions cannot have static members) ───────

EscalationRole escalationRoleFromName(String? name) {
  switch ((name ?? '').trim().toLowerCase()) {
    case 'admin':           return EscalationRole.admin;
    case 'general manager': return EscalationRole.gm;
    case 'manager':         return EscalationRole.manager;
    case 'department head': return EscalationRole.deptHead;
    case 'supervisor':      return EscalationRole.supervisor;
    default:                return EscalationRole.staff;
  }
}

EscalationRole escalationRoleFromId(int? id) {
  // DB role_id: 1=Admin, 2=GM, 3=Manager, 4=DeptHead, 5=Supervisor, 6=Staff
  switch (id) {
    case 1: return EscalationRole.admin;
    case 2: return EscalationRole.gm;
    case 3: return EscalationRole.manager;
    case 4: return EscalationRole.deptHead;
    case 5: return EscalationRole.supervisor;
    default: return EscalationRole.staff;
  }
}

extension EscalationRoleX on EscalationRole {
  int get level => index; // 0–5, higher = more authority

  bool get isManagerOrAbove    => level >= EscalationRole.manager.level;
  bool get isSupervisorOrAbove => level >= EscalationRole.supervisor.level;
  bool get isDeptHeadOrAbove   => level >= EscalationRole.deptHead.level;

  String get displayName {
    switch (this) {
      case EscalationRole.staff:      return 'Staff';
      case EscalationRole.supervisor: return 'Supervisor';
      case EscalationRole.deptHead:   return 'Department Head';
      case EscalationRole.manager:    return 'Manager';
      case EscalationRole.gm:         return 'General Manager';
      case EscalationRole.admin:      return 'Admin';
    }
  }
}

// ── Escalation visibility rules ───────────────────────────────────────────────

class EscalationVisibility {
  /// Whether this role should see the "Escalated" KPI tile and filter.
  static bool canViewEscalatedTab(EscalationRole role) => true;

  /// Whether this role defaults to the Escalated filter on home page open.
  static bool defaultsToEscalated(EscalationRole role) =>
      role.isManagerOrAbove;

  /// Whether this role can take over (reassign) an escalated task.
  static bool canTakeOver(EscalationRole role) =>
      role.isSupervisorOrAbove;

  /// Whether the escalation accent bar on a task card should be shown.
  /// Staff see a softer "Pending attention" variant; Supervisor+ see the
  /// full "SLA breached" message.
  static EscalationAccentStyle accentStyle(EscalationRole role) {
    if (role.isManagerOrAbove)   return EscalationAccentStyle.critical;
    if (role.isSupervisorOrAbove) return EscalationAccentStyle.warning;
    return EscalationAccentStyle.info;
  }

  /// Whether a task is visible to this user given their departments.
  /// Managers and above see all tasks regardless of department.
  static bool taskVisibleForDept({
    required EscalationRole role,
    required List<String> userDepts,
    required String? taskDept,
  }) {
    if (role.isManagerOrAbove) return true;
    if (taskDept == null || taskDept.isEmpty) return true;
    final td = taskDept.toLowerCase().trim();
    return userDepts.any((d) => d.toLowerCase().trim() == td);
  }
}

enum EscalationAccentStyle { info, warning, critical }

// ── Task-map escalation extractor ─────────────────────────────────────────────
//
// All fields come from get_all_services_mobile RESULT rows mapped by
// HomeService._mapTasks(). No additional network call is ever made here.

class EscalationInfo {
  // ── Current escalation state ──────────────────────────────────────────────
  final bool    isEscalated;
  final int?    instanceId;       // escalation_instance_id
  final int?    stageId;          // current_stage_id
  final String? stageName;        // current_stage_name  e.g. "Level 2 – Supervisor"
  final int?    stageLevel;       // current_stage_level  e.g. 2
  final String? escalationStatus; // "Working" | "Completed" | null
  final DateTime? nextEscalationAt; // <-- ALWAYS IN UTC (from server)
  final int?    escalationTimeMinutes;

  // ── Who is currently being notified ──────────────────────────────────────
  // Parsed from current_stage_users_json — first name shown inline on cards.
  final String?       currentNotifiedName;  // display name of lead notified user
  final List<String>  currentNotifiedNames; // all names at current stage

  // ── Acceptance ────────────────────────────────────────────────────────────
  final int?    acceptedStageLevel; // level at which the task was accepted
  final String? acceptedStageName;  // name of that level

  // ── Closure ───────────────────────────────────────────────────────────────
  final String? closedByName; // closed_by_user_name

  // ── Most recent reassignment ──────────────────────────────────────────────
  final String?   reassignedToName;   // recent_reassigned_to_user_name
  final String?   reassignedByName;   // recent_reassigned_by_user_name
  final DateTime? reassignedAt;       // recent_reassigned_at

  const EscalationInfo({
    required this.isEscalated,
    this.instanceId,
    this.stageId,
    this.stageName,
    this.stageLevel,
    this.escalationStatus,
    this.nextEscalationAt,
    this.escalationTimeMinutes,
    this.currentNotifiedName,
    this.currentNotifiedNames = const [],
    this.acceptedStageLevel,
    this.acceptedStageName,
    this.closedByName,
    this.reassignedToName,
    this.reassignedByName,
    this.reassignedAt,
  });

  static const EscalationInfo none = EscalationInfo(isEscalated: false);

  // ── Factory ───────────────────────────────────────────────────────────────

  /// Build from the task map produced by HomeService._mapTasks().
  /// Returns [EscalationInfo.none] when the task is not escalated.
  /// All timestamps are kept in UTC (no conversion) to avoid timezone errors.
  factory EscalationInfo.fromTask(Map<String, dynamic> task) {
    final raw = task['raw'] as Map? ?? {};

    // ── Is escalated? ────────────────────────────────────────────────────
    final instanceId = (task['escalation_instance_id'] ??
        raw['escalation_instance_id']) as int?;

    final isEscalated = task['is_escalated'] == 1 ||
        task['is_escalated'] == true ||
        raw['is_escalated'] == 1 ||
        raw['is_escalated'] == true ||
        instanceId != null;

    if (!isEscalated) return EscalationInfo.none;

    // ── SLA countdown ────────────────────────────────────────────────────
    // Try to get next_escalation_at from the task; fallback to accepted_at + escalation_time_minutes.
    // All times are kept in UTC (no .toLocal()) to avoid timezone errors.
    DateTime? nextAtUtc;
    final nextRaw = (task['next_escalation_at'] ??
            raw['next_escalation_at'] ?? '').toString();
    if (nextRaw.isNotEmpty && nextRaw != 'null') {
      final parsed = DateTime.tryParse(nextRaw.replaceAll(' ', 'T'));
      if (parsed != null) {
        nextAtUtc = parsed;
      }
    }

    // If next_escalation_at is missing, compute from accepted_at + escalation_time_minutes (UTC).
    if (nextAtUtc == null) {
      final acceptedAtRaw = (task['accepted_at'] ?? raw['accepted_at'] ?? '').toString();
      final mins = _parseInt(task['escalation_time_minutes'] ?? raw['escalation_time_minutes']);
      if (acceptedAtRaw.isNotEmpty && acceptedAtRaw != 'null' && mins != null && mins > 0) {
        final parsed = DateTime.tryParse(acceptedAtRaw.replaceAll(' ', 'T'));
        if (parsed != null) {
          // Keep as UTC (do not convert to local)
          nextAtUtc = parsed.add(Duration(minutes: mins));
        }
      }
    }

    // ── Reassigned at ────────────────────────────────────────────────────
    final reassignedAtRaw = (task['recent_reassigned_at'] ??
            raw['recent_reassigned_at'] ?? '').toString();
    DateTime? reassignedAt;
    if (reassignedAtRaw.isNotEmpty && reassignedAtRaw != 'null') {
      reassignedAt = DateTime.tryParse(reassignedAtRaw.replaceAll(' ', 'T'));
    }

    // ── Current stage users (parse JSON array) ───────────────────────────
    // current_stage_users_json is a JSON array of objects with a "name" key.
    // Extract display names for "Notified: X, Y" line on cards.
    final List<String> notifiedNames = _parseUserNames(
      task['current_stage_users_json'] ?? raw['current_stage_users_json'],
    );

    return EscalationInfo(
      isEscalated:           true,
      instanceId:            instanceId,
      stageId:               (task['current_stage_id'] ??
          raw['current_stage_id']) as int?,
      stageName:             (task['current_stage_name'] ??
              raw['current_stage_name'])
          ?.toString(),
      stageLevel:            _parseInt(task['current_stage_level'] ??
          raw['current_stage_level']),
      escalationStatus:      (task['escalation_status'] ??
              raw['escalation_status'])
          ?.toString(),
      nextEscalationAt:      nextAtUtc, // UTC
      escalationTimeMinutes: _parseInt(task['escalation_time_minutes'] ??
          raw['escalation_time_minutes']),
      currentNotifiedNames:  notifiedNames,
      currentNotifiedName:   notifiedNames.isNotEmpty ? notifiedNames.first : null,
      acceptedStageLevel:    _parseInt(task['accepted_stage_level'] ??
          raw['accepted_stage_level']),
      acceptedStageName:     (task['accepted_stage_name'] ??
              raw['accepted_stage_name'])
          ?.toString(),
      closedByName:          (task['closed_by_user_name'] ??
              raw['closed_by_user_name'])
          ?.toString(),
      reassignedToName:      (task['recent_reassigned_to_user_name'] ??
              raw['recent_reassigned_to_user_name'])
          ?.toString(),
      reassignedByName:      (task['recent_reassigned_by_user_name'] ??
              raw['recent_reassigned_by_user_name'])
          ?.toString(),
      reassignedAt:          reassignedAt,
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    return int.tryParse(v.toString());
  }

  /// Parse a JSON array value into a flat list of user name strings.
  /// Handles: null, already-decoded List, or raw JSON String.
  static List<String> _parseUserNames(dynamic raw) {
    if (raw == null) return const [];
    try {
      List<dynamic> list;
      if (raw is List) {
        list = raw;
      } else {
        // May be a JSON string from the DB
        final decoded = _tryDecodeJson(raw.toString());
        if (decoded is List) {
          list = decoded;
        } else {
          return const [];
        }
      }
      return list
          .whereType<Map>()
          .map((u) =>
              (u['name'] ?? u['user_name'] ?? u['username'] ?? '').toString().trim())
          .where((n) => n.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static dynamic _tryDecodeJson(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  // ── SLA countdown helpers ─────────────────────────────────────────────────

  bool get hasCountdown => nextEscalationAt != null;

  /// Remaining seconds until the next escalation, negative if overdue.
  /// All times are in UTC (no timezone conversion).
  int get remainingSeconds {
    if (nextEscalationAt == null) return 9999;
    // Both deadline and current time are UTC.
    return nextEscalationAt!.difference(DateTime.now().toUtc()).inSeconds;
  }

  bool get isOverdue  => hasCountdown && remainingSeconds <= 0;
  bool get isWarning  => hasCountdown && remainingSeconds > 0 && remainingSeconds <= 60;

  /// e.g. "05:30" or "+02:14" when overdue
  String get countdownLabel {
    final secs = remainingSeconds.abs();
    final mm   = (secs ~/ 60).toString().padLeft(2, '0');
    final ss   = (secs  % 60).toString().padLeft(2, '0');
    return isOverdue ? '+$mm:$ss' : '$mm:$ss';
  }

  /// Human-readable SLA line for banners/cards
  String get slaLabel {
    if (!hasCountdown) return stageName ?? 'Escalated';
    if (isOverdue) return '${remainingSeconds.abs() ~/ 60} min overdue';
    if (isWarning) return 'Due in < 1 min';
    return '${remainingSeconds ~/ 60} min remaining';
  }

  /// "Level 2 – Supervisor" or just "Level 2" when name is absent
  String get stageLevelLabel {
    if (stageLevel == null) return stageName ?? '';
    if (stageName != null && stageName!.isNotEmpty) return stageName!;
    return 'Level $stageLevel';
  }

  /// "Accepted at Level 2 – Supervisor" line for the detail banner
  String? get acceptedAtLabel {
    if (acceptedStageLevel == null) return null;
    if (acceptedStageName != null && acceptedStageName!.isNotEmpty) {
      return 'Accepted at: $acceptedStageName';
    }
    return 'Accepted at: Level $acceptedStageLevel';
  }

  /// Comma-joined list of currently notified users, capped at 3.
  String get notifiedSummary {
    if (currentNotifiedNames.isEmpty) return '';
    final shown = currentNotifiedNames.take(3).join(', ');
    final extra = currentNotifiedNames.length > 3
        ? ' +${currentNotifiedNames.length - 3}'
        : '';
    return '$shown$extra';
  }
}

// ── Escalation display helpers ────────────────────────────────────────────────

class EscalationDisplay {
  EscalationDisplay._();

  // ── Accent bar (top stripe on task card) ──────────────────────────────────

  static Color accentBarColor(EscalationAccentStyle style) {
    switch (style) {
      case EscalationAccentStyle.critical: return AppColors.error;
      case EscalationAccentStyle.warning:  return AppColors.warning;
      case EscalationAccentStyle.info:     return AppColors.info;
    }
  }

  static String accentBarLabel(EscalationAccentStyle style, String? stageName) {
    final stage = (stageName != null && stageName.isNotEmpty)
        ? '  ·  $stageName'
        : '';
    switch (style) {
      case EscalationAccentStyle.critical:
        return 'SLA BREACHED$stage — IMMEDIATE ACTION REQUIRED';
      case EscalationAccentStyle.warning:
        return 'SLA BREACHED$stage — SUPERVISOR ATTENTION';
      case EscalationAccentStyle.info:
        return 'ESCALATED$stage';
    }
  }

  // ── Card border / shadow ──────────────────────────────────────────────────

  static Border escalatedBorder() =>
      Border.all(color: AppColors.error.withOpacity(0.4), width: 1.5);

  static List<BoxShadow> escalatedShadow() => [
        BoxShadow(
          color:       AppColors.error.withOpacity(0.07),
          blurRadius:  12,
          offset:      const Offset(0, 4),
        ),
      ];

  // ── Stage pill ────────────────────────────────────────────────────────────

  static Widget stagePill(String stageName) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color:        AppColors.errorLight,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: AppColors.error.withOpacity(0.25), width: 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.layers_rounded,
              size: 11, color: AppColors.error),
          const SizedBox(width: 4),
          Text(
            stageName,
            style: const TextStyle(
              color:       AppColors.error,
              fontSize:    11,
              fontWeight:  FontWeight.w700,
              letterSpacing: 0.1,
            ),
          ),
        ]),
      );

  // ── Escalated status pill ─────────────────────────────────────────────────

  static Widget statusPill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color:        AppColors.errorLight,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.error.withOpacity(0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(
                color: AppColors.error, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          const Text(
            'Escalated',
            style: TextStyle(
              color:      AppColors.error,
              fontWeight: FontWeight.w700,
              fontSize:   11,
            ),
          ),
        ]),
      );

  // ── SLA countdown chip (inline on card) ───────────────────────────────────

  static Widget countdownChip(EscalationInfo esc) {
    if (!esc.hasCountdown) return const SizedBox.shrink();

    final color = esc.isOverdue
        ? AppColors.error
        : (esc.isWarning ? AppColors.warning : AppColors.primary);
    final bgColor = esc.isOverdue
        ? AppColors.errorLight
        : (esc.isWarning ? AppColors.warningLight : AppColors.primaryLight);
    final icon = esc.isOverdue
        ? Icons.timer_off_outlined
        : (esc.isWarning ? Icons.bolt_rounded : Icons.timer_outlined);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color:        bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(
          esc.countdownLabel,
          style: TextStyle(
            fontSize:    11,
            fontWeight:  FontWeight.w700,
            color:       color,
            letterSpacing: 0.2,
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EscalationView — new single source of truth for escalation UI
// ─────────────────────────────────────────────────────────────────────────────
//
// Built entirely from fields that arrive in ScreenSync_get_all_services_mobile1:
//   • is_escalated                    (top-level flag)
//   • escalation_enabled              (feature flag)
//   • escalation_time_minutes         (base SLA before any escalation)
//   • escalation_history              (JSON array of level entries)
//   • created_at / accepted_at / closed_at
//   • accepted_by_user_name / closed_by_user_name
//   • assigned_to_user_name / assigned_by_user_name
//
// Does NOT depend on the optional web-only fields such as current_stage_name,
// current_stage_users_json, or next_escalation_at.  When those fields are
// present they are ignored — the history array + the phase timestamps give us
// everything we need.

enum EscalationPhase { awaitingAcceptance, inProgress, closed }

enum SlaSeverity { onTrack, warning, overdue, escalated, neutral }

class EscalationChainStep {
  final int      level;
  final DateTime? escalatedAt;     // UTC
  final String?  toUserName;
  final String?  toRoleName;
  final int?     toRoleId;
  final List<String> fromUserNames;
  final String?  fromRoleName;
  final int?     acceptanceMinutes;
  final int?     completionMinutes;
  final bool     isCurrent;        // last entry when task is currently escalated

  const EscalationChainStep({
    required this.level,
    required this.isCurrent,
    this.escalatedAt,
    this.toUserName,
    this.toRoleName,
    this.toRoleId,
    this.fromUserNames = const [],
    this.fromRoleName,
    this.acceptanceMinutes,
    this.completionMinutes,
  });

  String get toLabel {
    if ((toUserName ?? '').isNotEmpty && (toRoleName ?? '').isNotEmpty) {
      return '$toRoleName · $toUserName';
    }
    if ((toRoleName ?? '').isNotEmpty) return toRoleName!;
    if ((toUserName ?? '').isNotEmpty) return toUserName!;
    return 'Level $level';
  }

  String get fromLabel {
    if (fromUserNames.isEmpty && (fromRoleName ?? '').isEmpty) return '';
    if (fromUserNames.isEmpty) return fromRoleName ?? '';
    final joined = fromUserNames.take(2).join(', ');
    final extra  = fromUserNames.length > 2 ? ' +${fromUserNames.length - 2}' : '';
    if ((fromRoleName ?? '').isEmpty) return '$joined$extra';
    return '$fromRoleName · $joined$extra';
  }
}

class EscalationDeadline {
  final DateTime deadline;        // UTC
  final int      quotaMinutes;
  final bool     isOverdue;
  final bool     isWarning;

  const EscalationDeadline({
    required this.deadline,
    required this.quotaMinutes,
    required this.isOverdue,
    required this.isWarning,
  });

  /// mm:ss (or +mm:ss when overdue)
  String get countdownText {
    final now = DateTime.now().toUtc();
    final remaining = deadline.difference(now).inSeconds;
    final s = remaining.abs();
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return remaining < 0 ? '+$mm:$ss' : '$mm:$ss';
  }

  /// Human readable urgency like "Due in 5 min" or "Overdue by 2 min"
  String get urgencyLabel {
    final now = DateTime.now().toUtc();
    final remaining = deadline.difference(now).inSeconds;
    if (remaining < 0) {
      final mins = remaining.abs() ~/ 60;
      return 'Overdue by ${mins <= 1 ? '1 min' : '$mins min'}';
    }
    if (remaining <= 60) return 'Due in < 1 min';
    final mins = remaining ~/ 60;
    return 'Due in ${mins <= 1 ? '1 min' : '$mins min'}';
  }
}

class EscalationView {
  // ── State ────────────────────────────────────────────────────────────────
  final bool             isEscalated;
  final EscalationPhase  phase;
  final int              currentLevel;        // 0 when not escalated
  final String?          currentUserName;     // to_user.user_name of latest step
  final String?          currentRoleName;     // to_user.role_name of latest step
  final String?          previousRoleName;    // from_user.role_name of latest step

  // ── Timing ───────────────────────────────────────────────────────────────
  final EscalationDeadline? deadline;  // deadline info with countdown text
  final int?      slaMinutesQuota;  // total minutes granted for this window

  // ── Audit ────────────────────────────────────────────────────────────────
  final String?  acceptedByName;
  final String?  closedByName;
  final List<EscalationChainStep> chain;

  const EscalationView._({
    required this.isEscalated,
    required this.phase,
    required this.currentLevel,
    required this.chain,
    this.currentUserName,
    this.currentRoleName,
    this.previousRoleName,
    this.deadline,
    this.slaMinutesQuota,
    this.acceptedByName,
    this.closedByName,
  });

  // ── Factory ──────────────────────────────────────────────────────────────

  factory EscalationView.fromTask(Map<String, dynamic> task) {
    final raw = (task['raw'] is Map) ? task['raw'] as Map : const {};

    // Phase ─────────────────────────────────────────────────────────────────
    final statusStr = (task['status'] ?? raw['status'] ?? 'Open')
        .toString()
        .toLowerCase();
    final closed = (raw['closed'] ?? task['closed'] ?? 0).toString();
    final acceptedAtUtc = _parseUtc(task['accepted_at'] ?? raw['accepted_at']);
    final createdAtUtc  = _parseUtc(task['created_at']  ?? raw['created_at']);
    final closedAtUtc   = _parseUtc(task['closed_at']   ?? raw['closed_at']);

    final EscalationPhase phase;
    if (statusStr == 'closed' || closed == '1' || closedAtUtc != null) {
      phase = EscalationPhase.closed;
    } else if (statusStr == 'in progress' || acceptedAtUtc != null) {
      phase = EscalationPhase.inProgress;
    } else {
      phase = EscalationPhase.awaitingAcceptance;
    }

    // Escalation flag ───────────────────────────────────────────────────────
    final instanceId = task['escalation_instance_id'] ?? raw['escalation_instance_id'];
    final isEscalated = task['is_escalated'] == 1 ||
        task['is_escalated'] == true ||
        raw['is_escalated'] == 1 ||
        raw['is_escalated'] == true ||
        (instanceId != null &&
            instanceId.toString().isNotEmpty &&
            instanceId.toString() != '0');

    // Chain ────────────────────────────────────────────────────────────────
    final rawHistory = task['escalation_history'] ?? raw['escalation_history'];
    final steps = _parseChain(rawHistory);

    // Names ────────────────────────────────────────────────────────────────
    final acceptedByName = _cleanString(task['accepted_by_user_name'] ??
        raw['accepted_by_user_name']);
    final closedByName = _cleanString(task['closed_by_user_name'] ??
        raw['closed_by_user_name']);

    // If not escalated we still may want to show timers, but no chain-derived
    // info.  Wire the base acceptance/completion window from
    // escalation_time_minutes.
    final baseMinutes = _parseInt(task['escalation_time_minutes'] ??
        raw['escalation_time_minutes']);

    if (!isEscalated) {
      final (deadlineUtc, quota) = _computeBaseWindow(
        phase:         phase,
        createdAt:     createdAtUtc,
        acceptedAt:    acceptedAtUtc,
        baseMinutes:   baseMinutes,
      );
      final escalationDeadline = deadlineUtc != null && quota != null
        ? EscalationDeadline(
            deadline: deadlineUtc,
            quotaMinutes: quota,
            isOverdue: deadlineUtc.difference(DateTime.now().toUtc()).inSeconds < 0,
            isWarning: deadlineUtc.difference(DateTime.now().toUtc()).inSeconds <= 60,
          )
        : null;
      
      return EscalationView._(
        isEscalated:     false,
        phase:           phase,
        currentLevel:    0,
        chain:           steps, // usually empty, occasionally has history
        acceptedByName:  acceptedByName,
        closedByName:    closedByName,
        deadline:        escalationDeadline,
        slaMinutesQuota: quota,
      );
    }

    // Escalated → drive from the latest chain step.
    final latest = steps.isNotEmpty ? steps.last : null;

    final currentLevel = latest?.level ?? 0;
    final currentRoleName = latest?.toRoleName;
    final currentUserName = latest?.toUserName;
    final previousRoleName = latest?.fromRoleName;

    // Deadline for escalated tasks -----------------------------------------
    EscalationDeadline? escalationDeadline;
    int? quotaMins;
    if (phase == EscalationPhase.closed) {
      escalationDeadline = null;
    } else if (phase == EscalationPhase.awaitingAcceptance &&
        latest?.escalatedAt != null) {
      final mins = latest!.acceptanceMinutes ?? baseMinutes;
      if (mins != null && mins > 0) {
        final deadlineUtc = latest.escalatedAt!.add(Duration(minutes: mins));
        escalationDeadline = EscalationDeadline(
          deadline: deadlineUtc,
          quotaMinutes: mins,
          isOverdue: deadlineUtc.difference(DateTime.now().toUtc()).inSeconds < 0,
          isWarning: deadlineUtc.difference(DateTime.now().toUtc()).inSeconds <= 60,
        );
        quotaMins = mins;
      }
    } else if (phase == EscalationPhase.inProgress && acceptedAtUtc != null) {
      final mins = latest?.completionMinutes ?? baseMinutes;
      if (mins != null && mins > 0) {
        final deadlineUtc = acceptedAtUtc.add(Duration(minutes: mins));
        escalationDeadline = EscalationDeadline(
          deadline: deadlineUtc,
          quotaMinutes: mins,
          isOverdue: deadlineUtc.difference(DateTime.now().toUtc()).inSeconds < 0,
          isWarning: deadlineUtc.difference(DateTime.now().toUtc()).inSeconds <= 60,
        );
        quotaMins = mins;
      }
    }

    return EscalationView._(
      isEscalated:     true,
      phase:           phase,
      currentLevel:    currentLevel,
      currentUserName: currentUserName,
      currentRoleName: currentRoleName,
      previousRoleName: previousRoleName,
      deadline:        escalationDeadline,
      slaMinutesQuota: quotaMins,
      acceptedByName:  acceptedByName,
      closedByName:    closedByName,
      chain:           steps,
    );
  }

  // ── Timer helpers (UTC-safe) ─────────────────────────────────────────────

  bool get hasCountdown => deadline != null && phase != EscalationPhase.closed;

  int get remainingSeconds {
    if (deadline == null) return 0;
    return deadline!.deadline.difference(DateTime.now().toUtc()).inSeconds;
  }

  bool get isOverdue => deadline?.isOverdue ?? false;

  /// Warning band: < 25 % of the SLA quota left, or < 60 s remaining.
  bool get isWarning {
    if (deadline == null) return false;
    return deadline!.isWarning;
  }

  /// 0 → just started, 1 → deadline reached (clamped).
  double get progress {
    if (!hasCountdown || slaMinutesQuota == null || slaMinutesQuota! <= 0) {
      return 0;
    }
    final totalSecs = slaMinutesQuota! * 60;
    final elapsed = totalSecs - remainingSeconds;
    if (elapsed <= 0) return 0;
    if (elapsed >= totalSecs) return 1;
    return elapsed / totalSecs;
  }

  /// mm:ss (or +mm:ss when overdue).  Falls back to empty when no deadline.
  String get countdownLabel {
    return deadline?.countdownText ?? '';
  }

  /// Compact human phrase like "Accept in 05:12", "Complete in 02:44",
  /// "3 min overdue", "Closed".  Never empty for non-closed tasks with a
  /// deadline.
  String get phaseLabel {
    switch (phase) {
      case EscalationPhase.closed:
        return 'Closed';
      case EscalationPhase.awaitingAcceptance:
        if (!hasCountdown) return 'Awaiting acceptance';
        if (isOverdue) return 'Acceptance overdue by ${_absMin()}';
        return 'Accept in $countdownLabel';
      case EscalationPhase.inProgress:
        if (!hasCountdown) return 'In progress';
        if (isOverdue) return 'Resolution overdue by ${_absMin()}';
        return 'Complete in $countdownLabel';
    }
  }

  /// Optional shorter sub-line — small explanatory text.  Empty when the main
  /// phaseLabel already carries everything.
  String get subLabel {
    if (phase == EscalationPhase.closed) {
      return closedByName != null && closedByName!.isNotEmpty
          ? 'Closed by $closedByName'
          : '';
    }
    if (!hasCountdown) return '';
    if (isOverdue) {
      return isEscalated
          ? 'SLA breached · ${_levelRoleLine()}'
          : 'SLA breached';
    }
    if (isWarning) return 'Nearing SLA';
    return 'On track';
  }

  /// Top strip title for cards: "Level 2 · General Manager".
  String get accentStripTitle {
    if (!isEscalated) return '';
    final role = (currentRoleName ?? '').trim();
    if (currentLevel > 0 && role.isNotEmpty) return 'Level $currentLevel · $role';
    if (currentLevel > 0) return 'Level $currentLevel';
    return 'Escalated';
  }

  SlaSeverity get severity {
    if (phase == EscalationPhase.closed) return SlaSeverity.neutral;
    if (isOverdue) return SlaSeverity.overdue;
    if (isEscalated) return SlaSeverity.escalated;
    if (isWarning) return SlaSeverity.warning;
    if (hasCountdown) return SlaSeverity.onTrack;
    return SlaSeverity.neutral;
  }

  /// Color/icon tokens based on current severity.
  SlaTokens get slaTokens => SlaTokens.forSeverity(severity);

  // ── Private helpers ──────────────────────────────────────────────────────

  String _absMin() {
    if (deadline == null) return '1 min';
    final now = DateTime.now().toUtc();
    final remaining = deadline!.deadline.difference(now).inSeconds;
    final m = remaining.abs() ~/ 60;
    return m <= 1 ? '1 min' : '$m min';
  }

  String _levelRoleLine() {
    final role = (currentRoleName ?? '').trim();
    if (currentLevel > 0 && role.isNotEmpty) return 'Level $currentLevel · $role';
    if (currentLevel > 0) return 'Level $currentLevel';
    return 'Escalated';
  }

  static (DateTime?, int?) _computeBaseWindow({
    required EscalationPhase phase,
    required DateTime? createdAt,
    required DateTime? acceptedAt,
    required int?      baseMinutes,
  }) {
    if (baseMinutes == null || baseMinutes <= 0) return (null, null);
    switch (phase) {
      case EscalationPhase.awaitingAcceptance:
        if (createdAt == null) return (null, null);
        return (createdAt.add(Duration(minutes: baseMinutes)), baseMinutes);
      case EscalationPhase.inProgress:
        if (acceptedAt == null) return (null, null);
        return (acceptedAt.add(Duration(minutes: baseMinutes)), baseMinutes);
      case EscalationPhase.closed:
        return (null, null);
    }
  }

  static List<EscalationChainStep> _parseChain(dynamic rawHistory) {
    if (rawHistory == null) return const [];
    List list = const [];
    if (rawHistory is List) {
      list = rawHistory;
    } else if (rawHistory is String) {
      final s = rawHistory.trim();
      if (s.isEmpty || s == '[]' || s == 'null') return const [];
      try {
        final decoded = jsonDecode(s);
        if (decoded is List) list = decoded;
      } catch (_) {
        return const [];
      }
    }
    if (list.isEmpty) return const [];

    final steps = <EscalationChainStep>[];
    for (int i = 0; i < list.length; i++) {
      final item = list[i];
      if (item is! Map) continue;
      final level = _parseInt(item['level']) ?? (i + 1);
      final escalatedAt = _parseUtc(item['escalated_at']);
      final toUser = item['to_user'];
      final fromUsers = item['from_users'];
      String? toUserName;
      String? toRoleName;
      int?    toRoleId;
      if (toUser is Map) {
        toUserName = _cleanString(toUser['user_name']);
        toRoleName = _cleanString(toUser['role_name']);
        toRoleId   = _parseInt(toUser['role_id']);
      }
      final List<String> fromNames = <String>[];
      String? fromRoleName;
      if (fromUsers is List) {
        for (final u in fromUsers) {
          if (u is Map) {
            final n = _cleanString(u['user_name']);
            if (n != null && n.isNotEmpty) fromNames.add(n);
            fromRoleName ??= _cleanString(u['role_name']);
          }
        }
      }
      steps.add(EscalationChainStep(
        level:             level,
        escalatedAt:       escalatedAt,
        toUserName:        toUserName,
        toRoleName:        toRoleName,
        toRoleId:          toRoleId,
        fromUserNames:     fromNames,
        fromRoleName:      fromRoleName,
        acceptanceMinutes: _parseInt(item['acceptance_time_minutes']),
        completionMinutes: _parseInt(item['completion_time_minutes']),
        isCurrent:         i == list.length - 1,
      ));
    }
    return steps;
  }

  static int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static String? _cleanString(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty || s.toLowerCase() == 'null') return null;
    return s;
  }

  /// Parses any timestamp coming from the service_request API into UTC.
  /// Accepts:
  ///   "2026-08-27T16:40:49.000Z"        (ISO with Z)
  ///   "2026-08-27 16:43:22.000000"      (MySQL DATETIME — treated as UTC)
  ///   "2026-08-27T16:40:49+05:30"       (ISO with offset)
  static DateTime? _parseUtc(dynamic value) {
    if (value == null) return null;
    var s = value.toString().trim();
    if (s.isEmpty || s.toLowerCase() == 'null') return null;
    s = s.replaceFirst(' ', 'T');
    final hasTz = s.endsWith('Z') ||
        RegExp(r'[+\-]\d{2}:?\d{2}$').hasMatch(s);
    if (!hasTz) s = '${s}Z';
    return DateTime.tryParse(s);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Severity → colour tokens shared across every escalation surface.
// ─────────────────────────────────────────────────────────────────────────────

class SlaTokens {
  const SlaTokens({
    required this.fg,
    required this.bg,
    required this.border,
    required this.icon,
  });

  final Color    fg;
  final Color    bg;
  final Color    border;
  final IconData icon;

  static SlaTokens forSeverity(SlaSeverity s) {
    switch (s) {
      case SlaSeverity.overdue:
        return SlaTokens(
          fg:     AppColors.error,
          bg:     AppColors.errorLight,
          border: AppColors.error.withOpacity(0.35),
          icon:   Icons.timer_off_outlined,
        );
      case SlaSeverity.escalated:
        return SlaTokens(
          fg:     AppColors.error,
          bg:     AppColors.errorLight,
          border: AppColors.error.withOpacity(0.30),
          icon:   Icons.arrow_upward_rounded,
        );
      case SlaSeverity.warning:
        return SlaTokens(
          fg:     AppColors.warning,
          bg:     AppColors.warningLight,
          border: AppColors.warning.withOpacity(0.35),
          icon:   Icons.bolt_rounded,
        );
      case SlaSeverity.onTrack:
        return SlaTokens(
          fg:     AppColors.success,
          bg:     AppColors.successLight,
          border: AppColors.success.withOpacity(0.30),
          icon:   Icons.timer_outlined,
        );
      case SlaSeverity.neutral:
        return SlaTokens(
          fg:     AppColors.textSecondary,
          bg:     AppColors.surfaceAlt,
          border: AppColors.borderLight,
          icon:   Icons.info_outline_rounded,
        );
    }
  }
}
