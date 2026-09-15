// login_service.dart
import 'dart:developer' as dev;
import 'dart:convert';
import 'package:dio/dio.dart';

import '../constants/api_constants.dart';
import '../constants/api_timeouts.dart';
import '../constants/app_config.dart';
import 'device_info.dart';
import '../utils/user_session_helper.dart';
import '../utils/error_handler.dart';
import 'fcm_service.dart';

class LoginService {
  final Dio _dio;

  LoginService()
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
        responseHeader: false,
        responseBody: true,
        error: true,
      ),
    );
  }

  // ─── LOGIN ────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    try {
      await UserSessionHelper.clearSession();

      // ── Build payload ────────────────────────────────────────────────────
      final deviceInfo = await DeviceInfo.getDeviceInfo();
      String fcmToken = await FCMService.getToken();
      if (fcmToken.trim().isEmpty) {
        fcmToken = 'fallback_${deviceInfo['installation_id'] ?? 'device'}';
      }

      final payload = {
        'username': username,
        'password': password,
        'fcm_token': fcmToken,
        'installation_id': deviceInfo['installation_id'],
        'device_identifier': deviceInfo['device_identifier'],
        'device_type': deviceInfo['device_type'],
        'device_model': deviceInfo['device_model'],
        'os_version': deviceInfo['os_version'],
        'app_version': deviceInfo['app_version'],
        'stage': AppConfig.stage,
      };

      dev.log('📤 Login payload: ${jsonEncode(payload)}');

      // ── API Call ─────────────────────────────────────────────────────────
      final response = await _dio.post(ApiConstants.login, data: payload);

      if (response.statusCode != 200) {
        return {
          'success': false,
          'message': 'Server error ${response.statusCode}',
        };
      }

      // ── Parse response ───────────────────────────────────────────────────
      final statusRaw = response.data['STATUS'];
      final resultRaw = response.data['RESULT'];

      final statusList = _toList(statusRaw);
      final resultList = _toList(resultRaw);

      if (statusList.isEmpty) {
        return {'success': false, 'message': 'Invalid server response'};
      }

      final statusFlag = statusList[0]['status']?.toString() ?? 'F';
      final statusMessage =
          statusList[0]['message']?.toString() ?? 'Unknown error';

      if (statusFlag != 'S') {
        return {'success': false, 'message': statusMessage};
      }

      if (resultList.isEmpty) {
        return {'success': false, 'message': 'No user data returned'};
      }

      final user = resultList[0];

      final userIdRaw = user['user_id'];
      final userId =
          userIdRaw is int ? userIdRaw : int.tryParse(userIdRaw.toString()) ?? 0;

      await UserSessionHelper.saveUserId(userId);
      await UserSessionHelper.saveUserName(user['full_name']?.toString() ?? '');
      await UserSessionHelper.saveEmail(user['email']?.toString() ?? '');
      await UserSessionHelper.savePhone(user['phone']?.toString() ?? '');
      if (user['enterprise_id'] != null) {
        final enterpriseIdRaw = user['enterprise_id'];
        final enterpriseId = enterpriseIdRaw is int
            ? enterpriseIdRaw
            : int.tryParse(enterpriseIdRaw.toString()) ?? 0;
        await UserSessionHelper.saveEnterpriseId(enterpriseId);
      }
      if (user['enterprise_name'] != null && user['enterprise_name'].toString().trim().isNotEmpty) {
        await UserSessionHelper.saveEnterpriseName(user['enterprise_name'].toString().trim());
      }
      await UserSessionHelper.saveIsLoggedIn(true);

      // ── Save rush-hour / F&B config returned by login_mobile SP ─────────
      // These fields come directly from enterprise_food_service_rule via the SP.
      try {
        final rushActive = _readInt(user['current_rush_hour']) ?? 0;
        final maxTap     = _readInt(user['max_tap_count'])     ?? 0;
        final tapMin     = _readInt(user['tap_count_min'])     ?? 0;
        final rushStatus = (user['rush_hour_status'] ?? 'INACTIVE').toString();
        final rawRushData = user['rush_hour_data'];
        final rushData = rawRushData is Map || rawRushData is List
            ? jsonEncode(rawRushData)
            : rawRushData?.toString() ?? '';
        await UserSessionHelper.saveRushHourConfig(
          rushHourActive: rushActive,
          maxTapCount:    maxTap,
          tapCountMin:    tapMin,
          rushHourStatus: rushStatus,
          rushHourData:   rushData,
        );
        dev.log('✅ Rush-hour config saved: active=$rushActive, maxTap=$maxTap, tapMin=$tapMin');
      } catch (e) {
        dev.log('⚠️ Could not save rush-hour config at login: $e');
      }

      // ── Fetch dept + escalation rule (replaces old role/departments) ─────
      // get_user_dept_details_mobile returns one row per dept the user has access to.
      // We look for the first food department row to seed F&B-related session keys.
      try {
        final deptResponse = await _dio.post(
          ApiConstants.userDeptDetails,
          data: {'user_id': userId, 'stage': AppConfig.stage},
        );
        final deptStatus = _toList(deptResponse.data['STATUS']);
        final deptResult = _toList(deptResponse.data['RESULT']);

        if (deptStatus.isNotEmpty && deptStatus[0]['status'] == 'S' && deptResult.isNotEmpty) {
          // Save all dept names as the departments list
          final deptNames = deptResult
              .map((r) => (r['department_name'] ?? '').toString().trim())
              .where((n) => n.isNotEmpty)
              .toList();
          if (deptNames.isNotEmpty) {
            await UserSessionHelper.saveDepartments(deptNames);
            dev.log('✅ Departments saved from dept details: $deptNames');
          }

          // Save role from first row
          final firstRow = deptResult.first;
          final roleFromDept = firstRow['department_name']?.toString().trim() ?? '';
          if (roleFromDept.isNotEmpty) {
            await UserSessionHelper.saveRole(roleFromDept);
          }

          // Find food dept row for F&B seeding
          final foodRow = deptResult.firstWhere(
            (r) => (r['department_type'] ?? '').toString().toLowerCase() == 'food',
            orElse: () => deptResult.first,
          );

          await UserSessionHelper.saveDeptDetails(
            foodDeptId:       _readInt(foodRow['department_id'])        ?? 0,
            completionMinutes: _readInt(foodRow['completion_minutes'])   ?? 30,
            supervisorUserId:  _readInt(foodRow['supervisor_user_id'])   ?? 0,
            supervisorName:    (foodRow['supervisor_user_name'] ?? '').toString(),
            supervisorDeptId:  _readInt(foodRow['supervisor_dept_id'])   ?? 0,
          );
          dev.log('✅ Dept details saved at login');
        }
      } catch (e) {
        dev.log('⚠️ Could not fetch dept details at login: $e');
        // Non-fatal — app can continue; dept details will be re-fetched when needed.
      }

      return {
        'success': true,
        'message': statusMessage,
        'user':    user,
        'user_id': userId,
      };
    } on DioException catch (e) {
      dev.log('❌ Dio error: ${e.message}');
      return {'success': false, 'message': ErrorHandler.friendlyMessage(e)};
    } catch (e) {
      dev.log('⚠️ Exception: $e');
      return {'success': false, 'message': ErrorHandler.friendlyMessage(e)};
    }
  }

  // ─── SEND OTP ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> sendOtp({required String mobile}) async {
    try {
      final payload = {
        "mobile_no": mobile,
        "stage":     AppConfig.stage,
      };

      dev.log('📤 Send OTP payload: $payload');
      final response = await _dio.post(ApiConstants.sendOtp, data: payload);
      return _parseResponse(response);
    } catch (e) {
      return _handleError(e);
    }
  }

  // ─── VERIFY OTP ───────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> verifyOtp({
    required String mobile,
    required String otp,
  }) async {
    try {
      final payload = {
        'mobile_no': mobile,
        'otp': otp,
        'action': 'VERIFY_OTP',
        'stage': AppConfig.stage,
      };

      dev.log('📤 Verify OTP Payload: $payload');
      final response = await _dio.post(ApiConstants.verifyOtp, data: payload);
      return _parseResponse(response);
    } catch (e) {
      return _handleError(e);
    }
  }

  // ─── RESET PASSWORD ───────────────────────────────────────────────────────

  Future<Map<String, dynamic>> resetPassword({
    required String mobile,
    required String newPassword,
  }) async {
    try {
      final payload = {
        'mobile_no': mobile,
        'new_pass': newPassword,
        'action': 'RESET_PASSWORD',
        'stage': AppConfig.stage,
      };

      dev.log('📤 Reset Password Payload: $payload');
      final response =
          await _dio.post(ApiConstants.resetPassword, data: payload);
      return _parseResponse(response);
    } catch (e) {
      return _handleError(e);
    }
  }

  // ─── HELPERS ─────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _toList(dynamic raw) {
    if (raw is List) return List<Map<String, dynamic>>.from(raw);
    if (raw is Map) return [Map<String, dynamic>.from(raw)];
    return [];
  }

  Map<String, dynamic> _parseResponse(Response response) {
    if (response.statusCode != 200) {
      return {'success': false, 'message': 'Server error'};
    }

    final data = response.data;

    // ✅ CASE 1: OTP APIs (RESULT only)
    if (data["RESULT"] != null && data["STATUS"] == null) {
      final result = data["RESULT"];

      return {
        'success': result["status"] == "S",
        'message': result["message"] ?? "Operation completed",
        'result': result,
      };
    }

    // ✅ CASE 2: Normal APIs (STATUS + RESULT)
    final statusList = _toList(data['STATUS']);
    final resultList = _toList(data['RESULT']);

    if (statusList.isEmpty) {
      return {'success': false, 'message': 'Invalid server response'};
    }

    final statusFlag = statusList[0]['status']?.toString() ?? 'F';
    final message = statusList[0]['message']?.toString() ?? 'Operation completed';

    return {
      'success': statusFlag == 'S',
      'message': message,
      'result': resultList.isNotEmpty ? resultList[0] : null,
    };
  }

  Map<String, dynamic> _handleError(dynamic error) {
    dev.log('❌ Error: $error');
    return {'success': false, 'message': ErrorHandler.friendlyMessage(error)};
  }

  /// Safe int parser for dynamic values from server response maps.
  static int? _readInt(dynamic value) {
    if (value is int)    return value;
    if (value == null)   return null;
    return int.tryParse(value.toString());
  }
}
