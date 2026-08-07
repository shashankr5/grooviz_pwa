import 'package:shared_preferences/shared_preferences.dart';

class AppPreferences {
  AppPreferences._();

  static SharedPreferences? _prefs;

  /// Ensures SharedPreferences instance is initialized.
  static Future<SharedPreferences> _getPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  /// Write String to preferences.
  static Future<bool> setString(String key, String value) async {
    final prefs = await _getPrefs();
    return prefs.setString(key, value);
  }

  /// Read String from preferences.
  static Future<String?> getString(String key) async {
    final prefs = await _getPrefs();
    return prefs.getString(key);
  }

  /// Write int to preferences.
  static Future<bool> setInt(String key, int value) async {
    final prefs = await _getPrefs();
    return prefs.setInt(key, value);
  }

  /// Read int from preferences.
  static Future<int?> getInt(String key) async {
    final prefs = await _getPrefs();
    return prefs.getInt(key);
  }

  /// Write bool to preferences.
  static Future<bool> setBool(String key, bool value) async {
    final prefs = await _getPrefs();
    return prefs.setBool(key, value);
  }

  /// Read bool from preferences.
  static Future<bool> getBool(String key, {bool defaultValue = false}) async {
    final prefs = await _getPrefs();
    return prefs.getBool(key) ?? defaultValue;
  }

  /// Remove key from preferences.
  static Future<bool> remove(String key) async {
    final prefs = await _getPrefs();
    return prefs.remove(key);
  }

  /// Purges all data from preferences except custom keys like device identifiers.
  static Future<void> clear({List<String>? preserveKeys}) async {
    final prefs = await _getPrefs();
    
    if (preserveKeys == null || preserveKeys.isEmpty) {
      await prefs.clear();
      return;
    }

    final Map<String, dynamic> preserved = {};
    for (final key in preserveKeys) {
      if (prefs.containsKey(key)) {
        preserved[key] = prefs.get(key);
      }
    }

    await prefs.clear();

    // Restore preserved keys
    for (final entry in preserved.entries) {
      final k = entry.key;
      final v = entry.value;
      if (v is String) await prefs.setString(k, v);
      else if (v is int) await prefs.setInt(k, v);
      else if (v is bool) await prefs.setBool(k, v);
      else if (v is double) await prefs.setDouble(k, v);
      else if (v is List<String>) await prefs.setStringList(k, v);
    }
  }
}
