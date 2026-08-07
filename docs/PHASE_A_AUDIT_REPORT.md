# Phase A Audit Report — ScreenSync Modernization

This document records the baseline measurements, dependency reviews, code inventories, security audits, and performance metrics collected during Phase A.

---

## 1. Baseline & Compilation Report

### 1.1 Static Analysis Count
- **Initial Warnings Count**: 202 warnings.
- **Key Warnings Categories**:
  - `avoid_print`: 178 warnings due to inline debug `print()` statements.
  - `invalid_override`: 6 compiler errors in foreground task handlers.
  - `unused_import`: 1 warning in `upload_service.dart`.
  - `depend_on_referenced_packages` / `uri_does_not_exist`: 3 errors in `test/widget_test.dart`.

### 1.2 Resolving Actions (Phase A)
- Method override signatures in `order_alert_foreground_task.dart` and `task_alert_foreground_task.dart` have been corrected to v8.x conventions.
- Package imports and `MyApp` constructor arguments inside `test/widget_test.dart` have been corrected.
- Stubs `FCMService.deregisterToken()` and `UserSessionHelper.logout()` have been added to resolve compiler references in logout utilities.

### 1.3 Test Run Status
All 25 dynamic parsing unit tests and the widget smoke tests compile and pass successfully:
```
00:02 +26: All tests passed!
```

---

## 2. Dependency Audit

### 2.1 Package Inventory (`pubspec.yaml`)
- **Core HTTP**: `dio: ^5.4.3` (locked, no upgrade required).
- **Messaging & Notifications**:
  - `firebase_core: ^2.24.1`
  - `firebase_messaging: ^14.7.1`
  - `flutter_local_notifications: ^17.1.2`
- **Utility Storage**: `shared_preferences: ^2.2.2`
- **Foreground Audio Service**: `flutter_foreground_task: ^8.6.0` (Upgraded from v6.x in preceding update session, signatures aligned).
- **Audio Engines**:
  - `just_audio: ^0.9.46`
  - `audioplayers: ^6.0.0`
- **State Websocket**: `web_socket_channel: ^2.4.0`

### 2.2 Dependency Rules
- **Pruning**: Unused packages or helper libraries are prohibited from insertion without explicit user approvals.
- **Version Lock**: Package versions are locked to local SDK capabilities.

---

## 3. Code & Architecture Inventory

### 3.1 Folder Structures
- `lib/constants/`: Configuration keys and endpoint strings.
- `lib/pages/`: 18 page layouts and state views.
- `lib/services/`: 22 background execution layers and REST client abstractions.
- `lib/utils/`: Standardized utility scripts, color mappings, and preference buffers.
- `lib/widgets/`: Exposes `dialog_helpers.dart` overlays.

### 3.2 Services Inventory (22 Files)
1. `alert_reload_coordinator.dart`
2. `checkout_service.dart`
3. `device_info.dart`
4. `fcm_background.dart`
5. `fcm_service.dart`
6. `food_order_service.dart`
7. `home_service.dart`
8. `login_service.dart`
9. `logout_service.dart`
10. `notification_handler.dart`
11. `order_alert_foreground_task.dart`
12. `order_alert_service.dart`
13. `profile_service.dart`
14. `role_change_watcher.dart`
15. `rooms_service.dart`
16. `session_change_service.dart`
17. `task_alert_foreground_task.dart`
18. `task_alert_service.dart`
19. `task_service.dart`
20. `unified_alert_foreground_task.dart`
21. `upload_service.dart`
22. `websocket_service.dart`

---

## 4. Performance Baseline (Pre-Optimization)

The following parameters are scheduled to be tracked under Profile mode during Phase B integrations:
- **Cold Start Duration**: Calculated using Android ADB shell cold boot timing metrics.
- **Widget Rebuild Frequency**: Tracked in DevTools Rebuild visualizer.
- **WS Latency**: Measures elapsed time from register action to registration acknowledgement.
- **Memory Consumption**: Tracked under a 30-minute stress trial in the DevTools Memory profile graph.

---

## 5. Security Audit

### 5.1 Storage Verification
- Checked if sensitive credentials are leaked inside SharedPreferences.
- **Findings**: User Profile data containing name, roles list, email, and user ID are saved in JSON format. SharedPreferences are cleared during logout but left unmodified if profile load fails during login.
- **Mitigation**: Ensure that session credentials are fully cleared during any login profile failure path.

### 5.2 Notification & Token Safety
- Stale FCM tokens on backend database tables cause security alerts post-logout.
- **Mitigation**: Standardize empty token registration `ScreenSync_save_fcm_token_mobile` during logouts.
