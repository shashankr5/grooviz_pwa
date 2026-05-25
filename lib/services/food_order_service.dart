import 'dart:developer' as dev;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

import '../utils/user_session_helper.dart';
import '../utils/food_order_status.dart';
import '../constants/api_constants.dart';

class FoodOrderService {
  final Dio _dio;

  FoodOrderService()
      : _dio = Dio(
          BaseOptions(
            baseUrl: ApiConstants.baseUrl,
            connectTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 60),
            sendTimeout: const Duration(seconds: 60),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': ApiConstants.apiKey,
            },
            validateStatus: (code) => code != null && code < 500,
          ),
        ) {
    _dio.interceptors.add(
      LogInterceptor(
        request: true,
        requestBody: true,
        responseBody: true,
      ),
    );
  }

  // ── GET FOOD ORDERS (F&B) ─────────────────────────────────────────────────

  Future<Map<String, dynamic>> getFoodOrders() async {
    try {
      final int? userId       = await UserSessionHelper.getUserId();
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }
      if (enterpriseId == null || enterpriseId == 0) {
        return {"success": false, "message": "Enterprise ID missing"};
      }

      final payload = {
        "user_id":       userId,
        "enterprise_id": enterpriseId,
        "stage":         "dev",
      };

      dev.log("📤 Fetching Food Orders");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.foodOrderDetails,
        data: payload,
      );

      dev.log("📥 Response keys: ${response.data?.keys?.toList()}");
      dev.log("📥 Raw Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      // ── Result Set 1: Active orders (Pending / Preparing / Ready) ─────────
      // Lambda returns STATUS[0].response as a JSON string (same as get_food_orders_for_fnb)
      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final statusFlag     = statusList[0]["status"];
      final responseString = statusList[0]["response"];

      if (statusFlag != "S" || responseString == null) {
        return {"success": false, "message": "Invalid server response"};
      }

      final decoded   = json.decode(responseString);
      final ordersRaw = decoded["orders"] as List? ?? [];
      final orders    = _mapFoodOrders(ordersRaw);

      // ── Result Set 2: Cancelled orders ────────────────────────────────────
      final cancelledRaw = (response.data["CANCELLED"] ?? []) as List;
      dev.log("📥 Cancelled orders count: ${cancelledRaw.length}");

      final cancelledOrders = _mapCancelledOrders(cancelledRaw);

      return {
        "success":         true,
        "message":         decoded["message"] ?? "Success",
        "orders":          orders,
        "cancelledOrders": cancelledOrders,
      };
    } catch (e, stack) {
      dev.log("❌ ERROR (getFoodOrders): $e");
      dev.log("❌ Stack: $stack");
      return {"success": false, "message": "Network error"};
    }
  }

  // ── MAP ACTIVE ORDERS ─────────────────────────────────────────────────────

  static List<Map<String, dynamic>> _mapFoodOrders(List raw) {
    return raw.map<Map<String, dynamic>>((o) {
      final m = Map<String, dynamic>.from(o);
      return {
        "orderRequestId":      m["order_request_id"],
        "orderNumber":         m["order_number"]          ?? "-",
        "roomNumber":          m["room_number"]            ?? "-",
        "roomId":              m["room_id"],
        "guestName":           m["guest_name"]             ?? "Guest",
        "foodItem":            m["food_item"]              ?? "-",
        "quantity":            m["quantity"]               ?? 0,
        "cookingInstructions": (m["cooking_instructions"]  ?? "").toString().trim(),
        "status":              _statusText(m["order_status"]),
        "statusColor":         _statusColor(m["order_status"]),
        "cancelReason":        m["cancel_reason"]          ?? "",
        "orderTime":           _formatTime(m["order_time"]),
        "extraEtaMinutes":     _safeInt(m["extra_eta_minutes"]),
        "etaLocked":           _safeBool(m["eta_locked"]),
        "raw":                 m,
      };
    }).toList();
  }

  // ── MAP CANCELLED ORDERS ──────────────────────────────────────────────────

  static List<Map<String, dynamic>> _mapCancelledOrders(List raw) {
    return raw.map<Map<String, dynamic>>((o) {
      final m = Map<String, dynamic>.from(o);
      return {
        "orderRequestId":      m["order_request_id"],
        "orderNumber":         m["order_number"]          ?? "-",
        "roomNumber":          m["room_number"]            ?? "-",
        "roomId":              m["room_id"],
        "guestName":           m["guest_name"]             ?? "Guest",
        "foodItem":            m["food_item"]              ?? "-",
        "quantity":            m["quantity"]               ?? 0,
        "cookingInstructions": (m["cooking_instructions"]  ?? "").toString().trim(),
        "status":              FoodOrderStatus.cancelled.label,
        "statusColor":         const Color(0xFFD32F2F),
        "cancelReason":        m["cancel_reason"]          ?? "",
        "orderTime":           _formatTime(m["order_time"]),
        "extraEtaMinutes":     _safeInt(m["extra_eta_minutes"]),
        "etaLocked":           _safeBool(m["eta_locked"]),
        "raw": {
          ...m,
          "order_status":  "CANCELLED",
          "cancel_reason": m["cancel_reason"] ?? "",
        },
      };
    }).toList();
  }

  // ── SAFE TYPE HELPERS ─────────────────────────────────────────────────────

  static int _safeInt(dynamic v) {
    if (v == null) return 0;
    if (v is int)  return v;
    if (v is num)  return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool _safeBool(dynamic v) {
    if (v == null)   return false;
    if (v is bool)   return v;
    if (v is int)    return v == 1;
    if (v is String) return v == '1' || v.toLowerCase() == 'true';
    return false;
  }

  // ── STATUS HELPERS ────────────────────────────────────────────────────────

  static String _statusText(String? s) {
    if (s == null || s.trim().isEmpty) return FoodOrderStatus.pending.label;
    switch (s.trim().toUpperCase()) {
      case "PENDING":   return FoodOrderStatus.pending.label;
      case "PREPARING": return FoodOrderStatus.preparing.label;
      case "READY":     return FoodOrderStatus.ready.label;
      case "DELIVERED": return FoodOrderStatus.delivered.label;
      case "CANCELLED":
      case "CANCELED":  return FoodOrderStatus.cancelled.label;
      default:          return FoodOrderStatus.pending.label;
    }
  }

  static Color _statusColor(String? s) {
    if (s == null || s.trim().isEmpty) return const Color(0xFF1976D2);
    switch (s.trim().toUpperCase()) {
      case "PENDING":   return const Color(0xFF1976D2);
      case "PREPARING": return const Color(0xFFFF9800);
      case "READY":     return const Color(0xFF4CAF50);
      case "DELIVERED": return const Color(0xFF2E7D32);
      case "CANCELLED":
      case "CANCELED":  return const Color(0xFFD32F2F);
      default:          return const Color(0xFF1976D2);
    }
  }

  static String _formatTime(String? timestamp) {
    if (timestamp == null) return "-";
    try {
      final dt = DateTime.parse(
        timestamp.toString().replaceFirst(' ', 'T'),
      ).toLocal();
      return "${dt.hour}:${dt.minute.toString().padLeft(2, '0')} • "
          "${dt.day}/${dt.month}/${dt.year}";
    } catch (_) {
      return "-";
    }
  }

  // ── UPDATE FOOD ORDER STATUS ──────────────────────────────────────────────
  // Handles: PREPARING, READY, CANCELLED, DELIVERED, ACCEPTED, ADD_ETA, RUSH_HOUR
  // Lambda returns RESULT[0] directly (not STATUS[0].response)

  Future<Map<String, dynamic>> updateFoodOrderStatus({
    required String orderNumber,
    required String status,
    String? cancelReason,
    int?    addMinutes,
  }) async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User not logged in"};
      }

      final payload = <String, dynamic>{
        "order_number":  orderNumber,
        "status":        status,
        "cancel_reason": cancelReason ?? "",
        "changed_by":    userId,
        "stage":         "dev",
      };

      if (addMinutes != null && addMinutes > 0) {
        payload["add_minutes"] = addMinutes;
      }

      dev.log("📤 Update Food Order Status");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.updateFoodOrderStatus,
        data: payload,
      );

      dev.log("📥 Raw Update Response: ${response.data}");

      final resultList = response.data["RESULT"] as List?;
      if (resultList == null || resultList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final result  = Map<String, dynamic>.from(resultList.first);
      final flag    = result["status"];
      final message = result["message"] ?? "Unknown error";

      return {
        "success":         flag == "S",
        "message":         message,
        "status":          flag,
        "data":            result,
        "extraEtaMinutes": result["extra_eta_minutes"],
        "etaLocked":       result["eta_locked"],
      };
    } catch (e, stack) {
      dev.log("❌ ERROR (updateFoodOrderStatus): $e");
      dev.log("❌ Stack: $stack");
      return {"success": false, "message": "Network error"};
    }
  }

  // ── GET RUSH HOUR STATE ───────────────────────────────────────────────────
  // Calls the dedicated read-only Lambda (ScreenSync_get_rush_hour_state_mobile)
  // via ApiConstants.getRushHour.
  // Used by FoodOrdersPage._loadRushHourState() on page load and app resume.
  //
  // SP OUT param is JSON → Lambda parses it and wraps fields in RESULT[0].
  // So we read RESULT[0] directly here — same as updateFoodOrderStatus.

  Future<Map<String, dynamic>> getRushHourState() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User not logged in"};
      }

      final payload = {
        "user_id": userId,
        "stage":   "dev",
      };

      dev.log("📤 Get Rush Hour State");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.getRushHour,   // ScreenSync_get_rush_hour_state_mobile
        data: payload,
      );

      dev.log("📥 Raw Rush Hour State Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      // Lambda wraps SP response in RESULT[0] — read directly
      final resultList = response.data["RESULT"] as List?;
      if (resultList == null || resultList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final result = Map<String, dynamic>.from(resultList.first);
      final flag   = result["status"];

      if (flag != "S") {
        return {
          "success": false,
          "message": result["message"] ?? "Failed to get rush hour state",
        };
      }

      return {
        "success":             true,
        "message":             result["message"] ?? "Success",
        "rush_hour_active":    result["rush_hour_active"],
        "rush_hour_ends_at":   result["rush_hour_ends_at"],
        "rush_hour_extra_min": result["rush_hour_extra_min"],
        "enterprise_id":       result["enterprise_id"],
      };
    } catch (e, stack) {
      dev.log("❌ ERROR (getRushHourState): $e");
      dev.log("❌ Stack: $stack");
      return {"success": false, "message": "Network error"};
    }
  }

  // ── SET RUSH HOUR ─────────────────────────────────────────────────────────
  // Calls updateFoodOrderStatus Lambda with status='RUSH_HOUR' via
  // ApiConstants.updateFoodOrderStatus (NOT a separate endpoint).
  // Server writes to ent_dept_mapping and broadcasts RUSH_HOUR_UPDATED
  // via WebSocket so all connected F&B devices update in real-time.
  //
  // active=true  → pass durationMinutes > 0 (e.g. 30, 60, 120, 240)
  // active=false → durationMinutes is ignored; server resets the row

  Future<Map<String, dynamic>> setRushHour({
    required bool active,
    int durationMinutes = 0,
  }) async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User not logged in"};
      }

      if (active && durationMinutes <= 0) {
        return {"success": false, "message": "Duration must be greater than 0"};
      }

      final payload = <String, dynamic>{
        "status":             "RUSH_HOUR",
        "changed_by":         userId,
        "rush_hour_active":   active ? 1 : 0,
        "rush_hour_duration": durationMinutes,
        "stage":              "dev",
      };

      dev.log("📤 Set Rush Hour");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.updateFoodOrderStatus, // ← same Lambda, RUSH_HOUR branch in SP
        data: payload,
      );

      dev.log("📥 Raw Set Rush Hour Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      // Lambda returns RESULT[0] — same as all other updateFoodOrderStatus calls
      final resultList = response.data["RESULT"] as List?;
      if (resultList == null || resultList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final result = Map<String, dynamic>.from(resultList.first);
      final flag   = result["status"];

      if (flag != "S") {
        return {
          "success": false,
          "message": result["message"] ?? "Failed to update rush hour",
        };
      }

      return {
        "success":             true,
        "message":             result["message"] ?? "Success",
        "rush_hour_active":    result["rush_hour_active"],
        "rush_hour_ends_at":   result["rush_hour_ends_at"],
        "rush_hour_extra_min": result["rush_hour_extra_min"],
        "enterprise_id":       result["enterprise_id"],
      };
    } catch (e, stack) {
      dev.log("❌ ERROR (setRushHour): $e");
      dev.log("❌ Stack: $stack");
      return {"success": false, "message": "Network error"};
    }
  }

  // ── GET ORDER SUMMARY (Weekly / Daily) ───────────────────────────────────

  Future<Map<String, dynamic>> getOrderSummary({DateTime? date}) async {
    try {
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();
      final int? userId       = await UserSessionHelper.getUserId();

      if (enterpriseId == null || enterpriseId == 0) {
        return {"success": false, "message": "Enterprise ID missing"};
      }
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {
        "enterprise_id": enterpriseId,
        "user_id":       userId,
        if (date != null)
          "date": "${date.year}-${date.month.toString().padLeft(2, '0')}"
                  "-${date.day.toString().padLeft(2, '0')}",
        "stage": "dev",
      };

      dev.log("📤 Fetching Order Summary");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.orderSummary,
        data: payload,
      );

      dev.log("📥 Raw Summary Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      // Summary Lambda also uses STATUS[0].response pattern
      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final statusFlag     = statusList[0]["status"];
      final responseString = statusList[0]["response"];

      if (statusFlag != "S" || responseString == null) {
        return {"success": false, "message": "Failed to fetch order summary"};
      }

      final decoded   = json.decode(responseString);
      final summary   = decoded["summary"] ?? {};
      final ordersRaw = decoded["orders"]  as List? ?? [];

      return {
        "success": true,
        "message": decoded["message"] ?? "Success",
        "summary": summary,
        "orders":  ordersRaw.map<Map<String, dynamic>>((o) {
          final m = Map<String, dynamic>.from(o);
          return {
            "orderRequestId": m["order_request_id"],
            "orderNumber":    m["order_number"],
            "roomNumber":     m["room_number"],
            "roomId":         m["room_id"],
            "guestName":      m["guest_name"] ?? "Guest",
            "foodItem":       m["food_item"],
            "quantity":       m["quantity"],
            "status":         _statusText(m["order_status"]),
            "orderTime":      _formatTime(m["order_time"]),
            "raw":            m,
          };
        }).toList(),
      };
    } catch (e, stack) {
      dev.log("❌ ERROR (getOrderSummary): $e");
      dev.log("❌ Stack: $stack");
      return {"success": false, "message": "Network error"};
    }
  }
}