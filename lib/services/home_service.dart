import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'dart:convert';
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

  Future<Map<String, dynamic>> getTasks() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      if (enterpriseId == null || enterpriseId == 0) {
        return {"success": false, "message": "Enterprise ID missing"};
      }

      final payload = {
        "user_id": userId,
        "enterprise_id": enterpriseId,
        "stage": "dev",
      };

      dev.log("Fetching tasks...");
      final response =
      await _dio.post(ApiConstants.tasks, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final status = response.data["STATUS"];
      if (status == null || status.isEmpty || status[0]["status"] != "S") {
        return {
          "success": false,
          "message": status?[0]["message"] ?? "Failed"
        };
      }

      final resultList = response.data["RESULT"];
      if (resultList == null) {
        return {"success": false, "message": "No tasks returned"};
      }

      List<Map<String, dynamic>> tasks = _mapTasks(resultList);

      return {"success": true, "tasks": tasks};
    } catch (e) {
      dev.log("ERROR (getTasks): $e");
      return {"success": false, "message": "Network error"};
    }
  }

  // MAP API → UI FRIENDLY FORMAT

  static List<Map<String, dynamic>> _mapTasks(List raw) {
    return raw.map<Map<String, dynamic>>((t) {
      final m = Map<String, dynamic>.from(t);

      return {
        "room": (m["requested_room"] ?? m["room_id"] ?? "-").toString(),

        "status": _statusText(m["status"], m["closed"]),
        "statusColor": _statusColor(m["status"]),

        "title": m["question"] ?? "Service Request",
        "subtitle": m["answer"] ?? "Awaiting response",
        "description": m["answer"] ?? "",
        "time": _formatTime(m["timestamp"]),

        "guest": m["guest_name"] ?? "Unknown Guest",
        "guestNote":
        "Phone: ${m["guest_phone"] ?? m["customer_number"] ?? "-"}",

        "assignedTo": (
            m["assigned_to_name"] ??
                m["assigned_user_name"] ??
                m["assigned_name"] ??
                m["name"] ??
                m["assigned_to"] ??
                "-"
        ).toString(),

        "raw": m
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
        return const Color(0xFF1976D2); // Blue
      case "INPROGRESS":
      case "IN_PROGRESS":
        return const Color(0xFFFF9800); // Orange
      case "CLOSED":
        return const Color(0xFF4CAF50); // Green
      default:
        return Colors.blueGrey;
    }
  }

  static String _formatTime(String? timestamp) {
    if (timestamp == null) return "-";

    try {
      DateTime dt = DateTime.parse(timestamp).toLocal();
      return "${dt.hour}:${dt.minute.toString().padLeft(2, '0')} • ${dt.day}/${dt.month}";
    } catch (_) {
      return "-";
    }
  }

  // GET STAFF LIST API

  Future<Map<String, dynamic>> getStaffList() async {
    try {
      final userId = await UserSessionHelper.getUserId();

      if (userId == null) {
        return {
          "success": false,
          "message": "User not logged in",
          "staff": []
        };
      }

      final payload = {
        "user_id": userId,
        "stage": "dev",
      };

      dev.log("📤 Fetching staff list...");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.staffList,
        data: payload,
      );

      dev.log("📥 Response: ${response.data}");

      if (response.statusCode != 200) {
        return {
          "success": false,
          "message": "Server error: ${response.statusCode}",
          "staff": []
        };
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid server response",
          "staff": []
        };
      }

      final statusFlag = statusList[0]["status"] ?? "F";
      final statusMessage = statusList[0]["message"] ?? "Unknown";

      if (statusFlag != "S") {
        return {
          "success": false,
          "message": statusMessage,
          "staff": []
        };
      }

      final resultList = response.data["RESULT"] as List?;

      final staff = resultList?.map((item) {
        return {
          "userId": item["user_id"],
          "name": item["name"] ?? "-",
          "department": item["department_name"] ?? "Not Assigned",
        };
      }).toList();

      return {
        "success": true,
        "message": statusMessage,
        "staff": staff ?? []
      };
    } catch (e) {
      dev.log("Staff API Error: $e");
      return {
        "success": false,
        "message": "Error: $e",
        "staff": []
      };
    }
  }

  // Reassign
  Future<Map<String, dynamic>> reassignTicket({
    required int ticketId,
    required int assignedUserId,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();

      if (userId == null) {
        return {
          "success": false,
          "message": "User not logged in",
        };
      }

      final payload = {
        "user_id": userId,
        "task_id": ticketId,
        "reassign_to": assignedUserId,
        "stage": "dev",
      };

      dev.log("📤 Reassign Ticket API Call");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.reassignTicket,
        data: payload,
      );

      dev.log("📥 Response: ${response.data}");

      if (response.statusCode != 200) {
        return {
          "success": false,
          "message": "Server error: ${response.statusCode}",
        };
      }

      final statusList = response.data["STATUS"] as List?;

      if (statusList == null || statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid server response",
        };
      }

      final flag = statusList[0]["status"];
      final msg = statusList[0]["message"];

      if (flag != "S") {
        return {
          "success": false,
          "message": msg ?? "Failed",
        };
      }

      final updatedTask = response.data["RESULT"][0];

      return {
        "success": true,
        "message": msg,
        "updatedTask": updatedTask,
      };
    } catch (e) {
      dev.log("ERROR (reassignTicket): $e");
      return {
        "success": false,
        "message": "Error: $e",
      };
    }
  }

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
        "user_id": userId,
        "service_request_id": serviceRequestId,
        "note_text": noteText,
        "stage": "dev",
      };

      dev.log("Add Note API Call");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.addNotes,
        data: payload,
      );

      dev.log("Response: ${response.data}");

      if (response.statusCode != 200) {
        return {
          "success": false,
          "message": "Server error: ${response.statusCode}",
          "note": null,
        };
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid server response",
          "note": null,
        };
      }

      final flag = statusList[0]["status"];
      final msg = statusList[0]["message"];

      if (flag != "S") {
        return {
          "success": false,
          "message": msg ?? "Failed",
          "note": null,
        };
      }

      final insertedNote = response.data["RESULT"][0];

      return {
        "success": true,
        "message": msg,
        "note": insertedNote,
      };
    } catch (e) {
      dev.log("ERROR (addNote): $e");
      return {
        "success": false,
        "message": "Error: $e",
        "note": null,
      };
    }
  }

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
        "user_id": userId,
        "service_request_id": serviceRequestId,
        "stage": "dev",
      };

      dev.log("📤 Close Service Request API Call");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.closeServiceRequest,
        data: payload,
      );

      dev.log("Response: ${response.data}");

      if (response.statusCode != 200) {
        return {
          "success": false,
          "message": "Server error: ${response.statusCode}",
          "data": null,
        };
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid server response",
          "data": null,
        };
      }

      final flag = statusList[0]["status"];
      final msg = statusList[0]["message"];

      if (flag != "S") {
        return {
          "success": false,
          "message": msg ?? "Failed",
          "data": null,
        };
      }

      final updated = response.data["RESULT"][0];

      return {
        "success": true,
        "message": msg,
        "data": updated,
      };
    } catch (e) {
      dev.log("ERROR (closeServiceRequest): $e");

      return {
        "success": false,
        "message": "Error: $e",
        "data": null,
      };
    }
  }

  Future<Map<String, dynamic>> acceptTask({
    required int taskId,
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
        "user_id": userId,
        "task_id": taskId,
        "stage": "dev",
      };

      dev.log("Accept Task API Call");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.acceptTask,
        data: payload,
      );

      dev.log("Response: ${response.data}");

      if (response.statusCode != 200) {
        return {
          "success": false,
          "message": "Server error: ${response.statusCode}",
          "updatedTask": null,
        };
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid server response",
          "updatedTask": null,
        };
      }

      final flag = statusList[0]["status"];
      final msg = statusList[0]["message"];

      if (flag != "S") {
        return {
          "success": false,
          "message": msg ?? "Failed",
          "updatedTask": null,
        };
      }

      final updatedTask = response.data["RESULT"]?[0];

      return {
        "success": true,
        "message": msg,
        "updatedTask": updatedTask,
      };
    } catch (e) {
      dev.log("ERROR (acceptTask): $e");
      return {
        "success": false,
        "message": "Error: $e",
        "updatedTask": null,
      };
    }
  }

  Future<Map<String, dynamic>> getTaskDetails(task) async {
    try {
      return {
        "success": true,
        "task": task,
      };
    } catch (e) {
      dev.log("ERROR (getTaskDetails): $e");
      return {
        "success": false,
        "message": "Error: $e",
        "task": null,
      };
    }
  }

  // GET READY ORDERS (Room Service - Home Page)
  Future<Map<String, dynamic>> getReadyOrdersForRoomService() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();

      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {
        "user_id": userId,
        "stage": "dev",
      };

      dev.log("📤 Fetching READY Orders for Room Service");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.getReadyOrders, // <-- add this constant
        data: payload,
      );

      dev.log("📥 Raw Ready Orders Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final resultList = response.data["RESULT"] as List? ?? [];

      final orders = _mapReadyOrders(resultList);

      return {
        "success": true,
        "orders": orders,
      };
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
        "orderNumber": m["order_number"],

        "roomNumber": m["room_number"],
        "roomId": m["room_id"],

        "guestName": m["guest_name"],

        "foodItem": m["food_item"],
        "quantity": m["quantity"],

        "status": "Ready",

        "orderTime": m["ready_time"],

        "raw": m,
      };
    }).toList();
  }

  // UPDATE ROOM SERVICE STATUS (Accept / Delivered)
  Future<Map<String, dynamic>> updateRoomServiceStatus({
    required String orderNumber,
    required String action, // "Delivered" or "Accepted"
  }) async {
    try {
      final int? userId = await UserSessionHelper.getUserId();

      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {
        "user_id": userId,
        "order_number": orderNumber,
        "delivery_action": action,
        "stage": "dev",
      };

      dev.log("📤 Updating Room Service Status");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.updateRoomServiceStatus,
        data: payload,
      );

      dev.log("📥 Raw Update Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final flag = statusList[0]["status"];
      final rawResponse = statusList[0]["response"];

      String message = "Action failed";

      // Backend nests message inside a JSON string
      if (rawResponse is String) {
        try {
          final decoded = jsonDecode(rawResponse);
          message = decoded["STATUS"]?[0]?["response"]?["message"] ?? message;
        } catch (e) {
          dev.log("⚠️ JSON decode failed: $e");
          message = rawResponse;
        }
      }

      if (flag != "S") {
        return {
          "success": false,
          "message": message,
        };
      }

      return {
        "success": true,
        "message": message,
      };
    } catch (e) {
      dev.log("❌ ERROR (updateRoomServiceStatus): $e");
      return {"success": false, "message": "Network error"};
    }
  }

  Future<Map<String, dynamic>> getAcceptedOrdersForRoomService() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();

      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {
        "user_id": userId,
        "stage": "dev",
      };

      dev.log("📤 Fetching ACCEPTED Orders for Room Service");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.getAcceptedOrders,
        data: payload,
      );

      dev.log("📥 Raw Accepted Orders Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final resultList = response.data["RESULT"] as List? ?? [];

      final orders = _mapAcceptedOrders(resultList);

      return {
        "success": true,
        "orders": orders,
      };
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
        "orderNumber": m["order_number"],

        "roomNumber": m["room_number"],
        "roomId": m["room_id"],

        "guestName": m["guest_name"],

        "foodItem": m["food_item"],
        "quantity": m["quantity"],

        "status": "Accepted",

        "orderTime": m["accepted_time"],

        "raw": m,
      };
    }).toList();
  }

  Future<Map<String, dynamic>> getDeliveredOrdersForRoomService() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();

      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {
        "user_id": userId,
        "stage": "dev",
      };

      dev.log("📤 Fetching DELIVERED Orders for Room Service");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.getDeliveredOrders,
        data: payload,
      );

      dev.log("📥 Raw Delivered Orders Response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final resultList = response.data["RESULT"] as List? ?? [];

      final orders = _mapDeliveredOrders(resultList);

      return {
        "success": true,
        "orders": orders,
      };
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
        "orderNumber": m["order_number"],

        "roomNumber": m["room_number"],
        "roomId": m["room_id"],

        "guestName": m["guest_name"],

        "foodItem": m["food_item"],
        "quantity": m["quantity"],

        "status": "Delivered",

        "orderTime": m["delivered_time"],

        "raw": m,
      };
    }).toList();
  }
}