import 'dart:convert';
import 'package:flutter/material.dart';

class TypeConverter {
  TypeConverter._();

  /// Parse integer safely from dynamic value. Defaults to 0 if parsing fails.
  static int safeToInt(dynamic v, {int defaultValue = 0}) {
    if (v == null) return defaultValue;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is bool) return v ? 1 : 0;
    try {
      final parsed = int.tryParse(v.toString());
      return parsed ?? double.tryParse(v.toString())?.toInt() ?? defaultValue;
    } catch (_) {
      return defaultValue;
    }
  }

  /// Parse double safely from dynamic value. Defaults to 0.0 if parsing fails.
  static double safeToDouble(dynamic v, {double defaultValue = 0.0}) {
    if (v == null) return defaultValue;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is bool) return v ? 1.0 : 0.0;
    try {
      final parsed = double.tryParse(v.toString());
      return parsed ?? defaultValue;
    } catch (_) {
      return defaultValue;
    }
  }

  /// Parse num safely from dynamic value. Defaults to 0 if parsing fails.
  static num safeToNum(dynamic v, {num defaultValue = 0}) {
    if (v == null) return defaultValue;
    if (v is num) return v;
    if (v is bool) return v ? 1 : 0;
    try {
      final parsed = num.tryParse(v.toString());
      return parsed ?? defaultValue;
    } catch (_) {
      return defaultValue;
    }
  }

  /// Parse List safely from dynamic value. Returns empty list if parsing fails.
  static List<T> safeToList<T>(dynamic v) {
    if (v == null) return <T>[];
    if (v is List) {
      try {
        return v.cast<T>();
      } catch (_) {
        return v.map((item) {
          if (T == int) return safeToInt(item) as T;
          if (T == double) return safeToDouble(item) as T;
          if (T == String) return safeToString(item) as T;
          return item as T;
        }).toList();
      }
    }
    if (v is String && v.isNotEmpty) {
      try {
        final decoded = jsonDecode(v);
        if (decoded is List) {
          return safeToList<T>(decoded);
        }
      } catch (_) {}
    }
    return <T>[];
  }

  /// Parse Map safely from dynamic value. Returns empty map if parsing fails.
  static Map<String, dynamic> safeToMap(dynamic v) {
    if (v == null) return <String, dynamic>{};
    if (v is Map) {
      try {
        return Map<String, dynamic>.from(v);
      } catch (_) {}
    }
    if (v is String && v.isNotEmpty) {
      try {
        final decoded = jsonDecode(v);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  /// Parse dynamic to Enum value from a list of enum values. Defaults to the first value if parsing fails.
  static T safeToEnum<T>(dynamic v, List<T> values) {
    if (v == null || values.isEmpty) throw ArgumentError('Values list cannot be empty');
    final matchString = v.toString().trim().toLowerCase();
    for (final val in values) {
      final enumName = val.toString().split('.').last.toLowerCase();
      if (enumName == matchString) {
        return val;
      }
    }
    return values.first;
  }

  /// Parse Color from dynamic hex string or int. Defaults to transparent if parsing fails.
  static Color safeToColor(dynamic v, {Color defaultColor = Colors.transparent}) {
    if (v == null) return defaultColor;
    if (v is Color) return v;
    if (v is int) return Color(v);
    try {
      var hexString = v.toString().replaceAll('#', '').trim();
      if (hexString.startsWith('0x')) {
        hexString = hexString.substring(2);
      }
      if (hexString.length == 6) {
        hexString = 'FF$hexString';
      }
      final colorVal = int.tryParse(hexString, radix: 16);
      return colorVal != null ? Color(colorVal) : defaultColor;
    } catch (_) {
      return defaultColor;
    }
  }

  /// Safely parse dynamic value to JSON Object. Returns null if invalid.
  static dynamic safeParseJson(dynamic v) {
    if (v == null) return null;
    if (v is Map || v is List) return v;
    try {
      return jsonDecode(v.toString());
    } catch (_) {
      return null;
    }
  }

  /// Parse string safely from dynamic value. Defaults to empty string.
  static String safeToString(dynamic v, {String defaultValue = ''}) {
    if (v == null) return defaultValue;
    if (v is String) return v;
    return v.toString();
  }

  /// Parse boolean safely from dynamic value. Handles true/false text and 1/0 checks.
  static bool safeToBool(dynamic v, {bool defaultValue = false}) {
    if (v == null) return defaultValue;
    if (v is bool) return v;
    if (v is int) return v != 0;
    if (v is double) return v != 0.0;
    final s = v.toString().trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes' || s == 'y') return true;
    if (s == 'false' || s == '0' || s == 'no' || s == 'n') return false;
    return defaultValue;
  }
}
