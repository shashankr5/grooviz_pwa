// lib/services/escalation_service.dart
//
// EscalationService — singleton for all escalation-related API calls and
// in-process event streams.
//
// Responsibilities:
//  • handleEscalationAlert() — called by WebSocketService on ESCALATION_ALERT
//  • onBadgeUpdate stream    — emits badge count for home_page badge chip
//  • onListRefresh stream    — emits void so home_page always reloads the list
//                             (no selectedFilter guard — always unconditional)
//  • triggerCheck()          — called by 60s timer (Manager+ only)
//  • resolveEscalation()     — called after accept / close / reassign
//  • getBadgeCount()         — REST fallback for badge count
//  • getEscalatedTasks()     — REST fetch of escalated task list
//  • getTaskStatus()         — per-task escalation status for TicketDetailPage
//  • getEscalationHistory()  — history list for a single task
//
// All payloads use AppConfig.stage — never hardcodes 'dev'.

import 'dart:async';
import 'dart:developer' as dev;
import 'package:dio/dio.dart';
import '../constants/api_constants.dart';
import '../constants/app_config.dart';
import '../utils/user_session_helper.dart';

// ── EscalationStatus model ────────────────────────────────────────────────────

class EscalationStatus {
  final int    currentLevel;
  final int    maxLevel;
  final int    pulseCount;
  final int    maxPulses;
  final String status;
  final String escalatedToName;
  final String notifiedUserName;
  final int    ageMinutes;
  final int    slaMinutes;

  const EscalationStatus({
    required this.currentLevel,
    required this.maxLevel,
    required this.pulseCount,
    required this.maxPulses,
    required this.status,
    required this.escalatedToName,
    required this.notifiedUserName,
    required this.ageMinutes,
    required this.slaMinutes,
  });

  bool get isEscalated  => currentLevel > 0;
  bool get isAtMaxLevel => currentLevel >= maxLevel;
  int  get overdueMinutes => (ageMinutes - slaMinutes).clamp(0, 9999);

  /// Human-readable SLA label for the TicketDetailPage escalation banner.
  String get slaLabel {
    if (overdueMinutes > 0) return '$overdueMinutes min overdue';
    final remaining = slaMinutes - ageMinutes;
    if (remaining <= 0) return 'SLA due now';
    return '$remaining min remaining';
  }

  factory EscalationStatus.fromMap(Map<String, dynamic> m) {
    return EscalationStatus(
      currentLevel:     (m['current_escalation_level'] as int?) ?? 0,
      maxLevel:         (m['max_escalation_level']     as int?) ?? 5,
      pulseCount:       (m['pulse_count']              as int?) ?? 0,
      maxPulses:        (m['max_pulses']               as int?) ?? 5,
      status:           (m['escalation_status']        as String?) ?? 'pulsing',
      escalatedToName:  (m['escalated_to_name']        as String?) ?? '-',
      notifiedUserName: (m['notified_user_name']       as String?) ?? '-',
      ageMinutes:       (m['age_minutes']              as int?) ?? 0,
      slaMinutes:       (m['sla_minutes']              as int?) ?? 0,
    );
  }
}

// ── EscalationService singleton ───────────────────────────────────────────────

class EscalationService {
  EscalationService._();
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
  // Called in websocket_service.dart _handleMessage() for ESCALATION_ALERT.

  void handleEscalationAlert(Map<String, dynamic> data) {
    final badge = int.tryParse(
      (data['badge_count'] ?? '0').toString(),
    ) ?? 0;
    _emitBadge(badge);
    _emitList(); // always — not conditional on selected filter
    dev.log('EscalationService: ESCALATION_ALERT badge=$badge');
  }

  // ── Periodic check — Manager+ only ───────────────────────────────────────
  // Called by the 60s Timer in home_page.dart initState (Manager+ guard there).

  Future<void> triggerCheck() async {
    try {
      await _dio.post(ApiConstants.checkAndEscalate, data: {
        'stage': AppConfig.stage,
      });
      dev.log('EscalationService.triggerCheck: OK');
    } catch (e) {
      dev.log('EscalationService.triggerCheck (non-fatal): $e');
    }
  }

  // ── Resolve escalation ────────────────────────────────────────────────────
  // Call after accept, close, OR reassign.
  // Sets task_alert_state.next_pulse_at = NULL,
  //      task_alert_state.next_escalation_at = NULL,
  //      service_request.is_escalated = 0,
  //      escalation_log.resolved_at = NOW().

  Future<void> resolveEscalation({
    required int    serviceRequestId,
    required int    resolvedByUserId,
    required String resolutionType, // 'accept' | 'close' | 'reassign'
  }) async {
    try {
      final res = await _dio.post(ApiConstants.resolveEscalation, data: {
        'service_request_id':  serviceRequestId,
        'resolved_by_user_id': resolvedByUserId,
        'resolution_type':     resolutionType,
        'stage':               AppConfig.stage,
      });
      dev.log('EscalationService.resolveEscalation: '
          'sr=$serviceRequestId type=$resolutionType '
          'status=${res.statusCode}');
    } catch (e) {
      // Non-fatal: the main SP (accept/close/reassign) already cleared
      // is_escalated and alert_pending on service_request.
      // This call ensures task_alert_state.next_escalation_at = NULL so
      // the Lambda doesn't re-escalate on the next tick.
      dev.log('EscalationService.resolveEscalation (non-fatal): $e');
    }
  }

  // ── Get badge count ───────────────────────────────────────────────────────

  Future<int> getBadgeCount() async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) return 0;

      final res = await _dio.post(ApiConstants.escalationBadgeCount, data: {
        'user_id': userId,
        'stage':   AppConfig.stage,
      });
      if (res.statusCode != 200) return 0;

      final statusList = res.data['STATUS'] as List?;
      if (statusList == null || statusList.isEmpty ||
          statusList[0]['status'] != 'S') { return 0; }

      final resultList = res.data['RESULT'] as List?;
      if (resultList == null || resultList.isEmpty) return 0;
      return (resultList[0]['badge_count'] as int?) ?? 0;
    } catch (e) {
      dev.log('EscalationService.getBadgeCount error: $e');
      return 0;
    }
  }

  // ── Get escalated task list ───────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getEscalatedTasks() async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) return [];

      final res = await _dio.post(ApiConstants.escalatedTasks, data: {
        'user_id': userId,
        'stage':   AppConfig.stage,
      });
      if (res.statusCode != 200) return [];

      final statusList = res.data['STATUS'] as List?;
      if (statusList == null || statusList.isEmpty ||
          statusList[0]['status'] != 'S') { return []; }

      final resultList = res.data['RESULT'] as List? ?? [];
      return resultList
          .map((t) => Map<String, dynamic>.from(t as Map))
          .toList();
    } catch (e) {
      dev.log('EscalationService.getEscalatedTasks error: $e');
      return [];
    }
  }

  // ── Get status for a single task (TicketDetailPage) ──────────────────────

  Future<EscalationStatus?> getTaskStatus(int serviceRequestId) async {
    try {
      final res = await _dio.post(ApiConstants.escalationStatus, data: {
        'service_request_id': serviceRequestId,
        'stage':              AppConfig.stage,
      });
      if (res.statusCode != 200) return null;

      final statusList = res.data['STATUS'] as List?;
      if (statusList == null || statusList.isEmpty ||
          statusList[0]['status'] != 'S') { return null; }

      final resultList = res.data['RESULT'] as List?;
      if (resultList == null || resultList.isEmpty) return null;
      return EscalationStatus.fromMap(
        Map<String, dynamic>.from(resultList[0] as Map),
      );
    } catch (e) {
      dev.log('EscalationService.getTaskStatus error: $e');
      return null;
    }
  }

  // ── Get escalation history for a task ────────────────────────────────────

  Future<List<Map<String, dynamic>>> getEscalationHistory(
      int serviceRequestId) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) return [];

      final res = await _dio.post(ApiConstants.escalationHistoryForTask, data: {
        'service_request_id': serviceRequestId,
        'user_id':            userId,
        'stage':              AppConfig.stage,
      });
      if (res.statusCode != 200) return [];

      final statusList = res.data['STATUS'] as List?;
      if (statusList == null || statusList.isEmpty ||
          statusList[0]['status'] != 'S') { return []; }

      return List<Map<String, dynamic>>.from(res.data['RESULT'] ?? []);
    } catch (e) {
      dev.log('EscalationService.getEscalationHistory error: $e');
      return [];
    }
  }

  // ── Dispose ───────────────────────────────────────────────────────────────
  // Only call when the entire app is shutting down.

  void dispose() {
    _badgeCtrl.close();
    _listCtrl.close();
  }
}
