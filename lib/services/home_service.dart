// services/home_service.dart
import 'dart:convert';
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


  // ──────── GET TASKS ──────────────────────────────────────────────────────────────

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
      final response = await _dio.post(ApiConstants.getAllServices, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final rawData = response.data;
      if (rawData == null) {
        return {"success": false, "message": "Empty response"};
      }

      // ScreenSync_get_all_services_mobile1 returns STATUS[] as the task rows
      // (no separate sentinel object — STATUS IS the data).
      // Fallback: if RESULT key exists and STATUS is a sentinel, use RESULT.
      final dynamic statusRaw  = rawData["STATUS"];
      final dynamic resultRaw  = rawData["RESULT"];

      List taskList;
      if (resultRaw != null && resultRaw is List) {
        // Standard sentinel format: STATUS[0].status == "S", RESULT[] = data
        final status = statusRaw as List?;
        if (status != null && status.isNotEmpty &&
            status[0] is Map && status[0]["status"] == "S") {
          taskList = resultRaw;
        } else {
          final msg = (status != null && status.isNotEmpty && status[0] is Map)
              ? (status[0]["message"] ?? "Failed")
              : "Failed";
          return {"success": false, "message": msg};
        }
      } else if (statusRaw != null && statusRaw is List && statusRaw.isNotEmpty) {
        // Data-in-STATUS format: STATUS[] contains service request rows directly
        taskList = statusRaw;
      } else {
        return {"success": false, "message": "No tasks returned"};
      }

      return {"success": true, "tasks": _mapTasks(taskList)};
    } catch (e) {
      dev.log("ERROR (getTasks): $e");
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }

  // ──────── USER DEPT DETAILS (ESCALATION RULES) ─────────────────────────────────

  /// Fetches user department mapping and escalation rules.
  /// Endpoint: ScreenSync_get_user_dept_details_mobile
  /// Returns: { success, departments: [ { department_id, department_name, department_type,
  ///           user_id, user_name, escalation_rule_id, supervisor_user_id,
  ///           supervisor_user_name, supervisor_dept_id, supervisor_department_name,
  ///           completion_minutes, json_data } ] }
  Future<Map<String, dynamic>> getUserDeptDetails() async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {'success': false, 'message': 'User not logged in'};
      }

      final response = await _dio.post(
        ApiConstants.userDeptDetails,
        data: {'user_id': userId, 'stage': AppConfig.stage},
      );

      if (response.statusCode != 200) {
        return {'success': false, 'message': 'Server error'};
      }

      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
      final statusList = data['STATUS'] as List? ?? [];
      if (statusList.isEmpty) {
        return {'success': false, 'message': 'Invalid response'};
      }

      final statusMap = statusList[0] as Map? ?? {};
      if (statusMap['status'] != 'S') {
        return {'success': false, 'message': statusMap['message'] ?? 'Failed to fetch department details'};
      }

      final resultList = data['RESULT'] as List? ?? [];
      return {
        'success': true,
        'message': statusMap['message'] ?? 'Success',
        'departments': resultList.map((row) => Map<String, dynamic>.from(row)).toList(),
      };
    } catch (e) {
      dev.log('ERROR (getUserDeptDetails): $e');
      return {'success': false, 'message': ErrorHandler.friendlyMessage(e)};
    }
  }

  // ──────── FETCH TASKS FOR DATE RANGE ──────────────────────────────────────────────

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
      final response = await _dio.post(ApiConstants.getAllServices, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final rawData = response.data;
      if (rawData == null) {
        return {"success": false, "message": "Empty response"};
      }

      final dynamic statusRaw  = rawData["STATUS"];
      final dynamic resultRaw  = rawData["RESULT"];

      List taskList;
      if (resultRaw != null && resultRaw is List) {
        final status = statusRaw as List?;
        if (status != null && status.isNotEmpty &&
            status[0] is Map && status[0]["status"] == "S") {
          taskList = resultRaw;
        } else {
          final msg = (status != null && status.isNotEmpty && status[0] is Map)
              ? (status[0]["message"] ?? "Failed")
              : "Failed";
          return {"success": false, "message": msg};
        }
      } else if (statusRaw != null && statusRaw is List && statusRaw.isNotEmpty) {
        taskList = statusRaw;
      } else {
        return {"success": false, "message": "No tasks returned"};
      }

      return {"success": true, "tasks": _mapTasks(taskList)};
    } catch (e) {
      dev.log("ERROR (fetchTasksForRange): $e");
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }

  // ──────── GENERATE EXECUTIVE REPORT ──────────────────────────────────────────────

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

  /// Returns the assigned/accepted user's name if available; otherwise "Unassigned".
  /// Ignores integer IDs (e.g. "12") so raw user IDs are never displayed to users.
  static String _resolveAssigneeName(Map<String, dynamic> m) {
    final candidates = [
      m["accepted_by_user_name"],
      m["assigned_to_name"],
      m["assigned_user_name"],
      m["assigned_name"],
      m["recent_reassigned_to_user_name"],
    ];
    for (final c in candidates) {
      if (c != null) {
        final s = c.toString().trim();
        if (s.isNotEmpty && s != 'null' && s != '-' && int.tryParse(s) == null) {
          return s;
        }
      }
    }
    return "Unassigned";
  }

  /// Returns [value] if it is a non-null, non-empty string; otherwise null.
  /// Used so `??` fallbacks work correctly when the API returns "" instead of null.
  static String? _nonEmpty(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }

  static String? _latestNoteText(dynamic notes) {
    final list = _decodeNotesList(notes);
    if (list.isEmpty) return null;
    for (final note in list.reversed) {
      if (note is Map) {
        final text = _nonEmpty(note['note_text']);
        if (text != null) return text;
      }
    }
    return null;
  }

  /// Decodes `notes` into a List regardless of whether it arrives as an
  /// already-decoded List or as a raw JSON string from JSON_ARRAYAGG.
  static List _decodeNotesList(dynamic notes) {
    if (notes == null) return const [];
    if (notes is List) return notes;
    if (notes is String && notes.isNotEmpty && notes != 'null') {
      try {
        final decoded = jsonDecode(notes);
        if (decoded is List) return decoded;
      } catch (_) {}
    }
    return const [];
  }

  static List<Map<String, dynamic>> _mapTasks(List raw) {
    return raw.map<Map<String, dynamic>>((t) {
      final m = Map<String, dynamic>.from(t);

      // ──────── Escalation derivation ─────────────────────────────────────────────
      // escalation_instance_id non-null ⇒ task is currently escalated.
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
        "assignedTo": _resolveAssigneeName(m),
        "accepted_by_user_id": m["accepted_by_user_id"],
        "note":         m["note_text"] ?? _latestNoteText(m["notes"]),
        "notes":        _decodeNotesList(m["notes"]),
        // ──── Escalation fields (from get_all_services_mobile RESULT) ────────────
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
        // ──── Acceptance fields ──────────────────────────────────────────────────
        "accepted_stage_level":   m["accepted_stage_level"], // level at which task was accepted
        "accepted_stage_name":    m["accepted_stage_name"],  // e.g. "Level 2 – Supervisor"
        "accepted_user_json":     m["accepted_user_json"],   // JSON user object of acceptor
        // ──── Closure fields ─────────────────────────────────────────────────────
        "closed_by_user_id":      m["closed_by_user_id"],
        "closed_by_user_name":    m["closed_by_user_name"],
        // ──── Recent escalated users ────────────────────────────────────────────
        "recent_escalation_level":  m["recent_escalation_level"],
        "recent_escalated_users_json": m["recent_escalated_users_json"],
        // ──── Reassignment fields ──────────────────────────────────────────────
        "recent_reassigned_to_user_id":   m["recent_reassigned_to_user_id"],
        "recent_reassigned_to_user_name": m["recent_reassigned_to_user_name"],
        "recent_reassigned_by_user_id":   m["recent_reassigned_by_user_id"],
        "recent_reassigned_by_user_name": m["recent_reassigned_by_user_name"],
        "recent_reassigned_at":           m["recent_reassigned_at"],
        // ──── Timestamps ────────────────────────────────────────────────────────
        "accepted_at":   m["accepted_at"],
        "created_at":    m["created_at"],
        "timestamp":     m["timestamp"],
        // ──── Identifiers ──────────────────────────────────────────────────────
        "department_id": m["department_id"],
        "enterprise_id": m["enterprise_id"],
        // Catalog / service-order fields (parsed here so home card and
        // ticket detail both read task['order_items'] directly).
        "is_from_order": m["is_from_order"] ?? 0,
        "order_number":  m["order_number"],
        "grand_total":   m["grand_total"],
        "order_items":   _parseOrderItems(m["order_items_json"]),
        "raw":           m,
      };
    }).toList();
  }

  /// Parses order_items_json (MySQL JSON_ARRAYAGG string or already-decoded
  /// List from Dio) into a typed list. Returns [] silently on any failure.
  static List<Map<String, dynamic>> _parseOrderItems(dynamic raw) {
    if (raw == null) return const [];
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is List) {
        return decoded.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (_) {}
    return const [];
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

  // ──────── GET STAFF LIST ──────────────────────────────────────────────────────────────

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

      dev.log("Fetching staff list...");
      final response = await _dio.post(ApiConstants.staffList, data: payload);

      if (response.statusCode != 200) {
        return {
          "success": false,
          "message": "Server error: ${response.statusCode}",
          "staff": [],
        };
      }

        final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
        final rawStatus = data["STATUS"];
        final statusList = rawStatus is List
          ? rawStatus
          : rawStatus is Map
            ? [rawStatus]
            : const <dynamic>[];
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
        dev.log("Staff item keys: ${resultList.first.keys.toList()}");
        dev.log("Staff item sample: ${resultList.first}");
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
      return {
        "success": false,
        "message": ErrorHandler.friendlyMessage(e),
        "staff": [],
      };
    }
  }

  // ──────── REASSIGN TICKET ──────────────────────────────────────────────────────────────

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
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }

  // ──────── ACCEPT SERVICE REQUEST ──────────────────────────────────────────────────────

  Future<Map<String, dynamic>> acceptTask({
    required int taskId,
    int? departmentId,
    int? enterpriseId,
    int? orderId,
  }) async {
    return await TaskService().acceptServiceRequest(
      serviceRequestId: taskId,
      enterpriseId:     enterpriseId,
    );
  }




  // ──────── ADD NOTE (routes to new endpoint: ScreenSync_add_service_note_mobile) ──────

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

      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
      final rawStatus = data["STATUS"];
      final statusList = rawStatus is List
          ? rawStatus
          : rawStatus is Map
              ? [rawStatus]
              : const <dynamic>[];
      if (statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid response",
          "note": null,
        };
      }

      final flag = statusList[0]["status"]?.toString().toUpperCase();
      final msg  = statusList[0]["message"];

      if (flag != "S") {
        return {"success": false, "message": msg ?? "Failed", "note": null};
      }

      final rawResult = data["RESULT"] ?? data["RESULT2"] ?? data["RESULT_2"];
      final resultList = rawResult is List
          ? rawResult
          : rawResult is Map
              ? [rawResult]
              : const <dynamic>[];
      return {
        "success": true,
        "message": msg,
        "note": resultList.isNotEmpty ? resultList[0] : null,
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

  // ──────── CLOSE SERVICE REQUEST (routes to new endpoint: ScreenSync_close_service_mobile1) ──────

  /// Compatibility entry point. The close_service_mobile1 contract is owned by
  /// TaskService and derives enterprise/department from the service request.
  Future<Map<String, dynamic>> closeServiceRequest({
    required int serviceRequestId,
  }) => TaskService().closeService(serviceRequestId: serviceRequestId);
  Future<Map<String, dynamic>> getTaskDetails(task) async {
    return {"success": true, "task": task};
  }



  // ──────── GET TEAM PERFORMANCE ──────────────────────────────────────────────────────────────

  /// Role-aware, rolling six-month operations report used by the Tasks page.
  Future<Map<String, dynamic>> getServiceOperationsReport() async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {'success': false, 'message': 'User not logged in'};
      }

      final response = await _dio.post(
        ApiConstants.serviceOperationsReport,
        data: {'user_id': userId, 'stage': AppConfig.stage},
      );
      if (response.statusCode != 200 || response.data is! Map) {
        return {'success': false, 'message': 'Server error'};
      }

      final data = Map<String, dynamic>.from(response.data as Map);
      final statuses = data['STATUS'] as List? ?? const [];
      final status = statuses.isNotEmpty && statuses.first is Map
          ? Map<String, dynamic>.from(statuses.first as Map)
          : const <String, dynamic>{};
      if (status['status'] != 'S') {
        return {
          'success': false,
          'message': status['message'] ?? 'Failed to load operations report',
        };
      }

      Map<String, dynamic> asMap(dynamic value) => value is Map
          ? Map<String, dynamic>.from(value)
          : <String, dynamic>{};
      List<Map<String, dynamic>> asMapList(dynamic value) => value is List
          ? value.whereType<Map>().map(asMap).toList()
          : <Map<String, dynamic>>[];

      final weekly = asMap(data['weekly']);
      final monthly = asMap(data['monthly']);
      return {
        'success': true,
        'message': status['message'] ?? 'Success',
        'overall': asMap(data['overall_summary']),
        'departments': asMapList(data['overall_department']),
        'monthlyDepartments': asMapList(monthly['department']),
        'weeklyDepartments': asMapList(weekly['department']),
        'monthlyUsers': asMapList(monthly['user']),
        'monthlyServices': asMapList(monthly['service_summary']),
        'weeklyUsers': asMapList(weekly['user']),
        'weeklyServices': asMapList(weekly['service_summary']),
        'weeklyFood': asMapList(weekly['food_summary']),
        'monthlyFood': asMapList(monthly['food_summary']),
        'weeklyFoodUsers': asMapList(weekly['food_user_summary']),
        'monthlyFoodUsers': asMapList(monthly['food_user_summary']),
        'weeklyGuests': asMapList(weekly['guest_checkin_checkout']),
        'monthlyGuests': asMapList(monthly['guest_checkin_checkout']),
      };
    } catch (e) {
      dev.log('ERROR (getServiceOperationsReport): $e');
      return {'success': false, 'message': ErrorHandler.friendlyMessage(e)};
    }
  }

  /// Compatibility facade for the Tasks page. It deliberately uses the new
  /// operations report rather than the deprecated team-performance API.
  Future<Map<String, dynamic>> getOperationsPerformance({
    int? departmentId,
    int? targetUserId,
    required int month,
    required int year,
  }) async {
    final report = await getServiceOperationsReport();
    if (report['success'] != true) {
      return {
        'success': false,
        'message': report['message'] ?? 'Failed to load operations report',
        'team': <Map<String, dynamic>>[],
        'weeklyUsers': <Map<String, dynamic>>[],
        'departments': <Map<String, dynamic>>[],
        'monthlyDepartments': <Map<String, dynamic>>[],
        'drillDown': <dynamic>[],
      };
    }

    final period = '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';
    Iterable<Map<String, dynamic>> rows =
        (report['monthlyUsers'] as List<Map<String, dynamic>>)
            .where((row) => row['report_month']?.toString() == period);
    if (departmentId != null) {
      rows = rows.where((row) => _asInt(row['department_id']) == departmentId);
    }
    if (targetUserId != null) {
      rows = rows.where((row) => _asInt(row['user_id']) == targetUserId);
    }

    List<Map<String, dynamic>> targetWeeklyUsers = [];
    if (targetUserId != null) {
      targetWeeklyUsers = (report['weeklyUsers'] as List<Map<String, dynamic>>)
          .where((row) => _asInt(row['user_id']) == targetUserId)
          .toList();
    }

    return {
      'success': true,
      'message': report['message'] ?? 'Success',
      // ── Team & user rows ──────────────────────────────────────────────────────────────
      'team': rows.map(_normaliseOperationsUserRow).toList(),
      'weeklyUsers': targetWeeklyUsers,
      'allMonthlyUsers': report['monthlyUsers'],
      'allWeeklyUsers': report['weeklyUsers'],
      // ── RS3: Department overall benchmark ───────────────────────────────────────────
      'departments': report['departments'],
      // ── RS7: Monthly department trends ──────────────────────────────────────────────
      'monthlyDepartments': report['monthlyDepartments'],
      // ── RS6: Weekly department trends ───────────────────────────────────────────────
      'weeklyDepartments': report['weeklyDepartments'],
      // ── RS4/RS10: Weekly enterprise service counts ──────────────────────────────────
      'weeklyServices': report['weeklyServices'],
      // ── RS5/RS11: Monthly enterprise service counts ─────────────────────────────────
      'monthlyServices': report['monthlyServices'],
      // ── RS12: Weekly food summary ──────────────────────────────────────────────────
      'weeklyFood': report['weeklyFood'],
      // ── RS13: Monthly food summary ─────────────────────────────────────────────────
      'monthlyFood': report['monthlyFood'],
      // ── RS14: Weekly food user (per-staff food stats) ──────────────────────────────
      'weeklyFoodUsers': report['weeklyFoodUsers'],
      // ── RS15: Monthly food user (per-staff food stats) ─────────────────────────────
      'monthlyFoodUsers': report['monthlyFoodUsers'],
      // ── RS16: Weekly guest check-in / check-out ────────────────────────────────────
      'weeklyGuests': report['weeklyGuests'],
      // ── RS17: Monthly guest check-in / check-out ───────────────────────────────────
      'monthlyGuests': report['monthlyGuests'],
      // ── RS1/RS2: Overall enterprise summary ─────────────────────────────────────────
      'overallSummary': report['overall'],
      // Legacy drill-down placeholder (not populated from this API)
      'drillDown': <dynamic>[],
    };
  }

  /// Alias for backward compatibility
  Future<Map<String, dynamic>> getTeamPerformance({
    int? departmentId,
    int? targetUserId,
    required int month,
    required int year,
  }) => getOperationsPerformance(
    departmentId: departmentId,
    targetUserId: targetUserId,
    month: month,
    year: year,
  );

  static int _asInt(dynamic value) => value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? 0;

  static Map<String, dynamic> _normaliseOperationsUserRow(Map row) =>
      _normaliseTeamPerformanceRow({
        ...row,
        'total_assigned': row['total_tasks'],
        'total_closed': row['closed_tasks'],
        'total_escalated': row['escalation_count'],
        'avg_resolution_minutes': row['average_time_taken'],
        'escalation_rate_pct': _asInt(row['total_tasks']) == 0
            ? 0
            : (_asInt(row['escalation_count']) / _asInt(row['total_tasks'])) *
                100,
      });
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
      'open_tasks': asInt(row['open_tasks']),
      'in_progress_tasks': asInt(row['in_progress_tasks']),
      'overdue_tasks': asInt(row['overdue_tasks']),
      'total_assigned': asInt(row['total_assigned']),
      'total_closed': asInt(row['total_closed']),
      'total_escalated': asInt(row['total_escalated']),
      'avg_resolution_minutes': asDouble(row['avg_resolution_minutes']),
      'escalation_rate_pct': asDouble(row['escalation_rate_pct']),
    };
  }



  // ──────── GET READY ORDERS ──────────────────────────────────────────────────────────────

  // ──────── UPDATE ROOM SERVICE STATUS ─────────────────────────────────────────────────

  /* Deprecated Room Service API implementation retained as a reference only.
     Delivery now uses TaskService.getAllServices(), acceptServiceRequest(),
     and closeService().
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

      dev.log("Updating Room Service Status — $action for $orderNumber");
      final response = await _dio.post(
          ApiConstants.updateRoomServiceStatus,
          data: payload);
      dev.log("Update Response: ${response.data}");

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
          dev.log("updateRoomServiceStatus succeeded (notification-style response)");
          return {"success": true, "message": "Status updated successfully"};
        }

        dev.log("updateRoomServiceStatus: non-empty STATUS on 200 → success");
        return {"success": true, "message": "Status updated"};
      }

      final resultList = body["RESULT"] as List?;
      if (resultList != null && resultList.isNotEmpty) {
        final flag    = resultList[0]["status"];
        final message = resultList[0]["message"] ?? "Done";
        return {"success": flag == "S", "message": message};
      }

      dev.log("updateRoomServiceStatus: empty body on 200 → treating as success");
      return {"success": true, "message": "Status updated"};
    } catch (e) {
      dev.log("ERROR (updateRoomServiceStatus): $e");
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }

  // ──────── GET ACCEPTED ORDERS ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getAcceptedOrdersForRoomService() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {"user_id": userId, "stage": AppConfig.stage};

      dev.log("Fetching ACCEPTED Orders for Room Service");
      final response =
          await _dio.post(ApiConstants.getAcceptedOrders, data: payload);
      dev.log("Accepted Orders Response: ${response.data}");

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
      dev.log("ERROR (getAcceptedOrdersForRoomService): $e");
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

  // ──────── GET DELIVERED ORDERS ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getDeliveredOrdersForRoomService() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {"user_id": userId, "stage": AppConfig.stage};

      dev.log("Fetching DELIVERED Orders for Room Service");
      final response =
          await _dio.post(ApiConstants.getDeliveredOrders, data: payload);
      dev.log("Delivered Orders Response: ${response.data}");

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
      dev.log("ERROR (getDeliveredOrdersForRoomService): $e");
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
  */
}