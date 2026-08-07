/// Task status string constants matching the API contract.
///
/// These are the exact values returned by the backend for task `status`
/// and `task_flag` fields. Do NOT modify without a corresponding
/// backend contract change.
class TaskStatus {
  TaskStatus._();

  static const open       = 'Open';
  static const inProgress = 'In Progress';
  static const closed     = 'Closed';
  static const resolved   = 'Resolved';
  static const escalated  = 'Escalated';
}

/// Food/delivery order status constants (capitalised form used in UI and
/// filter logic). The uppercase variants (e.g. `DELIVERED`) are the raw
/// values returned directly from the backend; the capitalised variants are
/// the display/normalised forms used inside the app.
class OrderStatus {
  OrderStatus._();

  // Capitalised (display / filter)
  static const pending   = 'Pending';
  static const preparing = 'Preparing';
  static const ready     = 'Ready';
  static const delivered = 'Delivered';
  static const cancelled = 'Cancelled';

  // Uppercase (raw API values)
  static const rawPending   = 'PENDING';
  static const rawPreparing = 'PREPARING';
  static const rawReady     = 'READY';
  static const rawDelivered = 'DELIVERED';
  static const rawCancelled = 'CANCELLED';
}

/// Role name constants as returned by the backend and stored in session.
///
/// These must match the `user_role` strings written by [UserSessionHelper]
/// and compared throughout the UI for permission gating.
class UserRoles {
  UserRoles._();

  static const admin           = 'Admin';
  static const manager         = 'Manager';
  static const generalManager  = 'General Manager';
  static const supervisor      = 'Supervisor';
  static const departmentHead  = 'Department Head';
  static const staff           = 'Staff';

  /// Roles that receive escalation badges / priority views.
  static const List<String> managerialRoles = [
    admin,
    generalManager,
    manager,
    supervisor,
    departmentHead,
  ];

  /// All known roles in priority order (highest first).
  static const List<String> allRoles = [
    staff,
    supervisor,
    departmentHead,
    manager,
    generalManager,
    admin,
  ];

  /// Numeric priority map — higher number = higher authority.
  /// Matches the ordering used in tasks_page.dart.
  static const Map<String, int> priority = {
    admin:          1,
    generalManager: 2,
    manager:        3,
    departmentHead: 4,
    supervisor:     5,
    staff:          6,
  };
}

/// Standardized UI string constants to prevent hardcoded string duplicates.
class AppStrings {
  AppStrings._();

  static const String appName       = 'ScreenSync';
  static const String cancel        = 'Cancel';
  static const String confirm       = 'Confirm';
  static const String retry         = 'Retry';
  static const String logout        = 'Logout';
  static const String profile       = 'Profile';
  static const String noDataFound   = 'No Data Found';
  static const String search        = 'Search';
  static const String save          = 'Save';
  static const String close         = 'Close';
  static const String loading       = 'Loading...';
  static const String errorOccurred = 'An unexpected error occurred';
}
