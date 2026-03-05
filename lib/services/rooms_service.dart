// rooms_service.dart
import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'dart:convert';
import '../utils/user_session_helper.dart';
import '../constants/api_constants.dart';

class RoomsService {
  final Dio _dio;

  RoomsService()
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

  /// GET ROOMS
  Future<Map<String, dynamic>> getRooms() async {
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
        "enterprise_id": enterpriseId.toString(),
        "stage": "dev",
      };

      dev.log("📤 Fetching Rooms");
      dev.log("Payload: $payload");

      final response =
          await _dio.post(ApiConstants.getRooms, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;

      if (statusList == null ||
          statusList.isEmpty ||
          statusList[0]["status"] != "S") {
        return {
          "success": false,
          "message": statusList?[0]["message"] ?? "Failed"
        };
      }

      final resultList = response.data["RESULT"] as List?;

      if (resultList == null) {
        return {"success": false, "message": "No rooms returned"};
      }

      final rooms = _mapRooms(resultList);

      return {
        "success": true,
        "rooms": rooms,
      };
    } catch (e) {
      dev.log("❌ ERROR (getRooms): $e");
      return {"success": false, "message": "Network error"};
    }
  }

  /// MAP API → UI FRIENDLY FORMAT
  static List<Map<String, dynamic>> _mapRooms(List raw) {
    return raw.map<Map<String, dynamic>>((room) {
      final m = Map<String, dynamic>.from(room);

      // Parse devices JSON string safely
      List devices = [];
      try {
        if (m["devices"] != null && m["devices"].toString().isNotEmpty) {
          devices = jsonDecode(m["devices"]);
        }
      } catch (_) {}

      return {
        "roomId": m["room_id"],
        "roomNumber": m["room_number"] ?? "-",
        "roomType": m["room_type_name"] ?? "-",
        "roomTypeId": m["room_type_id"],
        "status": m["room_status"] ?? "Unknown",
        "statusColor": _statusColor(m["room_status"]),
        "enterpriseId": m["enterprise_id"],

        /// device info
        "devices": devices,
        "deviceNames":
            devices.map((d) => d["device_name"]).join(", "),

        /// raw data
        "raw": m,
      };
    }).toList();
  }

  /// STATUS COLOR (UI friendly)
  static Color _statusColor(String? status) {
    if (status == null) return Colors.grey;

    switch (status.toLowerCase()) {
      case "available":
        return const Color(0xFF4CAF50); // green
      case "occupied":
        return const Color(0xFFF44336); // red
      case "cleaning":
        return const Color(0xFFFF9800); // orange
      default:
        return Colors.blueGrey;
    }
  }

  /// UPLOAD IMAGE CONTENT TO DEVICES
  Future<Map<String, dynamic>> uploadImageContent({
    required String title,
    required String filePath,
    required DateTime startTime,
    DateTime? endTime,
    required int displayTimer,
    required List<int> deviceIds,
  }) async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      if (enterpriseId == null || enterpriseId == 0) {
        return {"success": false, "message": "Enterprise ID missing"};
      }

      if (deviceIds.isEmpty) {
        return {"success": false, "message": "No devices selected"};
      }

      final payload = {
        "user_id": userId,
        "enterprise_id": enterpriseId.toString(),
        "stage": "dev",

        /// REQUIRED CONSTANT
        "type_name": "IMAGE",

        "title": title,
        "file_path": filePath,

        "start_time": startTime.toIso8601String(),

        // If null → backend accepts zero date
        "end_time": endTime != null
          ? endTime.toIso8601String()
          : "0000-00-00 00:00:00",

        "display_timer": displayTimer,

        /// MULTIPLE DEVICE IDS
        "device_ids": deviceIds,
      };

      dev.log("📤 Uploading Image Content");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.uploadImage,
        data: payload,
      );

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final resultList = response.data["RESULT"] as List?;

      if (resultList == null || resultList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final status = resultList[0]["status"];
      final message = resultList[0]["message"];

      if (status != "S") {
        return {
          "success": false,
          "message": message ?? "Upload failed",
        };
      }

      return {
        "success": true,
        "message": message,
      };
    } catch (e) {
      dev.log("❌ ERROR (uploadImageContent): $e");
      return {"success": false, "message": "Network error"};
    }
  }

  /// UPDATE EXISTING CONTENT
  Future<Map<String, dynamic>> updateContent({
    required int contentId,
    required String title,
    required String filePath,
    required DateTime startTime,
    DateTime? endTime,
    required int displayTimer,
    required List<int> deviceIds,
  }) async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      if (enterpriseId == null || enterpriseId == 0) {
        return {"success": false, "message": "Enterprise ID missing"};
      }

      if (deviceIds.isEmpty) {
        return {"success": false, "message": "No devices selected"};
      }

      final payload = {
        "user_id": userId,
        "content_id": contentId,
        "enterprise_id": enterpriseId.toString(),
        "stage": "dev",

        /// REQUIRED
        "type_name": "IMAGE",

        "title": title,
        "file_path": filePath,

        "start_time": startTime.toIso8601String(),

        "end_time": endTime != null
            ? endTime.toIso8601String()
            : "0000-00-00 00:00:00",

        "display_timer": displayTimer,

        /// MULTIPLE DEVICE IDS
        "device_ids": deviceIds,
      };

      dev.log("📤 Updating Content");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.updateContent,
        data: payload,
      );

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final resultList = response.data["RESULT"] as List?;

      if (resultList == null || resultList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final status = resultList[0]["status"];
      final message = resultList[0]["message"];

      if (status != "S") {
        return {
          "success": false,
          "message": message ?? "Update failed",
        };
      }

      return {
        "success": true,
        "message": message ?? "Content updated",
      };
    } catch (e) {
      dev.log("❌ ERROR (updateContent): $e");
      return {"success": false, "message": "Network error"};
    }
  }

  /// GET UPLOADED CONTENTS
  Future<Map<String, dynamic>> getContents() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || enterpriseId == null) {
        return {"success": false, "message": "User or Enterprise missing"};
      }

      final payload = {
        "user_id": userId.toString(),
        "enterprise_id": enterpriseId.toString(),
        "stage": "dev",
      };

      dev.log("📤 Fetching Contents (Mobile)");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.getContents,
        data: payload,
      );

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;

      if (statusList == null ||
          statusList.isEmpty ||
          statusList[0]["status"] != "S") {
        return {
          "success": false,
          "message": statusList?[0]["message"] ?? "Failed"
        };
      }

      final resultList = response.data["RESULT"] as List?;

      if (resultList == null) {
        return {"success": false, "message": "No contents returned"};
      }

      final contents = resultList.map<Map<String, dynamic>>((item) {
        final m = Map<String, dynamic>.from(item);

        // 🔹 decode rooms JSON string safely
        List rooms = [];
        try {
          if (m["rooms"] != null && m["rooms"].toString().isNotEmpty) {
            rooms = jsonDecode(m["rooms"]);
          }
        } catch (_) {}

        return {
          "id": m["content_id"].toString(),
          "title": m["title"] ?? "",
          "filePath": m["file_path"] ?? "",
          "type": m["content_type_name"] ?? "",
          "status": m["status"] ?? "",
          "startTime": m["start_time"],
          "endTime": m["end_time"],
          "displayTimer": m["display_timer"] ?? 0,

          /// NEW: rooms info
          "rooms": rooms,
          "roomNumbers":
              rooms.map((r) => r["room_number"]).join(", "),

          /// derived count
          "roomCount": rooms.length,
        };
      }).toList();

      return {
        "success": true,
        "contents": contents,
      };
    } catch (e) {
      dev.log("❌ ERROR (getContents): $e");
      return {"success": false, "message": "Network error"};
    }
  }

  /// DELETE CONTENT
  Future<Map<String, dynamic>> deleteContent({
    required String contentId,
  }) async {
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
        "content_id": contentId,
        "enterprise_id": enterpriseId.toString(),
        "stage": "dev",
      };

      dev.log("🗑 Deleting Content");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.deleteContent,
        data: payload,
      );

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final resultList = response.data["RESULT"] as List?;

      if (resultList == null || resultList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final status = resultList[0]["status"];
      final message = resultList[0]["message"];

      if (status != "S") {
        return {
          "success": false,
          "message": message ?? "Delete failed",
        };
      }

      return {
        "success": true,
        "message": message ?? "Content deleted",
      };
    } catch (e) {
      dev.log("❌ ERROR (deleteContent): $e");
      return {"success": false, "message": "Network error"};
    }
  }
}