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
import 'task_service.dart';

class DateRange {
  final DateTime startDate;
  final DateTime endDate;
  DateRange(this.startDate, this.endDate);
}

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
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }

  // ── FETCH TASKS FOR DATE RANGE ─────────────────────────────────────────────

  Future<Map<String, dynamic>> fetchTasksForRange(DateRange range) async {
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
        "start_date":    "${range.startDate.year}-${range.startDate.month.toString().padLeft(2, '0')}-${range.startDate.day.toString().padLeft(2, '0')}",
        "end_date":      "${range.endDate.year}-${range.endDate.month.toString().padLeft(2, '0')}-${range.endDate.day.toString().padLeft(2, '0')}",
        "stage":         AppConfig.stage,
      };

      dev.log("Fetching tasks for date range: ${payload['start_date']} to ${payload['end_date']}...");
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
      dev.log("ERROR (fetchTasksForRange): $e");
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }

  // ── GENERATE EXECUTIVE REPORT ──────────────────────────────────────────────

  Future<Map<String, dynamic>> generateExecutiveReport({
    required String startDate,
    required String endDate,
    required String templateId,
  }) async {
    try {
      final int? userId       = await UserSessionHelper.getUserId();
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || enterpriseId == null) {
        return {"success": false, "message": "Session credentials missing"};
      }

      final payload = {
        "userId":       userId,
        "enterpriseId": enterpriseId,
        "templateId":   templateId,
        "startDate":    startDate,
        "endDate":      endDate,
        "stage":        AppConfig.stage,
      };

      dev.log("Requesting executive report lambda...");
      final response = await _dio.post(
        "${ApiConstants.baseUrl}/generate_executive_report",
        data: payload,
      );

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error: ${response.statusCode}"};
      }

      if (response.data["success"] == true) {
        return {"success": true, "presignedUrl": response.data["presignedUrl"]};
      } else {
        return {"success": false, "message": response.data["message"] ?? "Failed"};
      }
    } catch (e) {
      dev.log("ERROR (generateExecutiveReport): $e");
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

      // ── Escalation derivation ────────────────────────────────────────────
      // escalation_instance_id non-null → task is currently escalated.
      // is_escalated flag is also checked for legacy rows that set it directly.
      final int? escalationInstanceId =
          m["escalation_instance_id"] as int?;
      final bool isEscalated =
          (m["is_escalated"] == 1 ||
           m["is_escalated"] == true ||
           escalationInstanceId != null);

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
        "guest_phone":  m["guest_phone"] ?? m["customer_number"] ?? "",
        "guestNote":
            "Phone: ${m["guest_phone"] ?? m["customer_number"] ?? "-"}",
        "assignedTo": (m["accepted_by_user_name"] ??
                m["assigned_to_name"] ??
                m["assigned_user_name"] ??
                m["assigned_name"] ??
                m["name"] ??
                m["assigned_to"] ??
                "-")
            .toString(),
        "accepted_by_user_id": m["accepted_by_user_id"],
        "note":         m["note_text"],
        // ── Escalation fields (from get_all_services_mobile RESULT) ─────
        // These are read by EscalationBanner, SlaCountdownWidget, and the
        // urgency border system without any extra API call.
        "is_escalated":           isEscalated ? 1 : 0,
        "alert_pending":          m["alert_pending"] ?? 0,
        "escalation_instance_id": escalationInstanceId,
        "escalation_status":      m["escalation_status"],   // "Working" | null
        "current_stage_id":       m["current_stage_id"],
        "current_stage_name":     m["current_stage_name"], // e.g. "Level 2 – Supervisor"
        "current_stage_level":    m["current_stage_level"],  // numeric 1,2,3…
        "current_stage_users_json": m["current_stage_users_json"], // JSON — users being notified now
        "next_escalation_at":     m["next_escalation_at"], // ISO-8601 — drives SLA countdown
        "escalation_time_minutes": m["escalation_time_minutes"],
        // ── Acceptance fields ────────────────────────────────────────────
        "accepted_stage_level":   m["accepted_stage_level"], // level at which task was accepted
        "accepted_stage_name":    m["accepted_stage_name"],  // e.g. "Level 2 – Supervisor"
        "accepted_user_json":     m["accepted_user_json"],   // JSON user object of acceptor
        // ── Closure fields ───────────────────────────────────────────────
        "closed_by_user_id":      m["closed_by_user_id"],
        "closed_by_user_name":    m["closed_by_user_name"],
        // ── Recent escalated users ───────────────────────────────────────
        "recent_escalation_level":  m["recent_escalation_level"],
        "recent_escalated_users_json": m["recent_escalated_users_json"],
        // ── Reassignment fields ──────────────────────────────────────────
        "recent_reassigned_to_user_id":   m["recent_reassigned_to_user_id"],
        "recent_reassigned_to_user_name": m["recent_reassigned_to_user_name"],
        "recent_reassigned_by_user_id":   m["recent_reassigned_by_user_id"],
        "recent_reassigned_by_user_name": m["recent_reassigned_by_user_name"],
        "recent_reassigned_at":           m["recent_reassigned_at"],
        // ── Timestamps ──────────────────────────────────────────────────
        "accepted_at":   m["accepted_at"],
        "created_at":    m["created_at"],
        "timestamp":     m["timestamp"],
        // ── Identifiers ─────────────────────────────────────────────────
        "department_id": m["department_id"],
        "enterprise_id": m["enterprise_id"],
        // Full raw row — any field not listed above is accessible via raw[key]
        "raw":           m,
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

  // ── GET ESCALATION HISTORY FOR TASK ─────────────────────────────────────────

  Future<Map<String, dynamic>> getEscalationHistoryForTask(
      int serviceRequestId) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {
          "success": false,
          "message": "User not logged in",
          "history": []
        };
      }

      final payload = {
        "user_id":            userId,
        "service_request_id": serviceRequestId,
        "stage":              AppConfig.stage,
      };

      dev.log("📤 Fetching escalation history for sr=$serviceRequestId...");
      final response = await _dio.post(
        ApiConstants.escalationHistoryForTask,
        data: payload,
      );

      if (response.statusCode != 200) {
        return {
          "success": false,
          "message": "Server error: ${response.statusCode}",
          "history": [],
        };
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid server response",
          "history": [],
        };
      }

      final statusFlag    = statusList[0]["status"] ?? "F";
      final statusMessage = statusList[0]["message"] ?? "Unknown";

      if (statusFlag != "S") {
        return {"success": false, "message": statusMessage, "history": []};
      }

      final resultList = response.data["RESULT"] as List? ?? [];
      return {
        "success": true,
        "message": statusMessage,
        "history": resultList.cast<Map<String, dynamic>>(),
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

  // ── GET STAFF LIST ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getStaffList({required int requestId}) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {"success": false, "message": "User not logged in", "staff": []};
      }

      final payload = {
        "user_id":    userId,
        "request_id": requestId,
        "stage":      AppConfig.stage,
      };

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
          await _dio.post(ApiConstants.reassignService, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final rawStatus = response.data["STATUS"];
      final statusList = rawStatus is List
          ? rawStatus
          : rawStatus is Map
              ? [rawStatus]
              : const <dynamic>[];
      final rawResult = response.data["RESULT"];
      final resultList = rawResult is List
          ? rawResult
          : rawResult is Map
              ? [rawResult]
              : const <dynamic>[];
      final status = statusList.isNotEmpty && statusList.first is Map
          ? statusList.first as Map
          : resultList.isNotEmpty && resultList.first is Map
              ? resultList.first as Map
              : const <dynamic, dynamic>{};
      if (status.isEmpty) {
        return {"success": false, "message": "Invalid response"};
      }

      final flag = status["status"]?.toString().toUpperCase();
      final msg = status["message"];
      if (flag != "S") return {"success": false, "message": msg ?? "Failed"};

      final updatedTask = resultList.isNotEmpty && resultList.first is Map
          ? Map<String, dynamic>.from(resultList.first as Map)
          : <String, dynamic>{};
      return {"success": true, "message": msg, "updatedTask": updatedTask};
    } catch (e) {
      dev.log("ERROR (reassignTicket): $e");
      // FIX-11/12 (Bugs 11-12): was "Error: $e"
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }




  // ── ADD NOTE (routes to new endpoint: ScreenSync_add_service_note_mobile) ──

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

      // Uses new endpoint: ScreenSync_add_service_note_mobile
      final response = await _dio.post(ApiConstants.addServiceNote, data: payload);

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

      final resultList = response.data["RESULT"] as List?;
      return {
        "success": true,
        "message": msg,
        "note": resultList?.isNotEmpty == true ? resultList![0] : null,
      };
    } catch (e) {
      dev.log("ERROR (addNote): $e");
      return {
        "success": false,
        "message": ErrorHandler.friendlyMessage(e),
        "note": null,
      };
    }
  }

  // ── CLOSE SERVICE REQUEST (routes to new endpoint: ScreenSync_close_service_mobile) ──

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

      // Uses new endpoint: ScreenSync_close_service_mobile
      // department_id and enterprise_id are forwarded so the SP can
      // broadcast TASK_CLOSED via WebSocket to all department devices.
      final payload = {
        "user_id":            userId,
        "service_request_id": serviceRequestId,
        "department_id":      departmentId,
        "enterprise_id":      enterpriseId,
        "stage":              AppConfig.stage,
      };

      final response =
          await _dio.post(ApiConstants.closeService, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error", "data": null};
      }

      final statusList = (response.data["STATUS"] ?? response.data["RESULT"]) as List?;
      if (statusList == null || statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid response",
          "data": null,
        };
      }

      final flag = statusList[0]["status"]?.toString();
      final msg  = statusList[0]["message"]?.toString();

      if (flag != "S" && flag != "200") {
        return {"success": false, "message": msg ?? "Failed", "data": null};
      }


      final resultList = response.data["RESULT"] as List?;
      return {
        "success": true,
        "message": msg,
        "data": resultList?.isNotEmpty == true ? resultList![0] : null,
      };
    } catch (e) {
      dev.log("ERROR (closeServiceRequest): $e");
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
    int? orderId,
  }) async {
    try {
      final res = await TaskService().updateServiceRequestStatus(
        serviceRequestId: taskId,
        status:           'IN_PROGRESS',
      );

      return {
        "success":     res['success'] == true,
        "message":     res['message'] ?? 'Task accepted',
        "updatedTask": res['status_data'],
      };
    } catch (e) {
      dev.log("ERROR (acceptTask): $e");
      return {
        "success":     false,
        "message":     ErrorHandler.friendlyMessage(e),
        "updatedTask": null,
      };
    }
  }


  Future<Map<String, dynamic>> getTaskDetails(task) async {
    return {"success": true, "task": task};
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

      final rawTeam = response.data["RESULT"];
      final rawDrillDown = response.data["RESULT2"];
      final teamList = (rawTeam is List
              ? rawTeam
              : rawTeam is Map
                  ? [rawTeam]
                  : const <dynamic>[])
          .whereType<Map>()
          .map(_normaliseTeamPerformanceRow)
          .toList();
      final drillDownList = rawDrillDown is List
          ? rawDrillDown
          : rawDrillDown is Map
              ? [rawDrillDown]
              : const <dynamic>[];

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

  /// API Gateway can deserialize database numeric columns as either numbers or
  /// strings. Convert them once here so the activity/team UI always renders
  /// the actual server values rather than falling back to zeroes.
  static Map<String, dynamic> _normaliseTeamPerformanceRow(Map row) {
    int asInt(dynamic value) => value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? 0;
    double asDouble(dynamic value) => value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '') ?? 0.0;

    return {
      ...Map<String, dynamic>.from(row),
      'user_id': asInt(row['user_id'] ?? row['staff_id']),
      'full_name': row['full_name'] ??
          row['name'] ??
          row['username'] ??
          row['staff_name'] ??
          '—',
      'department_name': row['department_name'] ??
          row['department'] ??
          row['dept_name'] ??
          '',
      'role_name': row['role_name'] ?? row['role'] ?? '',
      'department_id': asInt(row['department_id']),
      'total_assigned': asInt(row['total_assigned']),
      'total_closed': asInt(row['total_closed']),
      'total_escalated': asInt(row['total_escalated']),
      'avg_resolution_minutes': asDouble(row['avg_resolution_minutes']),
      'escalation_rate_pct': asDouble(row['escalation_rate_pct']),
    };
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
