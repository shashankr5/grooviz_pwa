import 'dart:developer' as dev;
import 'package:dio/dio.dart';
import 'dart:convert';
import '../utils/user_session_helper.dart';
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
        "message": "Exception: $e",
      };
    }
  }

}
