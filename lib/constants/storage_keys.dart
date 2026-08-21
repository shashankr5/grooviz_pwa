/// All SharedPreferences keys used across the ScreenSync application.
///
/// Centralising keys prevents typos and key mismatches between the write
/// site and the read site. Every key is documented with its type and the
/// service or helper that owns it.
class StorageKeys {
  StorageKeys._();

  // ─── User Session (UserSessionHelper) ────────────────────────────────────

  /// `int` — the authenticated user's database ID.
  static const userId = 'user_id';

  /// `String` — the authenticated user's display name.
  static const userName = 'user_name';

  /// `String` — the authenticated user's email address.
  static const email = 'email';

  /// `String` — the authenticated user's phone number.
  static const phone = 'phone';

  /// `int` — the enterprise (organisation) ID for the logged-in user.
  static const enterpriseId = 'enterprise_id';

  /// `String` — the enterprise (organisation) name for the logged-in user.
  static const enterpriseName = 'enterprise_name';

  /// `List<String>` — departments the user belongs to.
  static const departments = 'departments';

  /// `String` — the user's current role name (e.g. "Manager").
  static const userRole = 'user_role';

  /// `int` — the user's current role ID.
  static const userRoleId = 'user_role_id';

  /// `String` (JSON) — the full serialised user profile map.
  static const userProfile = 'user_profile';

  /// `int` — user_id that was active when [userProfile] was last written.
  /// Used to detect stale cached profiles across user switches.
  static const userProfileUserId = 'user_profile_user_id';

  /// `bool` — whether a user is currently authenticated.
  static const isLoggedIn = 'is_logged_in';

  /// `String` — authenticated initial baseline role (written once at login/seed lock).
  static const initialRole = 'initial_role';

  /// `List<String>` — authenticated initial baseline departments (written once at login/seed lock).
  static const initialDepartments = 'initial_departments';

  // ─── Device Identity (DeviceInfo / UserSessionHelper) ────────────────────

  /// `String` — UUID generated on first launch; stable across sessions.
  static const installationId = 'installation_id';

  /// `String` — platform-specific device identifier (Android ID / IDFV).
  static const deviceIdentifier = 'device_identifier';

  // ─── FCM / Push Notifications (FcmService) ───────────────────────────────

  /// `String` — the most-recently registered FCM push token.
  static const fcmToken = 'fcm_token';

  /// `String` — app version at the time the FCM token was last stored.
  /// Used to trigger re-registration on version upgrades.
  static const fcmStoredAppVersion = 'fcm_stored_app_version';

  /// `bool` — flag set when the token must be re-registered on next launch.
  static const fcmNeedsReregistration = 'fcm_needs_reregistration';

  // ─── Rush Hour / F&B Config (saved at login from login_mobile SP) ───────────

  /// `int` — 0 or 1; whether rush hour is currently active (from login + WS sync).
  static const rushHourActive = 'rush_hour_active';

  /// `int` — max number of ETA taps allowed per order (from enterprise_food_service_rule).
  static const maxTapCount = 'max_tap_count';

  /// `int` — minutes added per ETA tap (tap_count_min from enterprise_food_service_rule).
  static const tapCountMin = 'tap_count_min';

  /// `String` — rush hour status string: 'ACTIVE' | 'INACTIVE'.
  static const rushHourStatus = 'rush_hour_status';

  /// `String` (JSON) — raw rush_hour_data JSON blob from enterprise_food_service_rule.
  static const rushHourData = 'rush_hour_data';

  // ─── User Dept / Escalation Rule (from get_user_dept_details_mobile) ─────────

  /// `int` — food department ID for the logged-in user.
  static const foodDeptId = 'food_dept_id';

  /// `int` — completion_minutes from enterprise_escalation_user_rule.
  static const completionMinutes = 'completion_minutes';

  /// `int` — supervisor user_id from enterprise_escalation_user_rule.
  static const supervisorUserId = 'supervisor_user_id';

  /// `String` — supervisor full_name.
  static const supervisorName = 'supervisor_name';

  /// `int` — supervisor dept ID.
  static const supervisorDeptId = 'supervisor_dept_id';

  // ─── Foreground Task (UnifiedAlertForegroundTask) ────────────────────────

  /// `bool` — flag written before startService() to detect premature exits.
  static const foregroundTaskRunning = 'foreground_task_running';
}
