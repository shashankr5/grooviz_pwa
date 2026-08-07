# Delivery Management — Home Page Design Proposal

> Based on a full read of `home_page.dart`, `delivery_page.dart` (which is a thin wrapper over `DeliveryPage` defined inside `home_page.dart`), and `kpi_command_grid.dart`.

---

## What Actually Exists Right Now

Before proposing anything, this is the current state:

- `DeliveryPage` (`delivery_page.dart`) is a one-line wrapper: `return const FoodOrdersPage()`. It does not contain the delivery UI.
- The actual delivery UI — the three-tab filter row (Ready / Accepted / Delivered), order cards, Accept/Deliver buttons — lives in `_DeliveryPageState` **inside `home_page.dart`** starting at line ~1500.
- `_buildTopSummaryCards()` in `home_page.dart` has a Delivery card that navigates to `const DeliveryPage()`. But `_buildTopSummaryCards()` is **never called** in `_buildContent()`. It is dead code.
- `_buildContent()` calls `KpiCommandGrid` (4 filter tiles) and the task list. No delivery entry point exists.
- `_readyOrderCount`, `_acceptedOrderCount`, `_deliveredOrderCount` are fetched, kept live via `TaskAlertService.onNewDelivery`, but displayed nowhere.
- Department check exists for `isFrontOfficeUser` (front office). No `isRoomServiceUser` variable exists yet.

---

## Placement Decision — Rationale

**Chosen pattern: A standalone Delivery Command Card inserted between `KpiCommandGrid` and the Service Requests section header, visible only when the user is Room Service.**

### Why not a 5th KPI tile

The 4 KPI tiles are filter selectors — they change `selectedFilter` and update the task list below in place. Delivery must navigate to a different page (`DeliveryPage`). Mixing navigation tiles with filter tiles in the same grid creates inconsistent affordance: 4 tiles that filter the list below, and 1 tile that takes you somewhere else entirely. Users will not understand why one tile behaves differently. Wrong pattern.

### Why not a top-level tab switch (segmented view)

A segmented toggle between "Service Requests" and "Delivery Orders" at the top of Home would make sense if the user is *exclusively* Room Service. But most Room Service staff also handle service tasks. Replacing the entire list view with a mode switch hides tasks from users who need both. Over-engineered for the problem.

### Why this pattern works

A distinct card between the KPI grid and the task list:
- Is visually separate from the filter tiles — different shape, different interaction metaphor (full-width card with chevron = navigation, not filter)
- Shows live count data at-a-glance without navigating
- Collapses gracefully to a calm empty state when no ready orders exist
- Is invisible to non-Room-Service users — zero clutter
- Matches the precedent already set by the `ExecutiveHeaderCard` (a full-width card that provides context above the grid, not part of the grid itself)

---

## Home Page Layout — Room Service User

```
┌─────────────────────────────────────────────────────┐
│  AppBar: "Ticket Management"                        │
├─────────────────────────────────────────────────────┤
│  ExecutiveHeaderCard (gradient, greeting, role)     │
│                                            ● (dot)  │
├─────────────────────────────────────────────────────┤
│  KpiCommandGrid (4 tiles: Escalated / Open /        │
│                           In Progress / Completed)  │
├─────────────────────────────────────────────────────┤
│                                                     │
│  ┌───────────────────────────────────────────────┐  │  ← DELIVERY COMMAND CARD
│  │  🛵  Delivery Queue          [  → View All  ] │  │    (new, Room Service only)
│  │                                               │  │
│  │  ┌──────────┐  ┌──────────┐  ┌─────────────┐ │  │
│  │  │    3     │  │    1     │  │      8      │ │  │
│  │  │  Ready   │  │ Accepted │  │  Delivered  │ │  │
│  │  └──────────┘  └──────────┘  └─────────────┘ │  │
│  │                                               │  │
│  │  ⚠ Room 204 · Pasta · 18 min ago  [Oldest]  │  │  ← preview row (Ready > 0)
│  └───────────────────────────────────────────────┘  │
│                                                     │
├─────────────────────────────────────────────────────┤
│  Service Requests             [All Days ▾]          │
│  4 active requests                                  │
│  ┌─────────────────────────────────────────────┐   │
│  │  ROOM 101   ...task card...                 │   │
│  └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

**Non-Room-Service user:** The delivery command card does not exist. Layout is identical to today (header → KPI grid → task list).

---

## Visual Specification

### Delivery Command Card — Ready orders pending (urgency state)

```
┌──────────────────────────────────────────────────────────────┐
│  ●  Delivery Queue                          View All  ›       │
│     Room Service                                             │
│                                                              │
│   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐   │
│   │   🔴  3      │   │   🔵  1      │   │   🟢  8      │   │
│   │   Ready      │   │  Accepted    │   │  Delivered   │   │
│   └──────────────┘   └──────────────┘   └──────────────┘   │
│                                                              │
│   ⚠  Room 204 · Pasta, Soup  ·  18 min ago                  │
└──────────────────────────────────────────────────────────────┘
```

**Visual properties (urgency state — Ready > 0):**

- Card background: `AppColors.orange.withOpacity(0.06)` — same warm treatment as Escalated error state
- Left border accent: 3px solid `AppColors.orange`
- Header dot: pulsing orange circle (reuse `_pulseAnimation` from `ExecutiveHeaderCard`)
- "Ready" mini-tile: filled orange background, white text — same pattern as selected KPI tile
- "Accepted" and "Delivered" mini-tiles: white background, colored text/count
- Preview row: shows oldest Ready order — room number, first item name truncated, time elapsed
- "View All ›" button: text button right-aligned, `AppColors.primary` color, no border — clearly a navigation affordance, not a filter

**Visual properties (calm state — Ready = 0):**

- Card background: `Colors.white`
- Left border accent: 1px `AppColors.border`
- No pulsing dot, no preview row
- Header: muted grey icon, label "Delivery Queue · All clear"
- Mini-tiles: all white backgrounds, counts in muted colors
- Card height collapses (no preview row) — approximately 30% shorter

**How it differs visually from KPI tiles:**

| KPI tiles | Delivery Command Card |
|---|---|
| Square grid tiles, equal width | Full-width card, asymmetric layout |
| Tap anywhere on tile = filter the list below | Tap card body or "View All" = navigate to DeliveryPage |
| Selected state = filled color background | No "selected" state — it's always a launcher |
| No chevron | Chevron (›) on "View All" = navigation affordance |
| Count-only, no context | Shows 3 counts + oldest order preview |
| Part of a 4-tile grid | Standalone card between grid and list |

This makes the interaction model immediately readable: tiles above filter the content below; card below them takes you somewhere.

---

## Preview Row Logic

Show the oldest `Ready` order (lowest `_orderTimeDt` among `readyOrders`):

```
⚠  Room [roomNumber] · [first item name][+N more]  ·  [elapsed]
```

- `elapsed` = `DateTime.now().difference(_orderTimeDt)`, displayed as "X min ago" or "Xh Xm ago"
- If `_orderTimeDt` is unknown (empty timestamp), hide elapsed
- If items list > 1, show "Pasta +2 more"
- If Ready = 0, hide the entire preview row (no empty state row)

---

## Empty State

When all counts are zero:

```
┌────────────────────────────────────────────────────────────┐
│  🛵  Delivery Queue · All clear                            │
│                                                            │
│   ┌──────────────┐   ┌──────────────┐   ┌─────────────┐  │
│   │    0         │   │    0         │   │      0      │  │
│   │  Ready       │   │  Accepted    │   │  Delivered  │  │
│   └──────────────┘   └──────────────┘   └─────────────┘  │
└────────────────────────────────────────────────────────────┘
```

- Card stays visible (does not collapse/hide entirely)
- Reason: the Room Service user is on the Home page precisely because this is their primary workflow. Hiding the card entirely would require them to remember that delivery was "somewhere" and go looking for it
- Card height is reduced (no preview row, counts are 0)
- "View All ›" link is still present — they may want to check Accepted or Delivered history even when Ready is empty

---

## Interaction Flow — Tapping

**Tap on card body or "View All ›":**
→ `Navigator.push(context, MaterialPageRoute(builder: (_) => const DeliveryPage()))` 
→ `DeliveryPage` opens, defaulting to the `Ready` tab
→ On pop: `_loadDeliveryCounts()` is called (already the pattern in `_buildTopSummaryCards()`)

**Tap on the "Ready" mini-tile:**
→ Same navigation, but pass `initialTab: 'Ready'` — open `DeliveryPage` with Ready pre-selected

**Tap on "Accepted" mini-tile:**
→ Same navigation with `initialTab: 'Accepted'`

**Tap on "Delivered" mini-tile:**
→ Same navigation with `initialTab: 'Delivered'`

This requires `DeliveryPage` / `_DeliveryPageState` to accept an optional `initialFilter` parameter (one line change).

---

## Changes Required to `DeliveryPage`

### 1. Add `initialFilter` parameter

`DeliveryPage` is currently a thin wrapper (`return const FoodOrdersPage()`). The actual delivery state is in `_DeliveryPageState` inside `home_page.dart`. That class needs:

```dart
class DeliveryPage extends StatefulWidget {
  final String initialFilter;  // 'Ready' | 'Accepted' | 'Delivered'
  const DeliveryPage({super.key, this.initialFilter = 'Ready'});
  ...
}
```

And in `initState()`:
```dart
selectedFilter = widget.initialFilter;
```

### 2. Move `DeliveryPage` out of `home_page.dart`

`_DeliveryPageState` is currently defined at the bottom of `home_page.dart`. Now that it becomes a primary navigation destination (tapped from Home directly), it should live in its own file `lib/pages/delivery_page.dart`, replacing the current one-line stub. This is a refactor only — no logic changes.

### 3. AppBar improvement

The current AppBar title is `"Delivery Management"` with a default back button. Since this is now a primary destination reached from Home, consider:
- Add a subtitle: `"Room Service Orders"` (same pattern as `"Here's your task overview"` in Home AppBar)
- The back button is correct — keep it

### 4. `delivery_page.dart` stub → real page

Replace:
```dart
class DeliveryPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const FoodOrdersPage();
}
```

With the actual `_DeliveryPageState` code extracted from `home_page.dart`, plus the `initialFilter` parameter above.

---

## Changes Required to `home_page.dart`

### 1. Add `isRoomServiceUser` bool

```dart
bool isRoomServiceUser = false;
```

In `_loadUserDepartments()`, alongside the existing `isFrontOfficeUser` check:
```dart
isRoomServiceUser = normalized.any((d) =>
    d.contains('room service') || d.contains('roomservice'));
```

### 2. Add `_buildDeliveryCommandCard()` widget method

New private method returning the card described above. References `_readyOrderCount`, `_acceptedOrderCount`, `_deliveredOrderCount` (already loaded), and the oldest ready order (requires storing it — one field: `Map<String, dynamic>? _oldestReadyOrder`).

### 3. Insert card in `_buildContent()`

```dart
// After KpiCommandGrid, before the Service Requests header
if (isRoomServiceUser) ...[
  const SizedBox(height: 16),
  Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: _buildDeliveryCommandCard(),
  ),
],
```

### 4. Store oldest ready order in `_loadDeliveryCounts()`

```dart
// existing
_readyOrderCount = _distinctOrderCount(readyOrders);

// add
_oldestReadyOrder = readyOrders.isNotEmpty
    ? readyOrders.reduce((a, b) {
        final da = _parseTimestamp(a['orderTime']?.toString());
        final db = _parseTimestamp(b['orderTime']?.toString());
        return da.isBefore(db) ? a : b;
      })
    : null;
```

### 5. Remove dead code

`_buildTopSummaryCards()` and `_buildTaskFilterGrid()` are never called in `_buildContent()`. They are dead code. Remove them to clean up ~150 lines.

---

## Implementation Checklist

| Task | File | Effort |
|---|---|---|
| Add `isRoomServiceUser` detection | `home_page.dart` | 5 min |
| Store `_oldestReadyOrder` in `_loadDeliveryCounts()` | `home_page.dart` | 5 min |
| Build `_buildDeliveryCommandCard()` widget | `home_page.dart` | 30 min |
| Insert card into `_buildContent()` | `home_page.dart` | 2 min |
| Move `_DeliveryPageState` to `delivery_page.dart` | new `delivery_page.dart` | 20 min |
| Add `initialFilter` parameter to `DeliveryPage` | `delivery_page.dart` | 5 min |
| Remove dead `_buildTopSummaryCards()` + `_buildTaskFilterGrid()` | `home_page.dart` | 5 min |

Total estimated effort: ~70 minutes of implementation.

---

## What NOT to Change

- The `KpiCommandGrid` — no changes. Leave it as 4 filter tiles. Do not add delivery as a 5th tile.
- `DeliveryPage` internal structure (3 tabs, order cards, Accept/Deliver buttons) — keep as-is. It is functionally correct.
- The `_readyOrderCount` / `_acceptedOrderCount` / `_deliveredOrderCount` fetch logic — keep as-is. It is already wired and live.
- The `TaskAlertService.onNewDelivery` subscription — keep as-is. It already calls `_loadDeliveryCounts()` in real time.
