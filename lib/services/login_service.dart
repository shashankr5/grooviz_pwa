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
              'x-api-key': ApiConstants.apiKey,
            },
            validateStatus: (code) => code != null && code < 500,
          ),
        ) {
    _dio.interceptors.add(
      LogInterceptor(
        request: true,
        requestHeader: true,
        requestBody: true,
        responseHeader: false,
        responseBody: true,
        error: true,
      ),
    );
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    try {
      final fcmToken = await FCMService.getFCMToken();
      final deviceInfo = await DeviceInfo.getDeviceInfo();

      final payload = {
        "username": username,
        "password": password,
        "fcm_token": fcmToken ?? "",
        "installation_id": deviceInfo["installation_id"],
        "device_identifier": deviceInfo["device_identifier"],
        "device_type": deviceInfo["device_type"],
        "device_model": deviceInfo["device_model"],
        "os_version": deviceInfo["os_version"],
        "app_version": deviceInfo["app_version"],
        "stage": "dev",
      };

      dev.log("📤 Login payload: ${jsonEncode(payload)}");
      final response = await _dio.post(ApiConstants.login, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error ${response.statusCode}"};
      }

      final statusList = response.data["STATUS"] as List?;
      final resultList = response.data["RESULT"] as List?;

      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid response"};
      }

      final statusFlag = statusList[0]["status"] ?? "F";
      final statusMessage = statusList[0]["message"] ?? "Unknown";

      if (statusFlag != "S") {
        return {"success": false, "message": statusMessage};
      }

      if (resultList == null || resultList.isEmpty) {
        return {"success": false, "message": "No user data returned"};
      }

      final user = Map<String, dynamic>.from(resultList[0]);

      /// Save session safely
      final userId = user["user_id"];
      await UserSessionHelper.saveUserId(userId is int ? userId : int.tryParse("$userId") ?? 0);

      await UserSessionHelper.saveUserName(user["full_name"]?.toString() ?? "");
      await UserSessionHelper.saveEmail(user["email"]?.toString() ?? "");
      await UserSessionHelper.savePhone(user["phone"]?.toString() ?? "");
      await UserSessionHelper.saveIsLoggedIn(true);

      return {
        "success": true,
        "message": statusMessage,
        "user": user,
        "user_id": userId,
      };

    } on DioException catch (e) {
      dev.log("❌ Dio error: ${e.message}");
      return {"success": false, "message": "Network error"};
    } catch (e) {
      dev.log("⚠️ Exception: $e");
      return {"success": false, "message": "Error: $e"};
    }
  }
}
