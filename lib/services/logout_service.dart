import 'dart:developer' as dev;
import 'dart:convert';
import 'package:dio/dio.dart';

import '../constants/api_constants.dart';
import '../utils/user_session_helper.dart';
import 'device_info.dart';

class LogoutService {
  final Dio _dio;

  LogoutService()
      : _dio = Dio(
          BaseOptions(
            baseUrl: ApiConstants.baseUrl,
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': 'sa9F4GyTT45OImNkKjaHu6bsJbk8UWmZfKdzmeoc',
            },
            validateStatus: (status) => status != null && status < 500,
          ),
        );

  Future<Map<String, dynamic>> logout() async {
    try {
      final userId = await UserSessionHelper.getUserId();
  
      final info = await DeviceInfo.getDeviceInfo();

      if (userId == null || userId == 0) {
        await UserSessionHelper.clearSession();
        return {"success": true, "message": "Logged out locally (no user id stored)"};
      }

      final payload = {
        "user_id": userId,
        "installation_id": info["installation_id"],
        "stage": "dev"
      };
      // Api Call
      final response = await _dio.post(ApiConstants.logout, data: payload);
      dev.log("📥 Logout response: ${response.data}");

      if (response.statusCode != 200) {
        await UserSessionHelper.clearSession();
        return {"success": true, "message": "Logged out locally (server error ${response.statusCode})"};
      }
      // Normal response
      final resultList = response.data["RESULT"] as List?;
      if (resultList != null && resultList.isNotEmpty) {
        final status = resultList[0]["status"] ?? "F";
        final message = resultList[0]["message"] ?? "";

        if (status == "S") {
          await UserSessionHelper.clearSession();
          return {"success": true, "message": message};
        }

        if (message.toLowerCase().contains("no active session")) {
          await UserSessionHelper.clearSession();
          return {"success": true, "message": "Logged out (no active session)"};
        }

        return {"success": false, "message": message};
      }

      // Invalid server response
      await UserSessionHelper.clearSession();
      return {"success": true, "message": "Logged out locally (invalid response)"};

    } on DioException catch (e) {
      dev.log("❌ DioException in logout: ${e.message}");

      // SQL error handler (same as login)
      if (e.response?.data != null) {
        final data = e.response!.data;

        if (data["message"] != null && data["status"] != null) {
          final isSuccess = data["status"] == "S";
          if (isSuccess || data["message"].toString().toLowerCase().contains("no active session")) {
            await UserSessionHelper.clearSession();
            return {"success": true, "message": data["message"]};
          }
          return {"success": false, "message": data["message"]};
        }

        if (data["RESULT"] != null) {
          final r = data["RESULT"][0];
          final isSuccess = r["status"] == "S";
          final message = r["message"];
          if (isSuccess || message.toLowerCase().contains("no active session")) {
            await UserSessionHelper.clearSession();
            return {"success": true, "message": message};
          }
          return {"success": false, "message": message};
        }
      }

      // Unexpected error → still logout locally
      await UserSessionHelper.clearSession();
      return {"success": true, "message": "Logged out locally (network error)"};

    } catch (e) {
      await UserSessionHelper.clearSession();
      return {"success": false, "message": "Logout failed: $e"};
    }
  }
}
