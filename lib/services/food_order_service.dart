//food_order_service.dart
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

      dev.log("📥 Raw Response: ${response.data}");

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
        return {"success": false, "message": "Invalid server response"};
      }

      final decoded  = json.decode(responseString);
      final ordersRaw = decoded["orders"] as List? ?? [];
      final orders   = _mapFoodOrders(ordersRaw);

      return {
        "success": true,
        "message": decoded["message"] ?? "Success",
        "orders":  orders,
      };
    } catch (e) {
      dev.log("❌ ERROR (getFoodOrders): $e");
      return {"success": false, "message": "Network error"};
    }
  }

  // ── MAP API → UI FRIENDLY FORMAT ─────────────────────────────────────────

  static List<Map<String, dynamic>> _mapFoodOrders(List raw) {
    return raw.map<Map<String, dynamic>>((o) {
      final m = Map<String, dynamic>.from(o);
      return {
        "orderRequestId":  m["order_request_id"],
        "orderNumber":     m["order_number"] ?? "-",
        "roomNumber":      m["room_number"]  ?? "-",
        "roomId":          m["room_id"],
        "guestName":       m["guest_name"]   ?? "Guest",
        "foodItem":        m["food_item"]    ?? "-",
        "quantity":        m["quantity"]     ?? 0,
        "cookingInstructions": (m["cooking_instructions"] ?? "").toString().trim(),
        "status":          _statusText(m["order_status"]),
        "statusColor":     _statusColor(m["order_status"]),
        "cancelReason":    m["cancel_reason"],
        "orderTime":       _formatTime(m["order_time"]),
        // ── NEW: extra ETA fields from DB ──────────────────────────────
        "extraEtaMinutes": (m["extra_eta_minutes"] ?? 0) as int,
        "etaLocked":       (m["eta_locked"] ?? 0) == 1,
        // ──────────────────────────────────────────────────────────────
        "raw": m,
      };
    }).toList();
  }

  // ── STATUS HELPERS ────────────────────────────────────────────────────────

  static String _statusText(String? s) {
    if (s == null || s.trim().isEmpty) return FoodOrderStatus.pending.label;
    switch (s.trim().toUpperCase()) {
      case "PENDING":              return FoodOrderStatus.pending.label;
      case "PREPARING":            return FoodOrderStatus.preparing.label;
      case "READY":                return FoodOrderStatus.ready.label;
      case "DELIVERED":            return FoodOrderStatus.delivered.label;
      case "CANCELLED":
      case "CANCELED":             return FoodOrderStatus.cancelled.label;
      default:                     return FoodOrderStatus.pending.label;
    }
  }

  static Color _statusColor(String? s) {
    if (s == null || s.trim().isEmpty) return const Color(0xFF1976D2);
    switch (s.trim().toUpperCase()) {
      case "PENDING":              return const Color(0xFF1976D2);
      case "PREPARING":            return const Color(0xFFFF9800);
      case "READY":                return const Color(0xFF4CAF50);
      case "DELIVERED":            return const Color(0xFF2E7D32);
      case "CANCELLED":
      case "CANCELED":             return const Color(0xFFD32F2F);
      default:                     return const Color(0xFF1976D2);
    }
  }

  static String _formatTime(String? timestamp) {
    if (timestamp == null) return "-";
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      return "${dt.hour}:${dt.minute.toString().padLeft(2, '0')} • "
          "${dt.day}/${dt.month}/${dt.year}";
    } catch (_) {
      return "-";
    }
  }

  // ── UPDATE FOOD ORDER STATUS ──────────────────────────────────────────────
  //
  // Now accepts an optional [addMinutes] parameter.
  // When status == 'ADD_ETA', pass addMinutes > 0.
  // The SP handles ADD_ETA as a special branch — no status transition occurs.

  Future<Map<String, dynamic>> updateFoodOrderStatus({
    required String orderNumber,
    required String status,
    String? cancelReason,
    int?    addMinutes,       // ← NEW: only used when status == 'ADD_ETA'
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

      // Only include add_minutes when it is meaningful
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
        "success": flag == "S",
        "message": message,
        "status":  flag,
        "data":    result,
        // ── NEW: returned by ADD_ETA branch ───────────────────────────
        "extraEtaMinutes": result["extra_eta_minutes"],
        "etaLocked":       result["eta_locked"],
        // ─────────────────────────────────────────────────────────────
      };
    } catch (e) {
      dev.log("❌ ERROR (updateFoodOrderStatus): $e");
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
          "date": "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}",
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

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final statusFlag     = statusList[0]["status"];
      final responseString = statusList[0]["response"];

      if (statusFlag != "S" || responseString == null) {
        return {"success": false, "message": "Failed to fetch order summary"};
      }

      final decoded  = json.decode(responseString);
      final summary  = decoded["summary"] ?? {};
      final ordersRaw = decoded["orders"] as List? ?? [];

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
    } catch (e) {
      dev.log("❌ ERROR (getOrderSummary): $e");
      return {"success": false, "message": "Network error"};
    }
  }
}