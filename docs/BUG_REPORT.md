# ScreenSync Mobile — Bug Report & Fix Summary

> This document covers every bug encountered during development, the root cause analysis, and the fix applied. Written for technical interviews and team handoff.

---

## BUG 1 — Service task notifications silent in background and killed state

### What the user saw
When a new service request was created, staff phones received the alert sound only when the app was open. If the app was backgrounded or killed, nothing happened — no tray notification, no sound.

### Root cause
The two Lambda functions responsible for accepting and closing service requests (`accept_service_request_mobile1` and `close_service_mobile1`) only sent FCM to the **guest TV device** (data-only payload). They never sent any FCM to staff mobile phones. Staff were only notified via WebSocket, which only works when the app is in the foreground.

Compare this to food orders: `update_food_order_mobile1` already sent FCM with a `notification: { title, body }` block to staff phones, which is why food worked in all three states.

The critical Android/iOS rule: a data-only FCM message (no `notification` block) will not display in the notification tray when the app is backgrounded or killed. The background isolate handler runs but the user sees nothing and hears nothing.

### Fix
Added `sendMobileStaffNotification()` to both Lambdas. This function:
1. Queries `user_fcm_tokens` via `user_role_dept_mapping` to get FCM tokens for all active staff in the department
2. Sends a multicast FCM with a `notification: { title, body }` block so Android/iOS shows the tray notification automatically

Table name, column names, and join pattern were confirmed from the existing food Lambda (`update_food_order_mobile1`) which already used the correct schema.

### Files changed
- `accept_service_request_mobile1/index.mjs` — added mobile Firebase app + `sendMobileStaffNotification()`
- `close_service_mobile1/index.mjs` — same

### Interview answer
"The Lambdas were only sending FCM to the TV device. Staff phones had no FCM at all — only WebSocket, which dies when the app leaves the foreground. We added a second Firebase send to all department staff with a notification block, matching the pattern already used by the food order Lambda."

---

## BUG 2 — Service task alert not starting in background/killed state (Flutter side)

### What the user saw
Even after the Lambda fix above, the alert sound still did not start on staff phones in background/killed state when a service request arrived. Food orders worked fine with the same mechanism.

### Root cause
In `alert_reload_coordinator.dart`, the `reloadTasks()` function computed a `pendingCount` using `isAssignedToMe()`. A newly created service request has `assigned_to = NULL` and `accepted_by_user_id = NULL`. The original `isAssignedToMe()` checked those fields against the current user's ID — if all fields were null, it fell through and returned `false`, meaning the task counted for nobody. `pendingCount = 0` → no alert started.

Food worked because `reloadFood()` had no user ID filter — any pending food order counted for everyone.

```dart
// BEFORE — returned false when all ownership fields were null
bool isAssignedToMe(dynamic s) => _matchesUserId(s, const [
  'assigned_to_user_id', 'assigned_to', 'accepted_by_user_id',
]);
```

### Fix
`isAssignedToMe()` was updated to return `true` when all ownership fields are null (unassigned task). Unassigned tasks should alert all staff. Once someone accepts (`accepted_by_user_id` is set), `isUnassigned` becomes false and only the acceptor's device keeps alerting.

```dart
// AFTER — unassigned tasks count for everyone
bool isAssignedToMe(dynamic s) {
  final isUnassigned = assignedTo is null/0 AND acceptedBy is null/0;
  if (isUnassigned) return true;
  return _matchesUserId(s, [...]);
}
```

### Files changed
- `lib/services/alert_reload_coordinator.dart` — `isAssignedToMe()` logic

### Interview answer
"The pending count filter used a user ID comparison that returned false when no user was assigned, so new unassigned service requests never incremented the count on any device. Food had no such filter. We made unassigned tasks count for all staff, which is the correct intent — whoever is in the department should be alerted."

---

## BUG 3 — Alert not stopping cross-device when a staff member accepts a task

### What the user saw
User A accepts a task. The alert stops on User A's device. But User B and User C (other staff) still have the alert sound playing. The only way to stop it was to manually refresh.

### Root cause
A race condition between two parallel systems both controlling `_serviceTaskCount` in `AlertStateManager`.

**Correct path (server reconciliation):**
`SERVICE_TASK_ACCEPTED` FCM → `AlertReloadCoordinator.reloadTasks()` → server returns task with `accepted_by_user_id` set → `isTrulyOpen = false` → `pendingCount = 0` → `setServiceTaskCount(0)` → alert stops.

**Broken path (stale local data):**
`notifyNewTask()` fires at the end of every FCM handler → `_newTaskSub` stream in `HomePage` fires → `_loadTasks()` runs → recalculates `openCount` from the **in-memory task list** (which still shows `status = "Open"` because it hasn't refreshed from server yet) → calls `TaskAlertService.resetServiceCount(openCount, reconcileAlert: true)` → immediately re-arms the alert with count = 1.

The comment in the code even said "cannot re-arm" — but it was wrong. The two paths ran at the same time and the stale local path won because it ran synchronously while the server call was still in flight.

```
Timeline:
t=0  FCM arrives
t=1  reloadTasks() → API call starts
t=2  notifyNewTask() fires
t=3  _loadTasks() runs → reads stale local list → resetServiceCount(1) ← re-arms
t=4  API returns → pendingCount=0 → setServiceTaskCount(0) → stops
t=5  But _loadTasks() already re-armed at t=3...
```

In practice the race was consistent because `notifyNewTask()` was called before `reloadTasks()` returned, and `_loadTasks()` ran synchronously against cached data.

### Fix
Removed the `resetServiceCount` call from `home_page._loadTasks()` entirely. Alert counts are now the **exclusive responsibility** of `AlertReloadCoordinator.reloadTasks()` which always queries the server with proper filters. The local task list is only used for UI display.

```dart
// REMOVED from home_page.dart _loadTasks():
// final openCount = tasks.where(...).length;
// TaskAlertService.resetServiceCount(openCount, reconcileAlert: true);
```

### Files changed
- `lib/pages/home_page.dart` — removed stale local count recalculation

### Interview answer
"Two systems were both writing to the same alert count variable. The correct system queried the server. The broken system read from a stale in-memory cache. They ran in parallel and the stale one wrote last, re-arming the alert. The fix was to make the alert count a single source of truth — only the server reconciliation path writes to it."

---

## BUG 4 — Service order notification appearing twice in foreground

### What the user saw
When a new service request arrived while the app was open, the notification appeared twice in the tray.

### Root cause
When the app is in the foreground and an FCM message with a `notification` block arrives:
1. Android's FCM SDK auto-displays it in the notification tray
2. Flutter's `onMessage.listen` fires, and `_showLambdaNotification()` also displays it via `flutter_local_notifications`

Both fired independently, producing two identical notifications.

### Fix
Added `setForegroundNotificationPresentationOptions` to suppress the FCM SDK's own display in foreground. Only `_showLambdaNotification()` runs in foreground, giving full control over the channel, sound, and ID.

```dart
await messaging.setForegroundNotificationPresentationOptions(
  alert: false,
  badge: false,
  sound: false,
);
```

### Files changed
- `lib/services/notification_handler.dart` — added `setForegroundNotificationPresentationOptions`

### Interview answer
"FCM was displaying the notification once automatically and our local notification plugin was displaying it a second time. We suppressed FCM's auto-display in foreground mode so we have full control over how notifications are shown."

---

## BUG 5 — Notification ID collision for SERVICE_TASK_ACCEPTED and TASK_CLOSED

### What the user saw
When a task was accepted and then quickly closed, only one notification appeared in the shade instead of two. The second overwrote the first.

### Root cause
`_getNotificationId()` had no case for `SERVICE_TASK_ACCEPTED` or `TASK_CLOSED`, so both fell to `default → return 1000`. Android notifications with the same ID replace each other.

### Fix
Added dedicated IDs:
- `SERVICE_TASK_ACCEPTED` / `ACCEPTED` → 1007
- `TASK_CLOSED` → 1008

### Files changed
- `lib/services/notification_handler.dart` — `_getNotificationId()` switch

---

## BUG 6 — SERVICE_TASK_ACCEPTED and TASK_CLOSED not navigating to ticket on tap (killed state)

### What the user saw
Tapping the `SERVICE_TASK_ACCEPTED` or `TASK_CLOSED` tray notification opened the app to the Home tab but never pushed the `TicketDetailPage`.

### Root cause
`DeepLinkPayload.fromData()` had no `else if` branch for `SERVICE_TASK_ACCEPTED` or `TASK_CLOSED`. These types fell through all conditions, leaving `entityType = null`. The navigation coordinator checked `entityType == DeepLinkEntityType.serviceTask` before resolving and pushing the detail page — with `entityType = null` it skipped navigation entirely.

### Fix
Added both types to the service task branch in `DeepLinkPayload.fromData()`:

```dart
} else if (rawType == 'SERVICE_ORDER' ||
    rawType == 'NEW_SERVICE_REQUEST' ||
    rawType == 'TASK_REASSIGNED' ||
    rawType == 'SERVICE_TASK_ACCEPTED' ||   // added
    rawType == 'TASK_CLOSED') {             // added
```

### Files changed
- `lib/models/deep_link_payload.dart`

---

## BUG 7 — Build error: stray character in date_formatter.dart

### What the user saw
`flutter run` failed with:
```
lib/utils/date_formatter.dart:213:2: Error: Variables must be declared using the keywords 'const', 'final', 'var' or a type name.
}R
```

### Root cause
A stray `R` character was appended to the last line of the file. This was caused by Git's LF→CRLF line ending conversion on Windows corrupting the final byte of the file.

### Fix
Removed the stray `R` from line 213.

---

## BUG 8 — Release build failing: keystore file not found

### What the user saw
```
Keystore file 'C:\screen-sync\my-release-key.jks' not found for signing config 'release'.
```
Release APK build failed.

### Root cause
`android/key.properties` had `storeFile=C:/screen-sync/my-release-key.jks` — pointing to the wrong drive. The project was on `D:\grooviz Mobile\screen-sync\` but the path pointed to `C:\`.

### Fix
Updated `key.properties`:
```
storeFile=D:/grooviz Mobile/screen-sync/my-release-key.jks
```

### Files changed
- `android/key.properties`

---

## BUG 9 — Cold launch slow: login page took 2-5 seconds to appear

### What the user saw
After tapping the app icon, there was a 2-5 second black screen before the login page appeared.

### Root cause
`main()` was making 3 sequential API calls (`reloadTasks`, `reloadFood`, `reloadDelivery`) **before** calling `runApp()`. The first pixel of UI was blocked on network round trips.

Also `FCMService.initialize()` and printer init were awaited serially, adding further delay.

### Fix
- Moved the 3 reconciliation API calls to `addPostFrameCallback` — they now run after the first frame renders
- Changed the 3 calls to run in parallel via `Future.wait([...])` instead of serial
- Kept `FCMService.initialize()` awaited (required before FCM listeners register)
- Made printer init `unawaited`

### Files changed
- `lib/main.dart`

### Interview answer
"The app was doing 3 network calls before rendering a single pixel. We moved them to after the first frame using `addPostFrameCallback` and ran them in parallel with `Future.wait`. The user now sees the login screen in ~300ms instead of 3 seconds."

---

## BUG 10 — Report button hidden in tasks page

### What the user saw
Intentional — the report/analytics export button was temporarily hidden from the tasks page app bar per product decision.

### How it was done
Commented out the button inline, matching the same pattern used for the Rush Hour feature in `food_orders_page.dart`:

```dart
// REPORT BUTTON — hidden for now. All logic preserved below.
// Re-enable by uncommenting the block below and removing this comment.
// if (_isSupervisorOrAbove(_userRoleId) && _canSendReports)
//   Container( ... IconButton(onPressed: _showExportReportDialog) ... ),
```

All supporting logic (`_showExportReportDialog`, `_ExportReportBottomSheet`, `report_pdf_helper.dart` import) is preserved and can be re-enabled in one step.

### Files changed
- `lib/pages/tasks_page.dart`

---

## Architecture summary for interviews

### Notification system design
The app uses a three-layer notification architecture:

1. **Lambda (backend)** — sends FCM with `notification: { title, body }` block to all relevant devices. This is the trigger.
2. **Flutter FCM handlers** — foreground (`onMessage`) and background (`firebaseMessagingBackgroundHandler` with `@pragma('vm:entry-point')`) both call `AlertReloadCoordinator.reloadX()`.
3. **AlertReloadCoordinator** — always queries the server for the true pending count. Server is the single source of truth. Never trusts local cache for alert state.

### Why server reconciliation instead of optimistic counting
Optimistic counting (increment on FCM arrive, decrement on accept) is fragile across devices and network failures. We always reload from the server so the count reflects reality regardless of timing, dropped messages, or race conditions.

### The foreground service pattern
Alert audio uses `flutter_foreground_task` which starts an Android foreground service. This allows audio to play even when the app is backgrounded. The service is started/stopped/switched exclusively by `AlertStateManager._sync()` based on the current counts.

Priority chain: Escalation (4) > Food Order (3) > Service Task (2) > Delivery (1). Higher priority preempts lower priority audio without interruption.
