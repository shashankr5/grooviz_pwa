// services/food_order_service.dart
//
// CHANGES IN THIS VERSION (v1 migration):
//  • getFoodOrders()        → getFoodOrdersV1() using ScreenSync_get_food_orders_mobile1
//  • acceptFoodOrder()      → NEW, using ScreenSync_accept_food_order_mobile1 (uses order_id/summary_id)
//  • updateFoodOrderStatus()→ updateFoodOrderStatusV1() using ScreenSync_update_food_order_mobile1
//  • tapEta()               → NEW, using ScreenSync_update_food_tap_count (uses order_id/summary_id)
//  • setRushHour()          → setRushHourV1() using ScreenSync_set_rush_hour_state_mobile (no duration)
//  • getRushHourState()     → reads from SharedPreferences; server only on cache-miss
//  • getOrderSummary()      → unchanged (not yet migrated, still uses old endpoint)
//
// KEY CONTRACT CHANGES vs. old service:
//  • get_food_orders_mobile1 only needs user_id (enterprise derived server-side)
//  • accept / update / tap all use order_id (summary_id), NOT order_number
//  • accept Lambda returns STATUS only — no RESULT row is returned
//  • update Lambda returns STATUS only — no RESULT row is returned
//  • set_rush_hour Lambda returns STATUS only with response JSON body
//  • stage is MANDATORY in every payload — Lambda fails if missing

import 'dart:developer' as dev;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

import '../utils/user_session_helper.dart';
import '../utils/food_order_status.dart';
import '../utils/date_formatter.dart';
import '../constants/api_constants.dart';
import '../constants/app_config.dart';
import '../constants/api_timeouts.dart';

class FoodOrderService {
  final Dio _dio;

  FoodOrderService()
      : _dio = Dio(
          BaseOptions(
            baseUrl: ApiConstants.baseUrl,
            connectTimeout: ApiTimeouts.connectTimeout,
            receiveTimeout: ApiTimeouts.receiveTimeout,
            sendTimeout: ApiTimeouts.sendTimeout,
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

  // ── GET FOOD ORDERS (v1) ──────────────────────────────────────────────────
  // Endpoint: ScreenSync_get_food_orders_mobile1
  // Input:    { user_id, stage }   (enterprise_id derived server-side)
  // Output:   STATUS[0] + RESULT[] flat rows, one row per order-item.
  //           New fields: summary_id, final_eta_time, final_eta_duration,
  //                       eta_tap_count, eta_tap_minutes

  Future<Map<String, dynamic>> getFoodOrders() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {
        "user_id": userId,
        "stage":   AppConfig.stage,
      };

      dev.log("📤 Fetching Food Orders v1");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.getFoodOrdersV1,
        data: payload,
      );

      dev.log("📥 Raw Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final statusFlag = (statusList[0]["status"] ?? "F").toString();
      if (statusFlag != "S") {
        return {
          "success": false,
          "message": statusList[0]["message"] ?? "Failed to load orders",
        };
      }

      final resultList = (response.data["RESULT"] ?? []) as List;

      // Separate active and cancelled by order_status (from order_status_summary)
      final activeRaw    = <dynamic>[];
      final cancelledRaw = <dynamic>[];

      for (final item in resultList) {
        final itemMap   = Map<String, dynamic>.from(item);
        // order_status comes from order_status_summary.status (Pending/Accepted/Ready/etc)
        final statusVal = (
          itemMap["order_status"] ??
          itemMap["status"] ??
          ""
        ).toString().trim().toUpperCase();

        if (statusVal == "CANCELLED" || statusVal == "CANCELED") {
          cancelledRaw.add(item);
        } else {
          activeRaw.add(item);
        }
      }

      return {
        "success":         true,
        "message":         statusList[0]["message"] ?? "Success",
        "orders":          _mapFoodOrders(activeRaw),
        "cancelledOrders": _mapCancelledOrders(cancelledRaw),
      };
    } catch (e, stack) {
      dev.log("❌ ERROR (getFoodOrders v1): $e");
      dev.log("❌ Stack: $stack");
      return {"success": false, "message": "Network error"};
    }
  }

  // ── ACCEPT FOOD ORDER (v1) ────────────────────────────────────────────────
  // Endpoint: ScreenSync_accept_food_order_mobile1
  // Input:    { user_id, enterprise_id, order_id (summary_id), stage }
  // Output:   STATUS[0] only — Lambda does NOT return RESULT rows.
  //           On success: reload orders from getFoodOrders() to get updated state.

  Future<Map<String, dynamic>> acceptFoodOrder({
    required int summaryId,
  }) async {
    try {
      final int? userId       = await UserSessionHelper.getUserId();
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || userId == 0) {
        return {"success": false, "message": "User not logged in"};
      }
      if (enterpriseId == null || enterpriseId == 0) {
        return {"success": false, "message": "Enterprise ID missing"};
      }

      final payload = <String, dynamic>{
        "user_id":       userId,
        "enterprise_id": enterpriseId,
        "order_id":      summaryId,   // summary_id from order_status_summary
        "stage":         AppConfig.stage,
      };

      dev.log("📤 Accept Food Order v1");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.acceptFoodOrderV1,
        data: payload,
      );

      dev.log("📥 Raw Accept Response: ${response.data}");

      // Lambda returns { STATUS: results[0] } only
      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final flag    = (statusList[0]["status"] ?? "F").toString();
      final message = (statusList[0]["message"] ?? "Unknown error").toString();

      return {
        "success": flag == "S",
        "message": message,
      };
    } catch (e, stack) {
      dev.log("❌ ERROR (acceptFoodOrder v1): $e");
      dev.log("❌ Stack: $stack");
      return {"success": false, "message": "Network error"};
    }
  }

  // ── UPDATE FOOD ORDER STATUS (v1) ─────────────────────────────────────────
  // Endpoint: ScreenSync_update_food_order_mobile1
  // Input:    { user_id, enterprise_id, order_id (summary_id), status, cancel_reason, stage }
  // Handles:  Ready, Delivered, Cancelled   (NOT Accepted — use acceptFoodOrder())
  // Output:   STATUS[0] only — Lambda does NOT return RESULT rows.

  Future<Map<String, dynamic>> updateFoodOrderStatus({
    required int    summaryId,
    required String status,        // 'Ready' | 'Delivered' | 'Cancelled'
    String?         cancelReason,
  }) async {
    try {
      final int? userId       = await UserSessionHelper.getUserId();
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || userId == 0) {
        return {"success": false, "message": "User not logged in"};
      }
      if (enterpriseId == null || enterpriseId == 0) {
        return {"success": false, "message": "Enterprise ID missing"};
      }

      final payload = <String, dynamic>{
        "user_id":       userId,
        "enterprise_id": enterpriseId,
        "order_id":      summaryId,
        "status":        status,
        "cancel_reason": cancelReason ?? "",
        "stage":         AppConfig.stage,
      };

      dev.log("📤 Update Food Order Status v1 (status=$status)");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.updateFoodOrderV1,
        data: payload,
      );

      dev.log("📥 Raw Update Response: ${response.data}");

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final flag    = (statusList[0]["status"] ?? "F").toString();
      final message = (statusList[0]["message"] ?? "Unknown error").toString();

      return {
        "success": flag == "S",
        "message": message,
      };
    } catch (e, stack) {
      dev.log("❌ ERROR (updateFoodOrderStatus v1): $e");
      dev.log("❌ Stack: $stack");
      return {"success": false, "message": "Network error"};
    }
  }

  // ── TAP ETA (v1) ──────────────────────────────────────────────────────────
  // Endpoint: ScreenSync_update_food_tap_count
  // Input:    { user_id, enterprise_id, order_id (summary_id), stage }
  // Server:   reads tap_count_min from enterprise_food_service_rule and
  //           adds it to final_eta_time.  Enforces max_tap_count server-side.
  // Output:   STATUS[0] + RESULT[0] with updated tap state:
  //           { summary_id, order_number, order_status, eta_time,
  //             eta_tap_count, eta_tap_minutes, update_time }

  Future<Map<String, dynamic>> tapEta({
    required int summaryId,
  }) async {
    try {
      final int? userId       = await UserSessionHelper.getUserId();
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || userId == 0) {
        return {"success": false, "message": "User not logged in"};
      }
      if (enterpriseId == null || enterpriseId == 0) {
        return {"success": false, "message": "Enterprise ID missing"};
      }

      final payload = <String, dynamic>{
        "user_id":       userId,
        "enterprise_id": enterpriseId,
        "order_id":      summaryId,
        "stage":         AppConfig.stage,
      };

      dev.log("📤 Tap ETA v1");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.tapFoodOrderEtaV1,
        data: payload,
      );

      dev.log("📥 Raw Tap ETA Response: ${response.data}");

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final flag    = (statusList[0]["status"] ?? "F").toString();
      final message = (statusList[0]["message"] ?? "Unknown error").toString();

      if (flag != "S") {
        return {"success": false, "message": message};
      }

      // RESULT[0] has the updated tap state
      final resultList = response.data["RESULT"] as List?;
      final result     = resultList != null && resultList.isNotEmpty
          ? Map<String, dynamic>.from(resultList.first)
          : <String, dynamic>{};

      return {
        "success":       true,
        "message":       message,
        "etaTapCount":   _safeInt(result["eta_tap_count"]),
        "etaTapMinutes": _safeInt(result["eta_tap_minutes"]),
        "finalEtaTime":  result["final_eta_time"]?.toString(),
        "summaryId":     result["summary_id"],
      };
    } catch (e, stack) {
      dev.log("❌ ERROR (tapEta v1): $e");
      dev.log("❌ Stack: $stack");
      return {"success": false, "message": "Network error"};
    }
  }

  // ── SET RUSH HOUR (v1) ────────────────────────────────────────────────────
  // Endpoint: ScreenSync_set_rush_hour_state_mobile
  // Input:    { user_id, rush_hour_active (0|1), stage }
  // NOTE:     NO durationMinutes — server reads from enterprise_food_service_rule
  // Output:   STATUS[0] with JSON response body:
  //           { status, message, current_rush_hour, rush_hour_status, enterprise_id }

  Future<Map<String, dynamic>> setRushHour({required bool active}) async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User not logged in"};
      }

      final payload = <String, dynamic>{
        "user_id":          userId,
        "rush_hour_active": active ? 1 : 0,
        "stage":            AppConfig.stage,
      };

      dev.log("📤 Set Rush Hour v1 (active=$active)");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.setRushHourV1,
        data: payload,
      );

      dev.log("📥 Raw Set Rush Hour Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      // Lambda returns { STATUS: results[0] } — response field is a JSON string
      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final flag = (statusList[0]["status"] ?? "F").toString();

      // The SP OUT param p_out_mssg is a JSON object — Lambda wraps it in STATUS[0].response
      dynamic responseBody = statusList[0]["response"];
      Map<String, dynamic> body = {};
      if (responseBody is String && responseBody.isNotEmpty) {
        try { body = Map<String, dynamic>.from(jsonDecode(responseBody)); }
        catch (_) {}
      } else if (responseBody is Map) {
        body = Map<String, dynamic>.from(responseBody);
      }

      if (flag != "S") {
        return {
          "success": false,
          "message": body["message"] ?? statusList[0]["message"] ?? "Failed",
        };
      }

      final newActive = body["current_rush_hour"];
      final rushActive = newActive == 1 || newActive == true || newActive == "1";

      // Persist updated rush hour state to SharedPreferences
      await UserSessionHelper.saveRushHourConfig(
        rushHourActive: rushActive ? 1 : 0,
        maxTapCount:    await UserSessionHelper.getMaxTapCount(),
        tapCountMin:    await UserSessionHelper.getTapCountMin(),
        rushHourStatus: (body["rush_hour_status"] ?? (rushActive ? "ACTIVE" : "INACTIVE")).toString(),
      );

      return {
        "success":          true,
        "message":          body["message"] ?? "Rush hour updated",
        "rush_hour_active": rushActive,
        "rush_hour_status": body["rush_hour_status"],
        "enterprise_id":    body["enterprise_id"],
      };
    } catch (e, stack) {
      dev.log("❌ ERROR (setRushHour v1): $e");
      dev.log("❌ Stack: $stack");
      return {"success": false, "message": "Network error"};
    }
  }

  // ── GET RUSH HOUR STATE ───────────────────────────────────────────────────
  // Reads from SharedPreferences (saved at login or after setRushHour).
  // Returns immediately without a network call.

  Future<Map<String, dynamic>> getRushHourState() async {
    try {
      final active = await UserSessionHelper.getRushHourActive();
      final status = await UserSessionHelper.getRushHourStatus();
      return {
        "success":          true,
        "rush_hour_active": active,
        "rush_hour_status": status,
      };
    } catch (e) {
      dev.log("❌ ERROR (getRushHourState): $e");
      return {"success": false, "rush_hour_active": false};
    }
  }

  // ── GET ORDER SUMMARY (unchanged — not yet migrated) ─────────────────────

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
        "stage": AppConfig.stage,
      };

      dev.log("📤 Fetching Order Summary");

      // Uses old endpoint — not yet v1 migrated
      final response = await _dio.post(
        "$baseUrl/ScreenSync_get_order_summary_mobile",
        data: payload,
      );

      dev.log("📥 Raw Summary Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final statusFlag     = statusList[0]["status"];
      final responseString = statusList[0]["response"];

      if (statusFlag != "S" || responseString == null) {
        return {"success": false, "message": "Failed to fetch order summary"};
      }

      final decoded   = jsonDecode(responseString);
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

  // ── MAP ACTIVE ORDERS ─────────────────────────────────────────────────────
  // Maps flat API rows to a normalised structure compatible with groupFoodOrderRows().
  // New v1 fields: summary_id, final_eta_time, final_eta_duration, eta_tap_count, eta_tap_minutes

  static List<Map<String, dynamic>> _mapFoodOrders(List raw) {
    return raw.map<Map<String, dynamic>>((o) {
      final m            = Map<String, dynamic>.from(o);
      final foodItemName = m["food_name"] ?? m["food_item"] ?? "-";
      final statusVal    = m["order_status"] ?? m["status"] ?? "Pending";
      final orderTimeVal = m["created_at"] ?? m["order_time"];

      return {
        "summaryId":           _safeInt(m["summary_id"]),        // ★ NEW v1 field
        "orderRequestId":      m["order_request_id"],
        "orderNumber":         m["order_number"]          ?? "-",
        "roomNumber":          m["room_number"]            ?? "-",
        "roomId":              m["room_id"],
        "guestName":           m["guest_name"]             ?? "Guest",
        "foodItem":            foodItemName,
        "quantity":            m["quantity"]               ?? 0,
        "cookingInstructions": (m["cooking_instructions"]  ?? "").toString().trim(),
        "status":              _statusText(statusVal),
        "statusColor":         _statusColor(statusVal),
        "cancelReason":        m["cancel_reason"]          ?? "",
        "orderTime":           _formatTime(orderTimeVal),
        "isVeg":               m["is_veg"],
        // ETA fields (new v1)
        "etaTapCount":         _safeInt(m["summary_eta_tap_count"] ?? m["eta_tap_count"]),
        "etaTapMinutes":       _safeInt(m["eta_tap_minutes"]),
        "finalEtaTime":        m["final_eta_time"]?.toString(),
        "finalEtaDuration":    _safeInt(m["final_eta_duration"]),
        // Legacy ETA fields (kept for groupFoodOrderRows() compatibility)
        "extraEtaMinutes":     _safeInt(m["extra_eta_minutes"]),
        "etaLocked":           false,   // v1 uses tap count check instead
        "raw":                 m,
      };
    }).toList();
  }

  // ── MAP CANCELLED ORDERS ──────────────────────────────────────────────────

  static List<Map<String, dynamic>> _mapCancelledOrders(List raw) {
    return raw.map<Map<String, dynamic>>((o) {
      final m            = Map<String, dynamic>.from(o);
      final foodItemName = m["food_name"] ?? m["food_item"] ?? "-";
      final orderTimeVal = m["created_at"] ?? m["order_time"];

      return {
        "summaryId":           _safeInt(m["summary_id"]),
        "orderRequestId":      m["order_request_id"],
        "orderNumber":         m["order_number"]          ?? "-",
        "roomNumber":          m["room_number"]            ?? "-",
        "roomId":              m["room_id"],
        "guestName":           m["guest_name"]             ?? "Guest",
        "foodItem":            foodItemName,
        "quantity":            m["quantity"]               ?? 0,
        "cookingInstructions": (m["cooking_instructions"]  ?? "").toString().trim(),
        "status":              FoodOrderStatus.cancelled.label,
        "statusColor":         const Color(0xFFD32F2F),
        "cancelReason":        m["cancel_reason"]          ?? "",
        "orderTime":           _formatTime(orderTimeVal),
        "isVeg":               m["is_veg"],
        "etaTapCount":         0,
        "etaTapMinutes":       0,
        "extraEtaMinutes":     0,
        "etaLocked":           false,
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

  // ── STATUS HELPERS ────────────────────────────────────────────────────────

  static String _statusText(dynamic s) {
    if (s == null || s.toString().trim().isEmpty) return FoodOrderStatus.pending.label;
    switch (s.toString().trim().toUpperCase()) {
      case "PENDING":   return FoodOrderStatus.pending.label;
      case "ACCEPTED":  return FoodOrderStatus.preparing.label;  // Accepted = Preparing in UI
      case "PREPARING": return FoodOrderStatus.preparing.label;
      case "READY":     return FoodOrderStatus.ready.label;
      case "DELIVERED": return FoodOrderStatus.delivered.label;
      case "CANCELLED":
      case "CANCELED":  return FoodOrderStatus.cancelled.label;
      default:          return FoodOrderStatus.pending.label;
    }
  }

  static Color _statusColor(dynamic s) {
    if (s == null || s.toString().trim().isEmpty) return const Color(0xFF1976D2);
    switch (s.toString().trim().toUpperCase()) {
      case "PENDING":   return const Color(0xFF1976D2);
      case "ACCEPTED":
      case "PREPARING": return const Color(0xFFFF9800);
      case "READY":     return const Color(0xFF4CAF50);
      case "DELIVERED": return const Color(0xFF2E7D32);
      case "CANCELLED":
      case "CANCELED":  return const Color(0xFFD32F2F);
      default:          return const Color(0xFF1976D2);
    }
  }

  static String _formatTime(String? timestamp) {
    return DateFormatter.formatDateTimeAmPm(timestamp);
  }

  // Internal base URL copy for getOrderSummary (not yet migrated)
  static const String baseUrl = "https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production";
}
