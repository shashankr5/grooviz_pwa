// lib/utils/user_session_helper.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class UserSessionHelper {
  // ---------- USER ID ----------
  static Future<void> saveUserId(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt("user_id", userId);
  }

  static Future<int?> getUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt("user_id");
  }

  // ---------- USER NAME ----------
  static Future<void> saveUserName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("user_name", name);
  }

  static Future<String?> getUserName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("user_name");
  }

  // ---------- EMAIL ----------
  static Future<void> saveEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("email", email);
  }

  static Future<String?> getEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("email");
  }

  // ---------- PHONE ----------
  static Future<void> savePhone(String phone) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("phone", phone);
  }

  static Future<String?> getPhone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("phone");
  }

  // ---------- ENTERPRISE ID ----------
  static Future<void> saveEnterpriseId(int enterpriseId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt("enterprise_id", enterpriseId);
  }

  static Future<int?> getEnterpriseId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt("enterprise_id");
  }

  // ---------- DEPARTMENTS ----------
  static Future<void> saveDepartments(List<String> depts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList("departments", depts);
  }

  static Future<List<String>> getDepartments() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList("departments") ?? [];
  }

  // ---------- ROLE (string name) ----------
  static Future<void> saveRole(String role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("user_role", role);
  }

  static Future<String?> getRole() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("user_role");
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
    await prefs.setInt("user_role_id", roleId);
  }

  static Future<int?> getRoleId() async {
    final prefs = await SharedPreferences.getInstance();
    // Prefer the stored numeric role_id.
    final stored = prefs.getInt("user_role_id");
    if (stored != null) return stored;

    // Fallback: derive role_id from the stored role name string.
    final roleName = prefs.getString("user_role");
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
    final currentUserId = prefs.getInt("user_id");
    final profileCopy = Map<String, dynamic>.from(profile);

    final profileUserId = _readInt(profileCopy["user_id"]) ?? currentUserId;
    if (profileUserId != null && profileUserId != 0) {
      profileCopy["user_id"] = profileUserId;
      await prefs.setInt("user_profile_user_id", profileUserId);
    } else {
      await prefs.remove("user_profile_user_id");
    }

    // Also persist role_id from the profile if present.
    final roleId = _readInt(profileCopy["role_id"]);
    if (roleId != null && roleId != 0) {
      await prefs.setInt("user_role_id", roleId);
    }

    await prefs.setString("user_profile", jsonEncode(profileCopy));
  }

  static Future<Map<String, dynamic>?> getUserProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString("user_profile");
    if (data == null) return null;

    final decoded = jsonDecode(data);
    if (decoded is! Map) {
      await clearCachedProfile();
      return null;
    }

    final profile = Map<String, dynamic>.from(decoded);
    final currentUserId = prefs.getInt("user_id");
    final cachedUserId =
        prefs.getInt("user_profile_user_id") ?? _readInt(profile["user_id"]);

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
    await prefs.remove("user_profile");
    await prefs.remove("user_profile_user_id");
  }

  // ---------- LOGIN STATE ----------
  static Future<void> saveIsLoggedIn(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool("is_logged_in", value);
  }

  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool("is_logged_in") ?? false;
  }

  // ---------- CLEAR EVERYTHING ----------
  static Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();

    // Preserve installation_id (device identity)
    final installationId   = prefs.getString("installation_id");
    final deviceIdentifier = prefs.getString("device_identifier");

    await prefs.remove("user_id");
    await prefs.remove("user_name");
    await prefs.remove("email");
    await prefs.remove("phone");
    await prefs.remove("enterprise_id");
    await prefs.remove("departments");
    await prefs.remove("user_role");
    await prefs.remove("user_role_id");        // ← NEW
    await prefs.remove("user_profile");
    await prefs.remove("user_profile_user_id");
    await prefs.remove("is_logged_in");

    // Restore installation ID and device identifier
    if (installationId != null) {
      await prefs.setString("installation_id", installationId);
    }
    if (deviceIdentifier != null) {
      await prefs.setString("device_identifier", deviceIdentifier);
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

    final data = prefs.getString("user_profile");
    if (data == null) return null;

    final profile = jsonDecode(data);
    final currentUserId = prefs.getInt("user_id");

    if (profile["user_id"] != currentUserId) {
      await prefs.remove("user_profile");
      return null;
    }
    return profile;
  }
}