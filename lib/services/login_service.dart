// lib/services/login_service.dart
import 'dart:developer' as dev;
import 'dart:convert';
import 'package:dio/dio.dart';

import '../constants/api_constants.dart';
import 'device_info.dart';
import 'fcm_service.dart';
import '../utils/user_session_helper.dart';

class LoginService {
  final Dio _dio;

  LoginService()
      : _dio = Dio(
          BaseOptions(
            baseUrl: ApiConstants.baseUrl,
            connectTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 60),
            sendTimeout: const Duration(seconds: 60),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': 'sa9F4GyTT45OImNkKjaHu6bsJbk8UWmZfKdzmeoc',
            },
            validateStatus: (status) => status != null && status < 500,
          ),
        ) {
    _dio.interceptors.add(LogInterceptor(
      request: true,
      requestHeader: true,
      requestBody: true,
      responseHeader: true,
      responseBody: true,
      error: true,
    ));
  }

  /// LOGIN API
  /// Returns: { success: bool, message: String, user: Map<String,dynamic>? }
  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    try {
      final fcmToken = await FCMService.getFCMToken();
      final info = await DeviceInfo.getDeviceInfo();

      final payload = {
        "username": username,
        "password": password,
        "fcm_token": fcmToken ?? "",
        "installation_id": info['installation_id'],
        "device_identifier": info['device_identifier'],
        "device_type": info['device_type'],
        "device_model": info['device_model'],
        "os_version": info['os_version'],
        "app_version": info['app_version'],
        "stage": 'dev',
      };

      dev.log("📤 Calling login: ${ApiConstants.login}");
      dev.log("Payload: ${jsonEncode(payload)}"); 

      final response = await _dio.post(ApiConstants.login, data: payload);
      dev.log("📥 Login response: ${response.data}");

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error: ${response.statusCode}"};
      }

      // Read STATUS
      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final statusFlag = statusList[0]["status"] ?? "F";
      final statusMessage = statusList[0]["message"] ?? "Unknown";

      if (statusFlag != "S") {
        return {"success": false, "message": statusMessage};
      }

      // Read RESULT (user info)
      final resultList = response.data["RESULT"] as List?;
      if (resultList == null || resultList.isEmpty) {
        return {"success": false, "message": "No user data returned"};
      }

      final user = Map<String, dynamic>.from(resultList[0]);

      // Save user info
      try {
        final uid = user["user_id"]; 
        if (uid is int) {         
          await UserSessionHelper.saveUserId(uid);      
        } else if (uid is String) {
          await UserSessionHelper.saveUserId(int.tryParse(uid) ?? 0);
        }

        await UserSessionHelper.saveUserName(user["full_name"]?.toString() ?? "");
        await UserSessionHelper.saveEmail(user["email"]?.toString() ?? "");
        await UserSessionHelper.savePhone(user["phone"]?.toString() ?? "");
        await UserSessionHelper.saveIsLoggedIn(true);
    
        // extra verification
        final prefsTest = await UserSessionHelper.getUserId(); 
        
      } catch (e) {
        dev.log("⚠️ Error saving user session: $e");
      }

      return {"success": true, "message": statusMessage, "user": user};

    } on DioException catch (e) {
      dev.log("❌ DioException: ${e.message}");

      final data = e.response?.data;

      if (data != null) {
        if (data["STATUS"] != null) {
          return {
            "success": data["STATUS"][0]["status"] == "S",
            "message": data["STATUS"][0]["message"],
          };
        }
        if (data["RESULT"] != null) {
          return {
            "success": data["RESULT"][0]["status"] == "S",
            "message": data["RESULT"][0]["message"],
          };
        }
      }

      return {"success": false, "message": "Network error"};
    } catch (e) {
      dev.log("⚠️ Unexpected error: $e");
      return {"success": false, "message": "Exception: $e"};
    }
  }
}

