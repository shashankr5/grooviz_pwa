// services/checkout_service.dart
import 'dart:developer' as dev;
import 'dart:convert';
import 'package:dio/dio.dart';

import '../constants/api_constants.dart';
import '../constants/api_timeouts.dart';
import '../utils/user_session_helper.dart';

class CheckoutService {
  final Dio _dio;

  CheckoutService()
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
        requestHeader: true,
        requestBody: true,
        responseBody: true,
        error: true,
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _normalizeList(dynamic raw) {
    if (raw is List) return List<Map<String, dynamic>>.from(raw);
    if (raw is Map) return [Map<String, dynamic>.from(raw)];
    return [];
  }

  // ── GET GUEST CHECKOUT REPORT ─────────────────────────────────────────────

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
        return {"success": false, "message": "Server error ${response.statusCode}"};
      }

      final statusList = _normalizeList(response.data["STATUS"]);
      final resultList = _normalizeList(response.data["RESULT"]);

      if (statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final statusFlag = statusList[0]["status"]?.toString() ?? "F";
      final message = statusList[0]["message"]?.toString() ?? "Unknown error";

      if (statusFlag != "S") {
        return {"success": false, "message": message};
      }

      final guests = resultList.map((g) {
        return {
          "guestId": g["guest_id"],
          "guestName": g["guest_name"],
          // guard null room_number
          "roomNumber": g["room_number"] ?? '—',
          "contact": g["phone_number"] ?? '',
          "email": g["email"] ?? '',
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
      return {"success": false, "message": "Network error"};
    } catch (e) {
      dev.log("⚠️ Exception: $e");
      return {"success": false, "message": "Error: $e"};
    }
  }

  // ── GET GUEST BILL ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getGuestBill({required int guestId}) async {
    try {
      final userId = await UserSessionHelper.getUserId();

      final payload = {
        "user_id": userId,
        "guest_id": guestId,
        "stage": "dev",
      };

      dev.log("📤 Guest Bill Payload: ${jsonEncode(payload)}");

      // Uses the same base URL as all other endpoints — just swap the path.
      // Match the naming convention from your other API constants, e.g.:
      //   ApiConstants.guestBill = 'ScreenSync_get_guest_bill_mobile'
      // If you haven't added that constant yet, replace the line below with
      // the literal string: 'ScreenSync_get_guest_bill_mobile'
      final response = await _dio.post(
        ApiConstants.guestBill,
        data: payload,
      );

      if (response.statusCode != 200) {
        return {"success": false, "message": "Server error ${response.statusCode}"};
      }

      final statusList = _normalizeList(response.data["STATUS"]);
      final resultList = _normalizeList(response.data["RESULT"]);

      if (statusList.isEmpty) {
        return {"success": false, "message": "Invalid server response"};
      }

      final statusFlag = statusList[0]["status"]?.toString() ?? "F";
      final message = statusList[0]["message"]?.toString() ?? "Unknown error";

      if (statusFlag != "S") {
        return {"success": false, "message": message};
      }

      // The SP returns items as a JSON_ARRAYAGG — Dio may parse it as a List
      // already, or it might come as a JSON string. Handle both.
      final orders = resultList.map((o) {
        dynamic items = o["items"];
        if (items is String) {
          try {
            items = jsonDecode(items);
          } catch (_) {
            items = [];
          }
        }
        return <String, dynamic>{
          ...o,
          "items": (items is List) ? items : [],
        };
      }).toList();

      return {
        "success": true,
        "message": message,
        "orders": orders,
      };
    } on DioException catch (e) {
      dev.log("❌ Dio error (bill): ${e.message}");
      return {"success": false, "message": "Network error"};
    } catch (e) {
      dev.log("⚠️ Exception (bill): $e");
      return {"success": false, "message": "Error: $e"};
    }
  }
}