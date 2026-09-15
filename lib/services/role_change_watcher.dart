// services/role_change_watcher.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';

import 'profile_service.dart';
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
  static const _kPollInterval  = Duration(minutes: 30);

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

  bool _didPause = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_active) return;
    if (state == AppLifecycleState.paused) {
      _didPause = true;
      _debounce?.cancel();
      return;
    }
    if (state == AppLifecycleState.inactive) {
      _debounce?.cancel();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (!_didPause) return; // shade pull — skip
      _didPause = false;
      _debounce?.cancel();
      _debounce = Timer(_kDebounceDelay, _checkForRoleChange);
    }
  }

  // ── Snapshot helpers ──────────────────────────────────────────────────────

  static Future<({Set<String> depts, String? role})> _loadBaseline() async {
    var depts = await UserSessionHelper.getInitialDepartments();
    var role  = await UserSessionHelper.getInitialRole();

    // Fallback to standard session role/depts if initial baseline was not set yet
    if (role == null || depts.isEmpty) {
      final fallbackRole  = await UserSessionHelper.getRole();
      final fallbackDepts = await UserSessionHelper.getDepartments();

      if (role == null && fallbackRole != null) {
        role = fallbackRole;
        await UserSessionHelper.saveInitialRole(role);
      }
      if (depts.isEmpty && fallbackDepts.isNotEmpty) {
        depts = fallbackDepts;
        await UserSessionHelper.saveInitialDepartments(depts);
      }
    }

    return (
      depts: depts.map((e) => e.trim().toLowerCase()).toSet(),
      role:  role?.trim(),
    );
  }

  // ── Core check ────────────────────────────────────────────────────────────

  Future<void> _checkForRoleChange() async {
    if (_checking || !_active) return;
    _checking = true;

    debugPrint('[RoleChangeWatcher] ⏱ _checkForRoleChange() fired at ${DateTime.now()}');

    try {
      final baseline = await _loadBaseline();

      debugPrint('[RoleChangeWatcher] 📖 Baseline from SharedPrefs: role="${baseline.role}" depts=${baseline.depts}');

      if (baseline.depts.isEmpty && baseline.role == null) {
        debugPrint('[RoleChangeWatcher] ⚠️ Baseline empty — attempting to seed from getProfile() before comparing.');
        final seedResult = await ProfileService().getProfile();
        if (seedResult['success'] != true) {
          debugPrint('[RoleChangeWatcher] ⚠️ Could not seed baseline — skipping this cycle.');
          return;
        }
        final seeded = await _loadBaseline();
        if (seeded.depts.isEmpty && seeded.role == null) {
          debugPrint('[RoleChangeWatcher] ⚠️ Baseline still empty after seed — skipping.');
          return;
        }
        debugPrint('[RoleChangeWatcher] ✅ Baseline seeded from server: role="${seeded.role}" depts=${seeded.depts}');
        return; // First-run seed — no change to detect yet.
      }

      // ── Step 2: Fetch fresh profile from server ───────────────────────────
      // NOTE: ProfileService().getProfile() also calls saveDepartments() and
      // saveRole() internally, which would overwrite SharedPreferences.
      // That's why we read the baseline FIRST (step 1), then compare against
      // the values returned in the response object — not re-read from prefs.
      final result = await ProfileService().getProfile();
      if (result['success'] != true) {
        debugPrint('[RoleChangeWatcher] ⚠️  getProfile() failed: ${result['message']}');
        return;
      }

      final profile = result['profile'] as Map<String, dynamic>;

      debugPrint('[RoleChangeWatcher] 📥 Fresh profile from server: role="${profile['role']}" departments=${profile['departments']}');

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

      debugPrint('[RoleChangeWatcher] 🔍 Comparison: role changed=$roleChanged ("${baseline.role}" → "$freshRole")');
      debugPrint('[RoleChangeWatcher] 🔍 Comparison: depts changed=$deptChanged (${baseline.depts} → $freshDeptSet)');

      if (deptChanged || roleChanged) {
        debugPrint('[RoleChangeWatcher] Role/dept change detected — notifying then logging out');

        // Build human-readable reason
        String reason;
        if (roleChanged && deptChanged) {
          reason = 'Your role and department have been updated by an administrator.';
        } else if (roleChanged) {
          reason = 'Your role has been changed by an administrator.';
        } else if (deptChanged) {
          reason = 'Your department assignment has changed.';
        } else {
          reason = 'Your account permissions have changed.';
        }

        // Store reason so MainNavigation can display it
        SessionChangeService.instance.setChangeReason(reason);

        // Notify all listening pages
        SessionChangeService.instance.notifyRoleChange(freshRole ?? '');

        // Small delay so stream listeners receive the event
        await Future.delayed(const Duration(milliseconds: 200));

        // Clean up the session and disconnect live updates.
        WebSocketService().disconnect();
        await UserSessionHelper.clearSession();

        onRoleChanged();
      } else {
        // No change detected.
        // NOTE: We do NOT call _saveBaseline() here. ProfileService().getProfile()
        // already wrote fresh departments+role to SharedPreferences internally,
        // so the baseline is already up to date for the next check.
        debugPrint('[RoleChangeWatcher] ✅ No role/dept change detected.');
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