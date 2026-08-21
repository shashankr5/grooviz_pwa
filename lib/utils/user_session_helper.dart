// lib/utils/user_session_helper.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/storage_keys.dart';

class UserSessionHelper {
  // ---------- USER ID ----------
  static Future<void> saveUserId(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.userId, userId);
  }

  static Future<int?> getUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(StorageKeys.userId);
  }

  // ---------- USER NAME ----------
  static Future<void> saveUserName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.userName, name);
  }

  static Future<String?> getUserName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(StorageKeys.userName);
  }

  // ---------- EMAIL ----------
  static Future<void> saveEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.email, email);
  }

  static Future<String?> getEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(StorageKeys.email);
  }

  // ---------- PHONE ----------
  static Future<void> savePhone(String phone) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.phone, phone);
  }

  static Future<String?> getPhone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(StorageKeys.phone);
  }

  // ---------- ENTERPRISE ID ----------
  static Future<void> saveEnterpriseId(int enterpriseId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.enterpriseId, enterpriseId);
  }

  static Future<int?> getEnterpriseId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(StorageKeys.enterpriseId);
  }

  // ---------- ENTERPRISE NAME ----------
  static Future<void> saveEnterpriseName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.enterpriseName, name);
  }

  static Future<String?> getEnterpriseName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(StorageKeys.enterpriseName);
  }

  // ---------- DEPARTMENTS ----------
  static Future<void> saveDepartments(List<String> depts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(StorageKeys.departments, depts);
  }

  static Future<List<String>> getDepartments() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(StorageKeys.departments) ?? [];
  }

  // ---------- ROLE (string name) ----------
  static Future<void> saveRole(String role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.userRole, role);
  }

  static Future<String?> getRole() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(StorageKeys.userRole);
  }

  // ---------- RUSH HOUR / F&B CONFIG (from login_mobile) ----------

  static Future<void> saveRushHourConfig({
    required int rushHourActive,
    required int maxTapCount,
    required int tapCountMin,
    required String rushHourStatus,
    String rushHourData = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.rushHourActive, rushHourActive);
    await prefs.setInt(StorageKeys.maxTapCount, maxTapCount);
    await prefs.setInt(StorageKeys.tapCountMin, tapCountMin);
    await prefs.setString(StorageKeys.rushHourStatus, rushHourStatus);
    await prefs.setString(StorageKeys.rushHourData, rushHourData);
  }

  static Future<bool> getRushHourActive() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(StorageKeys.rushHourActive) ?? 0) == 1;
  }

  static Future<int> getMaxTapCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(StorageKeys.maxTapCount) ?? 0;
  }

  static Future<int> getTapCountMin() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(StorageKeys.tapCountMin) ?? 0;
  }

  static Future<String> getRushHourStatus() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(StorageKeys.rushHourStatus) ?? 'INACTIVE';
  }

  // ---------- DEPT / ESCALATION RULE (from get_user_dept_details_mobile) ----------

  static Future<void> saveDeptDetails({
    required int foodDeptId,
    required int completionMinutes,
    required int supervisorUserId,
    required String supervisorName,
    required int supervisorDeptId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.foodDeptId, foodDeptId);
    await prefs.setInt(StorageKeys.completionMinutes, completionMinutes);
    await prefs.setInt(StorageKeys.supervisorUserId, supervisorUserId);
    await prefs.setString(StorageKeys.supervisorName, supervisorName);
    await prefs.setInt(StorageKeys.supervisorDeptId, supervisorDeptId);
  }

  static Future<int?> getFoodDeptId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(StorageKeys.foodDeptId);
  }

  static Future<int> getCompletionMinutes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(StorageKeys.completionMinutes) ?? 30;
  }

  // ---------- ROLE ID (numeric, from DB roles table) ----------
  // Role ID mapping (must match DB):
  //   1 = Admin
  //   2 = General Manager
  //   3 = Manager
  //   4 = Department Head
  //   5 = Supervisor
  //   6 = Staff
  static Future<void> saveRoleId(int roleId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StorageKeys.userRoleId, roleId);
  }

  static Future<int?> getRoleId() async {
    final prefs = await SharedPreferences.getInstance();
    // Prefer the stored numeric role_id.
    final stored = prefs.getInt(StorageKeys.userRoleId);
    if (stored != null) return stored;

    // Fallback: derive role_id from the stored role name string.
    final roleName = prefs.getString(StorageKeys.userRole);
    return _roleNameToId(roleName);
  }

  /// Maps the role name string (as stored at login) to the numeric role_id.
  /// Returns null if the name is unrecognised.
  static int? _roleNameToId(String? name) {
    if (name == null) return null;
    switch (name.trim().toLowerCase()) {
      case 'admin':           return 1;
      case 'general manager': return 2;
      case 'manager':         return 3;
      case 'department head': return 4;
      case 'supervisor':      return 5;
      case 'staff':           return 6;
      default:                return null;
    }
  }

  // ---------- FULL PROFILE ----------
  static Future<void> saveUserProfile(Map<String, dynamic> profile) async {
    final prefs = await SharedPreferences.getInstance();
    final currentUserId = prefs.getInt(StorageKeys.userId);
    final profileCopy = Map<String, dynamic>.from(profile);

    final profileUserId = _readInt(profileCopy["user_id"]) ?? currentUserId;
    if (profileUserId != null && profileUserId != 0) {
      profileCopy["user_id"] = profileUserId;
      await prefs.setInt(StorageKeys.userProfileUserId, profileUserId);
    } else {
      await prefs.remove(StorageKeys.userProfileUserId);
    }

    // Also persist role_id from the profile if present.
    final roleId = _readInt(profileCopy["role_id"]);
    if (roleId != null && roleId != 0) {
      await prefs.setInt(StorageKeys.userRoleId, roleId);
    }

    await prefs.setString(StorageKeys.userProfile, jsonEncode(profileCopy));
  }

  static Future<Map<String, dynamic>?> getUserProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(StorageKeys.userProfile);
    if (data == null) return null;

    final decoded = jsonDecode(data);
    if (decoded is! Map) {
      await clearCachedProfile();
      return null;
    }

    final profile = Map<String, dynamic>.from(decoded);
    final currentUserId = prefs.getInt(StorageKeys.userId);
    final cachedUserId =
        prefs.getInt(StorageKeys.userProfileUserId) ?? _readInt(profile["user_id"]);

    if (currentUserId == null ||
        currentUserId == 0 ||
        cachedUserId == null ||
        cachedUserId != currentUserId) {
      await clearCachedProfile();
      return null;
    }

    return profile;
  }

  static Future<void> clearCachedProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(StorageKeys.userProfile);
    await prefs.remove(StorageKeys.userProfileUserId);
  }

  // ---------- LOGIN STATE ----------
  static Future<void> saveIsLoggedIn(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageKeys.isLoggedIn, value);
  }

  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(StorageKeys.isLoggedIn) ?? false;
  }

  // ---------- INITIAL BASELINE FOR ROLE CHANGE WATCHER ----------
  static Future<void> saveInitialRole(String role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.initialRole, role);
  }

  static Future<String?> getInitialRole() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(StorageKeys.initialRole);
  }

  static Future<void> saveInitialDepartments(List<String> depts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(StorageKeys.initialDepartments, depts);
  }

  static Future<List<String>> getInitialDepartments() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(StorageKeys.initialDepartments) ?? [];
  }

  // ---------- CLEAR EVERYTHING ----------
  static Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();

    // Preserve installation_id (device identity)
    final installationId   = prefs.getString(StorageKeys.installationId);
    final deviceIdentifier = prefs.getString(StorageKeys.deviceIdentifier);

    await prefs.remove(StorageKeys.userId);
    await prefs.remove(StorageKeys.userName);
    await prefs.remove(StorageKeys.email);
    await prefs.remove(StorageKeys.phone);
    await prefs.remove(StorageKeys.enterpriseId);
    await prefs.remove(StorageKeys.enterpriseName);
    await prefs.remove(StorageKeys.departments);
    await prefs.remove(StorageKeys.userRole);
    await prefs.remove(StorageKeys.userRoleId);
    await prefs.remove(StorageKeys.userProfile);
    await prefs.remove(StorageKeys.userProfileUserId);
    await prefs.remove(StorageKeys.isLoggedIn);
    await prefs.remove(StorageKeys.initialRole);
    await prefs.remove(StorageKeys.initialDepartments);
    // F&B / rush-hour config
    await prefs.remove(StorageKeys.rushHourActive);
    await prefs.remove(StorageKeys.maxTapCount);
    await prefs.remove(StorageKeys.tapCountMin);
    await prefs.remove(StorageKeys.rushHourStatus);
    await prefs.remove(StorageKeys.rushHourData);
    // Dept / escalation rule
    await prefs.remove(StorageKeys.foodDeptId);
    await prefs.remove(StorageKeys.completionMinutes);
    await prefs.remove(StorageKeys.supervisorUserId);
    await prefs.remove(StorageKeys.supervisorName);
    await prefs.remove(StorageKeys.supervisorDeptId);

    // Restore installation ID and device identifier
    if (installationId != null) {
      await prefs.setString(StorageKeys.installationId, installationId);
    }
    if (deviceIdentifier != null) {
      await prefs.setString(StorageKeys.deviceIdentifier, deviceIdentifier);
    }
  }

  static Future<dynamic> getUserData() async {}

  static int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  static Future<Map<String, dynamic>?> getSafeUserProfile() async {
    final prefs = await SharedPreferences.getInstance();

    final data = prefs.getString(StorageKeys.userProfile);
    if (data == null) return null;

    final profile = jsonDecode(data);
    final currentUserId = prefs.getInt(StorageKeys.userId);

    if (profile["user_id"] != currentUserId) {
      await prefs.remove(StorageKeys.userProfile);
      return null;
    }
    return profile;
  }

  static Future<void> logout() async {
    await clearSession();
  }
}