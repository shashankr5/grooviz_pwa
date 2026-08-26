# ScreenSync Notification System

Complete reference for how every notification type is received, how its alert sound works, how notification tap redirects the user, and how multiple concurrent alert types interact.

---

## Architecture Overview

The system uses **two parallel delivery channels** for every event:

| Channel | Transport | When it fires |
|---|---|---|
| **FCM (Firebase Cloud Messaging)** | Push notification via APNs/FCM | App is backgrounded, killed, or screen-off |
| **WebSocket** | Persistent `wss://` connection | App is in the foreground |

Both channels carry the same `type` field. The same logic runs on both paths — they are not additive. If the app is foreground, WebSocket handles it. If backgrounded, FCM handles it. They do not stack.

There is **one shared foreground service** (`UnifiedAlertTaskHandler`) that plays audio. Only one sound plays at a time. Priority determines which sound wins when multiple alert types are active simultaneously.

---

## Notification Types

### 1. `NEW_FOOD_ORDER` — New Food & Beverage Order

**Who receives it:** Staff and supervisors assigned to the F&B department.

**Delivery channel:** FCM (background) + WebSocket (foreground).

**What it does:**

- Starts the unified foreground service with `bell_notification.wav` in **loop mode**.
- Sound continues looping until a device accepts the order or `ORDER_DELIVERED` arrives.
- Increments `OrderAlertService._pendingOrderCount`.
- `AlertReloadCoordinator` polls the API every 30 seconds as a safety net to re-sync the count.

**Alert sound:** `bell_notification.wav` — loops continuously.

**Notification tap behaviour:**

- `DeepLinkPayload` maps this type → `targetTab: 'food'`, `entityType: foodOrder`.
- `NotificationNavigationCoordinator` switches the bottom tab to **Food Orders**.
- If an `order_id` or `order_number` is in the payload, `EntityResolver.resolveFoodOrder()` is called, but no push navigation happens — the tab switch alone is sufficient (the food orders list renders with the relevant order visible).
- If the app was killed, the payload is stashed in `_pendingPayload` and consumed after login via `onPostLogin()`.

**Stop condition:** `ORDER_DELIVERED` or `resetCount(0)` after `_loadFoodOrders()` finds zero pending orders.

---

### 2. `ORDER_ACCEPTED` / `ORDER_CANCELLED`

**Who receives it:** All devices subscribed to the same enterprise.

**What it does:**

- FCM: stops the foreground service only if the payload includes `stop_alert: true`. Otherwise it stays running (another device may still have the order open).
- WebSocket: calls `OrderAlertService.notifyNewOrder()` to trigger a list reload.
- `AlertReloadCoordinator.reloadFood()` re-fetches and calls `resetCount(pendingCount)`.

**Alert sound:** No new sound. If the count drops to 0 after reload, the service stops.

**Notification tap:** Same as `NEW_FOOD_ORDER` — switches to the **Food Orders** tab.

---

### 3. `ORDER_DELIVERED`

**What it does:** Immediately stops the foreground service (`_stopServiceIfRunning()`). No new sound.

**Notification tap:** Switches to **Food Orders** tab.

---

### 4. `ORDER_STATUS_CHANGED` (with `order_status: READY`)

**What it does:**

- When the server-reported status is `READY`, this is treated as a **delivery alert** (same as `NEW_DELIVERY_TASK`).
- Starts the foreground service with `delivery_notification.wav` in **loop mode**.
- Increments `TaskAlertService._pendingDeliveryCount`.

**Alert sound:** `delivery_notification.wav` — loops continuously.

**Notification tap:** `DeepLinkPayload` maps this → `targetTab: 'delivery'`, `entityType: delivery`. Navigator pushes `DeliveryPage()` on top of the current screen.

---

### 5. `NEW_SERVICE_TASK` — New Housekeeping / Maintenance / Guest Service Request

**Who receives it:** Staff assigned to the relevant department.

**What it does:**

- Starts the foreground service with `task_notification.wav` in **loop mode**.
- Increments `TaskAlertService._pendingServiceCount`.
- `AlertReloadCoordinator.reloadTasks()` re-fetches open tasks every event or every 30 seconds.

**Alert sound:** `task_notification.wav` — loops continuously.

**Notification tap:**

- `DeepLinkPayload` maps this → `targetTab: 'home'`, `entityType: serviceTask`, `entityId: task_id`.
- `NotificationNavigationCoordinator` switches to the **Home** tab.
- `EntityResolver.resolveServiceTask(taskId)` fetches the full task object from the API.
- If resolved: `Navigator.push(TicketDetailPage(task: task))` — opens the detail page directly.
- If stale (task closed or not found): shows a snackbar `"Requested task is no longer available or has been closed."`.

**Stop condition:** `resetServiceCount(0)` after reload finds zero open tasks.

---

### 6. `SERVICE_TASK_ACCEPTED`

**What it does:**

- FCM: stops the service if `stop_alert: true` (acceptor's device broadcast stops all other devices' alerts for that task).
- WebSocket: calls `TaskAlertService.notifyNewTask()` to trigger a reload. `resetServiceCount()` follows.

**Notification tap:** Switches to **Home** tab, resolves task by ID, pushes `TicketDetailPage`.

---

### 7. `NEW_DELIVERY_TASK` / `ORDER_READY` / `FOOD_ORDER_READY` / `DELIVERY_READY` / `DELIVERY_NOTIFICATION`

All five types are treated identically — they are aliases for "a food order is ready for room delivery."

**What it does:**

- Starts the foreground service with `delivery_notification.wav` in **loop mode**.
- Increments `TaskAlertService._pendingDeliveryCount`.
- `AlertReloadCoordinator.reloadDelivery()` fetches `getReadyOrdersForRoomService()` and calls `resetDeliveryCount(distinctOrderCount)`.

**Alert sound:** `delivery_notification.wav` (ascending triad) — loops continuously. Distinct from the food order bell so Room Service staff can distinguish.

**Notification tap:**

- `DeepLinkPayload` → `targetTab: 'delivery'`, `entityType: delivery`.
- `NotificationNavigationCoordinator` switches to the **Delivery** tab and pushes `DeliveryPage()`.

**Stop condition:** `resetDeliveryCount(0)` after `distinctOrderCount()` returns 0.

---

### 8. `DELIVERY_ACCEPTED` / `DELIVERY_DELIVERED`

**What it does:** Calls `notifyNewDelivery()` → triggers `reloadDelivery()`. If count drops to 0, service stops.

**No new sound.** Service stops only when count hits 0 after reload.

---

### 9. `ESCALATION_ALERT`

**Who receives it:** Only the designated escalation recipient (Supervisor, Dept Head, Manager, or GM depending on SLA tier). Lambda sends this FCM only to that specific user's token.

**What it does:**

- Starts the foreground service with `escalation_notification.wav` in **loop mode**.
- The sound continues until the escalated task is accepted, closed, or reassigned.
- Updates `TaskAlertService._escalationCount` from `badge_count` in the payload.
- Emits the count on `TaskAlertService.onEscalation` stream → `HomePage` and `TasksPage` update their escalation badge in real time without a manual reload.

**Alert sound:** `escalation_notification.wav` — loops continuously until the escalation is resolved.

**Notification tap:**

- `DeepLinkPayload` → `targetTab: 'home'`, `entityType: escalation`, `entityId: service_request_id`.
- Switches to the **Home** tab.
- `EntityResolver.resolveServiceTask(taskId)` fetches the task.
- Pushes `TicketDetailPage(task: task)` directly.
- If the task is already closed or transferred: snackbar warning.

---

### 10. `PULSE`

**What it is:** A Lambda EventBridge scheduled job sends a `PULSE` FCM to all devices that still have unaccepted tasks. It re-rings the alert on devices where the sound may have stopped (e.g. screen timeout, audio session interrupted).

**What it does:**

- FCM background: `_startServiceIfNeeded()` — restarts the foreground service if it had stopped.
- WebSocket foreground: calls `TaskAlertService.ensureServiceRunning()` + `notifyNewTask()`.
- The `alert_type` sub-field routes to food (`bell_notification`), delivery (`delivery_notification`), or service (`task_notification`).

**Alert sound:** Replays whichever sound was active. Because the service is restarted from scratch via `unifiedAlertStartCallback`, `onStart()` reads the `AlertSoundKey.prefKey` from SharedPreferences and plays the correct sound again.

**Notification tap:** Routes the same as `NEW_SERVICE_TASK` (home tab + task resolution).

---

### 11. `ACCEPTED` — Cross-Device Accept Stop

**What it is:** When any device accepts a task, the Lambda broadcasts `ACCEPTED` to all other devices in the same enterprise.

**What it does:**

- FCM background: immediately stops the foreground service on all other devices.
- WebSocket foreground: calls `TaskAlertService.stopOneServiceAlert()` (optimistic decrement) + `notifyNewTask()` to trigger a list reload.

**No sound.** This is a silence command, not an alert.

**Notification tap:** Switches to **Home** tab, resolves task by ID, pushes `TicketDetailPage`.

---

### 12. `TASK_CLOSED`

**What it does:** WebSocket only. Calls `notifyNewTask()` → triggers `reloadTasks()` → `resetServiceCount()` re-evaluates. No sound change.

---

### 13. `SESSION_INVALIDATED` / `ROLE_UPDATED` / `DEPARTMENT_UPDATED`

**What it does:** WebSocket only (no FCM for these).

- Stops all alerts (`OrderAlertService.stop()`, `TaskAlertService.stopAll()`).
- Disconnects the WebSocket.
- Clears local session via `UserSessionHelper.clearSession()`.
- Shows `RoleChangedSheet` via `SessionChangeService` with the reason from the payload.

**No notification tap** — these are server-initiated forced actions, not user-tappable notifications.

---

## Sound Priority System

Only one foreground service instance runs at a time. When multiple alert types are active simultaneously, this priority order applies:

```
Food Orders (bell_notification) 
    ↓  highest priority
Delivery Orders (delivery_notification)
    ↓
Service Tasks (task_notification)
    ↓  lowest priority
Escalation (escalation_notification) — loops until the escalated task is actioned
```

**How priority is enforced in `TaskAlertService._reevaluate()`:**

1. If `OrderAlertService.pendingOrderCount > 0` → restart service with `bell_notification` (food wins).
2. Else if `_pendingDeliveryCount > 0` → use `delivery_notification`.
3. Else if `_pendingServiceCount > 0` → use `task_notification`.
4. Else → stop the service.

This means if you have a pending service task alert running and a new food order arrives, the food order bell **replaces** the task sound. The task alert is not lost — `_pendingServiceCount` is still non-zero — but food takes the speaker until it is cleared.

---

## The Single Foreground Service Constraint

**Yes — only one notification sound plays at a time.** This is a deliberate design decision, not a limitation.

The Android foreground service (`FlutterForegroundTask`) is a singleton. You cannot run two instances simultaneously. The `UnifiedAlertTaskHandler` reads a single `AlertSoundKey.prefKey` from SharedPreferences on start and plays that one sound.

**What this means in practice:**

- If a food order and a service task arrive within seconds of each other, the food bell wins and plays. The service task is queued in `_pendingServiceCount`. When the food order is accepted and cleared, `_reevaluate()` immediately restarts the service with the task sound.
- Staff will hear one sound at a time, but all alert counts are maintained independently in memory. No alert is lost — only its sound is deferred.

---

## Notification Channels (Android)

Five separate Android notification channels are registered at app start:

| Channel ID | Sound File | Used For |
|---|---|---|
| `high_importance_channel` | `bell_notification` | Food orders |
| `task_alert_channel` | `task_notification` | Service tasks |
| `delivery_alert_channel` | `delivery_notification` | Delivery / room service |
| `escalation_alert_channel` | `escalation_notification` | Escalated tasks |
| `order_alert_service` | *(silent)* | Foreground service persistent notification |

Each channel has `Importance.max` which means Android will show a heads-up notification (pops over any app) and play the channel's assigned sound through the system notification sound path — **separate** from the in-app foreground service audio.

The in-app `playSound: false` flag on `AndroidNotificationDetails` means the local notification itself does not play sound — sound is handled exclusively by the foreground service to allow looping and volume control.

---

## Tap Navigation Summary

| Type | Tab switched | Push navigation |
|---|---|---|
| `NEW_FOOD_ORDER`, `ORDER_ACCEPTED`, `ORDER_CANCELLED` | Food | None (list already visible) |
| `ORDER_STATUS_CHANGED` (READY) | Delivery | `DeliveryPage` pushed |
| `NEW_SERVICE_TASK`, `SERVICE_TASK_ACCEPTED`, `ACCEPTED` | Home | `TicketDetailPage(task)` pushed if `task_id` present |
| `ESCALATION_ALERT` | Home | `TicketDetailPage(task)` pushed if `service_request_id` present |
| `NEW_DELIVERY_TASK`, `ORDER_READY`, `DELIVERY_*` | Delivery | `DeliveryPage` pushed |
| `PULSE` | Home | `TicketDetailPage(task)` pushed if `task_id` present |

**Stale entity handling:** If the server can no longer resolve the entity (task closed, order delivered), a red snackbar is shown: `"Requested task is no longer available or has been closed."` No crash, no navigation.

**Post-login stash:** If a notification is tapped while the user is logged out (cold-start kill-and-reopen), the `DeepLinkPayload` is stored in `NotificationNavigationCoordinator._pendingPayload`. After successful login, `onPostLogin()` is called with a 300ms delay and the full navigation sequence executes.

---

## Safety Net: `AlertReloadCoordinator`

Even if FCM or WebSocket delivery fails, the coordinator ensures alert accuracy:

- **App resume:** `didChangeAppLifecycleState(resumed)` → calls `reloadFood()`, `reloadTasks()`, `reloadDelivery()` in parallel.
- **30-second poll:** `Timer.periodic(30s)` → same three reloads, but only if the foreground service is currently running (skips if no alerts are active).
- **Service start failure:** If `ensureRunning()` returns `false` (Android killed the service), a persistent snackbar appears: `"Alert sound may not work. Check notification permissions."` with a Fix button that opens app settings.

---

## Files Reference

| File | Role |
|---|---|
| `services/notification_handler.dart` | Foreground FCM handler, local notification display, tap routing |
| `services/fcm_background.dart` | Background isolate handler — start/stop service per FCM type |
| `services/websocket_service.dart` | Real-time WS events — same logic as FCM, plus session invalidation |
| `services/unified_alert_foreground_task.dart` | Single audio engine for all alert sounds |
| `services/order_alert_service.dart` | Food order alert state machine |
| `services/task_alert_service.dart` | Service task + delivery + escalation state machine |
| `services/alert_reload_coordinator.dart` | Safety poll on resume + 30s interval |
| `services/notification_navigation_coordinator.dart` | Deep-link routing + post-login stash |
| `models/deep_link_payload.dart` | Maps FCM `type` → tab + entity type + entity ID |
| `main.dart` | Bootstrap: Firebase init, channel creation, cold-start tap consumption |
