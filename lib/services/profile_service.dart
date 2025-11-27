// lib/services/profile_service.dart

import 'dart:convert';
import 'dart:developer' as dev;

import 'package:dio/dio.dart';

import '../constants/api_constants.dart';
import '../utils/user_session_helper.dart';

class ProfileService {
  final Dio _dio;

  ProfileService()
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
            validateStatus: (status) => status != null && status < 500,
          ),
        ) {
    _dio.interceptors.add(
      LogInterceptor(
        request: true,
        requestHeader: true,
        requestBody: true,
        responseHeader: true,
        responseBody: true,
        error: true,
      ),
    );
  }

  /// Fetch profile for the currently-saved user_id.
  /// Returns a Map:
  /// {
  ///   "success": bool,
  ///   "message": String,
  ///   "profile": Map<String,dynamic>?  // present when success == true
  /// }
  
  Future<Map<String, dynamic>> getProfile() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID not found in session"};
      }

      final payload = {
        "user_id": userId,
        "stage": "dev",
      };

      dev.log("📤 Calling profile: ${ApiConstants.profile}");
      dev.log("Payload: ${jsonEncode(payload)}");

      final response = await _dio.post(ApiConstants.profile, data: payload);
      dev.log("📥 Profile response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error: ${response.statusCode}"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final statusFlag = statusList[0]["status"] ?? "F";
      final statusMessage = statusList[0]["message"] ?? "Unknown";

      if (statusFlag != "S") {
        return {"success": false, "message": statusMessage};
      }

      final resultList = response.data["RESULT"] as List?;
      if (resultList == null || resultList.isEmpty) {
        return {"success": false, "message": "No profile data returned"};
      }

      final raw = Map<String, dynamic>.from(resultList[0]);

      // Normalize keys (your stored proc returns e.g. phone_number)
      final profile = <String, dynamic>{
        "user_id": raw["user_id"],
        "name": raw["name"] ?? raw["full_name"] ?? "",
        "designation": raw["designation"] ?? "",
        "email": raw["email"] ?? "",
        "phone_number": raw["phone_number"] ?? raw["phone"] ?? "",
        "user_type": raw["user_type"],
        "status": raw["status"],
        "is_verified": raw["is_verified"],
        "enterprise_id": raw["enterprise_id"],
        "departments": raw["departments"], // may be JSON string or JSON array
      };

      // Optionally save basic fields into session for quick access
      try {
        if (profile["name"] != null && profile["name"].toString().isNotEmpty) {
          await UserSessionHelper.saveUserName(profile["name"].toString());
        }
        if (profile["email"] != null && profile["email"].toString().isNotEmpty) {
          await UserSessionHelper.saveEmail(profile["email"].toString());
        }
        if (profile["phone_number"] != null && profile["phone_number"].toString().isNotEmpty) {
          await UserSessionHelper.savePhone(profile["phone_number"].toString());
        }
        if (profile["enterprise_id"] != null) {
          await UserSessionHelper.saveEnterpriseId(profile["enterprise_id"]);
        }
      } catch (e) {
        dev.log("⚠️ Error saving profile to session: $e");
      }

      return {"success": true, "message": statusMessage, "profile": profile};
    } on DioException catch (e) {
      dev.log("❌ DioException (getProfile): ${e.message}");
      final data = e.response?.data;

      if (data != null) {
        if (data["STATUS"] != null && (data["STATUS"] as List).isNotEmpty) {
          return {
            "success": (data["STATUS"][0]["status"] == "S"),
            "message": data["STATUS"][0]["message"] ?? "Error",
          };
        }
      }
      return {"success": false, "message": "Network error"};
    } catch (e) {
      dev.log("⚠️ Unexpected error (getProfile): $e");
      return {"success": false, "message": "Exception: $e"};
    }
  }
}
