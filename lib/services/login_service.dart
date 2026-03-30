// login_service.dart
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

  /// LOGIN API

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    try {
      final fcmToken = await FCMService.getFCMToken(
        timeout: const Duration(seconds: 20),
      );

      if (fcmToken == null || fcmToken.isEmpty) {
        return {
          "success": false,
          "message": "Push registration is still in progress. Please try again in a moment."
        };
      }
      final deviceInfo = await DeviceInfo.getDeviceInfo();

      final payload = {
        "username": username,
        "password": password,
        "fcm_token": fcmToken,
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

      final statusRaw = response.data["STATUS"];
      final resultRaw = response.data["RESULT"];

      List<Map<String, dynamic>> statusList = [];
      List<Map<String, dynamic>> resultList = [];

      if (statusRaw is List) {
        statusList = List<Map<String, dynamic>>.from(statusRaw);
      } else if (statusRaw is Map) {
        statusList = [Map<String, dynamic>.from(statusRaw)];
      }

      if (resultRaw is List) {
        resultList = List<Map<String, dynamic>>.from(resultRaw);
      } else if (resultRaw is Map) {
        resultList = [Map<String, dynamic>.from(resultRaw)];
      }

      if (statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final statusFlag = statusList[0]["status"]?.toString() ?? "F";
      final statusMessage = statusList[0]["message"]?.toString() ?? "Unknown error";

      if (statusFlag != "S") {
        return {"success": false, "message": statusMessage};
      }

      if (resultList.isEmpty) {
        return {"success": false, "message": "No user data returned"};
      }

      final user = resultList[0];

      final userIdRaw = user["user_id"];
      final userId =
      userIdRaw is int ? userIdRaw : int.tryParse(userIdRaw.toString()) ?? 0;

      await UserSessionHelper.saveUserId(userId);
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

  /// SEND OTP

  Future<Map<String, dynamic>> sendOtp({
    required String mobile,
  }) async {
    try {
      final payload = {
        "mobile_no": mobile,
        "action": "SEND_OTP",
        "stage": "dev",
      };

      dev.log("📤 Send OTP Payload: $payload");
      final response = await _dio.post(ApiConstants.sendOtp, data: payload);

      final data = response.data;
      final statusList = data["STATUS"];
      if (statusList != null && statusList is List && statusList.isNotEmpty) {
        final status = statusList[0];
        final success = status["status"] == "S";
        final otp = status["otp_demo_only"] ?? "";
        final message = success ? "OTP sent successfully" : status["message"] ?? "Failed to send OTP";

        return {
          "success": success,
          "message": message,
          "otp": otp,
        };
      } else {
        return {"success": false, "message": "Invalid server response"};
      }
    } catch (e) {
      return _handleError(e);
    }
  }
  /// VERIFY OTP

  Future<Map<String, dynamic>> verifyOtp({
    required String mobile,
    required String otp,
  }) async {
    try {
      final payload = {
        "mobile_no": mobile,
        "otp": otp,
        "action": "VERIFY_OTP",
        "stage": "dev",
      };

      dev.log("📤 Verify OTP Payload: $payload");
      final response = await _dio.post(ApiConstants.verifyOtp, data: payload);

      return _parseResponse(response);
    } catch (e) {
      return _handleError(e);
    }
  }

  /// RESET PASSWORD

  Future<Map<String, dynamic>> resetPassword({
    required String mobile,
    required String newPassword,
  }) async {
    try {
      final payload = {
        "mobile_no": mobile,
        "new_pass": newPassword,
        "action": "RESET_PASSWORD",
        "stage": "dev",
      };

      dev.log("📤 Reset Password Payload: $payload");
      final response = await _dio.post(ApiConstants.resetPassword, data: payload);

      // ✅ Use _parseResponse, but fallback message if missing
      return _parseResponse(response);
    } catch (e) {
      return _handleError(e);
    }
  }
  /// RESPONSE NORMALIZER

  Map<String, dynamic> _parseResponse(Response response) {
    if (response.statusCode != 200) {
      return {"success": false, "message": "Server error"};
    }

    final statusRaw = response.data["STATUS"];
    final resultRaw = response.data["RESULT"];

    List<Map<String, dynamic>> statusList = [];
    List<Map<String, dynamic>> resultList = [];

    if (statusRaw is List) {
      statusList = List<Map<String, dynamic>>.from(statusRaw);
    } else if (statusRaw is Map) {
      statusList = [Map<String, dynamic>.from(statusRaw)];
    }

    if (resultRaw is List) {
      resultList = List<Map<String, dynamic>>.from(resultRaw);
    } else if (resultRaw is Map) {
      resultList = [Map<String, dynamic>.from(resultRaw)];
    }

    if (statusList.isEmpty) {
      return {"success": false, "message": "Invalid server response"};
    }

    final statusFlag = statusList[0]["status"]?.toString() ?? "F";

    // ✅ Use message if exists, else fallback to otp_demo_only or generic text
    final message = statusList[0]["message"]?.toString() ??
        statusList[0]["otp_demo_only"]?.toString() ??
        "Operation completed";

    return {
      "success": statusFlag == "S",
      "message": message,
      "result": resultList.isNotEmpty ? resultList[0] : null,
    };
  }
  /// ERROR HANDLER

  Map<String, dynamic> _handleError(dynamic error) {
    dev.log("❌ Error: $error");
    return {"success": false, "message": "Something went wrong"};
  }
}
