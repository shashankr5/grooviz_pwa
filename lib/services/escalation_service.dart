// lib/services/escalation_service.dart
//
// EscalationService — singleton for all escalation-related API calls and
// in-process event streams.
//
// ARCHITECTURE NOTE (updated):
//  • Escalation status is now embedded in every get_all_services_mobile RESULT
//    row (escalation_instance_id, escalation_status, current_stage_name,
//    next_escalation_at). No separate per-task REST call is needed.
//
//  • resolveEscalation() has been REMOVED. The SP
//    ScreenSync_update_service_request_status_mobile handles escalation
//    resolution atomically inside its DB transaction. A separate round-trip
//    was redundant and could race with the SP.
//
//  • getTaskStatus() has been REMOVED. EscalationStatus is now built from the
//    task map that _mapTasks() produces — no extra network call.
//
//  • triggerCheck() — KEPT. Called by the 60s Manager+ timer in home_page.dart.
//    Routes to ScreenSync_sp_check_and_escalate_mobile.
//
//  • onBadgeUpdate / onListRefresh streams — KEPT. Fed by WebSocket
//    ESCALATION_ALERT events; consumed by home_page.dart.
//
// Deprecated endpoints (commented for reference — DO NOT CALL):
//  // ScreenSync_get_escalation_status_mobile  → status in RESULT row now
//  // ScreenSync_sp_resolve_escalation_mobile  → resolved inside update_status SP

import 'dart:async';
import 'dart:developer' as dev;
import 'package:dio/dio.dart';
import '../constants/api_constants.dart';
import '../constants/app_config.dart';
import '../utils/user_session_helper.dart';

// ── EscalationStatus model ────────────────────────────────────────────────────
//
// Built from the task map produced by HomeService._mapTasks().
// All fields originate from the get_all_services_mobile RESULT row —
// no additional network call is required.
//
// Usage:
//   final es = EscalationStatus.fromTaskMap(task);
//   if (es.isEscalated) { /* show banner */ }

class EscalationStatus {
  final int?      instanceId;       // escalation_instance_id — null = not escalated
  final String?   status;           // "Working" | "Completed" | "Accepted" | null
  final int?      currentStageId;
  final String?   currentStageName; // e.g. "Level 2 – Supervisor"
  final DateTime? nextEscalationAt; // from task_alert_state.next_escalation_at
  final String?   currentAssignedTo;

  const EscalationStatus({
    this.instanceId,
    this.status,
    this.currentStageId,
    this.currentStageName,
    this.nextEscalationAt,
    this.currentAssignedTo,
  });

  bool get isEscalated => instanceId != null;

  /// True if the next escalation deadline has already passed.
  bool get isOverdue =>
      nextEscalationAt != null &&
      DateTime.now().isAfter(nextEscalationAt!);

  /// Remaining minutes until the next escalation fires. Negative = overdue.
  int get remainingMinutes {
    if (nextEscalationAt == null) return 9999;
    return nextEscalationAt!.difference(DateTime.now()).inMinutes;
  }

  /// Human-readable SLA label shown in the escalation banner / countdown widget.
  String get slaLabel {
    if (!isEscalated || nextEscalationAt == null) return '';
    if (isOverdue) return '${-remainingMinutes} min overdue';
    if (remainingMinutes == 0) return 'SLA due now';
    return '$remainingMinutes min remaining';
  }

  /// Build from the task map returned by HomeService._mapTasks().
  /// Returns a non-escalated (instanceId == null) sentinel if not escalated.
  factory EscalationStatus.fromTaskMap(Map<String, dynamic> task) {
    final instanceId = task['escalation_instance_id'] as int?;
    if (instanceId == null) return const EscalationStatus();

    final nextEscRaw = task['next_escalation_at'] as String?;
    DateTime? nextEsc;
    if (nextEscRaw != null && nextEscRaw.isNotEmpty) {
      try { nextEsc = DateTime.parse(nextEscRaw).toLocal(); } catch (_) {}
    }

    return EscalationStatus(
      instanceId:        instanceId,
      status:            task['escalation_status'] as String?,
      currentStageId:    task['current_stage_id'] as int?,
      currentStageName:  task['current_stage_name'] as String?,
      nextEscalationAt:  nextEsc,
      currentAssignedTo: (task['raw'] as Map?)?['current_assigned_to'] as String?,
    );
  }
}

// ── EscalationService singleton ───────────────────────────────────────────────

class EscalationService {
  EscalationService._();

  // Active endpoint
  static const String _checkAndEscalateUrl =
      "${ApiConstants.baseUrl}/ScreenSync_sp_check_and_escalate_mobile";

  // Deprecated — DO NOT USE (kept for historical reference)
  // static const String _escalationStatusUrl =
  //     "${ApiConstants.baseUrl}/ScreenSync_get_escalation_status_mobile";
  // static const String _resolveEscalationUrl =
  //     "${ApiConstants.baseUrl}/ScreenSync_sp_resolve_escalation_mobile";

  static final EscalationService instance = EscalationService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    headers: {
      'Content-Type': 'application/json',
      'x-api-key':    ApiConstants.apiKey,
    },
    validateStatus: (c) => c != null && c < 500,
  ));

  // ── Streams ───────────────────────────────────────────────────────────────

  final _badgeCtrl = StreamController<int>.broadcast();
  final _listCtrl  = StreamController<void>.broadcast();

  /// Emits updated badge count on every ESCALATION_ALERT WebSocket event.
  Stream<int>  get onBadgeUpdate => _badgeCtrl.stream;

  /// Emits void when the escalated task list must be re-fetched.
  /// Always unconditional — home_page must NOT add a selectedFilter guard.
  Stream<void> get onListRefresh => _listCtrl.stream;

  void _emitBadge(int n) {
    if (!_badgeCtrl.isClosed) _badgeCtrl.add(n);
  }

  void _emitList() {
    if (!_listCtrl.isClosed) _listCtrl.add(null);
  }

  // ── Entry point from WebSocketService ────────────────────────────────────
  // Called by websocket_service.dart _handleMessage() for ESCALATION_ALERT.

  void handleEscalationAlert(Map<String, dynamic> data) {
    final badge = int.tryParse(
      (data['badge_count'] ?? '0').toString(),
    ) ?? 0;
    _emitBadge(badge);
    _emitList(); // always unconditional — not guarded by selected filter
    dev.log('EscalationService: ESCALATION_ALERT badge=$badge');
  }

  // ── Periodic check — Manager+ only ───────────────────────────────────────
  // Called by the 60s Timer in home_page.dart (behind Manager+ role guard).

  Future<void> triggerCheck() async {
    try {
      final userId       = await UserSessionHelper.getUserId();
      final enterpriseId = await UserSessionHelper.getEnterpriseId();
      await _dio.post(_checkAndEscalateUrl, data: {
        if (userId != null)       'user_id':       userId,
        if (enterpriseId != null) 'enterprise_id': enterpriseId,
        'stage': AppConfig.stage,
      });
      dev.log('EscalationService.triggerCheck: OK');
    } catch (e) {
      dev.log('EscalationService.triggerCheck (non-fatal): $e');
    }
  }

  // ── Legacy resolveEscalation compatibility method ─────────────────────────
  // Escalation resolution is handled atomically inside the stored procedure.
  Future<void> resolveEscalation({
    required int serviceRequestId,
    required int resolvedByUserId,
    required String resolutionType,
  }) async {
    dev.log(
        'EscalationService.resolveEscalation (handled in SP): sr=$serviceRequestId type=$resolutionType');
  }

  // ── Dispose ───────────────────────────────────────────────────────────────
  // Only call when the entire app is shutting down.

  void dispose() {
    _badgeCtrl.close();
    _listCtrl.close();
  }
}


