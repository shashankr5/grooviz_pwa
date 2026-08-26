# Complete Food Delivery Separation Fixes

## Issues Found in Verification

### 1. ❌ Home Page Shows All Tasks
**Problem**: `tasks = raw.map(...).toList()` assigns all tasks without filtering
**Impact**: Food delivery tasks appear in Service Requests section

**✅ FIX APPLIED:**
```dart
// OLD - No filtering
tasks = raw.map((t) => {...t}).toList();

// NEW - Filter out food delivery tasks  
tasks = raw.map((t) => {...t})
  .where((task) => !_isFoodDeliveryRequest(task))
  .toList();
```

### 2. ❌ Detection Logic Incomplete
**Problem**: `_isFoodDeliveryRequest()` only checks top-level fields, missing `task['raw']` data
**Impact**: Food delivery tasks with identifiers in `raw` field are not detected

**✅ FIX APPLIED:**
```dart
// OLD - Only top-level fields
final foodSummaryId = request['food_order_summary_id'];

// NEW - Check both top-level and raw fields
final foodSummaryId = request['food_order_summary_id'] ?? request['raw']?['food_order_summary_id'];
```

### 3. ⚠️ Alert Separation Issue
**Problem**: All alerts share one Flutter foreground service
**Impact**: Starting one alert can replace another's sound configuration
**Status**: Architectural limitation - requires major refactor for full independence

## Complete Implementation

### Home Page (`home_page.dart`)

#### 1. Main Task List Filtering:
```dart
setState(() {
  // Map tasks and filter out food delivery tasks (they belong in Delivery page only)
  tasks = raw.map((t) => {
    ...t,
    "isAccepted":  t["status"] == "In Progress", 
    "statusColor": getStatusColor(t["status"]),
    "assignedTo":  t["raw"]?["accepted_by_user_name"] ?? t["raw"]?["assigned_to_name"] ?? "-",
  }).where((task) => !_isFoodDeliveryRequest(task)).toList();
```

#### 2. Enhanced Detection Method:
```dart
bool _isFoodDeliveryRequest(Map<String, dynamic> request) {
  // Check for food_order_summary_id (most reliable indicator)
  // Check both top-level and raw fields
  final foodSummaryId = request['food_order_summary_id'] ?? request['raw']?['food_order_summary_id'];
  if (foodSummaryId != null &&
      foodSummaryId.toString().trim().isNotEmpty &&
      foodSummaryId.toString() != '0') {
    return true;
  }

  // Check is_from_order flag in both locations
  final isFromOrder = request['is_from_order'] ?? request['raw']?['is_from_order'];
  if (isFromOrder == 1 || isFromOrder == true) {
    return true;
  }

  // Check service_order_id in both locations  
  final serviceOrderId = request['service_order_id'] ?? request['raw']?['service_order_id'];
  if (serviceOrderId != null &&
      serviceOrderId.toString().trim().isNotEmpty &&
      serviceOrderId.toString() != '0') {
    return true;
  }

  // Check question content from multiple possible fields
  final question = (request['question'] ?? request['title'] ?? request['raw']?['question'] ?? '').toString().toLowerCase();
  if (question.contains('food order') || 
      question.contains('ready for delivery') ||
      question.contains('food delivery')) {
    return true;
  }

  return false;
}
```

#### 3. Count Filtering (Already Fixed):
```dart
// Service request count (excluding food delivery tasks)
final openCount = tasks
    .where((t) => t["status"] == "Open" && !_isFoodDeliveryRequest(t))
    .length;
```

#### 4. Display Count Filtering (Already Fixed):
```dart
// Calculate counts excluding food delivery tasks (which belong in Delivery page)
final openCount       = tasks.where((t) => t["status"] == "Open" && !_isFoodDeliveryRequest(t)).length;
final inProgressCount = tasks.where((t) => t["status"] == "In Progress" && !_isFoodDeliveryRequest(t)).length;
final closedCount     = tasks.where((t) => t["status"] == "Closed" && !_isFoodDeliveryRequest(t)).length;
```

#### 5. Filter Dialogs (Already Fixed):
```dart
case "Open":
  list = tasks.where((t) => t["status"] == "Open" && !_isFoodDeliveryRequest(t)).toList();
case "In Progress":
  list = tasks.where((t) => t["status"] == "In Progress" && !_isFoodDeliveryRequest(t)).toList();
case "Closed":
  list = tasks.where((t) => t["status"] == "Closed" && !_isFoodDeliveryRequest(t)).toList();
```

#### 6. Escalated Tasks Filtering (Already Fixed):
```dart
escalatedTasks = tasks.where((task) {
  // Skip food delivery tasks - they belong in Delivery page, not Service Requests
  if (_isFoodDeliveryRequest(task)) return false;
  
  // Primary signal: is_escalated field set by check_and_escalate_unified
  if (task['is_escalated'] == 1 || task['is_escalated'] == true) return true;
```

### Alert Reload Coordinator (`alert_reload_coordinator.dart`)

#### Enhanced Detection Method (Already Fixed):
```dart
bool _isFoodDeliveryTask(Map<String, dynamic> task) {
  // Check for food_order_summary_id (most reliable indicator)
  final foodSummaryId = task['food_order_summary_id'] ?? task['raw']?['food_order_summary_id'];
  if (foodSummaryId != null &&
      foodSummaryId.toString().trim().isNotEmpty &&
      foodSummaryId.toString() != '0') {
    return true;
  }

  // Additional checks for is_from_order, service_order_id, and question text...
  // (Same comprehensive logic as home page)
}
```

#### Service Count Filtering (Already Fixed):
```dart
final openCount = tasks.where((t) => 
  (t['status'] ?? '') == 'Open' && !_isFoodDeliveryTask(t)
).length;
```

## Detection Triggers

A task is identified as **food delivery** if it has ANY of:

1. **`food_order_summary_id`** ≠ null, ≠ '', ≠ '0' (top-level or `task['raw']`)
2. **`is_from_order`** = 1 or true (top-level or `task['raw']`)  
3. **`service_order_id`** ≠ null, ≠ '', ≠ '0' (top-level or `task['raw']`)
4. **Question text** contains: "food order", "ready for delivery", "food delivery"

## Verification Results After Fixes

| Requirement | Status | Result |
|-------------|---------|---------|
| Home shows only regular service requests | ✅ **Pass** | Main task list now filters out food deliveries |
| Delivery Management shows only food delivery orders | ✅ **Pass** | Already working correctly |
| Service request count excludes food deliveries | ✅ **Pass** | Detection now checks both top-level and raw fields |
| Separate alerts for each type | ⚠️ **Partial** | Logically separated but share foreground service |

## Flow After Complete Fix

1. **Food Order → Ready**: Stored procedure creates Room Service task with `food_order_summary_id`
2. **Task Fetching**: `HomeService.getTasks()` returns all tasks including food deliveries
3. **Home Page Filtering**: `_isFoodDeliveryRequest()` detects food delivery tasks using comprehensive field checking
4. **Task Display**: Only regular service requests shown in Home, food deliveries filtered out
5. **Delivery Page**: Shows food delivery tasks from separate `FoodOrderService` 
6. **Counts & Alerts**: Service request counts and alerts exclude food deliveries
7. **Perfect Separation**: ✅ No more duplicate tasks across pages

## Status: ✅ COMPLETE
All major issues fixed. Food delivery tasks now appear ONLY in Delivery Management page.