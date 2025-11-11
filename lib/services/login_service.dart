import 'dart:developer' as dev;
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../constants/api_constants.dart';
import 'device_info.dart';
import 'fcm_service.dart';
import '../services/api_services.dart';
import '../services/device_info.dart';
import '../services/fcm_service.dart';
import '../services/login_service.dart';
import '../services/api_services.dart';
import '../constants/api_constants.dart';
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

  /// ✅ LOGIN API
  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    try {
      // ✅ get FCM token
      final fcmToken = await FCMService.getFCMToken();

      // ✅ get device info from your device_info.dart
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

      final response = await _dio.post(
        ApiConstants.login,
        data: payload,
      );

      dev.log("📥 Login response: ${response.data}");

      if (response.statusCode != 200) {
        return {
          "success": false,
          "message": "Server error: ${response.statusCode}"
        };
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final statusFlag = statusList[0]["status"];
      final statusMessage = statusList[0]["message"] ?? "Unknown";

      // ❌ Login failed
      if (statusFlag != "S") {
        return {"success": false, "message": statusMessage};
      }

      // ✅ Login success → get RESULT
      final resultList = response.data["RESULT"] as List?;
      if (resultList == null || resultList.isEmpty) {
        return {"success": false, "message": "Invalid result format"};
      }

      final user = resultList[0];

      // ✅ Save user session
      await UserSessionHelper.saveUserId(user["user_id"]);
      await UserSessionHelper.saveUserName(user["full_name"]);
      await UserSessionHelper.saveEmail(user["email"]);
      await UserSessionHelper.savePhone(user["phone"]);
      await UserSessionHelper.saveIsLoggedIn(true);

      return {
        "success": true,
        "message": statusMessage,
        "user": user,
      };
    } on DioException catch (e) {
      dev.log("❌ DioException in login: ${e.message}");
      return {
        "success": false,
        "message": e.response?.data?["message"] ?? "Network error"
      };
    } catch (e) {
      dev.log("⚠️ Unexpected error in login: $e");
      return {"success": false, "message": "Exception: $e"};
    }
  }
}
