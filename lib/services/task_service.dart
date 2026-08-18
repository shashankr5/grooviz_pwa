import 'dart:developer' as dev;
import 'package:dio/dio.dart';
import 'dart:convert';
import '../utils/user_session_helper.dart';
import '../utils/error_handler.dart';
import '../constants/api_constants.dart';
import '../constants/api_timeouts.dart';
import 'home_service.dart';

class TaskService {
  final Dio _dio;

  TaskService()
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

  //  COMMON STATUS NORMALIZER  (same as HomeService)

  String normalizeStatus(String? status, int? closedFlag) {
    if (closedFlag == 1) return "Closed";

    if (status == null) return "Open";

    switch (status.toUpperCase()) {
      case "PENDING":
        return "Open";
      case "INPROGRESS":
      case "IN_PROGRESS":
      case "IN PROGRESS":
        return "In Progress";
      case "CLOSED":
        return "Closed";
      default:
        return status;
    }
  }

  //  MAIN SUMMARY METHOD

  Future<Map<String, dynamic>> fetchTaskSummary() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || userId == 0) {
        return {
          "success": false,
          "message": "User session missing (user_id)",
        };
      }

      final payload = {
        "user_id": userId,
        "enterprise_id": enterpriseId,
        "stage": "dev",
      };

      dev.log("📤 Fetching task summary (TaskService)…");

      final response = await _dio.post(ApiConstants.taskSummary, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"];

      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final rawResponse = statusList[0]["response"];

      if (rawResponse == null) {
        return {"success": false, "message": "Missing summary response"};
      }

      // 🔥 Decode the nested JSON string
      final decoded = jsonDecode(rawResponse);

      final summary = decoded["summary"];

      final int totalTasks = summary["totalTasks"] ?? 0;
      final int completedToday = summary["completedToday"] ?? 0;
      final int inProgressTasks = summary["inProgressTasks"] ?? 0;

      // Fetch real tasks from HomeService for recent activity
      // Fetch real tasks from HomeService for recent activity
      final homeRes = await HomeService().getTasks();

      List<dynamic> recentTasks = [];

      if (homeRes["success"]) {
        List<dynamic> allTasks = homeRes["tasks"];

        // 1️⃣ Keep only CLOSED
        final closedTasks = allTasks
            .where((t) => t["status"] == "Closed")
            .toList();

        // 2️⃣ Sort by time DESC (latest first)
        closedTasks.sort((a, b) {
          final aTime = a["raw"]?["timestamp"];
          final bTime = b["raw"]?["timestamp"];

          if (aTime == null || bTime == null) return 0;

          return DateTime.parse(bTime)
              .compareTo(DateTime.parse(aTime));
        });

        // Take only top 5
        recentTasks = closedTasks.take(5).map((t) {
          return {
            "roomNumber": t["room"],
            "question": t["title"],
            "timeAgo": t["time"],
            "status": t["status"],
          };
        }).toList();
      }

      return {
        "success": true,
        "message": decoded["message"] ?? "Success",
        "totalTasks": totalTasks,
        "completedToday": completedToday,
        "inProgressTasks": inProgressTasks,
        "tasks": recentTasks,
      };
    } catch (e) {
      dev.log("❌ ERROR (fetchTaskSummary): $e");
      return {
        "success": false,
        "message": ErrorHandler.friendlyMessage(e),
      };
    }
  }

  /// Fetches all service department requests using ScreenSync_get_all_services_mobile
  Future<Map<String, dynamic>> getAllServices({String stage = 'prod'}) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {'success': false, 'message': 'User session not found'};
      }

      final response = await _dio.post(
        ApiConstants.getAllServices,
        data: {
          'user_id': userId,
          'stage': stage,
        },
      );

      final data = response.data;
      List<dynamic> statusList = data['STATUS'] ?? [];
      List<dynamic> resultList = data['RESULT'] ?? [];

      if (statusList.isNotEmpty && statusList[0]['status'] == 'S') {
        return {
          'success': true,
          'message': statusList[0]['message'] ?? 'Success',
          'services': resultList,
        };
      } else {
        return {
          'success': false,
          'message': statusList.isNotEmpty ? statusList[0]['message'] : 'Failed to fetch services',
          'services': [],
        };
      }
    } catch (e) {
      dev.log("❌ ERROR (getAllServices): $e");
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
        'services': [],
      };
    }
  }

  /// Accept/Reject/Cancel/Complete a service order
  Future<Map<String, dynamic>> acceptServiceOrder({
    required int orderId,
    required String action, // ACCEPT, REJECT, CANCEL, COMPLETE
    String? remarks,
    List<Map<String, dynamic>>? items,
    String stage = 'prod',
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      final enterpriseId = await UserSessionHelper.getEnterpriseId();
      if (userId == null || enterpriseId == null) {
        return {'success': false, 'message': 'User session not found'};
      }

      final response = await _dio.post(
        ApiConstants.acceptServiceOrder,
        data: {
          'user_id': userId,
          'enterprise_id': enterpriseId,
          'order_id': orderId,
          'action': action,
          if (remarks != null) 'remarks': remarks,
          if (items != null) 'items': items,
          'stage': stage,
        },
      );

      final data = response.data;
      List<dynamic> statusList = data['STATUS'] ?? [];
      
      if (statusList.isNotEmpty && statusList[0]['status'] == 'S') {
        return {
          'success': true,
          'message': statusList[0]['message'] ?? 'Action processed successfully',
        };
      } else {
        return {
          'success': false,
          'message': statusList.isNotEmpty ? statusList[0]['message'] : 'Failed to process order action',
        };
      }
    } catch (e) {
      dev.log("❌ ERROR (acceptServiceOrder): $e");
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
      };
    }
  }

  /// Update the progress/delivery status of a service request
  Future<Map<String, dynamic>> updateServiceRequestStatus({
    required int serviceRequestId,
    required String status, // IN_PROGRESS, OUT_FOR_DELIVERY, DELIVERED, COMPLETED, CANCELLED
    String? remarks,
    String stage = 'prod',
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {'success': false, 'message': 'User session not found'};
      }

      final response = await _dio.post(
        ApiConstants.updateServiceRequestStatus,
        data: {
          'user_id': userId,
          'service_request_id': serviceRequestId,
          'status': status,
          if (remarks != null) 'remarks': remarks,
          'stage': stage,
        },
      );

      final data = response.data;
      List<dynamic> statusList = data['STATUS'] ?? [];
      
      if (statusList.isNotEmpty && statusList[0]['status'] == 'S') {
        return {
          'success': true,
          'message': statusList[0]['message'] ?? 'Status updated successfully',
        };
      } else {
        return {
          'success': false,
          'message': statusList.isNotEmpty ? statusList[0]['message'] : 'Failed to update request status',
        };
      }
    } catch (e) {
      dev.log("❌ ERROR (updateServiceRequestStatus): $e");
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
      };
    }
  }

  /// Reassign a service request to another staff member
  Future<Map<String, dynamic>> reassignService({
    required int taskId,
    required int reassignTo,
    String stage = 'prod',
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {'success': false, 'message': 'User session not found'};
      }

      final response = await _dio.post(
        ApiConstants.reassignService,
        data: {
          'user_id': userId,
          'task_id': taskId,
          'reassign_to': reassignTo,
          'stage': stage,
        },
      );

      final data = response.data;
      List<dynamic> statusList = data['STATUS'] ?? [];
      
      if (statusList.isNotEmpty && statusList[0]['status'] == 'S') {
        return {
          'success': true,
          'message': statusList[0]['message'] ?? 'Task reassigned successfully',
        };
      } else {
        return {
          'success': false,
          'message': statusList.isNotEmpty ? statusList[0]['message'] : 'Failed to reassign task',
        };
      }
    } catch (e) {
      dev.log("❌ ERROR (reassignService): $e");
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
      };
    }
  }

  /// Add a note to a service request
  Future<Map<String, dynamic>> addServiceNote({
    required int serviceRequestId,
    required String noteText,
    String stage = 'prod',
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {'success': false, 'message': 'User session not found'};
      }

      final response = await _dio.post(
        ApiConstants.addServiceNote,
        data: {
          'user_id': userId,
          'service_request_id': serviceRequestId,
          'note_text': noteText,
          'stage': stage,
        },
      );

      final data = response.data;
      List<dynamic> statusList = data['STATUS'] ?? [];
      
      if (statusList.isNotEmpty && statusList[0]['status'] == 'S') {
        return {
          'success': true,
          'message': statusList[0]['message'] ?? 'Note added successfully',
        };
      } else {
        return {
          'success': false,
          'message': statusList.isNotEmpty ? statusList[0]['message'] : 'Failed to add note',
        };
      }
    } catch (e) {
      dev.log("❌ ERROR (addServiceNote): $e");
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
      };
    }
  }

  /// Close a service request
  Future<Map<String, dynamic>> closeService({
    required int serviceRequestId,
    String stage = 'prod',
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {'success': false, 'message': 'User session not found'};
      }

      final response = await _dio.post(
        ApiConstants.closeService,
        data: {
          'user_id': userId,
          'service_request_id': serviceRequestId,
          'stage': stage,
        },
      );

      final data = response.data;
      List<dynamic> statusList = data['STATUS'] ?? [];
      
      if (statusList.isNotEmpty && statusList[0]['status'] == 'S') {
        return {
          'success': true,
          'message': statusList[0]['message'] ?? 'Service closed successfully',
        };
      } else {
        return {
          'success': false,
          'message': statusList.isNotEmpty ? statusList[0]['message'] : 'Failed to close service',
        };
      }
    } catch (e) {
      dev.log("❌ ERROR (closeService): $e");
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
      };
    }
  }
}
