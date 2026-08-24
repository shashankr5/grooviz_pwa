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
  static bool canViewEscalatedTab(EscalationRole role) =>
      role.isSupervisorOrAbove;

  /// Whether this role defaults to the Escalated filter on home page open.
  static bool defaultsToEscalated(EscalationRole role) =>
      role.isManagerOrAbove;

  /// Whether this role can take over (reassign) an escalated task.
  static bool canTakeOver(EscalationRole role) =>
      role.isSupervisorOrAbove;

  /// Whether this role sees the full escalation history timeline.
  static bool canViewEscalationHistory(EscalationRole role) =>
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
  final DateTime? nextEscalationAt;
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
    final nextRaw = (task['next_escalation_at'] ??
            raw['next_escalation_at'] ?? '').toString();
    DateTime? nextAt;
    if (nextRaw.isNotEmpty && nextRaw != 'null') {
      final parsed = DateTime.tryParse(nextRaw.replaceAll(' ', 'T'));
      if (parsed != null) {
        // Show timestamps as current time without UTC conversion for consistency
        nextAt = parsed;
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
      nextEscalationAt:      nextAt,
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

  int get remainingSeconds {
    if (nextEscalationAt == null) return 9999;
    return nextEscalationAt!.difference(DateTime.now()).inSeconds;
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
        return 'ESCALATED$stage — PENDING RESOLUTION';
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

  // ── History timeline dot color ────────────────────────────────────────────

  static Color historyDotColor(String status) {
    switch (status.toLowerCase()) {
      case 'resolved':
      case 'accepted':
      case 'completed': return AppColors.success;
      case 'open':
      case 'timedout':
      case 'cancelled': return AppColors.error;
      case 'viewed':
      case 'notified':  return AppColors.primary;
      default:          return AppColors.warning;
    }
  }
}
