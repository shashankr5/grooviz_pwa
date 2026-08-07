# ScreenSync Mobile Code Audit Report

**Target Project:** ScreenSync Mobile Flutter App (`com.tekchant.screensyncmobileapp`)  
**Audit Scope:** Entire `lib/` directory (`main.dart`, `pages/`, `services/`, `utils/`, `constants/`, `widgets/`)  
**Audit Type:** Read-Only Static Code & Architectural Analysis  
**Date:** July 21, 2026  

---

## Executive Overview

This audit evaluates the codebase of **ScreenSync Mobile**, a real-time operational dashboard for hotel operations built with Flutter. The application interfaces with an AWS Serverless backend (API Gateway REST & WebSocket API, AWS Lambda) and Firebase Cloud Messaging (FCM) to manage service requests, room service food orders, guest camera media uploads, task escalations, and background audio alerts across hotel departments.

While the project incorporates sophisticated real-time patterns (auto-reconnecting WebSockets, foreground task audio alerts, FCM token state recovery), several **critical bugs, state leaks, security vulnerabilities, and structural code quality issues** were identified that jeopardize runtime stability, security, and developer maintainability.

---

# 1. Critical Bugs

### BUG-CRIT-01: Non-Existent Method Calls in `LogoutHelper` (Runtime Crash Target)
* **File & Line Reference:** [`lib/utils/logout_helper.dart:36, 43`](file:///d:/grooviz%20Mobile/screen-sync/lib/utils/logout_helper.dart#L36-L43)
* **Description:** `LogoutHelper.logout()` calls `FCMService.deregisterToken()` (line 36) and `UserSessionHelper.logout()` (line 43). Neither method exists in their respective class.
  * `FCMService` contains no `deregisterToken()` method.
  * `UserSessionHelper` names its cleanup method `clearSession()`, not `logout()`.
* **Concrete Failure Scenario:** If any developer invokes `LogoutHelper.logout(context)` (as instructed by the class doc comments on lines 14–17), Dart throws a fatal `NoSuchMethodError` runtime exception, crashing the application during the user logout sequence.
* **Suggested Fix:**
  1. Implement `deregisterToken()` in `FCMService` to call the backend token unbinding endpoint.
  2. In `LogoutHelper.logout()`, replace `UserSessionHelper.logout()` with `await UserSessionHelper.clearSession()`.

---

### BUG-CRIT-02: Permanent Singleton Destruction on Logout in `LogoutService`
* **File & Line Reference:** [`lib/services/logout_service.dart:40`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/logout_service.dart#L40), [`lib/services/websocket_service.dart:282-288`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/websocket_service.dart#L282-L288)
* **Description:** `LogoutService._cleanupAndClearSession()` calls `WebSocketService().dispose()`. Because `WebSocketService` is a singleton (`factory WebSocketService() => _instance;`), calling `.dispose()` closes the singleton's `StreamController.broadcast()` (`_controller.close()`) and disposes the `isConnected` `ValueNotifier`.
* **Concrete Failure Scenario:** When a user logs out and a new user logs in without quitting the app process, the app attempts to reconnect using the same `WebSocketService` instance. When WebSocket messages arrive, `_handleMessage()` attempts to add events to the closed `_controller`, throwing `StateError: Cannot add event after closing stream`. All real-time push updates (food orders, task alerts) fail permanently until the app process is force-closed.
* **Suggested Fix:** Change `LogoutService` to call `WebSocketService().disconnect()` instead of `dispose()`. Reserve `dispose()` strictly for app termination.

---

### BUG-CRIT-03: FCM Token Acquisition Lockup on Fresh Reinstall Without Network
* **File & Line Reference:** [`lib/services/fcm_service.dart:94-115`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/fcm_service.dart#L94-L115)
* **Description:** In `FCMService.ensureFCMToken()`, when `_tokenCompleter` times out after 30 seconds without obtaining a token (e.g. device offline or missing Google Play Services), the method sets state to `FCMStatus.failed` and returns `null`. However, `_tokenCompleter` remains nullified while `_retryLoop()` continues running in the background.
* **Concrete Failure Scenario:** On a fresh install with poor connectivity or on non-GMS Android devices, `login_service.dart` receives `fcmToken == null` and blocks login with `fcm_pending: true`. If the user immediately retries, `ensureFCMToken()` re-creates `_tokenCompleter`, but `_startRetryLoopIfNeeded()` ignores the call because `_retryLoopActive` is already `true`. The second attempt hangs for another full 30-second timeout, frustrating staff during shift changes.
* **Suggested Fix:** Explicitly cancel and reset `_retryLoopActive` on timeout, and provide an explicit fallback mechanism or offline login override when FCM services are unavailable on the hardware.

---

### BUG-CRIT-04: Alert Count Ping-Pong Race Condition Between Local Decrement & Safety Poll
* **File & Line Reference:** [`lib/services/task_alert_service.dart:51-55`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/task_alert_service.dart#L51-L55), [`lib/services/alert_reload_coordinator.dart:118-137`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/alert_reload_coordinator.dart#L118-L137)
* **Description:** `TaskAlertService.stopOneServiceAlert()` optimistically decrements `_pendingServiceCount`. Simultaneously, `AlertReloadCoordinator` runs `_safetyPoll()` every 30 seconds or when the app resumes, calling `reloadTasks()`, fetching tasks from the backend, and resetting `TaskAlertService.resetServiceCount(openCount)`.
* **Concrete Failure Scenario:** Staff member accepts a task on device A. `stopOneServiceAlert()` decrements the count to 0, stopping the alarm. However, if the backend Lambda/database update takes 3–5 seconds to process, and `_safetyPoll()` or an app resume occurs during this window, `reloadTasks()` fetches the still-'Open' task from the server, calls `resetServiceCount(1)`, and re-triggers `ensureServiceRunning()`. The alarm suddenly starts ringing again after the user already accepted the task.
* **Suggested Fix:** Maintain a set of locally-acknowledged `taskId`s with a 30-second suppression window in `AlertReloadCoordinator` so server polls do not re-arm alerts for tasks recently accepted on the local device.

---

### BUG-CRIT-05: Unhandled Server Response Shape Cast Exceptions
* **File & Line Reference:** [`lib/services/food_order_service.dart:73-83`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/food_order_service.dart#L73-L83), [`lib/services/home_service.dart:74-80`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/home_service.dart#L74-L80)
* **Description:** Service methods assume API response bodies always contain a `STATUS` list (`response.data["STATUS"] as List`). If an API Gateway error (e.g. 504 Gateway Timeout, 403 Forbidden, WAF block) returns a plain HTML page or JSON object with `{ "message": "Internal server error" }` without a `STATUS` array, explicit casting `response.data["STATUS"] as List` throws a `TypeError`.
* **Concrete Failure Scenario:** When API Gateway experiences transient degradation or returns an unexpected error payload, the catch block catches the `TypeError`, but the service returns generic `"Network error"` while masking the actual server failure mode.
* **Suggested Fix:** Use safe list casting helper `_toList(response.data["STATUS"])` across all services (as already implemented in `LoginService`).

---

# 2. Logic & State Bugs

### BUG-LOG-01: Memory Leak & Duplicate WebSocket Listeners across Page Lifecycle
* **File & Line Reference:** [`lib/pages/food_orders_page.dart`](file:///d:/grooviz%20Mobile/screen-sync/lib/pages/food_orders_page.dart), [`lib/pages/home_page.dart:124-150`](file:///d:/grooviz%20Mobile/screen-sync/lib/pages/home_page.dart#L124-L150)
* **Description:** Multiple pages listen to `WebSocketService().stream` and `TaskAlertService` broadcast streams. In several secondary widget implementations, `StreamSubscription` instances are created in `initState()` or during state callbacks without being consistently stored and cancelled in `dispose()`.
* **Concrete Failure Scenario:** Navigating back and forth between screens creates orphaned stream listeners that continue executing `setState()` on unmounted widget states, leading to memory leaks and `setState() called after dispose()` console exceptions.
* **Suggested Fix:** Audit all page classes to ensure every `.listen()` subscription is assigned to a `StreamSubscription` variable and cancelled inside `dispose()`.

---

### BUG-LOG-02: Duplicate Local & Sound Notifications on Foreground FCM Arrival
* **File & Line Reference:** [`lib/services/fcm_background.dart:60`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/fcm_background.dart#L60), [`lib/services/websocket_service.dart:139-191`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/websocket_service.dart#L139-L191)
* **Description:** When an incoming order or task occurs, the backend fires both a Push Notification via FCM and a WebSocket event via `WebSocketService`. When the app is in the foreground, `FirebaseMessaging.onMessage` fires while `WebSocketService._handleMessage` simultaneously receives the event payload. Both attempt to start the foreground service alert (`OrderAlertService.ensureRunning()` / `TaskAlertService.ensureServiceRunning()`).
* **Concrete Failure Scenario:** Dual execution causes audio tracks to overlap or restart mid-phrase, producing distorted audio output or notification channel collisions.
* **Suggested Fix:** Gate FCM foreground event execution: if `WebSocketService().isConnected.value == true`, suppress redundant foreground sound triggers from FCM `onMessage`.

---

### BUG-LOG-03: Timer Race Condition in `RoleChangeWatcher`
* **File & Line Reference:** [`lib/services/role_change_watcher.dart:33-55`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/role_change_watcher.dart#L33-L55)
* **Description:** `RoleChangeWatcher` manages both a periodic 5-minute timer (`_periodicTimer`) and a 3-second lifecycle resume debounce timer (`_debounce`). Resuming the application triggers `_debounce` while `_periodicTimer` remains active.
* **Concrete Failure Scenario:** If the app resumes right before the 5-minute periodic timer tick, both timers invoke `_checkForRoleChange()` almost simultaneously. Although `_checking` flag guards execution, concurrent calls can overlap before `_checking` is set to `true`, making redundant `getProfile()` API requests.
* **Suggested Fix:** In `didChangeAppLifecycleState()`, reset the `_periodicTimer` countdown whenever `_debounce` is scheduled.

---

### BUG-LOG-04: Session Clearing Inconsistency Between `getUserProfile` and `getSafeUserProfile`
* **File & Line Reference:** [`lib/utils/user_session_helper.dart:145-176, 226-240`](file:///d:/grooviz%20Mobile/screen-sync/lib/utils/user_session_helper.dart#L145-L176)
* **Description:** `UserSessionHelper.getUserProfile()` verifies `cachedUserId == currentUserId`. If mismatched, it executes `clearCachedProfile()`, removing both `user_profile` and `user_profile_user_id`. Conversely, `getSafeUserProfile()` removes `user_profile` but forgets to clear `user_profile_user_id`.
* **Concrete Failure Scenario:** Stale `user_profile_user_id` values remain in `SharedPreferences`, causing subsequent login sessions to misidentify cached profile ownership.
* **Suggested Fix:** Standardize profile caching calls by having `getSafeUserProfile()` delegate directly to `getUserProfile()`.

---

# 3. Security Concerns

### SEC-01: Hardcoded Static AWS API Gateway Key in Source Code
* **File & Line Reference:** [`lib/constants/api_constants.dart:4`](file:///d:/grooviz%20Mobile/screen-sync/lib/constants/api_constants.dart#L4)
* **Description:** The static API key (`x-api-key: sa9F4GyTT45OImNkKjaHu6bsJbk8UWmZfKdzmeoc`) is committed directly into the client repository as a constant string.
* **Security Risk:** Flutter APKs and IPAs can be trivially decompiled using reverse-engineering tools (e.g. `jadx`, `apktool`, `strings`). Anyone obtaining the client binary can extract this API key and make unauthorized direct HTTP requests against the backend AWS API Gateway endpoints.
* **Suggested Fix:**
  1. Store sensitive keys in build-time environment variables using `--dart-define` or `flutter_dotenv`.
  2. Implement backend rate limiting, IP restrictions, or IAM/Cognito authentication.

---

### SEC-02: PII (Personally Identifiable Information) Logged to Console in Production
* **File & Line Reference:** [`lib/services/login_service.dart:100`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/login_service.dart#L100), [`lib/services/food_order_service.dart:57, 65`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/food_order_service.dart#L57-L65), [`lib/services/home_service.dart:108`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/home_service.dart#L108)
* **Description:** Services utilize `dev.log()` and standard `print()` statements to output full request payloads and response bodies, including passwords, guest phone numbers, full names, room numbers, and customer contact data.
* **Security Risk:** On Android and iOS, `print()` and `dev.log()` write to system logs (logcat / syslog). Malicious apps with log-reading permissions or connected USB debugging sessions can inspect system logs to harvest guest PII and staff credentials.
* **Suggested Fix:** Wrap all logging calls in a custom logger utility that checks `kDebugMode` from `package:flutter/foundation.dart` and sanitizes sensitive fields before printing.

---

### SEC-03: Absence of Session Tokens & Bearer Authorization Headers
* **File & Line Reference:** [`lib/constants/api_constants.dart`](file:///d:/grooviz%20Mobile/screen-sync/lib/constants/api_constants.dart), [`lib/services/home_service.dart:61-65`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/home_service.dart#L61-L65)
* **Description:** Authentication relies entirely on passing `user_id` as an unencrypted JSON body parameter. The app does not request or send OAuth tokens, JWTs, or session cookies in HTTP headers (`Authorization: Bearer <token>`).
* **Security Risk:** Any user capable of proxying HTTP traffic (using tools like Charles Proxy or Fiddler) can modify `user_id` in request payloads to fetch or mutate tasks, food orders, and checkout reports belonging to other users or enterprises.
* **Suggested Fix:** Implement JWT token issuance upon login and validate session tokens in backend API Gateway authorizers.

---

# 4. Error Handling Gaps

### ERR-01: Exposure of Raw Exception Strings to End Users
* **File & Line Reference:** [`lib/services/task_service.dart:151-153`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/task_service.dart#L151-L153), [`lib/services/home_service.dart:272`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/home_service.dart#L272)
* **Description:** Catch blocks format user-facing error messages using raw string interpolation: `"message": "Exception: $e"` or `"message": "Error: $e"`.
* **Impact:** Technical exception messages (e.g. `FormatException`, `DioException [bad response]`) are presented directly to hotel staff via UI SnackBars, confusing users and exposing internal implementation details.
* **Suggested Fix:** Map internal exceptions to user-friendly messages (e.g., *"Unable to connect. Please check your internet connection."*).

---

### ERR-02: Silent Error Swallowing in Image Upload & Room Services
* **File & Line Reference:** [`lib/services/upload_service.dart`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/upload_service.dart), [`lib/services/rooms_service.dart`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/rooms_service.dart)
* **Description:** Network calls during room list fetching and image upload operations contain empty or unhandled `catch (_)` blocks.
* **Impact:** When a guest photo upload fails due to network dropouts or image encoding issues, the UI spinner dismisses without showing an error message, leaving staff believing the upload succeeded.
* **Suggested Fix:** Ensure all asynchronous service methods return explicit success/failure indicators and display error SnackBars on failure.

---

### ERR-03: Disparate API Response Payload Structures Across Microservices
* **File & Line Reference:** [`lib/services/food_order_service.dart:73-86, 258-270`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/food_order_service.dart#L73-L86), [`lib/services/login_service.dart:257-291`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/login_service.dart#L257-L291)
* **Description:** Backend AWS Lambda microservices return data using three incompatible conventions:
  1. `STATUS` list + `RESULT` list (`login`, `tasks`).
  2. `RESULT` list directly without `STATUS` (`update_food_order_status`).
  3. `STATUS[0].response` containing a stringified nested JSON payload (`get_food_orders_for_fnb`).
* **Impact:** Parsing logic is duplicated and fragmented across every service file. Adding new endpoints requires writing fragile custom parsing code.
* **Suggested Fix:** Standardize backend Lambda output schemas or create a single `ApiResponseParser` helper class to unify response normalization.

---

# 5. Code Quality & Maintainability

### QUAL-01: Redundant Status Color & Label Logic
* **File & Line Reference:** [`lib/services/food_order_service.dart:181-205`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/food_order_service.dart#L181-L205), [`lib/pages/food_orders_page.dart`](file:///d:/grooviz%20Mobile/screen-sync/lib/pages/food_orders_page.dart), [`lib/services/home_service.dart:128-157`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/home_service.dart#L128-L157)
* **Description:** Status normalization (`_statusText`) and color mapping (`_statusColor`) are duplicated across `FoodOrderService`, `HomeService`, `TaskService`, and individual page classes instead of reusing `FoodOrderStatus` from `lib/utils/food_order_status.dart`.
* **Impact:** If a status label or brand color changes, updates must be made in 5+ separate files, risking UI inconsistency.
* **Suggested Fix:** Consolidate all status mapping functions into `lib/utils/food_order_status.dart` and `lib/utils/task_status.dart`.

---

### QUAL-02: Monolithic View Controllers (Huge File Sizes)
* **File & Line Reference:** 
  * [`lib/pages/home_page.dart`](file:///d:/grooviz%20Mobile/screen-sync/lib/pages/home_page.dart) (1,922 lines)
  * [`lib/pages/food_orders_page.dart`](file:///d:/grooviz%20Mobile/screen-sync/lib/pages/food_orders_page.dart) (1,850+ lines)
  * [`lib/pages/tasks_page.dart`](file:///d:/grooviz%20Mobile/screen-sync/lib/pages/tasks_page.dart) (1,700+ lines)
  * [`lib/pages/ticket_details_page.dart`](file:///d:/grooviz%20Mobile/screen-sync/lib/pages/ticket_details_page.dart) (1,600+ lines)
* **Description:** Core pages combine networking, state management, dialog generators, filter logic, and complex widget sub-trees within single monolithic `StatefulWidget` files.
* **Impact:** Reduced readability, high risk of regression bugs during edits, and difficulty writing automated widget tests.
* **Suggested Fix:** Decompose large page files into smaller, modular sub-widgets (e.g., `TaskFilterChips`, `OrderCardWidget`, `RushHourBanner`).

---

### QUAL-03: Ubiquitous Magic Strings
* **File & Line Reference:** [`lib/pages/main_navigation.dart:84-100`](file:///d:/grooviz%20Mobile/screen-sync/lib/pages/main_navigation.dart#L84-L100), [`lib/services/websocket_service.dart:126-248`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/websocket_service.dart#L126-L248)
* **Description:** Department names (`"Food & Beverage"`, `"Front Office"`, `"House Keeping"`), task statuses (`"PENDING"`, `"IN_PROGRESS"`, `"CLOSED"`), and WebSocket event types (`"RUSH_HOUR_UPDATED"`, `"ESCALATION_ALERT"`) are hardcoded as raw string literals.
* **Impact:** Typographical errors (e.g. `"Housekeeping"` vs `"House Keeping"`) silently break department tab filtering and WebSocket event handling.
* **Suggested Fix:** Define central Dart `enum`s or constant definitions for department keys, status identifiers, and WebSocket message types.

---

# 6. Performance Concerns

### PERF-01: Redundant Battery-Draining Periodic Timers
* **File & Line Reference:** [`lib/pages/home_page.dart:110-113`](file:///d:/grooviz%20Mobile/screen-sync/lib/pages/home_page.dart#L110-L113), [`lib/services/alert_reload_coordinator.dart:57-60`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/alert_reload_coordinator.dart#L57-L60), [`lib/services/role_change_watcher.dart:33-36`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/role_change_watcher.dart#L33-L36)
* **Description:** The app simultaneously runs multiple periodic background timers:
  1. `HomePage._escalationTimer` (runs every 60 seconds).
  2. `AlertReloadCoordinator._pollTimer` (runs every 30 seconds).
  3. `RoleChangeWatcher._periodicTimer` (runs every 5 minutes).
  4. Active WebSocket stream connection listening for real-time events.
* **Impact:** When WebSockets are active, periodic REST polling creates redundant network overhead, battery drain, and server load on AWS Lambda.
* **Suggested Fix:** Pause periodic REST polling when `WebSocketService().isConnected.value == true`, using timers strictly as a fallback when the WebSocket disconnects.

---

### PERF-02: Main-Thread JSON Decoding & Object Mapping
* **File & Line Reference:** [`lib/services/food_order_service.dart:85-88`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/food_order_service.dart#L85-L88), [`lib/services/task_service.dart:96-98`](file:///d:/grooviz%20Mobile/screen-sync/lib/services/task_service.dart#L96-L98)
* **Description:** Response string decoding (`json.decode(responseString)`) and mapping of large order arrays occur synchronously on the main Dart UI thread.
* **Impact:** During peak operational hours with large order lists, parsing response payloads on the main isolate causes frame drops (UI jank) on lower-end mobile devices.
* **Suggested Fix:** Offload heavy JSON string parsing to background isolates using Flutter's `compute()` function.

---

### PERF-03: Uncached Base64 & Network Image Rendering
* **File & Line Reference:** [`lib/pages/camera_content_page.dart`](file:///d:/grooviz%20Mobile/screen-sync/lib/pages/camera_content_page.dart), [`lib/pages/my_contents_page.dart`](file:///d:/grooviz%20Mobile/screen-sync/lib/pages/my_contents_page.dart)
* **Description:** Guest images and room photos are rendered using standard `Image.memory()` / `Image.network()` without setting `cacheWidth`/`cacheHeight` or using disk caching.
* **Impact:** Displaying full-resolution images in gallery grid views consumes high memory (RAM), triggering Out-Of-Memory (OOM) crashes on budget Android devices.
* **Suggested Fix:** Implement `cached_network_image` and specify `cacheWidth`/`cacheHeight` on image widgets to downscale images to grid cell dimensions.

---

# 7. Suggested Enhancements

1. **Automatic HTTP Retry Interceptor:** Add `dio_smart_retry` to `Dio` instances to automatically retry failed network requests with exponential backoff before throwing network errors.
2. **Offline Data Persistence:** Integrate `Isar` or `Sqflite` to store tasks, room lists, and food orders locally so staff can review ticket history while moving through hotel dead-zones (e.g. elevators, basements).
3. **Shimmer Skeleton Loaders:** Replace generic `CircularProgressIndicator` widgets on `HomePage`, `TasksPage`, and `FoodOrdersPage` with layout-matching shimmer placeholders (`shimmer` package) for a polished enterprise user experience.
4. **Kitchen Order Ticket (KOT) Bluetooth Printing:** Add `blue_thermal_printer` support to `FoodOrdersPage` allowing kitchen staff to print physical receipts upon accepting room service orders.
5. **State Management Migration:** Transition from inline `setState()` logic in monolithic pages to lightweight `Provider` / `Riverpod` / `Bloc` controllers to decouple business rules from presentation code.

---

# 8. Priority Matrix

The following matrix categorizes all identified findings by **Severity** (Critical / High / Medium / Low) and **Effort** (Small / Medium / Large) to assist engineering leadership in prioritizing remediation sprints.

| Issue ID | Category | Description | Severity | Effort | Recommended Action |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **BUG-CRIT-01** | Critical Bug | Non-existent method calls in `LogoutHelper` (`deregisterToken`, `logout`) | **Critical** | **Small** | Implement `deregisterToken` in `FCMService`; fix method call to `clearSession()`. |
| **BUG-CRIT-02** | Critical Bug | `WebSocketService().dispose()` on logout breaks subsequent logins | **Critical** | **Small** | Replace `dispose()` with `disconnect()` in `LogoutService`. |
| **SEC-01** | Security | Hardcoded AWS API Gateway key in `api_constants.dart` | **Critical** | **Medium** | Move key to build-time `--dart-define` config; restrict backend CORS/WAF. |
| **SEC-03** | Security | Missing JWT / Session authorization headers on REST APIs | **Critical** | **Large** | Update Lambda backend & mobile app to use Bearer JWT tokens in headers. |
| **BUG-CRIT-03** | Critical Bug | FCM token acquisition loop lockup on GMS-less / offline devices | **High** | **Medium** | Reset completer state on timeout; allow offline login fallback. |
| **BUG-CRIT-04** | Critical Bug | Alert count ping-pong race condition between poll and local accept | **High** | **Medium** | Implement local task ID suppression window in `AlertReloadCoordinator`. |
| **BUG-CRIT-05** | Critical Bug | Unhandled response shape cast exceptions on API Gateway errors | **High** | **Small** | Use safe list parsing helper (`_toList`) across all service calls. |
| **SEC-02** | Security | Guest PII and passwords printed to system logcat/syslog | **High** | **Small** | Wrap logging calls in `kDebugMode` check and sanitize PII fields. |
| **BUG-LOG-01** | Logic Bug | Uncancelled `StreamSubscription` leaks in page widgets | **High** | **Medium** | Ensure all `.listen()` subscriptions are cancelled in `dispose()`. |
| **BUG-LOG-02** | Logic Bug | Duplicate foreground audio triggers from FCM + WebSocket | **Medium** | **Small** | Suppress FCM foreground sound when WebSocket is connected. |
| **BUG-LOG-03** | Logic Bug | Race condition with dual timers in `RoleChangeWatcher` | **Medium** | **Small** | Reset periodic timer countdown when scheduling resume debounce. |
| **ERR-01** | Error Handling | Raw exception strings displayed to users in SnackBars | **Medium** | **Small** | Replace `$e` strings with user-friendly error messages. |
| **ERR-02** | Error Handling | Silent error swallowing in upload & room services | **Medium** | **Small** | Return explicit status maps and surface error SnackBars on failure. |
| **PERF-01** | Performance | Redundant periodic polling overlapping active WebSocket | **Medium** | **Medium** | Pause REST polling timers when WebSocket connection is active. |
| **PERF-03** | Performance | High memory usage rendering uncached base64/network images | **Medium** | **Medium** | Add `cached_network_image` and downscale with `cacheWidth`/`cacheHeight`. |
| **QUAL-01** | Code Quality | Redundant status text & color mapping logic across 5+ files | **Low** | **Small** | Centralize status mappings in `food_order_status.dart` & `task_status.dart`. |
| **QUAL-02** | Code Quality | Monolithic page classes (1,600+ to 1,900+ lines per file) | **Low** | **Large** | Extract reusable UI sub-components into standalone widget files. |
| **QUAL-03** | Code Quality | Ubiquitous magic strings for statuses, departments, and WS events | **Low** | **Medium** | Replace raw string literals with Dart `enum`s and static constants. |
| **PERF-02** | Performance | Synchronous JSON parsing of large arrays on main UI isolate | **Low** | **Medium** | Use `compute()` isolate function for heavy JSON decoding tasks. |

---
*Report generated automatically by Antigravity Technical Auditor.*
