// login_service.dart
import 'dart:developer' as dev;
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;

import '../constants/api_constants.dart';
import '../constants/api_timeouts.dart';
import 'device_info.dart';
import 'fcm_service.dart';
import '../utils/user_session_helper.dart';
import '../utils/error_handler.dart';

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

      // ── FCM Token Acquisition ────────────────────────────────────────────
      //
      // We wait up to 30 seconds. This is the UX-acceptable ceiling:
      //  • On healthy installs: returns instantly from cache (<10ms).
      //  • On fresh reinstall, normal connectivity: GPS recovers in 2-15s.
      //  • On fresh reinstall, poor connectivity: may approach the 30s limit.
      //
      // The FCMService.statusStream lets the login screen show a progress
      // message ("Preparing secure connection...") during acquisition so the
      // user knows something is happening — not a frozen screen.
      //
      // If 30s elapses and GPS has not recovered, we return a clear,
      // actionable error. The FCM retry loop keeps running in the background;
      // the next login attempt will likely succeed immediately.

      dev.log('🔔 Requesting FCM token before login...');
      final fcmToken = await FCMService.ensureFCMToken(
        timeout: const Duration(seconds: 30),
        preferFresh: false,
      );

      if (fcmToken == null || fcmToken.isEmpty) {
        dev.log('❌ FCM token not available after timeout');
        return {
          'success': false,
          'message':
              'Your device is still setting up push notifications. '
              'Please wait a moment and try again.',
          'fcm_pending': true, // UI can check this to show a specific hint
        };
      }

      dev.log('✅ FCM token ready');

      // ── Build payload ────────────────────────────────────────────────────
      final deviceInfo = await DeviceInfo.getDeviceInfo();

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
        'stage': 'dev',
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

      // Save role and departments at login so RoleChangeWatcher has a
      // baseline to compare against. Without this, _loadBaseline() returns
      // empty values and the watcher's empty-baseline guard fires immediately,
      // skipping every comparison — so no logout ever triggers on role change.
      final rawRole = user['role'] ?? user['user_role'];
      if (rawRole != null) {
        await UserSessionHelper.saveRole(rawRole.toString().trim());
        dev.log('✅ Role saved at login: $rawRole');
      }

      try {
        final rawDepts = user['departments'];
        List<String> deptList = [];
        if (rawDepts is String && rawDepts.isNotEmpty) {
          deptList = List<String>.from(jsonDecode(rawDepts));
        } else if (rawDepts is List) {
          deptList = List<String>.from(rawDepts);
        }
        if (deptList.isNotEmpty) {
          await UserSessionHelper.saveDepartments(deptList);
          dev.log('✅ Departments saved at login: $deptList');
        }
      } catch (e) {
        dev.log('⚠️ Could not save departments at login: $e');
      }

      return {
        'success': true,
        'message': statusMessage,
        'user': user,
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
      final response = await http.post(
        Uri.parse(
          "https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production/ScreenSync_send_otp_mobile",
        ),
        headers: {
          "Content-Type": "application/json",
          "x-api-key": ApiConstants.apiKey, // ✅ keep consistent with your Dio
        },
        body: jsonEncode({
          "mobile_no": mobile,   // ✅ FIXED
          "stage": "dev",        // ✅ REQUIRED
        }),
      );

      final data = jsonDecode(response.body);

      final result = data["RESULT"];

      return {
        "success": result?["status"] == "S",                 // ✅ FIXED
        "message": result?["message"] ?? "OTP failed",       // ✅ FIXED
      };

    } catch (e) {
      return {
        "success": false,
        "message": ErrorHandler.friendlyMessage(e),
      };
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
        'stage': 'dev',
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
        'stage': 'dev',
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
}
