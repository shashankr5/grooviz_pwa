import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../utils/user_session_helper.dart';
import '../constants/api_constants.dart';

class HomeService {
  final Dio _dio;

  HomeService()
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

  // ── GET TASKS ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getTasks() async {
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

      dev.log("Fetching tasks...");
      final response = await _dio.post(ApiConstants.tasks, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final status = response.data["STATUS"];
      if (status == null || status.isEmpty || status[0]["status"] != "S") {
        return {
          "success": false,
          "message": status?[0]["message"] ?? "Failed",
        };
      }

      final resultList = response.data["RESULT"];
      if (resultList == null) {
        return {"success": false, "message": "No tasks returned"};
      }

      return {"success": true, "tasks": _mapTasks(resultList)};
    } catch (e) {
      dev.log("ERROR (getTasks): $e");
      return {"success": false, "message": "Network error"};
    }
  }

  static List<Map<String, dynamic>> _mapTasks(List raw) {
    return raw.map<Map<String, dynamic>>((t) {
      final m = Map<String, dynamic>.from(t);
      return {
        "service_request_id": m["service_request_id"],
        "room": (m["room_id"] ?? m["requested_room"] ?? "-").toString(),
        "status":      _statusText(m["status"], m["closed"]),
        "statusColor": _statusColor(m["status"]),
        "title":       m["question"] ?? "Service Request",
        "subtitle":    m["answer"]   ?? "Awaiting response",
        "description": m["answer"]   ?? "",
        "time":        _formatTime(m["timestamp"]),
        "guest":       m["guest_name"] ?? "Unknown Guest",
        "guestNote":
            "Phone: ${m["guest_phone"] ?? m["customer_number"] ?? "-"}",
        "assignedTo": (m["assigned_to_name"] ??
                m["assigned_user_name"] ??
                m["assigned_name"] ??
                m["name"] ??
                m["assigned_to"] ??
                "-")
            .toString(),
        "note": m["note_text"],
        "raw":  m,
      };
    }).toList();
  }

  static String _statusText(String? s, int? closed) {
    if (s == null) return "Open";
    switch (s.toUpperCase()) {
      case "CLOSED":
        return "Closed";
      case "PENDING":
        return "Open";
      case "IN_PROGRESS":
      case "INPROGRESS":
      case "IN PROGRESS":
        return "In Progress";
      default:
        return s;
    }
  }

  static Color _statusColor(String? s) {
    if (s == null) return Colors.blue;
    switch (s.toUpperCase()) {
      case "PENDING":
        return const Color(0xFF1976D2);
      case "INPROGRESS":
      case "IN_PROGRESS":
        return const Color(0xFFFF9800);
      case "CLOSED":
        return const Color(0xFF4CAF50);
      default:
        return Colors.blueGrey;
    }
  }

  static String _formatTime(String? timestamp) {
    if (timestamp == null) return "-";
    try {
      final dt = DateTime.parse(timestamp);
      return "${dt.hour}:${dt.minute.toString().padLeft(2, '0')} • ${dt.day}/${dt.month}";
    } catch (_) {
      return "-";
    }
  }

  // ── GET STAFF LIST ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getStaffList() async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {"success": false, "message": "User not logged in", "staff": []};
      }

      final payload = {"user_id": userId, "stage": "dev"};

      dev.log("📤 Fetching staff list...");
      final response = await _dio.post(ApiConstants.staffList, data: payload);

      if (response.statusCode != 200) {
        return {
          "success": false,
          "message": "Server error: ${response.statusCode}",
          "staff": [],
        };
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid server response",
          "staff": [],
        };
      }

      final statusFlag    = statusList[0]["status"] ?? "F";
      final statusMessage = statusList[0]["message"] ?? "Unknown";

      if (statusFlag != "S") {
        return {"success": false, "message": statusMessage, "staff": []};
      }

      final resultList = response.data["RESULT"] as List?;
      if (resultList != null && resultList.isNotEmpty) {
        dev.log("📋 Staff item keys: ${resultList.first.keys.toList()}");
        dev.log("📋 Staff item sample: ${resultList.first}");
      }

      final staff = resultList?.map((item) {
        final phone = (item["phone"] ??
                item["mobile"] ??
                item["mobile_number"] ??
                item["phone_number"] ??
                item["contact_number"] ??
                item["user_phone"] ??
                item["staff_phone"] ??
                "")
            .toString();
        return {
          "userId":     item["user_id"],
          "name":       item["name"]            ?? "-",
          "department": item["department_name"] ?? "Not Assigned",
          "phone":      phone,
        };
      }).toList();

      return {"success": true, "message": statusMessage, "staff": staff ?? []};
    } catch (e) {
      dev.log("Staff API Error: $e");
      return {"success": false, "message": "Error: $e", "staff": []};
    }
  }

  // ── REASSIGN TICKET ───────────────────────────────────────────────────────

  Future<Map<String, dynamic>> reassignTicket({
    required int ticketId,
    required int assignedUserId,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {"success": false, "message": "User not logged in"};
      }

      final payload = {
        "user_id":    userId,
        "task_id":    ticketId,
        "reassign_to": assignedUserId,
        "stage":      "dev",
      };

      final response =
          await _dio.post(ApiConstants.reassignTicket, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid response"};
      }

      final flag = statusList[0]["status"];
      final msg  = statusList[0]["message"];

      if (flag != "S") return {"success": false, "message": msg ?? "Failed"};

      final updatedTask = response.data["RESULT"][0];
      return {"success": true, "message": msg, "updatedTask": updatedTask};
    } catch (e) {
      dev.log("ERROR (reassignTicket): $e");
      return {"success": false, "message": "Error: $e"};
    }
  }

  // ── ADD NOTE ──────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> addNote({
    required int serviceRequestId,
    required String noteText,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {
          "success": false,
          "message": "User not logged in",
          "note": null,
        };
      }

      final payload = {
        "user_id":            userId,
        "service_request_id": serviceRequestId,
        "note_text":          noteText,
        "stage":              "dev",
      };

      final response = await _dio.post(ApiConstants.addNotes, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error", "note": null};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid response",
          "note": null,
        };
      }

      final flag = statusList[0]["status"];
      final msg  = statusList[0]["message"];

      if (flag != "S") {
        return {"success": false, "message": msg ?? "Failed", "note": null};
      }

      return {
        "success": true,
        "message": msg,
        "note": response.data["RESULT"][0],
      };
    } catch (e) {
      dev.log("ERROR (addNote): $e");
      return {"success": false, "message": "Error: $e", "note": null};
    }
  }

  // ── CLOSE SERVICE REQUEST ─────────────────────────────────────────────────

  Future<Map<String, dynamic>> closeServiceRequest({
    required int serviceRequestId,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {
          "success": false,
          "message": "User not logged in",
          "data": null,
        };
      }

      final payload = {
        "user_id":            userId,
        "service_request_id": serviceRequestId,
        "stage":              "dev",
      };

      final response =
          await _dio.post(ApiConstants.closeServiceRequest, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error", "data": null};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid response",
          "data": null,
        };
      }

      final flag = statusList[0]["status"];
      final msg  = statusList[0]["message"];

      if (flag != "S") {
        return {"success": false, "message": msg ?? "Failed", "data": null};
      }

      return {
        "success": true,
        "message": msg,
        "data": response.data["RESULT"][0],
      };
    } catch (e) {
      dev.log("ERROR (closeServiceRequest): $e");
      return {"success": false, "message": "Error: $e", "data": null};
    }
  }

  // ── ACCEPT TASK ───────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> acceptTask({required int taskId}) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {
          "success": false,
          "message": "User not logged in",
          "updatedTask": null,
        };
      }

      final payload = {
        "user_id": userId,
        "task_id": taskId,
        "stage":   "dev",
      };

      final response = await _dio.post(ApiConstants.acceptTask, data: payload);

      if (response.statusCode != 200) {
        return {
          "success": false,
          "message": "Server error",
          "updatedTask": null,
        };
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid response",
          "updatedTask": null,
        };
      }

      final flag = statusList[0]["status"];
      final msg  = statusList[0]["message"];

      if (flag != "S") {
        return {
          "success": false,
          "message": msg ?? "Failed",
          "updatedTask": null,
        };
      }

      return {
        "success": true,
        "message": msg,
        "updatedTask": response.data["RESULT"]?[0],
      };
    } catch (e) {
      dev.log("ERROR (acceptTask): $e");
      return {"success": false, "message": "Error: $e", "updatedTask": null};
    }
  }

  Future<Map<String, dynamic>> getTaskDetails(task) async {
    return {"success": true, "task": task};
  }

  // ── GET READY ORDERS ──────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getReadyOrdersForRoomService() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {"user_id": userId, "stage": "dev"};

      dev.log("📤 Fetching READY Orders for Room Service");
      final response =
          await _dio.post(ApiConstants.getReadyOrders, data: payload);
      dev.log("📥 Ready Orders Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid response"};
      }

      final resultList = response.data["RESULT"] as List? ?? [];
      return {"success": true, "orders": _mapReadyOrders(resultList)};
    } catch (e) {
      dev.log("❌ ERROR (getReadyOrdersForRoomService): $e");
      return {"success": false, "message": "Network error"};
    }
  }

  static List<Map<String, dynamic>> _mapReadyOrders(List raw) {
    return raw.map<Map<String, dynamic>>((o) {
      final m = Map<String, dynamic>.from(o);
      return {
        "orderRequestId": m["order_request_id"],
        "orderNumber":    m["order_number"],
        "roomNumber":     m["room_number"],
        "roomId":         m["room_id"],
        "guestName":      m["guest_name"],
        "foodItem":       m["food_item"],
        "quantity":       m["quantity"],
        "status":         "Ready",
        "orderTime":      m["ready_time"],
        "is_veg":         m["is_veg"],
        "raw":            m,
      };
    }).toList();
  }

  // ── UPDATE ROOM SERVICE STATUS ────────────────────────────────────────────
  //
  // The API response for this endpoint is DIFFERENT from other endpoints.
  // The STATUS array contains notification/user rows (not a status flag).
  // A non-empty STATUS array with a 200 response == success.
  //
  // Sample response (Accept / Deliver):
  //   {
  //     "STATUS": [
  //       { "user_id": 147, "username": "jahnavi", ...,
  //         "old_status": "Accepted", "new_status": "DELIVERED", ... }
  //     ]
  //   }
  //
  // There is NO "status": "S" field and NO "RESULT" array in this response.

  Future<Map<String, dynamic>> updateRoomServiceStatus({
    required String orderNumber,
    required String action,
  }) async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {
        "user_id":         userId,
        "order_number":    orderNumber,
        "delivery_action": action,
        "stage":           "dev",
      };

      dev.log("📤 Updating Room Service Status — $action for $orderNumber");
      final response = await _dio.post(
          ApiConstants.updateRoomServiceStatus,
          data: payload);
      dev.log("📥 Update Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final body = response.data;

      // ── Strategy 1: Standard STATUS flag ("status": "S") ─────────────
      // Some env configs may return this — handle it if present.
      final statusList = body["STATUS"] as List?;
      if (statusList != null && statusList.isNotEmpty) {
        final firstRow = statusList[0] as Map?;
        if (firstRow != null && firstRow.containsKey("status")) {
          // Standard flag-style response
          final flag = firstRow["status"];
          final msg  = firstRow["message"] ?? "Done";
          return {"success": flag == "S", "message": msg};
        }

        // ── Strategy 2: Notification-style STATUS array ───────────────
        // The STATUS rows are notification payloads (contain user_id,
        // username, new_status, etc.) — a non-empty array on HTTP 200
        // means the update succeeded.
        final hasNewStatus = firstRow != null &&
            (firstRow.containsKey("new_status") ||
             firstRow.containsKey("old_status") ||
             firstRow.containsKey("order_number"));
        if (hasNewStatus) {
          dev.log("✅ updateRoomServiceStatus succeeded (notification-style response)");
          return {"success": true, "message": "Status updated successfully"};
        }

        // ── Strategy 3: Any non-empty STATUS on HTTP 200 ─────────────
        // Fallback: if STATUS is non-empty and we got HTTP 200, treat as ok.
        dev.log("✅ updateRoomServiceStatus: non-empty STATUS on 200 → success");
        return {"success": true, "message": "Status updated"};
      }

      // ── Strategy 4: RESULT array fallback ────────────────────────────
      final resultList = body["RESULT"] as List?;
      if (resultList != null && resultList.isNotEmpty) {
        final flag    = resultList[0]["status"];
        final message = resultList[0]["message"] ?? "Done";
        return {"success": flag == "S", "message": message};
      }

      // ── Strategy 5: Empty body but HTTP 200 ──────────────────────────
      dev.log("⚠️ updateRoomServiceStatus: empty body on 200 → treating as success");
      return {"success": true, "message": "Status updated"};
    } catch (e) {
      dev.log("❌ ERROR (updateRoomServiceStatus): $e");
      return {"success": false, "message": "Network error"};
    }
  }

  // ── GET ACCEPTED ORDERS ───────────────────────────────────────────────────

  Future<Map<String, dynamic>> getAcceptedOrdersForRoomService() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {"user_id": userId, "stage": "dev"};

      dev.log("📤 Fetching ACCEPTED Orders for Room Service");
      final response =
          await _dio.post(ApiConstants.getAcceptedOrders, data: payload);
      dev.log("📥 Accepted Orders Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid response"};
      }

      final resultList = response.data["RESULT"] as List? ?? [];
      return {"success": true, "orders": _mapAcceptedOrders(resultList)};
    } catch (e) {
      dev.log("❌ ERROR (getAcceptedOrdersForRoomService): $e");
      return {"success": false, "message": "Network error"};
    }
  }

  static List<Map<String, dynamic>> _mapAcceptedOrders(List raw) {
    return raw.map<Map<String, dynamic>>((o) {
      final m = Map<String, dynamic>.from(o);
      return {
        "orderRequestId": m["order_request_id"],
        "orderNumber":    m["order_number"],
        "roomNumber":     m["room_number"],
        "roomId":         m["room_id"],
        "guestName":      m["guest_name"],
        "foodItem":       m["food_item"],
        "quantity":       m["quantity"],
        "status":         "Accepted",
        "orderTime":      m["accepted_time"],
        "is_veg":         m["is_veg"],
        "raw":            m,
      };
    }).toList();
  }

  // ── GET DELIVERED ORDERS ──────────────────────────────────────────────────

  Future<Map<String, dynamic>> getDeliveredOrdersForRoomService() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {"user_id": userId, "stage": "dev"};

      dev.log("📤 Fetching DELIVERED Orders for Room Service");
      final response =
          await _dio.post(ApiConstants.getDeliveredOrders, data: payload);
      dev.log("📥 Delivered Orders Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid response"};
      }

      final resultList = response.data["RESULT"] as List? ?? [];
      return {"success": true, "orders": _mapDeliveredOrders(resultList)};
    } catch (e) {
      dev.log("❌ ERROR (getDeliveredOrdersForRoomService): $e");
      return {"success": false, "message": "Network error"};
    }
  }

  static List<Map<String, dynamic>> _mapDeliveredOrders(List raw) {
    return raw.map<Map<String, dynamic>>((o) {
      final m = Map<String, dynamic>.from(o);
      return {
        "orderRequestId": m["order_request_id"],
        "orderNumber":    m["order_number"],
        "roomNumber":     m["room_number"],
        "roomId":         m["room_id"],
        "guestName":      m["guest_name"],
        "foodItem":       m["food_item"],
        "quantity":       m["quantity"],
        "status":         "Delivered",
        "orderTime":      m["delivered_time"],
        "is_veg":         m["is_veg"],
        "raw":            m,
      };
    }).toList();
  }
}