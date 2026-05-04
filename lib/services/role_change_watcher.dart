// services/role_change_watcher.dart

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

  RoleChangeWatcher({required this.onRoleChanged});

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void startWatching() {
    _active = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void stopWatching() {
    _active = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _active) {
      _checkForRoleChange();
    }
  }

  // ── Core check (departments + role) ───────────────────────────────────────

  Future<void> _checkForRoleChange() async {
    if (_checking) return;
    _checking = true;

    try {
      // ---------- Snapshot OLD state BEFORE the API call ----------
      final storedDepts = await UserSessionHelper.getDepartments();
      final storedRole  = await UserSessionHelper.getRole();   // e.g., "staff"

      // If nothing stored yet (first launch / already logged out), bail out
      if ((storedDepts == null || storedDepts.isEmpty) && storedRole == null) {
        return;
      }

      // ---------- Fetch fresh profile from server ----------
      final result = await ProfileService().getProfile();

      if (result['success'] != true) return; // network / server error → skip

      final profile = result['profile'] as Map<String, dynamic>;

      // ---------- Extract fresh department list ----------
      List<String> freshDepts = [];
      try {
        final raw = profile['departments'];
        if (raw is String) {
          freshDepts = List<String>.from(jsonDecode(raw));
        } else if (raw is List) {
          freshDepts = List<String>.from(raw);
        }
      } catch (_) {}

      // ---------- Extract fresh role ----------
      final freshRole = profile['role']?.toString().trim();   // adjust key as needed

      // ---------- Normalise for safe comparison ----------
      final storedDeptSet = (storedDepts ?? <String>[])
          .map((e) => e.trim().toLowerCase())
          .toSet();
      final freshDeptSet  = freshDepts
          .map((e) => e.trim().toLowerCase())
          .toSet();

      final deptChanged = (storedDeptSet != freshDeptSet);
      final roleChanged = (storedRole != freshRole);

      if (deptChanged || roleChanged) {
        debugPrint('[RoleChangeWatcher] Change detected -> forced logout');
        debugPrint('  departments: $storedDeptSet → $freshDeptSet');
        debugPrint('  role: $storedRole → $freshRole');

        // Stop all background services
        await OrderAlertService.stop();
        await TaskAlertService.stopAll();
        WebSocketService().disconnect();

        // Wipe the session
        await UserSessionHelper.clearSession();

        // Notify UI to navigate to login
        onRoleChanged();
      }
    } catch (e) {
      debugPrint('[RoleChangeWatcher] Error: $e');
    } finally {
      _checking = false;
    }
  }
}