// services/role_change_watcher.dart
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

  Timer? _debounce;
  Timer? _periodicTimer;

  static const _kDebounceDelay = Duration(seconds: 3);
  static const _kPollInterval  = Duration(minutes: 5);

  RoleChangeWatcher({required this.onRoleChanged});

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void startWatching() {
    _active = true;
    WidgetsBinding.instance.addObserver(this);
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
      if (result['success'] != true) return;

      final profile = result['profile'] as Map<String, dynamic>;

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
      final roleChanged = baseline.role != freshRole;

      debugPrint('[RoleChangeWatcher] depts: ${baseline.depts} → $freshDeptSet  changed=$deptChanged');
      debugPrint('[RoleChangeWatcher] role:  ${baseline.role} → $freshRole  changed=$roleChanged');

      if (deptChanged || roleChanged) {
        debugPrint('[RoleChangeWatcher] Role/dept change detected — notifying then logging out');

        // Build human-readable reason
        String reason;
        if (roleChanged && deptChanged) {
          reason = 'Your role and department have been updated.';
        } else if (roleChanged) {
          reason = 'Your role has been updated.';
        } else {
          reason = 'Your department has been updated.';
        }

        // Store reason so MainNavigation can display it
        SessionChangeService.instance.setChangeReason(reason);

        // Notify all listening pages
        SessionChangeService.instance.notifyRoleChange(freshRole ?? '');

        // Small delay so stream listeners receive the event
        await Future.delayed(const Duration(milliseconds: 200));

        // Stop all alerts and clean up
        await OrderAlertService.stop();
        await TaskAlertService.stopAll();
        WebSocketService().disconnect();
        await UserSessionHelper.clearSession();

        onRoleChanged();
      } else {
        // No change — update baseline
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