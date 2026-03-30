// services/checkout_service.dart
import 'dart:developer' as dev;
import 'dart:convert';
import 'package:dio/dio.dart';

import '../constants/api_constants.dart';
import '../utils/user_session_helper.dart';

class CheckoutService {
  final Dio _dio;

  CheckoutService()
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
        responseBody: true,
        error: true,
      ),
    );
  }

  /// 🔥 GET GUEST CHECKOUT REPORT
  Future<Map<String, dynamic>> getGuestCheckoutReport() async {
    try {
      final userId = await UserSessionHelper.getUserId();

      final payload = {
        "user_id": userId,
        "stage": "dev",
      };

      dev.log("📤 Checkout Report Payload: ${jsonEncode(payload)}");

      final response = await _dio.post(
        ApiConstants.checkoutReport,
        data: payload,
      );

      if (response.statusCode != 200) {
        return {
          "success": false,
          "message": "Server error ${response.statusCode}"
        };
      }

      final statusRaw = response.data["STATUS"];
      final resultRaw = response.data["RESULT"];

      List<Map<String, dynamic>> statusList = [];
      List<Map<String, dynamic>> resultList = [];

      /// Normalize STATUS
      if (statusRaw is List) {
        statusList = List<Map<String, dynamic>>.from(statusRaw);
      } else if (statusRaw is Map) {
        statusList = [Map<String, dynamic>.from(statusRaw)];
      }

      /// Normalize RESULT
      if (resultRaw is List) {
        resultList = List<Map<String, dynamic>>.from(resultRaw);
      } else if (resultRaw is Map) {
        resultList = [Map<String, dynamic>.from(resultRaw)];
      }

      if (statusList.isEmpty) {
        return {
          "success": false,
          "message": "Invalid server response"
        };
      }

      final statusFlag = statusList[0]["status"]?.toString() ?? "F";
      final message =
          statusList[0]["message"]?.toString() ?? "Unknown error";

      if (statusFlag != "S") {
        return {
          "success": false,
          "message": message,
        };
      }

      /// 🔥 Map API → UI friendly structure
      final guests = resultList.map((g) {
        return {
          "guestId": g["guest_id"],
          "guestName": g["guest_name"],
          "roomNumber": g["room_number"],
          "contact": g["phone_number"],
          "email": g["email"],
          "checkoutDate": g["checked_out_time"],
          "minutesToCheckout": g["minutes_to_checkout"],
          "checkoutStatus": g["checkout_status"],
          "raw": g,
        };
      }).toList();

      return {
        "success": true,
        "message": message,
        "guests": guests,
      };
    } on DioException catch (e) {
      dev.log("❌ Dio error: ${e.message}");
      return {
        "success": false,
        "message": "Network error"
      };
    } catch (e) {
      dev.log("⚠️ Exception: $e");
      return {
        "success": false,
        "message": "Error: $e"
      };
    }
  }
}