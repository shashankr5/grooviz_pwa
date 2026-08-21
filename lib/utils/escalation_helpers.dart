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

class EscalationInfo {
  final bool isEscalated;
  final int? instanceId;
  final String? stageName;        // "Level 2 – Supervisor"
  final int? stageId;
  final String? escalationStatus; // "Working" | null
  final DateTime? nextEscalationAt;
  final int? escalationTimeMinutes;
  final String? escalatedToName;

  const EscalationInfo({
    required this.isEscalated,
    this.instanceId,
    this.stageName,
    this.stageId,
    this.escalationStatus,
    this.nextEscalationAt,
    this.escalationTimeMinutes,
    this.escalatedToName,
  });

  static const EscalationInfo none = EscalationInfo(isEscalated: false);

  /// Extract from the task map produced by HomeService._mapTasks().
  factory EscalationInfo.fromTask(Map<String, dynamic> task) {
    final raw = task['raw'] as Map? ?? {};

    final instanceId = (task['escalation_instance_id'] ??
        raw['escalation_instance_id']) as int?;

    final isEscalated = task['is_escalated'] == 1 ||
        task['is_escalated'] == true ||
        raw['is_escalated'] == 1 ||
        raw['is_escalated'] == true ||
        instanceId != null;

    if (!isEscalated) return EscalationInfo.none;

    final nextRaw = (task['next_escalation_at'] ??
            raw['next_escalation_at'] ??
            '')
        .toString();
    DateTime? nextAt;
    if (nextRaw.isNotEmpty && nextRaw != 'null') {
      nextAt = DateTime.tryParse(nextRaw.replaceAll(' ', 'T'))?.toLocal();
    }

    return EscalationInfo(
      isEscalated:           true,
      instanceId:            instanceId,
      stageName:             (task['current_stage_name'] ??
              raw['current_stage_name'] ??
              task['stage_name'])
          ?.toString(),
      stageId:               (task['current_stage_id'] ??
          raw['current_stage_id']) as int?,
      escalationStatus:      (task['escalation_status'] ??
              raw['escalation_status'])
          ?.toString(),
      nextEscalationAt:      nextAt,
      escalationTimeMinutes: (task['escalation_time_minutes'] ??
          raw['escalation_time_minutes']) as int?,
      escalatedToName:       (task['escalated_to_name'] ??
              task['notified_user_name'] ??
              raw['escalated_to_name'])
          ?.toString(),
    );
  }

  // ── SLA countdown helpers ─────────────────────────────────────────────────

  bool get hasCountdown => nextEscalationAt != null;

  int get remainingSeconds {
    if (nextEscalationAt == null) return 9999;
    return nextEscalationAt!.difference(DateTime.now()).inSeconds;
  }

  bool get isOverdue => hasCountdown && remainingSeconds <= 0;

  bool get isWarning =>
      hasCountdown && remainingSeconds > 0 && remainingSeconds <= 60;

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
    if (isOverdue)  return '${remainingSeconds.abs() ~/ 60} min overdue';
    if (isWarning)  return 'Due in < 1 min';
    return '${remainingSeconds ~/ 60} min remaining';
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
