// services/home_service.dart
import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../utils/user_session_helper.dart';
import '../utils/date_formatter.dart';
import '../utils/error_handler.dart';
import '../constants/api_constants.dart';
import '../constants/api_timeouts.dart';
import '../constants/app_config.dart';

class HomeService {
  final Dio _dio;

  HomeService()
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
        "stage":         AppConfig.stage,
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
      // FIX-10/11/12 (Bugs 10-12): friendly message instead of raw "Network error"
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }

  /// Returns [value] if it is a non-null, non-empty string; otherwise null.
  /// Used so `??` fallbacks work correctly when the API returns "" instead of null.
  static String? _nonEmpty(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }

  static List<Map<String, dynamic>> _mapTasks(List raw) {
    return raw.map<Map<String, dynamic>>((t) {
      final m = Map<String, dynamic>.from(t);
      return {
        "service_request_id": m["service_request_id"],
        // room_number is the human-facing string (e.g. "101") from the SP.
        // room_id is the integer FK — never show to the user.
        // Priority: room_number > requested_room > room_id fallback.
        "room": (m["room_number"] ?? m["requested_room"] ?? m["room_id"] ?? "-").toString(),
        "status":      _statusText(m["status"], m["closed"]),
        "statusColor": _statusColor(m["status"]),
        "title":       m["question"] ?? "Service Request",
        "subtitle":    m["answer"]   ?? "Awaiting response",
        "description": m["answer"]   ?? "",
        "time":        _formatTime(m["timestamp"] ?? m["created_at"]),
        "guest":       _nonEmpty(m["guest_name"]) ?? "Unknown Guest",
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
        "alert_pending": m["alert_pending"] ?? 0,
        "escalation_time_minutes": m["escalation_time_minutes"],
        "accepted_at":  m["accepted_at"],
        "created_at":   m["created_at"],
        "timestamp":    m["timestamp"],
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
    return DateFormatter.formatDateTimeAmPm(timestamp);
  }

  Future<void> triggerEscalationCheck() async {
    try {
      final userId       = await UserSessionHelper.getUserId();
      final enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || enterpriseId == null) return;

      final payload = {
        "user_id":       userId,
        "enterprise_id": enterpriseId,
        "stage":         AppConfig.stage,
      };

      dev.log("📤 Triggering escalation check...");
      final response = await _dio.post(
        ApiConstants.checkAndEscalate,
        data: payload,
      );

      dev.log("📥 Escalation check response: ${response.data}");
    } catch (e) {
      dev.log("triggerEscalationCheck error (non-fatal): $e");
    }
  }

  // ── GET STAFF LIST ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getStaffList() async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {"success": false, "message": "User not logged in", "staff": []};
      }

      final payload = {"user_id": userId, "stage": AppConfig.stage};

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
      // FIX-11/12 (Bugs 11-12): was "Error: $e" — raw exception shown to user
      return {
        "success": false,
        "message": ErrorHandler.friendlyMessage(e),
        "staff": [],
      };
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
        "stage":       AppConfig.stage,
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
      // FIX-11/12 (Bugs 11-12): was "Error: $e"
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }

  Future<void> notifyReassign({
    required int    taskId,
    required int    assignedTo,
    required int    enterpriseId,
    required int    departmentId,
    required String taskName,
    required String roomId,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) return;

      final payload = {
        "user_id":       userId,
        "task_id":       taskId,
        "assigned_to":   assignedTo,
        "enterprise_id": enterpriseId,
        "department_id": departmentId,
        "task_name":     taskName,
        "room_id":       roomId,
        "stage":         AppConfig.stage,
      };

      dev.log("📤 Notifying reassign — task:$taskId → user:$assignedTo");
      final response = await _dio.post(
        ApiConstants.notifyReassign,
        data: payload,
      );
      dev.log("📥 notifyReassign response: ${response.data}");
    } catch (e) {
      dev.log("notifyReassign error (non-fatal): $e");
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
        "stage":              AppConfig.stage,
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
      // FIX-11 (Bug 11): was "Error: $e" — this is the exact bug you saw:
      // raw DioException text shown in the add-note SnackBar when offline.
      return {
        "success": false,
        "message": ErrorHandler.friendlyMessage(e),
        "note": null,
      };
    }
  }

  // ── CLOSE SERVICE REQUEST ─────────────────────────────────────────────────

  Future<Map<String, dynamic>> closeServiceRequest({
    required int serviceRequestId,
    required int departmentId,
    required int enterpriseId,
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
        "department_id":      departmentId,
        "enterprise_id":      enterpriseId,
        "stage":              AppConfig.stage,
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
        "data": response.data["RESULT"]?[0],
      };
    } catch (e) {
      dev.log("ERROR (closeServiceRequest): $e");
      // FIX-11/12 (Bugs 11-12): was "Error: $e"
      return {
        "success": false,
        "message": ErrorHandler.friendlyMessage(e),
        "data": null,
      };
    }
  }

  // ── ACCEPT TASK ───────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> acceptTask({
    required int taskId,
    required int departmentId,
    required int enterpriseId,
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
        "department_id": departmentId,
        "enterprise_id": enterpriseId,
        "stage":         AppConfig.stage,
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

      final flag = statusList[0]["status"]?.toString().trim().toUpperCase();
      final msg  = statusList[0]["message"]?.toString();

      if (flag != "S" && flag != "SUCCESS" && flag != "1" && flag != "200" && flag != "TRUE") {
        return {
          "success": false,
          "message": (msg != null && msg.isNotEmpty) ? msg : "Failed to accept task",
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
      // FIX-11/12 (Bugs 11-12): was "Error: $e"
      return {
        "success": false,
        "message": ErrorHandler.friendlyMessage(e),
        "updatedTask": null,
      };
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

      final payload = {"user_id": userId, "stage": AppConfig.stage};

      dev.log("📤 Fetching escalation badge count...");
      final response = await _dio.post(
        ApiConstants.escalationBadgeCount,
        data: payload,
      );

      if (response.statusCode != 200) return 0;

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null ||
          statusList.isEmpty ||
          statusList[0]["status"] != "S") {
        return 0;
      }

      final resultList = response.data["RESULT"] as List?;
      if (resultList == null || resultList.isEmpty) return 0;

      return (resultList[0]["badge_count"] ?? 0) as int;
    } catch (e) {
      dev.log("ERROR (getEscalationBadgeCount): $e");
      return 0;
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
        "stage": AppConfig.stage,
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
      // FIX-10/11/12 (Bugs 10-12): friendly message instead of raw "Network error"
      return {
        "success": false,
        "message": ErrorHandler.friendlyMessage(e),
        "tasks": [],
      };
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
        "alert_pending":         m["alert_pending"] ?? 0,
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

  // ── GET ESCALATION HISTORY FOR TASK ──────────────────────────────────────

  Future<Map<String, dynamic>> getEscalationHistoryForTask({
    required int serviceRequestId,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {
          "success": false,
          "message": "User not logged in",
          "history": [],
        };
      }

      final payload = {
        "user_id":            userId,
        "service_request_id": serviceRequestId,
        "stage":              AppConfig.stage,
      };

      dev.log("📤 Fetching escalation history — sr:$serviceRequestId");
      final response = await _dio.post(
        ApiConstants.escalationHistoryForTask,
        data: payload,
      );

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error", "history": []};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid response",
          "history": [],
        };
      }

      final flag = statusList[0]["status"];
      final msg  = statusList[0]["message"];

      if (flag != "S") {
        return {
          "success": false,
          "message": msg ?? "Failed",
          "history": [],
        };
      }

      final resultList = response.data["RESULT"] as List? ?? [];
      dev.log("📥 Escalation history rows: ${resultList.length}");

      return {
        "success": true,
        "message": msg,
        "history": resultList
            .map((r) => Map<String, dynamic>.from(r))
            .toList(),
      };
    } catch (e) {
      dev.log("ERROR (getEscalationHistoryForTask): $e");
      return {
        "success": false,
        "message": ErrorHandler.friendlyMessage(e),
        "history": [],
      };
    }
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
        "stage": AppConfig.stage,
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
      // FIX-10 (Bug 10): This is the exact call behind the Activity screen
      // silently showing stale/wrong-month data — was returning generic
      // "Network error" with no UI ever surfacing it. tasks_page.dart's
      // failure branch must now render this message (see tasks_page.dart
      // patch) instead of only clearing the loading flag.
      return {
        "success": false,
        "message": ErrorHandler.friendlyMessage(e),
        "team": [],
      };
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
        "stage":     AppConfig.stage,
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
        "summary":   response.data["RESULT"]  as List? ?? [],
        "byDept":    response.data["RESULT2"] as List? ?? [],
        "tasks":     response.data["RESULT3"] as List? ?? [],
      };
    } catch (e) {
      dev.log("ERROR (getEscalationReport): $e");
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }

  // ── GET READY ORDERS ──────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getReadyOrdersForRoomService() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {"user_id": userId, "stage": AppConfig.stage};

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
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
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
        "stage":           AppConfig.stage,
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
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }

  // ── GET ACCEPTED ORDERS ───────────────────────────────────────────────────

  Future<Map<String, dynamic>> getAcceptedOrdersForRoomService() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {"user_id": userId, "stage": AppConfig.stage};

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
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
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

      final payload = {"user_id": userId, "stage": AppConfig.stage};

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
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
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