import 'dart:developer' as dev;
import 'package:dio/dio.dart';
import '../utils/user_session_helper.dart';
import '../utils/error_handler.dart';
import '../constants/api_constants.dart';
import '../constants/api_timeouts.dart';
import '../constants/app_config.dart';
import 'home_service.dart';

class TaskService {
  final Dio _dio;

  TaskService()
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
        requestBody: true,
        responseBody: true,
      ),
    );
  }

  //  COMMON STATUS NORMALIZER  (same as HomeService)

  String normalizeStatus(String? status, int? closedFlag) {
    if (closedFlag == 1) return "Closed";

    if (status == null) return "Open";

    switch (status.toUpperCase()) {
      case "PENDING":
        return "Open";
      case "INPROGRESS":
      case "IN_PROGRESS":
      case "IN PROGRESS":
        return "In Progress";
      case "CLOSED":
        return "Closed";
      default:
        return status;
    }
  }

  /// Fetches all service department requests using
  /// ScreenSync_get_all_services_mobile1.
  ///
  /// Response format: STATUS[] contains service request rows directly
  /// (no RESULT key, no sentinel object).  Also handles the sentinel
  /// format (STATUS[0].status == 'S', RESULT[] = data rows) as a
  /// fallback so any future backend change is handled gracefully.
  Future<Map<String, dynamic>> getAllServices({String stage = AppConfig.stage}) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      final enterpriseId = await UserSessionHelper.getEnterpriseId();
      if (userId == null) {
        return {'success': false, 'message': 'User session not found', 'services': []};
      }

      final response = await _dio.post(
        ApiConstants.getAllServices,
        data: {
          'user_id': userId,
          'enterprise_id': enterpriseId,
          'stage': stage,
        },
      );

      final data = response.data as Map? ?? const {};

      // ScreenSync_get_all_services_mobile1 has two response formats:
      //  1. Data-in-STATUS: STATUS[] contains service rows directly (no RESULT, no sentinel)
      //  2. Sentinel format: STATUS[0].status == 'S', RESULT[] contains rows
      final dynamic statusRaw = data['STATUS'];
      final dynamic resultRaw = data['RESULT'];

      List<dynamic> serviceRows;
      if (resultRaw is List) {
        // Sentinel format: check STATUS[0].status == 'S', then use RESULT
        final statusList = statusRaw is List ? statusRaw : const <dynamic>[];
        if (statusList.isNotEmpty &&
            statusList[0] is Map &&
            statusList[0]['status'] == 'S') {
          serviceRows = resultRaw;
        } else {
          final msg = (statusList.isNotEmpty && statusList[0] is Map)
              ? (statusList[0]['message'] ?? 'Failed to fetch services')
              : 'Failed to fetch services';
          return {'success': false, 'message': msg, 'services': []};
        }
      } else if (statusRaw is List && statusRaw.isNotEmpty) {
        // Data-in-STATUS format: STATUS rows ARE the service requests
        serviceRows = statusRaw;
      } else {
        return {'success': false, 'message': 'Failed to fetch services', 'services': []};
      }

      return {'success': true, 'message': 'Success', 'services': serviceRows};
    } catch (e) {
      dev.log('ERROR (getAllServices): $e');
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
        'services': [],
      };
    }
  }

  /// Alias for getAllServices - kept for backward compatibility
  Future<Map<String, dynamic>> getTasks({String stage = AppConfig.stage}) async {
    return getAllServices(stage: stage);
  }






  /// Accept a service request using ScreenSync_accept_service_request_mobile1
  Future<Map<String, dynamic>> acceptServiceRequest({
    required int serviceRequestId,
    int? enterpriseId,
    String stage = AppConfig.stage,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      final entId = enterpriseId ?? await UserSessionHelper.getEnterpriseId();
      if (userId == null || entId == null) {
        return {'success': false, 'message': 'User session or enterprise not found'};
      }

      final payload = {
        'stage':              stage,
        'user_id':            userId,
        'enterprise_id':      entId,
        'service_request_id': serviceRequestId,
      };

      dev.log('📤 acceptServiceRequest: $payload');

      final response = await _dio.post(
        ApiConstants.acceptServiceRequest,
        data: payload,
      );

      final data = response.data as Map? ?? const {};

      // Lambda cold-start / timeout detection
      if (data['errorType'] != null) {
        dev.log('acceptServiceRequest: Lambda timeout — errorType=${data['errorType']}');
        return {
          'success': false,
          'timedOut': true,
          'message': 'The server took too long to respond. Please refresh to check the status.',
        };
      }

      // ── Response format: RESULT[0] carries both the status sentinel AND
      //    all service/food-order details in the same row.
      //    Fallback to STATUS[] for older Lambda versions.
      // ──────────────────────────────────────────────────────────────────────
      final rawResult = data['RESULT'];
      final rawStatus = data['STATUS'];

      // Prefer RESULT — new Lambda always populates it
      final resultList = rawResult is List
          ? rawResult
          : (rawResult is Map ? [rawResult] : const <dynamic>[]);

      final statusList = rawStatus is List
          ? rawStatus
          : (rawStatus is Map ? [rawStatus] : const <dynamic>[]);

      // Pick the first non-empty list as the sentinel source
      final sentinel = resultList.isNotEmpty
          ? resultList.first
          : (statusList.isNotEmpty ? statusList.first : null);

      if (sentinel == null || sentinel is! Map) {
        dev.log('acceptServiceRequest: no recognisable response — raw: $data');
        return {'success': false, 'message': 'Invalid server response from accept endpoint'};
      }

      final row     = Map<String, dynamic>.from(sentinel);
      final flag    = row['status']?.toString().toUpperCase();
      final message = row['message']?.toString() ?? 'Service request accepted successfully';

      dev.log('acceptServiceRequest: flag=$flag message=$message');

      // Deployed Lambda puts the SP status string in 'status' (e.g. "In Progress"),
      // not the sentinel 'S'/'E'. Accept either 'S' or any non-failure status.
      final isSuccess = flag == 'S' ||
          flag == 'IN PROGRESS' ||
          flag == 'IN_PROGRESS' ||
          flag == 'INPROGRESS' ||
          flag == 'SUCCESS' ||
          (flag != null && flag != 'E' && flag != 'F' && flag != 'ERROR' && flag != 'FAILED');

      if (!isSuccess) {
        return {'success': false, 'message': message};
      }

      // RESULT2 / RESULT_2 / ASSIGNMENT — assignment audit row (older Lambdas)
      final rawAssignment = data['RESULT2'] ?? data['RESULT_2'] ?? data['ASSIGNMENT'];
      final assignmentRows = rawAssignment is List
          ? rawAssignment
          : (rawAssignment is Map ? [rawAssignment] : const <dynamic>[]);
      final assignment = assignmentRows.isNotEmpty && assignmentRows.first is Map
          ? Map<String, dynamic>.from(assignmentRows.first as Map)
          : <String, dynamic>{};

      // Merge main result row + assignment row so callers get all available fields
      final merged = {...row, ...assignment};

      dev.log('✅ acceptServiceRequest success: $message | sr=${merged['service_request_id']}');

      return {
        'success':               true,
        'message':               message,
        'assignment':            merged,
        'accepted_at':           merged['accepted_at'],
        'accepted_by_user_name': merged['accepted_by_user_name'] ??
                                 merged['accepted_by_name'],
        // Pass through food-order fields the delivery UI may need
        'food_order_summary_id': merged['food_order_summary_id'],
        'order_number':          merged['order_number'],
      };
    } catch (e) {
      dev.log('ERROR (acceptServiceRequest): $e');
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
      };
    }
  }

  /// Reassign a service request to another staff member using ScreenSync_reassign_service_mobile1
  ///
  /// The SP returns a single result set whose first row contains BOTH the
  /// status flag/message AND all task fields (username, token_app, assigned_to,
  /// assigned_at, department_name, etc.).  The Lambda surfaces this as
  /// STATUS[0].  There is no separate RESULT / RESULT2 key.
  Future<Map<String, dynamic>> reassignService({
    required int taskId,
    required int reassignTo,
    int? departmentId,
    String stage = AppConfig.stage,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {'success': false, 'message': 'User session not found'};
      }

      final payload = {
        'stage':              stage,
        'user_id':            userId,
        'service_request_id': taskId,
        'reassign_to':        reassignTo,
      };

      dev.log('📤 reassignService: $payload');

      final response = await _dio.post(
        ApiConstants.reassignService,
        data: payload,
      );

      final data = response.data as Map? ?? const {};

      // The Lambda wraps the SP result as RESULT[0] (single result set).
      // Fall back to STATUS for legacy Lambda versions that split them.
      final rawResult = data['RESULT'] ?? data['STATUS'];
      final resultList = rawResult is List
          ? rawResult
          : (rawResult is Map ? [rawResult] : const <dynamic>[]);

      if (resultList.isNotEmpty && resultList.first is Map) {
        // STATUS[0] / RESULT[0] — the first row always carries status + message.
        final row = Map<String, dynamic>.from(resultList.first as Map);
        final flag    = row['status']?.toString().toUpperCase();
        final message = row['message']?.toString() ?? 'Task reassigned successfully';

        if (flag == 'S') {
          dev.log('✅ reassignService success: $message');

          // The same row also contains the task update fields returned by
          // the SP's final SELECT (assigned_to, assigned_at, department_name …).
          // Build updatedTask directly from it so callers always get the data.
          final updatedTask = Map<String, dynamic>.from(row);

          // Normalise the key names the UI expects.
          final assignedAt = (updatedTask['assigned_at'] ??
              updatedTask['recent_reassigned_at'])?.toString();
          final assignedByName = (updatedTask['assigned_by'] ??
              updatedTask['assigned_by_name'] ??
              updatedTask['recent_reassigned_by_user_name'])?.toString();
          final assignedToName = (updatedTask['assigned_to_name'] ??
              updatedTask['username'])?.toString();

          return {
            'success':          true,
            'message':          message,
            'updatedTask':      updatedTask,
            'assigned_by_name': assignedByName,
            'assigned_to_name': assignedToName,
            'assigned_at':      assignedAt,
            // Also expose the reassigned user's department for badge refresh
            'department_id':    updatedTask['department_id'],
            'department_name':  updatedTask['department_name'],
          };
        } else {
          return {
            'success': false,
            'message': message,
          };
        }
      }

      return {
        'success': false,
        'message': 'Invalid server response from reassign endpoint',
      };
    } catch (e) {
      dev.log('ERROR (reassignService): $e');
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
      };
    }
  }

  /// Add a note to a service request
  Future<Map<String, dynamic>> addServiceNote({
    required int serviceRequestId,
    required String noteText,
    String stage = AppConfig.stage,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {'success': false, 'message': 'User session not found', 'note': null};
      }

      final response = await _dio.post(
        ApiConstants.addServiceNote,
        data: {
          'user_id': userId,
          'service_request_id': serviceRequestId,
          'note_text': noteText,
          'stage': stage,
        },
      );

        final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
        final rawStatus = data['STATUS'];
        final statusList = rawStatus is List
          ? rawStatus
          : rawStatus is Map
            ? [rawStatus]
            : const <dynamic>[];
        final rawResult = data['RESULT'] ?? data['RESULT2'] ?? data['RESULT_2'];
        final resultList = rawResult is List
          ? rawResult
          : rawResult is Map
            ? [rawResult]
            : const <dynamic>[];

        if (statusList.isNotEmpty &&
          statusList[0] is Map &&
          statusList[0]['status']?.toString().toUpperCase() == 'S') {
        return {
          'success': true,
          'message': statusList[0]['message'] ?? 'Note added successfully',
          'note': resultList.isNotEmpty ? resultList[0] : null,
        };
      } else {
        return {
          'success': false,
          'message': statusList.isNotEmpty ? statusList[0]['message'] : 'Failed to add note',
          'note': null,
        };
      }
    } catch (e) {
      dev.log('ERROR (addServiceNote): $e');
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
        'note': null,
      };
    }
  }

  /// Closes a service request through close_service_mobile1.
  Future<Map<String, dynamic>> closeService({
    required int serviceRequestId,
    String stage = AppConfig.stage,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null || userId == 0) {
        return {'success': false, 'message': 'User session not found'};
      }

      final response = await _dio.post(
        ApiConstants.closeService,
        data: {
          'user_id': userId,
          'service_request_id': serviceRequestId,
          'stage': stage,
        },
      );
      final data = response.data as Map? ?? const {};

      if (data['errorType'] != null) {
        dev.log('closeService: Lambda timeout — errorType=${data['errorType']}');
        return {
          'success': false,
          'timedOut': true,
          'message': 'The server took too long to respond. Please refresh to check the status.',
        };
      }

      // The repo close_service_mobile1 returns { STATUS: [...], RESULT: [...] }
      // STATUS[0].status = flag, STATUS[0].message = message
      // RESULT[0] = detail row (closed_at, closed_by_user_name, etc.)
      // The deployed TV-only version uses formatResult → RESULT[0] for everything.
      // Handle both by checking STATUS first, falling back to RESULT.
      final rawStatus = data['STATUS'];
      final rawResult = data['RESULT'];

      final statusList = rawStatus is List
          ? rawStatus
          : (rawStatus is Map ? [rawStatus] : const <dynamic>[]);
      final resultList = rawResult is List
          ? rawResult
          : (rawResult is Map ? [rawResult] : const <dynamic>[]);

      // STATUS-based Lambda (repo version): STATUS[0] has flag, RESULT[0] has details
      // RESULT-based Lambda (deployed TV version): RESULT[0] has both flag + details
      Map<String, dynamic> flagRow;
      Map<String, dynamic> detailRow;

      if (statusList.isNotEmpty && statusList.first is Map) {
        flagRow   = Map<String, dynamic>.from(statusList.first as Map);
        detailRow = resultList.isNotEmpty && resultList.first is Map
            ? Map<String, dynamic>.from(resultList.first as Map)
            : <String, dynamic>{};
      } else if (resultList.isNotEmpty && resultList.first is Map) {
        // formatResult version — everything in RESULT[0]
        flagRow   = Map<String, dynamic>.from(resultList.first as Map);
        detailRow = flagRow;
      } else {
        dev.log('closeService: no recognisable response — raw: $data');
        return {'success': false, 'message': 'Invalid server response from close endpoint'};
      }

      final flag    = flagRow['status']?.toString().toUpperCase();
      final message = flagRow['message']?.toString() ?? 'Service request closed successfully';

      dev.log('closeService: flag=$flag message=$message');

      // The deployed Lambda puts the SP status string in 'status' (e.g. "Closed"),
      // not the sentinel 'S'/'E'. Accept either 'S' or any non-failure status.
      final isSuccess = flag == 'S' ||
          flag == 'CLOSED' ||
          flag == 'SUCCESS' ||
          (flag != null && flag != 'E' && flag != 'F' && flag != 'ERROR' && flag != 'FAILED');

      if (!isSuccess) {
        return {'success': false, 'message': message};
      }

      return {
        'success':             true,
        'message':             message,
        'current_status':      'Closed',
        'closed_at':           detailRow['closed_at'],
        'closed_by_user_name': detailRow['closed_by_user_name'],
        'data':                detailRow,
      };
    } catch (e) {
      dev.log('closeService failed: $e');
      return {'success': false, 'message': ErrorHandler.friendlyMessage(e)};
    }
  }
}
