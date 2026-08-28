// services/food_order_service.dart
//
// All methods are now on v1 endpoints:
//  • getFoodOrders()        → getFoodOrdersV1() using ScreenSync_get_food_orders_mobile1
//  • acceptFoodOrder()      → ScreenSync_accept_food_order_mobile1 (uses order_id/summary_id)
//  • updateFoodOrderStatus()→ ScreenSync_update_food_order_mobile1
//  • tapEta()               → ScreenSync_update_food_tap_count (uses order_id/summary_id)
//  • setRushHour()          → ScreenSync_set_rush_hour_state_mobile
//  • getRushHourState()     → reads from SharedPreferences; server only on cache-miss
//  • getOrderSummary()      → ScreenSync_get_food_orders_mobile1 (date filter applied client-side)
//
// KEY CONTRACT:
//  • get_food_orders_mobile1 only needs user_id (enterprise derived server-side)
//  • accept / update / tap all use order_id (summary_id), NOT order_number
//  • accept / update Lambdas return STATUS only — no RESULT row
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

      // Keep each terminal state separate for the UI. Delivery is now returned
      // by get_food_orders_mobile1; do not query the retired Room Service API.
      final activeRaw    = <dynamic>[];
      final cancelledRaw = <dynamic>[];
      final deliveredRaw = <dynamic>[];

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
        } else if (statusVal == "DELIVERED") {
          deliveredRaw.add(item);
        } else {
          activeRaw.add(item);
        }
      }

      return {
        "success":         true,
        "message":         statusList[0]["message"] ?? "Success",
        "orders":          _mapFoodOrders(activeRaw),
        "cancelledOrders": _mapCancelledOrders(cancelledRaw),
        "deliveredOrders": _mapFoodOrders(deliveredRaw),
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

      // ScreenSync_accept_food_order_mobile1 returns:
      //   { "RESULT": [{ "status": "S", "message": "...", ... }] }
      // NOT a STATUS key — check RESULT first, then fall back to STATUS.
      final rawResult = response.data["RESULT"];
      final rawStatus = response.data["STATUS"];

      List? sentinelList;
      if (rawResult is List && rawResult.isNotEmpty) {
        sentinelList = rawResult; // normal: RESULT contains the sentinel
      } else if (rawStatus is List && rawStatus.isNotEmpty) {
        sentinelList = rawStatus; // fallback: STATUS contains the sentinel
      }

      if (sentinelList == null || sentinelList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final flag    = (sentinelList[0]["status"] ?? "F").toString();
      final message = (sentinelList[0]["message"] ?? "Unknown error").toString();

      if (flag != "S") {
        return {"success": false, "message": message};
      }

      // Extract enriched accept data for the UI (ETA, accepted_user_id, etc.)
      final resultRow = rawResult is List && rawResult.isNotEmpty
          ? Map<String, dynamic>.from(rawResult[0] as Map)
          : <String, dynamic>{};

      return {
        "success":     true,
        "message":     message,
        "summaryId":   resultRow["summary_id"],
        "orderStatus": resultRow["order_status"],
        "etaTime":     resultRow["eta_time"],
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

      final rawResult = response.data["RESULT"];
      final rawStatus = response.data["STATUS"];

      List? sentinelList;
      if (rawResult is List && rawResult.isNotEmpty) {
        sentinelList = rawResult;
      } else if (rawStatus is List && rawStatus.isNotEmpty) {
        sentinelList = rawStatus;
      }

      if (sentinelList == null || sentinelList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final flag    = (sentinelList[0]["status"] ?? "F").toString();
      final message = (sentinelList[0]["message"] ?? "Unknown error").toString();

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

      final rawResult = response.data["RESULT"];
      final rawStatus = response.data["STATUS"];

      List? sentinelList;
      if (rawResult is List && rawResult.isNotEmpty) {
        sentinelList = rawResult;
      } else if (rawStatus is List && rawStatus.isNotEmpty) {
        sentinelList = rawStatus;
      }

      if (sentinelList == null || sentinelList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final flag    = (sentinelList[0]["status"] ?? "F").toString();
      final message = (sentinelList[0]["message"] ?? "Unknown error").toString();

      if (flag != "S") {
        return {"success": false, "message": message};
      }

      // RESULT[0] has the updated tap state
      final resultList = rawResult is List ? rawResult : rawStatus as List;
      final result     = resultList.isNotEmpty
          ? Map<String, dynamic>.from(resultList.first as Map)
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
  // Input:    { user_id, status: ACTIVE|INACTIVE, rush_hour: minutes, stage }
  // NOTE:     NO durationMinutes — server reads from enterprise_food_service_rule
  // Output:   STATUS[0] with JSON response body:
  //           { status, message, current_rush_hour, rush_hour_status, enterprise_id }

  /// Uses the enterprise-rule rush-hour contract.
  /// Input: { user_id, status: ACTIVE|INACTIVE, rush_hour: minutes, stage }.
  Future<Map<String, dynamic>> setRushHour({
    required bool active,
    required int rushHourMinutes,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {'success': false, 'message': 'User not logged in'};
      }
      if (active && rushHourMinutes <= 0) {
        return {
          'success': false,
          'message': 'Rush hour is not set by the enterprise.',
        };
      }
      final requestedMinutes = active ? rushHourMinutes.clamp(1, 24 * 60) : 0;
      final payload = <String, dynamic>{
        'user_id': userId,
        'status': active ? 'ACTIVE' : 'INACTIVE',
        'rush_hour': requestedMinutes,
        'stage': AppConfig.stage,
      };
      dev.log('Set rush hour: $payload');
      final response = await _dio.post(ApiConstants.setRushHourV1, data: payload);
      if (response.statusCode != 200) {
        return {'success': false, 'message': 'Server error'};
      }

      final data = response.data as Map? ?? const {};
      Map<String, dynamic> firstMap(dynamic rows) {
        if (rows is List) {
          for (final row in rows) {
            if (row is Map) return Map<String, dynamic>.from(row);
          }
        }
        return <String, dynamic>{};
      }
      final statusRow = firstMap(data['STATUS']);
      final resultRow = firstMap(data['RESULT']).isNotEmpty
          ? firstMap(data['RESULT'])
          : firstMap(data['RESULT2']);
      final responseValue = statusRow['response'];
      Map<String, dynamic> responseBody = <String, dynamic>{};
      if (responseValue is Map) {
        responseBody = Map<String, dynamic>.from(responseValue);
      } else if (responseValue is String && responseValue.isNotEmpty) {
        try {
          responseBody = Map<String, dynamic>.from(jsonDecode(responseValue) as Map);
        } catch (_) {}
      }
      final merged = <String, dynamic>{...statusRow, ...responseBody, ...resultRow};
      final flag = (merged['p_out_mssg_flg'] ?? merged['status'] ?? '').toString().toUpperCase();
      if (flag == 'F') {
        return {'success': false, 'message': merged['message'] ?? 'Failed to update rush hour'};
      }

      // Certain deployed Lambda versions expose the first SELECT as {"1": 1}.
      // An HTTP 200 without an explicit procedure failure is therefore accepted.
      final returnedMinutes = int.tryParse((merged['current_rush_hour'] ?? requestedMinutes).toString()) ?? requestedMinutes;
      final returnedStatus = (merged['rush_hour_status'] ?? (active ? 'ACTIVE' : 'INACTIVE')).toString().toUpperCase();
      final rushActive = returnedStatus == 'ACTIVE';
      final savedRushData = await UserSessionHelper.getRushHourData();
      Map<String, dynamic> rushData = <String, dynamic>{};
      if (savedRushData.isNotEmpty) {
        try {
          rushData = Map<String, dynamic>.from(jsonDecode(savedRushData) as Map);
        } catch (_) {}
      }
      rushData['current_rush_hour'] = returnedMinutes;
      await UserSessionHelper.saveRushHourConfig(
        rushHourActive: rushActive ? 1 : 0,
        maxTapCount: await UserSessionHelper.getMaxTapCount(),
        tapCountMin: await UserSessionHelper.getTapCountMin(),
        rushHourStatus: returnedStatus,
        rushHourData: jsonEncode(rushData),
      );
      return {
        'success': true,
        'message': merged['message'] ?? (rushActive ? 'Rush hour activated' : 'Rush hour deactivated'),
        'rush_hour_active': rushActive,
        'rush_hour_status': returnedStatus,
        'current_rush_hour': returnedMinutes,
      };
    } catch (e, stack) {
      dev.log('Set rush hour failed: $e');
      dev.log('$stack');
      return {'success': false, 'message': 'Network error'};
    }
  }

  // -- GET RUSH HOUR STATE ---------------------------------------------------
  // Reads the most recently confirmed enterprise state from local storage.
  Future<Map<String, dynamic>> getRushHourState() async {
    try {
      final active = await UserSessionHelper.getRushHourActive();
      final status = await UserSessionHelper.getRushHourStatus();
      final rawConfig = await UserSessionHelper.getRushHourData();
      Map<String, dynamic> config = <String, dynamic>{};
      if (rawConfig.isNotEmpty) {
        try {
          config = Map<String, dynamic>.from(jsonDecode(rawConfig) as Map);
        } catch (_) {}
      }
      int configuredMinutes = 0;
      if (rawConfig.isNotEmpty) {
        final value = config['Duration'] ??
            config['duration'] ??
            config['duration_minutes'] ??
            config['rush_hour_minutes'];
        configuredMinutes = int.tryParse('$value') ?? 0;
      }
      final currentMinutes = config['current_rush_hour'] is num
          ? (config['current_rush_hour'] as num).toInt()
          : int.tryParse('${config['current_rush_hour']}') ?? 0;
      return {
        "success": true,
        "rush_hour_active": active,
        "rush_hour_status": status,
        "current_rush_hour": currentMinutes,
        "configured_rush_hour_minutes": configuredMinutes,
      };
    } catch (e) {
      dev.log("❌ ERROR (getRushHourState): $e");
      return {"success": false, "rush_hour_active": false};
    }
  }

  // ── GET ORDER SUMMARY (v1 — migrated from ScreenSync_get_order_summary_mobile) ──
  // Uses getFoodOrdersV1 (ScreenSync_get_food_orders_mobile1) which returns all
  // historical orders including Delivered and Cancelled rows.
  //
  // When [date] is provided, the returned orders are filtered client-side to
  // that calendar day (daily view). When [date] is null the full result set is
  // returned for weekly-aggregate calculation in the caller.
  //
  // Summary aggregates (weeklyTotal, weeklyCancelled) are derived from the RESULT
  // rows rather than a separate server-side summary object.

  Future<Map<String, dynamic>> getOrderSummary({DateTime? date}) async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {
        "user_id": userId,
        "stage":   AppConfig.stage,
      };

      dev.log("📤 Fetching Order Summary (v1)");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.getFoodOrdersV1,
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

      final statusFlag = (statusList[0]["status"] ?? "F").toString();
      if (statusFlag != "S") {
        return {
          "success": false,
          "message": statusList[0]["message"] ?? "Failed to fetch order summary",
        };
      }

      final resultList = (response.data["RESULT"] ?? []) as List;

      // Map every row from the v1 flat structure into the shape the Order
      // History page and its widgets expect.
      final allMapped = resultList.map<Map<String, dynamic>>((o) {
        final m            = Map<String, dynamic>.from(o);
        final foodItemName = m["food_name"] ?? m["food_item"] ?? "-";
        final statusVal    = m["order_status"] ?? m["status"] ?? "Pending";
        final orderTimeVal = m["created_at"] ?? m["order_time"];

        return {
          "summaryId":      _safeInt(m["summary_id"]),
          "orderRequestId": m["order_request_id"],
          "orderNumber":    m["order_number"]  ?? "-",
          "roomNumber":     m["room_number"]   ?? "-",
          "roomId":         m["room_id"],
          "guestName":      m["guest_name"]    ?? "Guest",
          "foodItem":       foodItemName,
          "quantity":       m["quantity"]      ?? 0,
          "status":         _statusText(statusVal),
          "cancelReason":   m["cancel_reason"] ?? "",
          "orderTime":      _formatTime(orderTimeVal?.toString()),
          "raw": {
            ...m,
            // Ensure keys the analytics model reads are present
            "order_time":        orderTimeVal,
            "created_at":        orderTimeVal,
            "status_changed_at": m["status_changed_at"],
            "cancel_reason":     m["cancel_reason"] ?? "",
          },
        };
      }).toList();

      // ── Client-side date filter ──────────────────────────────────────────
      List<Map<String, dynamic>> filteredOrders;
      if (date != null) {
        filteredOrders = allMapped.where((o) {
          final rawTime = o["raw"]["order_time"] ?? o["raw"]["created_at"];
          final dt = rawTime is DateTime
              ? rawTime
              : DateTime.tryParse(rawTime?.toString() ?? "");
          if (dt == null) return false;
          return dt.year == date.year &&
              dt.month == date.month &&
              dt.day == date.day;
        }).toList();
      } else {
        filteredOrders = allMapped;
      }

      // ── Derive summary aggregates from rows ──────────────────────────────
      final int weeklyTotal = allMapped.length;
      final int weeklyCancelled = allMapped.where((o) {
        final s = (o["status"] ?? "").toString().toUpperCase();
        return s == "CANCELLED" || s == "CANCELED";
      }).length;

      return {
        "success": true,
        "message": statusList[0]["message"] ?? "Success",
        "summary": {
          "weeklyTotal":     weeklyTotal,
          "weeklyCancelled": weeklyCancelled,
        },
        "orders": filteredOrders,
      };
    } catch (e, stack) {
      dev.log("❌ ERROR (getOrderSummary v1): $e");
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
        // Escalation fields
        "isEscalated":         m["is_escalated"] == 1 || m["is_escalated"] == true,
        "escalationHistory":   _parseEscalationHistory(m["escalation_history"]),
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
        // Escalation fields
        "isEscalated":         m["is_escalated"] == 1 || m["is_escalated"] == true,
        "escalationHistory":   _parseEscalationHistory(m["escalation_history"]),
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

  // ── ESCALATION HISTORY PARSER ─────────────────────────────────────────────

  /// Parses escalation_history from a JSON string or list into a List<Map>.
  /// Each entry: { level, toUser: {userId, userName, roleName},
  ///              fromUsers: [{userId, userName, roleName}], escalatedAt }
  static List<Map<String, dynamic>> _parseEscalationHistory(dynamic value) {
    if (value == null) return [];
    try {
      List parsed;
      if (value is String) {
        if (value.trim().isEmpty) return [];
        parsed = json.decode(value) as List;
      } else if (value is List) {
        parsed = value;
      } else {
        return [];
      }

      // Deduplicate: stop once the same to_user repeats (max level hit).
      // The cron may keep re-escalating to the same person with incrementing levels.
      final Set<String> seenToUsers = {};
      final List<Map<String, dynamic>> result = [];

      for (final entry in parsed) {
        final e = Map<String, dynamic>.from(entry);
        final level = (e["level"] as num?)?.toInt() ?? 0;

        final toUser = e["to_user"] is Map ? Map<String, dynamic>.from(e["to_user"]) : <String, dynamic>{};

        // Build dedup key from to_user
        final toUserId = toUser["user_id"];
        final toKey = toUserId != null
            ? 'uid_$toUserId'
            : '${toUser["role_name"] ?? ""}_${toUser["user_name"] ?? ""}';

        // If same target user seen before, max reached — stop
        if (seenToUsers.contains(toKey)) break;
        seenToUsers.add(toKey);

        final fromUsers = (e["from_users"] is List)
            ? (e["from_users"] as List).map((f) => Map<String, dynamic>.from(f)).toList()
            : <Map<String, dynamic>>[];

        result.add({
          "level":       level,
          "toUser": {
            "userId":   toUser["user_id"],
            "userName":  toUser["user_name"] ?? "",
            "roleName":  toUser["role_name"] ?? "",
          },
          "fromUsers": fromUsers.map((f) => {
            "userId":   f["user_id"],
            "userName":  f["user_name"] ?? "",
            "roleName":  f["role_name"] ?? "",
          }).toList(),
          "escalatedAt": e["escalated_at"] ?? "",
        });
      }

      return result;
    } catch (_) {
      return [];
    }
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
}
