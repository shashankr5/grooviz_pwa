// services/alert_reload_coordinator.dart
//
// Server reconciliation - the "ears" of the alert system.
// Called EXPLICITLY by FCM handlers and WebSocket handlers.
// Fetches real counts from server, feeds them back to AlertStateManager
// which triggers _sync() to start/switch/stop alerts.
//
// NOTE: This no longer auto-reloads via stream listeners. Callers must
// explicitly call reloadX() to avoid double-reload races.

import 'dart:async';
import 'food_order_service.dart';
import 'task_service.dart';
import 'order_alert_service.dart';
import 'task_alert_service.dart';
import '../utils/user_session_helper.dart';
import '../utils/order_grouping.dart';

class AlertReloadCoordinator {
  static final AlertReloadCoordinator _instance = AlertReloadCoordinator._internal();
  static AlertReloadCoordinator get instance => _instance;
  factory AlertReloadCoordinator() => _instance;
  AlertReloadCoordinator._internal();

  // Stream for service start failed events (kept for backward compatibility)
  static final StreamController<String> _serviceFailController = StreamController.broadcast();
  static Stream<String> get onServiceStartFailed => _serviceFailController.stream;

  /// No-op init kept for main() compatibility. Reloads are now explicit.
  static void init() {
    print('AlertReloadCoordinator: explicit-reload mode (no stream listeners)');
  }

  /// Calls a reconcile endpoint and retries on failure.
  ///
  /// The service methods (getFoodOrders / getAllServices) never THROW — they
  /// swallow exceptions and return {'success': false}. So we treat
  /// success != true as retryable here. Without this, one transient blip
  /// (wifi drop, expired token, Lambda cold-start) left the siren stuck,
  /// because the FCM background isolate runs once and then dies with no
  /// second chance to reconcile.
  ///
  /// Bounds are deliberately tight (2 attempts, 700ms gap) so the total time
  /// stays well within the background-isolate execution budget on Android.
  Future<Map<String, dynamic>> _fetchWithRetry(
    Future<Map<String, dynamic>> Function() call, {
    int maxAttempts = 2,
    Duration delay = const Duration(milliseconds: 700),
  }) async {
    Map<String, dynamic> res = const {'success': false};
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        res = await call();
      } catch (e) {
        res = {'success': false, 'message': e.toString()};
      }
      if (res['success'] == true) return res;
      if (attempt < maxAttempts) {
        print('AlertReloadCoordinator: reconcile attempt $attempt failed, retrying in ${delay.inMilliseconds}ms');
        await Future.delayed(delay);
      }
    }
    return res;
  }

  Future<void> reloadFood({bool silentReconcile = false}) async {
    try {
      final response = await _fetchWithRetry(() => FoodOrderService().getFoodOrders());
      if (response['success'] != true) {
        print('AlertReloadCoordinator.reloadFood: API failed after retries, skipping reconcile');
        return;
      }
      final orders = response['orders'] as List<dynamic>? ?? [];

      // Group by order_number first — one card per order, not per item row.
      // A 3-item order is 3 flat rows but counts as 1 pending order.
      final grouped = groupFoodOrderRows(orders);
      final pendingCount = grouped.where((order) =>
          order['status']?.toString().toLowerCase() == 'pending').length;

      print('AlertReloadCoordinator.reloadFood: server pendingCount=$pendingCount');
      await OrderAlertService.resetCount(pendingCount, reconcileAlert: silentReconcile);
    } catch (e) {
      print('AlertReloadCoordinator.reloadFood error: $e');
    }
  }

  Future<void> reloadTasks({bool silentReconcile = false}) async {
    try {
      // Read current user ID so we only count tasks that belong to THIS device's
      // user. Without this filter every device in the department would sound
      // an alert for every new request, even ones assigned to someone else.
      final int? currentUserId = await UserSessionHelper.getUserId();

      final response = await _fetchWithRetry(() => TaskService().getTasks());
      if (response['success'] != true) {
        print('AlertReloadCoordinator.reloadTasks: API failed after retries, skipping reconcile');
        return;
      }
      // TaskService.getTasks() returns response['services'] not response['tasks'].
      // Raw rows have fields: status ("Open"|"In Progress"|"Closed"),
      // closed (0|1), is_escalated (0|1), accepted_by_user_id,
      // assigned_to_user_id, etc.
      final services = response['services'] as List<dynamic>? ?? [];

      // ── Per-user ID matcher ───────────────────────────────────────────────
      //
      // Returns true when at least one of the supplied SP column names holds
      // a non-zero integer equal to currentUserId.
      //
      // Passing an empty list of keys is a caller error — treat as no match.
      bool _matchesUserId(dynamic s, List<String> keys) {
        if (currentUserId == null || currentUserId == 0) return true; // no session guard
        for (final key in keys) {
          final v = s[key];
          if (v == null) continue;
          final id = v is int ? v : int.tryParse(v.toString());
          if (id != null && id != 0 && id == currentUserId) return true;
        }
        return false;
      }

      // ── isAssignedToMe: service-task ownership ────────────────────────────
      //
      // Used for the SERVICE TASK (non-escalation) pending count.
      // Checks the classic assignment / acceptance fields.
      //
      // IMPORTANT: A newly created service request has assigned_to = NULL
      // and accepted_by_user_id = NULL — it is unassigned and should alert
      // ALL staff in the department. Return true when all ownership fields
      // are null so every staff member's device alerts for unassigned tasks.
      bool isAssignedToMe(dynamic s) {
        final assignedTo   = s['assigned_to_user_id'] ?? s['assigned_to'];
        final acceptedBy   = s['accepted_by_user_id'];

        // If nobody owns this task yet, every staff member should be alerted.
        final isUnassigned = (assignedTo == null || assignedTo == 0 ||
                              assignedTo.toString() == '0') &&
                             (acceptedBy == null || acceptedBy == 0 ||
                              acceptedBy.toString() == '0');
        if (isUnassigned) return true;

        // Task is assigned/accepted — only alert the owner.
        return _matchesUserId(s, const [
          'assigned_to_user_id',
          'assigned_to',
          'accepted_by_user_id',
        ]);
      }

      // ── isEscalationTargetMe: escalation ownership ────────────────────────
      //
      // Used exclusively for the ESCALATION siren count.
      //
      // Priority order:
      //   1. escalation_target_user_id — the to_user_id of the latest OPEN
      //      escalation_log row, returned by the SP after the patch in
      //      patch_get_all_services_escalation_target.sql is applied.
      //      This is the authoritative field — always prefer it.
      //
      //   2. accepted_by_user_id — covers Case 3/4 of check_and_escalate_unified
      //      (user already accepted and then exceeded their SLA). In that case
      //      the escalation_log.to_user_id is their supervisor, but
      //      service_request.accepted_by_user_id is the current holder.
      //      Both need to hear the alarm.
      //
      // assigned_to / assigned_to_user_id are intentionally NOT checked here.
      // An escalation notification is addressed to a specific supervisor via
      // escalation_log.to_user_id; a plain reassignment does not create an
      // escalation_log row.
      bool isEscalationTargetMe(dynamic s) => _matchesUserId(s, const [
        'escalation_target_user_id', // SP patch — authoritative
        'accepted_by_user_id',       // Case 3/4 fallback (acceptor exceeded SLA)
      ]);

      // Pending = Open, not closed, no acceptor yet, AND assigned to me.
      // "No acceptor" means the request is still in the alert queue.
      // The assigned_to_user_id field tells us who should be alarmed.
      final pendingCount = services.where((s) {
        final status     = s['status']?.toString().toUpperCase() ?? '';
        final closed     = s['closed'];
        final acceptedBy = s['accepted_by_user_id'];
        final isTrulyOpen = status == 'OPEN' &&
            (closed == 0 || closed == null) &&
            (acceptedBy == null || acceptedBy == 0);
        return isTrulyOpen && isAssignedToMe(s);
      }).length;

      // Escalation siren fires ONLY when the current user is the explicit
      // escalation target (escalation_target_user_id from SP) or the acceptor
      // who exceeded their SLA. Using isEscalationTargetMe() instead of
      // isAssignedToMe() prevents every dept device from sounding when any
      // task in the dept has is_escalated=1.
      final escalatedCount = services.where((s) {
        final status      = s['status']?.toString().toUpperCase() ?? '';
        final closed      = s['closed'];
        final isEscalated = s['is_escalated'];
        final acceptedBy  = s['accepted_by_user_id'];
        final isTrulyOpen = (closed == 0 || closed == null) &&
            status == 'OPEN' &&
            (acceptedBy == null || acceptedBy == 0) &&
            (isEscalated == 1 || isEscalated == true);
        return isTrulyOpen && isEscalationTargetMe(s);
      }).length;

      print('AlertReloadCoordinator.reloadTasks: pendingCount=$pendingCount '
            'escalated=$escalatedCount total=${services.length} '
            'userId=$currentUserId');
      await TaskAlertService.resetServiceCount(pendingCount, reconcileAlert: silentReconcile);
      await TaskAlertService.setEscalationActive(escalatedCount > 0, reconcileAlert: silentReconcile);
    } catch (e) {
      print('AlertReloadCoordinator.reloadTasks error: $e');
    }
  }

  Future<void> reloadDelivery({bool silentReconcile = false}) async {
    try {
      // COUNT EXACTLY WHAT THE DELIVERY PAGE'S "READY" TAB SHOWS:
      // food-delivery service requests that are still OPEN (awaiting a delivery
      // person to accept). Source = ScreenSync_get_all_services_mobile1, the
      // same endpoint delivery_page uses.
      //
      // Previously this counted raw food-order rows with status == 'ready',
      // which only clears when an order is DELIVERED — so the siren stayed on
      // through the whole "Accepted" phase and disagreed with the screen
      // (causing a start/stop flap on cold launch). An Open delivery request,
      // by contrast, disappears the moment a colleague accepts, so the siren
      // now drops on ACCEPT, cross-device, matching what staff see.
      final response = await _fetchWithRetry(() => TaskService().getAllServices());
      if (response['success'] != true) {
        print('AlertReloadCoordinator.reloadDelivery: API failed after retries, skipping reconcile');
        return;
      }
      final services = response['services'] as List<dynamic>? ?? [];

      // A food-delivery SR is identified the same way delivery_page identifies
      // it: the question starts with "Food order #" OR it carries a non-zero
      // food_order_summary_id.
      int nonZeroInt(dynamic v) {
        if (v == null) return 0;
        final n = v is int ? v : int.tryParse(v.toString());
        return n ?? 0;
      }

      final openDeliveryCount = services.where((s) {
        if (s is! Map) return false;
        final question = (s['question'] ?? '').toString().toLowerCase();
        final isFoodDelivery =
            question.startsWith('food order #') || nonZeroInt(s['food_order_summary_id']) != 0;
        if (!isFoodDelivery) return false;
        // "Ready" tab == SR status "Open" (awaiting delivery acceptance).
        final status = (s['status'] ?? '').toString().toLowerCase();
        return status == 'open';
      }).length;

      print('AlertReloadCoordinator.reloadDelivery: open food-delivery SRs=$openDeliveryCount');
      await TaskAlertService.resetDeliveryCount(openDeliveryCount, reconcileAlert: silentReconcile);
    } catch (e) {
      print('AlertReloadCoordinator.reloadDelivery error: $e');
    }
  }
}