import 'dart:developer' as dev;
import 'package:dio/dio.dart';

import '../utils/user_session_helper.dart';
import '../constants/api_constants.dart';


class TaskService {
  final Dio _dio;

  TaskService()
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

  Future<Map<String, dynamic>> fetchTaskSummary() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || userId == 0 || enterpriseId == null || enterpriseId == 0) {
        return {
          "success": false,
          "message": "User session missing (user_id or enterprise_id)",
        };
      }

      final payload = {
        "user_id": userId,
        "enterprise_id": enterpriseId,
        "stage": "dev",
      };

      dev.log("📤 Fetching task summary...");
      final response = await _dio.post(ApiConstants.taskSummary, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final status = response.data["STATUS"];
      final result = response.data["RESULT"];

      if (status == null || status.isEmpty || status[0]["status"] != "S") {
        return {
          "success": false,
          "message": status?[0]["message"] ?? "Failed",
        };
      }

      // Convert result to a list of tasks
      final List<dynamic> tasks = result ?? [];

      dev.log("RAW SUMMARY LIST: $tasks");

      return {
        "success": true,
        "message": status[0]["message"],
        "tasks": tasks.map((task) {
          return {
            "roomId": task["room_id"],
            "roomNumber":
                task["room_number"] ??
                task["requested_room"] ??
                task["requested_room_id"]?.toString() ??
                "-",
            "status": task["status"],
            "question": task["question"],
            "timeAgo": task["time_ago"],
            "totalTasks": task["total_tasks"],
            "completedTasks": task["completed_tasks"],
          };
        }).toList(),
      };
    } catch (e) {
      return {
        "success": false,
        "message": "Exception: $e",
      };
    }
  }
}
