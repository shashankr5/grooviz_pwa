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

  // ---------- ENTERPRISE ID ----------

  static Future<void> saveEnterpriseId(int enterpriseId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt("enterprise_id", enterpriseId);
  }

  static Future<int?> getEnterpriseId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt("enterprise_id");
  }

  // ----------- Phone -----------------

  static Future<String?> getPhone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("phone");
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
    final installationId = prefs.getString("installation_id");
    final deviceIdentifier = prefs.getString("device_identifier");

    // Clear ONLY user-related data
    await prefs.remove("user_id");
    await prefs.remove("user_name");
    await prefs.remove("email");
    await prefs.remove("phone");
    await prefs.remove("is_logged_in");

    // Restore installation ID and device identifier
    if (installationId != null) {
      await prefs.setString("installation_id", installationId);
    }
    if (deviceIdentifier != null) {
      await prefs.setString("device_identifier", deviceIdentifier);
    }
  }

}
