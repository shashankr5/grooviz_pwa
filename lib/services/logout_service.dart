import 'dart:developer' as dev;
import 'package:dio/dio.dart';

import '../constants/api_constants.dart';
import '../constants/app_config.dart';
import '../utils/user_session_helper.dart';
import '../utils/error_handler.dart';
import '../services/fcm_service.dart';
import '../services/websocket_service.dart';
import '../services/midnight_notifier.dart';
import 'device_info.dart';

class LogoutService {
  final Dio _dio;

  LogoutService()
      : _dio = Dio(
          BaseOptions(
            baseUrl: ApiConstants.baseUrl,
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': ApiConstants.apiKey,
            },
            connectTimeout: const Duration(seconds: 5),
            sendTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 8),
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

  /// Stops all alerts, disconnects WebSocket, and clears local session.
  /// Called in every logout path — success, error, and fallback.
  Future<void> _cleanupAndClearSession() async {
    try {
      await FCMService.deregisterToken();
    } catch (_) {}
    try {
      WebSocketService().disconnect();
    } catch (_) {}
    try {
      MidnightNotifier.instance.stop();
    } catch (_) {}
    try {
      await UserSessionHelper.clearSession();
    } catch (_) {}
  }

  Future<Map<String, dynamic>> logout() async {
    Map<String, dynamic> result = {
      "success": true,
      "message": "Logged out locally",
    };

    try {
      final userId = await UserSessionHelper.getUserId();
      final info = await DeviceInfo.getDeviceInfo()
          .timeout(const Duration(seconds: 5));

      if (userId == null || userId == 0) {
        result = {"success": true, "message": "Logged out locally (no user id stored)"};
      } else {
        final payload = {
          "user_id": userId,
          "installation_id": info["installation_id"],
          "stage": AppConfig.stage
        };

        final response = await _dio.post(ApiConstants.logout, data: payload);
        dev.log("Logout response: ${response.data}");

        if (response.statusCode != 200) {
          result = {"success": true, "message": "Logged out locally (server error ${response.statusCode})"};
        } else {
          final resultList = response.data is Map
              ? response.data["RESULT"] as List?
              : null;
          final status = resultList != null && resultList.isNotEmpty
              ? resultList[0]["status"]?.toString() ?? "F"
              : "S";
          final message = resultList != null && resultList.isNotEmpty
              ? resultList[0]["message"]?.toString() ?? "Logged out"
              : "Logged out";

          result = {
            // The user requested a local logout. Even if the server rejects
            // or has already expired the session, local auth must be cleared.
            "success": true,
            "message": status == "S" ||
                    message.toLowerCase().contains("no active session")
                ? message
                : "Logged out locally",
          };
        }
      }

    } on DioException catch (e) {
      dev.log("❌ DioException in logout: ${e.message}");
      result = {"success": true, "message": "Logged out locally (network error)"};

    } catch (e) {
      result = {"success": true, "message": "Logged out locally"};
    } finally {
      // Logout must never leave the blocking spinner on screen because a
      // backend or platform service is unavailable.
      await _cleanupAndClearSession();
    }

    return result;
  }
}