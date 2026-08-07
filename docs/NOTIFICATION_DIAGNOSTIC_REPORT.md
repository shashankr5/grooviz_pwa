# Notification System — Diagnostic Report

> What the code **actually does** right now, with file + line references for every claim.

---

## 1. FCM Topic / Channel Subscription

### Where subscription happens

The app does **not use FCM topics at all**. There are zero calls to `FirebaseMessaging.instance.subscribeToTopic()` anywhere in the codebase.

The subscription model is **device-token-based**, not topic-based:

**`lib/services/login_service.dart` — `login()` method:**

```dart
// login_service.dart ~line 73
final fcmToken = await FCMService.ensureFCMToken(
  timeout: const Duration(seconds: 30),
  preferFresh: false,
);

// ~line 97
final payload = {
  'username': username,
  'password': password,
  'fcm_token': fcmToken,          // ← token sent to backend at login
  'installation_id': ...,
  'device_identifier': ...,
  'device_type': ...,
  ...
  'stage': 'dev',
};
```

The FCM token is sent to the Lambda login endpoint at login time. **The Lambda is the routing layer** — it decides which tokens to send FCM to based on the user's `user_id`, `enterprise_id`, and their department assignments stored in the database.

### Is subscription scoped per department?

**On the client: no.** The client sends one FCM token and its `user_id`. That's it. No department list is sent during token registration. No loop over departments exists in `login_service.dart`, `fcm_service.dart`, or `user_session_helper.dart`.

**Department scoping is entirely server-side.** When the Lambda emits a `NEW_SERVICE_TASK` or `NEW_DELIVERY_TASK`, it queries the DB for all users in the relevant department(s) and sends FCM to their registered tokens. The client has no visibility into or control over this routing.

**Implication:** If a user is assigned to multiple departments, whether they receive notifications for all of them depends entirely on the Lambda's query logic — which is not visible in this codebase. The Flutter client cannot confirm or deny cross-department delivery.

---

## 2. Multi-Department Users

### What happens on the client for any FCM event

Regardless of which department raised the event, once the FCM arrives on the device, the client processes it identically. There is no department filter anywhere in:

- `notification_handler.dart` — `_showNotification()` dispatches purely on `type` field
- `fcm_background.dart` — `firebaseMessagingBackgroundHandler()` dispatches purely on `type` field
- `websocket_service.dart` — `_handleMessage()` dispatches purely on `type` field

There is no `department_id` check on the receive path. If the Lambda sends the FCM to the device, it will be processed.

### Trace: `NEW_DELIVERY_TASK` for a secondary department

**Step 1 — Lambda sends FCM to device token** (server-side, not verifiable in this repo).

**Step 2 — FCM arrives, background isolate fires** (`fcm_background.dart`):
```dart
case 'NEW_DELIVERY_TASK':
  await _startServiceIfNeeded();
  return;
```
Foreground service starts with whatever sound key is currently in SharedPreferences.

**Step 3 — App comes foreground, `notification_handler.dart` `_showNotification()` fires:**
```dart
case 'NEW_DELIVERY_TASK':
  isDeliveryType = true;
  await TaskAlertService.ensureDeliveryRunning();
  TaskAlertService.notifyNewDelivery();
  break;
```
`ensureDeliveryRunning()` writes `AlertSoundKey.delivery` to SharedPreferences and starts the service.
`notifyNewDelivery()` emits on `_newDeliveryController` stream.

**Step 4 — `AlertReloadCoordinator` stream listener fires** (`alert_reload_coordinator.dart`):
```dart
_deliverySub = TaskAlertService.onNewDelivery.listen((_) => reloadDelivery());
```
`reloadDelivery()` calls `_homeService.getReadyOrdersForRoomService()`, counts distinct order numbers, calls `TaskAlertService.resetDeliveryCount(count)`.

**Step 5 — `_pendingDeliveryCount` is set** (`task_alert_service.dart`):
```dart
static void resetDeliveryCount(int count) {
  _pendingDeliveryCount = count.clamp(0, 9999);
  _reevaluate();
}
```

**What does NOT happen:** There is no badge UI update tied to `_pendingDeliveryCount` directly. The count is used only to decide whether to run or stop the alert sound service. The delivery tab badge is driven by the list count rendered in `DeliveryPage`, not by this counter.

### Trace: `NEW_SERVICE_TASK` for comparison

**`notification_handler.dart`:**
```dart
case 'NEW_SERVICE_TASK':
  isTaskType = true;
  await TaskAlertService.ensureServiceRunning();
  TaskAlertService.notifyNewTask();
  break;
```

**`alert_reload_coordinator.dart`:**
```dart
_taskSub = TaskAlertService.onNewTask.listen((_) => reloadTasks());
```
`reloadTasks()` calls `_homeService.getTasks()`, counts `status == 'Open'`, calls `TaskAlertService.resetServiceCount(openCount)`.

### Where the two paths diverge

| Step | `NEW_SERVICE_TASK` | `NEW_DELIVERY_TASK` |
|---|---|---|
| Sound | `task_notification.wav` (loop) | `delivery_notification.wav` (loop) |
| Count maintained | `_pendingServiceCount` | `_pendingDeliveryCount` |
| Reload method | `reloadTasks()` → `getTasks()` | `reloadDelivery()` → `getReadyOrdersForRoomService()` |
| Home badge driven by | `TaskAlertService.onEscalation` stream → `_escalationBadgeCount` in `HomePage` | No direct badge — delivery count shows in `DeliveryPage` list |
| Tap navigation | Home tab + `TicketDetailPage` push | Delivery tab + `DeliveryPage` push |

**The fundamental difference:** `NEW_SERVICE_TASK` drives a visible escalation/open-count badge in `HomePage` through `TaskAlertService.onNewTask`. `NEW_DELIVERY_TASK` drives an audio alert and a list reload in `DeliveryPage`, but has no corresponding badge counter update visible in the home UI.

---

## 3. Sound Priority vs. Count Accuracy

### Are counters truly independent?

**Yes — the three counters increment and decrement independently** regardless of which sound is playing:

```dart
// order_alert_service.dart
static int _pendingOrderCount = 0;       // food orders

// task_alert_service.dart
static int _pendingServiceCount  = 0;    // service tasks
static int _pendingDeliveryCount = 0;    // delivery orders
static int _escalationCount      = 0;    // escalations
```

Each counter has its own `resetXxxCount()` method. `notifyNewXxx()` emits on an independent stream. The `AlertReloadCoordinator` maintains three separate in-flight guards (`_orderInFlight`, `_taskInFlight`, `_deliveryInFlight`) so concurrent reloads don't race.

### Is a lower-priority event dropped or just loses the sound?

**Events are never dropped. Only the sound is pre-empted.** Here is the exact priority enforcement in `task_alert_service.dart`:

```dart
static Future<void> _reevaluate() async {
  // Food orders win unconditionally
  if (OrderAlertService.pendingOrderCount > 0) {
    await OrderAlertService.ensureRunning();   // plays bell_notification
    return;
  }

  if (totalPending == 0) {
    await _stopService();
  } else {
    await _ensureRunning(
      soundName: _pendingDeliveryCount > 0
          ? AlertSoundKey.delivery    // delivery wins over service
          : AlertSoundKey.task,
      ...
    );
  }
}
```

And in `order_alert_service.dart`:
```dart
static Future<void> _reevaluate() async {
  if (_pendingOrderCount > 0) {
    await _ensureRunning(soundName: AlertSoundKey.food, ...);
  } else {
    if (TaskAlertService.totalPending > 0) {
      await TaskAlertService.reevaluate();    // hand off to task/delivery
    } else {
      await _stopService();
    }
  }
}
```

**Conclusion:** A `NEW_SERVICE_TASK` that arrives while food orders are pending will:
- Increment `_pendingServiceCount` ✅
- Trigger `reloadTasks()` → update the task list ✅  
- **Not play `task_notification.wav`** — food bell continues ✅ (by design)
- When food orders clear, `_reevaluate()` immediately switches to `task_notification` ✅

No event is silently swallowed.

---

## 4. Tap Navigation — Current State Per Type

### `NEW_FOOD_ORDER`

**`deep_link_payload.dart`:**
```dart
if (rawType == 'NEW_FOOD_ORDER' || ...) {
  targetTab = 'food';
  entityType = DeepLinkEntityType.foodOrder;
  entityId = (data['order_id'] ?? data['order_number'])?.toString();
}
```

**`notification_navigation_coordinator.dart`:**
```dart
} else if (payload.entityType == DeepLinkEntityType.foodOrder) {
  final order = await EntityResolver.instance.resolveFoodOrder(payload.entityId!);
  if (order != null) {
    print('🧭 Food order resolved: $order');
    // Tab switch already happened to 'food'.
    // ← NO PUSH HAPPENS HERE
  } else {
    _showStaleWarning('Requested food order is no longer active.');
  }
}
```

**Actual behaviour:** Switches to Food tab. `resolveFoodOrder()` is called and resolves the order successfully, but **the result is never used to push a detail screen**. The `if (order != null)` branch only prints a log. No `Navigator.push()` follows.

**Is there a food order detail page to push to?** No. There is no `FoodOrderDetailPage` widget in the codebase. The `OrderCard` widget in `FoodOrdersPage` is a list item, not a standalone routable page. To add tap-to-detail for food orders, a new page would need to be built.

---

### `ORDER_ACCEPTED` / `ORDER_CANCELLED`

Same `deep_link_payload.dart` mapping as `NEW_FOOD_ORDER` → `targetTab: 'food'`, `entityType: foodOrder`.

Same coordinator behaviour: tab switch only, no push. Same gap: no detail page.

---

### `ORDER_STATUS_CHANGED` (status = READY)

```dart
// deep_link_payload.dart
} else if (rawType == 'ORDER_STATUS_CHANGED') {
  final orderStatus = (data['order_status'] ?? ...).toString().toUpperCase();
  if (orderStatus == 'READY') {
    targetTab = 'delivery';
    entityType = DeepLinkEntityType.delivery;
    entityId = (data['order_id'] ?? data['order_number'])?.toString();
  } else {
    targetTab = 'food';
    entityType = DeepLinkEntityType.foodOrder;
    // ← non-READY status resolves as food order — same tab-switch-only gap
  }
}
```

**Actual behaviour for READY status:**
```dart
// notification_navigation_coordinator.dart
} else if (payload.entityType == DeepLinkEntityType.delivery) {
  navState.push(MaterialPageRoute(builder: (_) => const DeliveryPage()));
}
```
✅ **Pushes `DeliveryPage`** — this one does navigate.

---

### `NEW_SERVICE_TASK` / `SERVICE_TASK_ACCEPTED` / `ACCEPTED`

```dart
// deep_link_payload.dart
targetTab = 'home';
entityType = DeepLinkEntityType.serviceTask;
entityId = (data['task_id'] ?? data['service_request_id'])?.toString();
```

```dart
// notification_navigation_coordinator.dart
if (payload.entityType == DeepLinkEntityType.serviceTask || ...) {
  final taskId = int.tryParse(payload.entityId!);
  final task = await EntityResolver.instance.resolveServiceTask(taskId);
  if (task != null) {
    navState.push(MaterialPageRoute(
      builder: (_) => TicketDetailPage(task: task),
    ));
  } else {
    _showStaleWarning('Requested task is no longer available...');
  }
}
```

✅ **Pushes `TicketDetailPage`** — full detail navigation with entity resolution.

**Gap:** If `entityId` is null (Lambda didn't include `task_id` or `service_request_id` in the payload), the check `if (payload.entityId == null || payload.entityId!.isEmpty) return;` exits early after the tab switch — no push happens. The coordinator returns at:

```dart
// notification_navigation_coordinator.dart
if (payload.entityId == null || payload.entityId!.isEmpty) return;
```

So push navigation for service tasks is contingent on the Lambda including the task ID in the FCM payload.

---

### `ESCALATION_ALERT`

```dart
// deep_link_payload.dart
targetTab = 'home';
entityType = DeepLinkEntityType.escalation;
entityId = (data['service_request_id'] ?? data['task_id'])?.toString();
```

```dart
// notification_navigation_coordinator.dart
if (payload.entityType == DeepLinkEntityType.serviceTask ||
    payload.entityType == DeepLinkEntityType.escalation) {  // ← same branch
  ...
  navState.push(MaterialPageRoute(
    builder: (_) => TicketDetailPage(task: task),
  ));
}
```

✅ **Pushes `TicketDetailPage`** — same resolution path as service tasks.

---

### `NEW_DELIVERY_TASK` / `ORDER_READY` / `FOOD_ORDER_READY` / `DELIVERY_READY` / `DELIVERY_NOTIFICATION`

All map to `entityType: delivery`. Coordinator pushes `DeliveryPage()`.

✅ **Pushes `DeliveryPage`**.

---

### `PULSE`

`deep_link_payload.dart` does not have an explicit `PULSE` case. It falls through to the default:

```dart
// deep_link_payload.dart — no case for PULSE
// targetTab stays 'home', entityType stays null, entityId stays null
```

Because `entityType` is null, the coordinator hits the early return:

```dart
if (payload.entityId == null || payload.entityId!.isEmpty) return;
```

**Actual behaviour:** Only switches to Home tab. No push happens. This is correct — PULSE is a re-ring, not a new entity to navigate to.

---

## 5. `EntityResolver.resolveFoodOrder()` — Why It Exists But Is Never Used

**`entity_resolver.dart`** has a fully implemented `resolveFoodOrder()`:

```dart
Future<Map<String, dynamic>?> resolveFoodOrder(String orderId) async {
  final res = await _foodOrderService.getFoodOrders();
  final List orders = res['orders'] as List? ?? [];
  for (final o in orders) {
    final orderNo = (o['orderNumber'] ?? raw['order_number'] ?? ...).toString().trim();
    if (orderNo == idStr || rawId == idStr) return Map<String, dynamic>.from(o);
  }
  return null;
}
```

It calls `getFoodOrders()` (the active orders endpoint — cancelled/delivered orders are not in this list), matches by `order_number` or `order_id`, and returns the full order map including its `items[]` array.

**In `notification_navigation_coordinator.dart` the call is made but the result is abandoned:**

```dart
} else if (payload.entityType == DeepLinkEntityType.foodOrder) {
  final order = await EntityResolver.instance.resolveFoodOrder(payload.entityId!);
  if (order != null) {
    print('🧭 Food order resolved: $order');
    // Tab switch already happened to 'food'.
    //
    // ← No push. The order data is fetched, logged, and discarded.
  }
}
```

**Why:** There is no `FoodOrderDetailPage` to push to. The resolver was implemented in preparation for a detail page that was never built. The food orders tab scrolls to show the list; it was presumably considered sufficient.

---

## Summary of Gaps

| Gap | File | Line area | Severity |
|---|---|---|---|
| No FCM topic subscription — department scoping is entirely Lambda-side, unverifiable from client | `login_service.dart` | `login()` | Architecture — no client fix possible |
| `NEW_FOOD_ORDER` tap resolves order but discards result, no detail push | `notification_navigation_coordinator.dart` | `foodOrder` branch | Medium — `FoodOrderDetailPage` needs to be built |
| `ORDER_ACCEPTED` / `ORDER_CANCELLED` tap: same as above | same file | same branch | Medium |
| `NEW_SERVICE_TASK` push depends on Lambda including `task_id` — if absent, only tab switch happens | `notification_navigation_coordinator.dart` | `entityId` null guard | Low — Lambda payload issue |
| `PULSE` has no `DeepLinkPayload` mapping — always tab-switch-only, entity never resolved | `deep_link_payload.dart` | no PULSE case | Low — by design |
| Food order `resolveFoodOrder()` only searches active orders — tapping an `ORDER_ACCEPTED` notification for a delivered order returns null and shows stale warning | `entity_resolver.dart` | `resolveFoodOrder()` | Low |
