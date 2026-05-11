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
        "note":         m["note_text"],
        "is_escalated": m["is_escalated"] ?? 0,
        "escalation_time_minutes": m["escalation_time_minutes"],
        "accepted_at":  m["accepted_at"],
        "department_id": m["department_id"],
        "enterprise_id": m["enterprise_id"],
        "raw":          m,
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
        "user_id":     userId,
        "task_id":     ticketId,
        "reassign_to": assignedUserId,
        "stage":       "dev",
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

  Future<Map<String, dynamic>> acceptTask({
    required int taskId,
    required int departmentId,   // needed by Lambda for WS broadcast
    required int enterpriseId,   // needed by Lambda for WS broadcast
  }) async {
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
        "user_id":       userId,
        "task_id":       taskId,
        "department_id": departmentId,  // ← NEW: Lambda uses for WS broadcast
        "enterprise_id": enterpriseId,  // ← NEW: Lambda uses for WS broadcast
        "stage":         "dev",
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

  // ── GET ESCALATION BADGE COUNT ────────────────────────────────────────────

  Future<int> getEscalationBadgeCount() async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) return 0;

      final payload = {"user_id": userId, "stage": "dev"};

      dev.log("📤 Fetching escalation badge count...");
      final response = await _dio.post(
        ApiConstants.escalationBadgeCount,
        data: payload,
      );

      if (response.statusCode != 200) return 0;

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null ||
          statusList.isEmpty ||
          statusList[0]["status"] != "S") return 0;

      final resultList = response.data["RESULT"] as List?;
      if (resultList == null || resultList.isEmpty) return 0;

      return (resultList[0]["badge_count"] ?? 0) as int;
    } catch (e) {
      dev.log("ERROR (getEscalationBadgeCount): $e");
      return 0; // non-fatal — badge just shows 0
    }
  }

  // ── GET ESCALATED TASKS ───────────────────────────────────────────────────

  Future<Map<String, dynamic>> getEscalatedTasks({int? departmentId}) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {"success": false, "message": "User not logged in", "tasks": []};
      }

      final payload = {
        "user_id": userId,
        if (departmentId != null) "department_id": departmentId,
        "stage": "dev",
      };

      dev.log("📤 Fetching escalated tasks...");
      final response = await _dio.post(
        ApiConstants.escalatedTasks,
        data: payload,
      );

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error", "tasks": []};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid response", "tasks": []};
      }

      final flag = statusList[0]["status"];
      final msg  = statusList[0]["message"];

      if (flag != "S") {
        return {"success": false, "message": msg ?? "Failed", "tasks": []};
      }

      final resultList = response.data["RESULT"] as List? ?? [];
      return {
        "success": true,
        "message": msg,
        "tasks": _mapEscalatedTasks(resultList),
      };
    } catch (e) {
      dev.log("ERROR (getEscalatedTasks): $e");
      return {"success": false, "message": "Network error", "tasks": []};
    }
  }

  static List<Map<String, dynamic>> _mapEscalatedTasks(List raw) {
    return raw.map<Map<String, dynamic>>((t) {
      final m = Map<String, dynamic>.from(t);
      return {
        "service_request_id":    m["service_request_id"],
        "room":                  (m["room_number"] ?? "-").toString(),
        "room_id":               m["room_id"],
        "guest":                 m["guest_name"] ?? "Unknown Guest",
        "guest_phone":           m["guest_phone"] ?? "-",
        "department_id":         m["department_id"],
        "department_name":       m["department_name"] ?? "-",
        "enterprise_id":         m["enterprise_id"],
        "title":                 m["name"] ?? m["question"] ?? "Service Request",
        "question":              m["question"] ?? "",
        "status":                m["status"] ?? "Open",
        "closed":                m["closed"] ?? 0,
        "is_escalated":          m["is_escalated"] ?? 1,
        "escalation_id":         m["escalation_id"],
        "escalation_level":      m["escalation_level"],
        "escalated_at":          m["escalated_at"],
        "original_assignee":     m["original_assignee_name"] ?? "-",
        "escalated_to":          m["escalated_to_name"] ?? "-",
        "overdue_minutes":       m["overdue_minutes"] ?? 0,
        "escalation_deadline":   m["escalation_deadline"],
        "assigned_to":           m["assigned_to"],
        "assigned_to_name":      m["assigned_to_name"] ?? "-",
        "assigned_to_phone":     m["assigned_to_phone"] ?? "-",
        "assigned_by":           m["assigned_by"],
        "assigned_by_name":      m["assigned_by_name"] ?? "-",
        "escalation_time_minutes": m["escalation_time_minutes"],
        "accepted_at":           m["accepted_at"],
        "created_at":            m["created_at"],
        "updated_at":            m["updated_at"],
        "note":                  m["note_text"],
        "task_flag":             "Escalated",
        "raw":                   m,
      };
    }).toList();
  }

  // ── GET TEAM PERFORMANCE ──────────────────────────────────────────────────

  Future<Map<String, dynamic>> getTeamPerformance({
    int? departmentId,
    int? targetUserId,
    required int month,
    required int year,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {"success": false, "message": "User not logged in", "team": []};
      }

      final payload = {
        "user_id": userId,
        if (departmentId != null) "department_id": departmentId,
        if (targetUserId  != null) "target_user_id": targetUserId,
        "month": month,
        "year":  year,
        "stage": "dev",
      };

      dev.log("📤 Fetching team performance — $month/$year");
      final response = await _dio.post(
        ApiConstants.teamPerformance,
        data: payload,
      );

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error", "team": []};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid response", "team": []};
      }

      final flag = statusList[0]["status"];
      final msg  = statusList[0]["message"];

      if (flag != "S") {
        return {"success": false, "message": msg ?? "Failed", "team": []};
      }

      // RS1 = team list, RS2 = individual drill-down (if target_user_id sent)
      final teamList       = response.data["RESULT"]  as List? ?? [];
      final drillDownList  = response.data["RESULT2"] as List? ?? [];

      return {
        "success":    true,
        "message":    msg,
        "team":       teamList,
        "drillDown":  drillDownList,
      };
    } catch (e) {
      dev.log("ERROR (getTeamPerformance): $e");
      return {"success": false, "message": "Network error", "team": []};
    }
  }

  // ── GET ESCALATION REPORT ─────────────────────────────────────────────────

  Future<Map<String, dynamic>> getEscalationReport({
    int? departmentId,
    required DateTime fromDate,
    required DateTime toDate,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {"success": false, "message": "User not logged in"};
      }

      final payload = {
        "user_id":   userId,
        if (departmentId != null) "department_id": departmentId,
        "from_date": "${fromDate.year}-${fromDate.month.toString().padLeft(2,'0')}-${fromDate.day.toString().padLeft(2,'0')}",
        "to_date":   "${toDate.year}-${toDate.month.toString().padLeft(2,'0')}-${toDate.day.toString().padLeft(2,'0')}",
        "stage":     "dev",
      };

      dev.log("📤 Fetching escalation report...");
      final response = await _dio.post(
        ApiConstants.escalationReport,
        data: payload,
      );

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid response"};
      }

      final flag = statusList[0]["status"];
      final msg  = statusList[0]["message"];

      if (flag != "S") {
        return {"success": false, "message": msg ?? "Failed"};
      }

      return {
        "success":   true,
        "message":   msg,
        // RS1: summary totals
        "summary":   response.data["RESULT"]  as List? ?? [],
        // RS2: per-department breakdown
        "byDept":    response.data["RESULT2"] as List? ?? [],
        // RS3: per-task detail rows
        "tasks":     response.data["RESULT3"] as List? ?? [],
      };
    } catch (e) {
      dev.log("ERROR (getEscalationReport): $e");
      return {"success": false, "message": "Network error"};
    }
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

      final statusList = body["STATUS"] as List?;
      if (statusList != null && statusList.isNotEmpty) {
        final firstRow = statusList[0] as Map?;
        if (firstRow != null && firstRow.containsKey("status")) {
          final flag = firstRow["status"];
          final msg  = firstRow["message"] ?? "Done";
          return {"success": flag == "S", "message": msg};
        }

        final hasNewStatus = firstRow != null &&
            (firstRow.containsKey("new_status") ||
             firstRow.containsKey("old_status") ||
             firstRow.containsKey("order_number"));
        if (hasNewStatus) {
          dev.log("✅ updateRoomServiceStatus succeeded (notification-style response)");
          return {"success": true, "message": "Status updated successfully"};
        }

        dev.log("✅ updateRoomServiceStatus: non-empty STATUS on 200 → success");
        return {"success": true, "message": "Status updated"};
      }

      final resultList = body["RESULT"] as List?;
      if (resultList != null && resultList.isNotEmpty) {
        final flag    = resultList[0]["status"];
        final message = resultList[0]["message"] ?? "Done";
        return {"success": flag == "S", "message": message};
      }

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