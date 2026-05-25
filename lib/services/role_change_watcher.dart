// services/role_change_watcher.dart
//
// CHANGES IN THIS VERSION:
//  1. Comparison uses profile JSON blob (saved by ProfileService/ProfilePage)
//     rather than the departments StringList.
//  2. 3-second debounce after resume before the API check fires to avoid
//     spurious logouts on FCM-driven background→resume events.
//  3. Comparison is symmetric-difference based (Set equality).
//  4. Saves authoritative dept list + role into dedicated prefs keys at startup.
//  5. NEW: Added _periodicTimer — checks every 5 minutes while app is in the
//     foreground so role changes are caught even without a background/resume cycle.
//  6. NEW: Calls SessionChangeService.instance.notifyRoleChange() when a change
//     is detected, so all open pages can react immediately before logout.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';

import 'profile_service.dart';
import 'order_alert_service.dart';
import 'task_alert_service.dart';
import 'websocket_service.dart';
import 'session_change_service.dart';
import '../utils/user_session_helper.dart';

class RoleChangeWatcher with WidgetsBindingObserver {
  final VoidCallback onRoleChanged;

  bool _active   = false;
  bool _checking = false;

  /// Debounce timer — prevents the check from firing during the brief
  /// background→resume that FCM causes when delivering a notification.
  Timer? _debounce;

  /// Periodic timer — catches role changes while app stays in foreground.
  Timer? _periodicTimer;

  /// How long to wait after resume before we actually hit the API.
  static const _kDebounceDelay = Duration(seconds: 3);

  /// How often to poll while the app is active in the foreground.
  static const _kPollInterval = Duration(minutes: 5);

  RoleChangeWatcher({required this.onRoleChanged});

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void startWatching() {
    _active = true;
    WidgetsBinding.instance.addObserver(this);

    // Periodic foreground check so we catch changes without needing a
    // background/resume cycle (e.g. admin changes role while app is open).
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_kPollInterval, (_) {
      if (_active) _checkForRoleChange();
    });
  }

  void stopWatching() {
    _active = false;
    _debounce?.cancel();
    _periodicTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_active) return;

    if (state == AppLifecycleState.resumed) {
      _debounce?.cancel();
      _debounce = Timer(_kDebounceDelay, _checkForRoleChange);
    } else if (state == AppLifecycleState.paused ||
               state == AppLifecycleState.inactive) {
      _debounce?.cancel();
    }
  }

  // ── Snapshot helpers ──────────────────────────────────────────────────────

  static Future<({Set<String> depts, String? role})> _loadBaseline() async {
    final depts = await UserSessionHelper.getDepartments();
    final role  = await UserSessionHelper.getRole();
    return (
      depts: depts.map((e) => e.trim().toLowerCase()).toSet(),
      role:  role?.trim(),
    );
  }

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
      final baseline = await _loadBaseline();

      if (baseline.depts.isEmpty && baseline.role == null) return;

      final result = await ProfileService().getProfile();

      // Network / server error → skip silently.
      if (result['success'] != true) return;

      final profile = result['profile'] as Map<String, dynamic>;

      // Parse fresh depts
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

      final freshRole = profile['role']?.toString().trim();

      final deptChanged = !_setsEqual(baseline.depts, freshDeptSet);
      final roleChanged = (baseline.role != freshRole);

      debugPrint('[RoleChangeWatcher] depts: ${baseline.depts} → $freshDeptSet  changed=$deptChanged');
      debugPrint('[RoleChangeWatcher] role:  ${baseline.role} → $freshRole  changed=$roleChanged');

      if (deptChanged || roleChanged) {
        debugPrint('[RoleChangeWatcher] Role/dept change detected — notifying pages then forcing logout');

        // Notify all listening pages BEFORE logout so they can react if needed.
        SessionChangeService.instance.notifyRoleChange(freshRole ?? '');

        // Small delay so pages receive the stream event before navigation clears them.
        await Future.delayed(const Duration(milliseconds: 200));

        await OrderAlertService.stop();
        await TaskAlertService.stopAll();
        WebSocketService().disconnect();
        await UserSessionHelper.clearSession();

        onRoleChanged();
      } else {
        // No change — update baseline so profile-page refreshes don't cause
        // false positives on the next check.
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