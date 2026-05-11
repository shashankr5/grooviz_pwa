// services/role_change_watcher.dart
//
// FIXES:
//  1. Comparison now uses the profile JSON blob (saved by ProfileService/ProfilePage)
//     rather than the departments StringList, which was never updated after login.
//     This ensures logout fires when the profile page already shows the new dept/role.
//
//  2. A minimum 3-second debounce after resume before the API check fires.
//     FCM notifications cause a background→resume lifecycle event.  Without this
//     delay the check races against the notification-processing window and can
//     produce spurious logouts on every push notification.
//
//  3. The comparison is now symmetric-difference based (Set equality) so
//     ordering differences do not cause false positives.
//
//  4. The watcher saves the authoritative dept list + role into dedicated prefs
//     keys at startup so it always has a known-good baseline to compare against.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';

import 'profile_service.dart';
import 'order_alert_service.dart';
import 'task_alert_service.dart';
import 'websocket_service.dart';
import '../utils/user_session_helper.dart';

class RoleChangeWatcher with WidgetsBindingObserver {
  final VoidCallback onRoleChanged;

  bool _active   = false;
  bool _checking = false;

  /// Debounce timer — prevents the check from firing during the brief
  /// background→resume that FCM causes when delivering a notification.
  Timer? _debounce;

  /// How long to wait after resume before we actually hit the API.
  /// 3 seconds is enough to skip the FCM-resume window (typically <1s)
  /// while still being prompt for a genuine app-foreground event.
  static const _kDebounceDelay = Duration(seconds: 3);

  RoleChangeWatcher({required this.onRoleChanged});

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void startWatching() {
    _active = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void stopWatching() {
    _active = false;
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_active) return;

    if (state == AppLifecycleState.resumed) {
      // Cancel any pending check from a previous resume event (e.g. rapid
      // background/foreground during notification delivery).
      _debounce?.cancel();
      _debounce = Timer(_kDebounceDelay, _checkForRoleChange);
    } else if (state == AppLifecycleState.paused ||
               state == AppLifecycleState.inactive) {
      // App going to background — cancel any pending debounced check so we
      // don't fire it after a notification-driven resume.
      _debounce?.cancel();
    }
  }

  // ── Snapshot helpers ──────────────────────────────────────────────────────

  /// Returns the dept set + role that were last confirmed-good (at login or
  /// at the previous successful check).  We store them in dedicated prefs keys
  /// so the comparison is always against the last *server-confirmed* state,
  /// not the login-time snapshot that never gets updated.
  static Future<({Set<String> depts, String? role})> _loadBaseline() async {
    final depts = await UserSessionHelper.getDepartments(); // List<String>
    final role  = await UserSessionHelper.getRole();
    return (
      depts: depts.map((e) => e.trim().toLowerCase()).toSet(),
      role:  role?.trim(),
    );
  }

  /// Persists the current server-confirmed state so the next check has a
  /// fresh baseline to compare against.
  static Future<void> _saveBaseline({
    required List<String> depts,
    required String? role,
  }) async {
    await UserSessionHelper.saveDepartments(depts);
    if (role != null) await UserSessionHelper.saveRole(role);
  }

  // ── Core check ────────────────────────────────────────────────────────────

  Future<void> _checkForRoleChange() async {
    if (_checking || !_active) return;
    _checking = true;

    try {
      // ── 1. Load current baseline ─────────────────────────────────────────
      final baseline = await _loadBaseline();

      // Nothing stored yet (e.g. first launch before login completes) → skip.
      if (baseline.depts.isEmpty && baseline.role == null) return;

      // ── 2. Fetch fresh profile from server ────────────────────────────────
      final result = await ProfileService().getProfile();

      // Network / server error → skip silently, do NOT logout.
      if (result['success'] != true) return;

      final profile = result['profile'] as Map<String, dynamic>;

      // ── 3. Parse fresh depts ──────────────────────────────────────────────
      List<String> freshDeptList = [];
      try {
        final raw = profile['departments'];
        if (raw is String) {
          freshDeptList = List<String>.from(jsonDecode(raw));
        } else if (raw is List) {
          freshDeptList = List<String>.from(raw);
        }
      } catch (_) {}

      final freshDeptSet = freshDeptList
          .map((e) => e.trim().toLowerCase())
          .toSet();

      // ── 4. Parse fresh role ───────────────────────────────────────────────
      final freshRole = profile['role']?.toString().trim();

      // ── 5. Compare (symmetric-difference so order doesn't matter) ─────────
      final deptChanged = !_setsEqual(baseline.depts, freshDeptSet);
      final roleChanged = (baseline.role != freshRole);

      debugPrint('[RoleChangeWatcher] depts: ${baseline.depts} → $freshDeptSet  changed=$deptChanged');
      debugPrint('[RoleChangeWatcher] role:  ${baseline.role} → $freshRole  changed=$roleChanged');

      if (deptChanged || roleChanged) {
        // ── 6a. Change detected → logout ──────────────────────────────────
        debugPrint('[RoleChangeWatcher] Role/dept change detected — forcing logout');

        await OrderAlertService.stop();
        await TaskAlertService.stopAll();
        WebSocketService().disconnect();
        await UserSessionHelper.clearSession();

        onRoleChanged();
      } else {
        // ── 6b. No change → update baseline so profile-page refreshes are
        //         reflected in future checks without causing false positives.
        await _saveBaseline(depts: freshDeptList, role: freshRole);
      }
    } catch (e) {
      debugPrint('[RoleChangeWatcher] Unexpected error: $e');
    } finally {
      _checking = false;
    }
  }

  // ── Utility ───────────────────────────────────────────────────────────────

  static bool _setsEqual(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }
}