// rooms_service.dart
import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'dart:convert';
import '../utils/user_session_helper.dart';
import '../utils/error_handler.dart';
import '../constants/api_constants.dart';
import '../constants/api_timeouts.dart';
import '../constants/app_config.dart';

class RoomsService {
  final Dio _dio;

  RoomsService()
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
        "stage": AppConfig.stage,
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
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }

  /// MAP API → UI FRIENDLY FORMAT
  static List<Map<String, dynamic>> _mapRooms(List raw) {
    return raw.map<Map<String, dynamic>>((room) {
      final m = Map<String, dynamic>.from(room);

      // Parse devices JSON string safely
      List devices = [];

      final rawDevices = m["devices"];

      if (rawDevices != null && rawDevices.toString().isNotEmpty) {
        try {
          if (rawDevices is String) {
            devices = jsonDecode(rawDevices);
          } else if (rawDevices is List) {
            devices = rawDevices;
          }
        } catch (e) {
          dev.log("Device decode error: $e");
        }
      }

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
  
  /// UPLOAD / UPDATE GUEST PHOTO TO DEVICES 
  Future<Map<String, dynamic>> updateGuestPhoto({
    required String filePath,
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
        "enterprise_id": enterpriseId,
        "device_ids": deviceIds, // ✅ CORRECT (ARRAY)
        "file_path": filePath,
        "stage": AppConfig.stage,
      };

      dev.log("📤 Updating Guest Photo");
      dev.log("Payload: $payload");

      final response = await _dio.post(
        ApiConstants.updateGuestPhoto,
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
        "message": message ?? "Photo updated successfully",
      };
    } catch (e) {
      dev.log("❌ ERROR (updateGuestPhoto): $e");
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }

  /// GET GUEST CONTENTS
  Future<Map<String, dynamic>> getContents() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      final int? enterpriseId = await UserSessionHelper.getEnterpriseId();

      if (userId == null || enterpriseId == null) {
        return {"success": false, "message": "User or Enterprise missing"};
      }

      final payload = {
        "user_id": userId, // ✅ FIX: no toString
        "enterprise_id": enterpriseId.toString(),
        "stage": AppConfig.stage,
      };

      dev.log("📤 Fetching Guest Contents");
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
        return {"success": false, "message": "No data returned"};
      }

      final contents = resultList.map<Map<String, dynamic>>((item) {
        final m = Map<String, dynamic>.from(item);

        /// 🔹 decode rooms JSON string safely
        List rooms = [];
        try {
          if (m["rooms"] != null && m["rooms"].toString().isNotEmpty) {
            rooms = jsonDecode(m["rooms"]);
          }
        } catch (_) {}

        return {
          "guestId": m["guest_id"],
          "fullName": m["full_name"] ?? "",
          "guestPhoto": m["guest_photo"] ?? "",

          /// rooms
          "rooms": rooms,
          "roomNumbers":
              rooms.map((r) => r["room_number"]).join(", "),
          "roomCount": rooms.length,

          /// optional raw
          "raw": m,
        };
      }).toList();

      return {
        "success": true,
        "contents": contents,
      };
    } catch (e) {
      dev.log("❌ ERROR (getContents): $e");
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
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
        "stage": AppConfig.stage,
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
      return {"success": false, "message": ErrorHandler.friendlyMessage(e)};
    }
  }
}