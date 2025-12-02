// lib/services/profile_service.dart
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
            validateStatus: (code) => code != null && code < 500,
          ),
        ) {
    _dio.interceptors.add(
      LogInterceptor(
        request: true,
        responseBody: true,
        requestBody: true,
      ),
    );
  }

  /// 🔍 Get Profile API
  Future<Map<String, dynamic>> getProfile() async {
    try {
      final int? userId = await UserSessionHelper.getUserId();

      if (userId == null || userId == 0) {
        return {"success": false, "message": "User ID missing"};
      }

      final payload = {
        "user_id": userId,
        "stage": "dev",
      };

      dev.log("📤 Calling profile API: ${ApiConstants.profile}");
      final response = await _dio.post(ApiConstants.profile, data: payload);

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error"};
      }

      final statusList = response.data["STATUS"] as List?;
      if (statusList == null || statusList.isEmpty) {
        return {"success": false, "message": "Invalid response format"};
      }

      final statusFlag = statusList[0]["status"] ?? "F";
      final message = statusList[0]["message"] ?? "";

      if (statusFlag != "S") {
        return {"success": false, "message": message};
      }

      final resultList = response.data["RESULT"] as List?;
      if (resultList == null || resultList.isEmpty) {
        return {"success": false, "message": "No profile data"};
      }

      final profile = Map<String, dynamic>.from(resultList[0]);

      /// 🧠 Save enterprise & other profile fields if available
      try {
        // store enterprise_id
        final enterpriseId = profile["enterprise_id"];
        if (enterpriseId != null) {
          await UserSessionHelper.saveEnterpriseId(enterpriseId is int
              ? enterpriseId
              : int.tryParse("$enterpriseId") ?? 0);
        }

        // store profile image if needed: profile["profile_picture"]
      } catch (e) {
        dev.log("⚠️ Profile save error: $e");
      }

      return {"success": true, "message": message, "profile": profile};

    } on DioException catch (e) {
      dev.log("❌ Dio Error: ${e.message}");
      return {"success": false, "message": "Network error"};
    } catch (e) {
      dev.log("⚠️ Exception: $e");
      return {"success": false, "message": "Exception: $e"};
    }
  }
}