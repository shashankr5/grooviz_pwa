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
  Future<Map<String, dynamic>> getAllServices({String stage = AppConfig.stage}) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      final enterpriseId = await UserSessionHelper.getEnterpriseId();
      if (userId == null) {
        return {'success': false, 'message': 'User session not found'};
      }

      final response = await _dio.post(
        ApiConstants.getAllServices,
        data: {
          'user_id': userId,
          'enterprise_id': enterpriseId,
          'stage': stage,
        },
      );

      final data = response.data;
      List<dynamic> statusList = data['STATUS'] ?? [];
      List<dynamic> resultList = data['RESULT'] ?? [];

      if (statusList.isNotEmpty && statusList[0]['status'] == 'S') {
        return {
          'success': true,
          'message': statusList[0]['message'] ?? 'Success',
          'services': resultList,
        };
      } else {
        return {
          'success': false,
          'message': statusList.isNotEmpty ? statusList[0]['message'] : 'Failed to fetch services',
          'services': [],
        };
      }
    } catch (e) {
      dev.log("Ã¢ÂÅ’ ERROR (getAllServices): $e");
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
        'services': [],
      };
    }
  }

  /// Accept/Reject/Cancel/Complete a service order
  Future<Map<String, dynamic>> acceptServiceOrder({
    required int orderId,
    required String action, // ACCEPT, REJECT, CANCEL, COMPLETE
    String? remarks,
    List<Map<String, dynamic>>? items,
    String stage = AppConfig.stage,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      final enterpriseId = await UserSessionHelper.getEnterpriseId();
      if (userId == null || enterpriseId == null) {
        return {'success': false, 'message': 'User session not found'};
      }

      final response = await _dio.post(
        ApiConstants.acceptServiceOrder,
        data: {
          'user_id': userId,
          'enterprise_id': enterpriseId,
          'order_id': orderId,
          'action': action,
          if (remarks != null) 'remarks': remarks,
          if (items != null) 'items': items,
          'stage': stage,
        },
      );

      final data = response.data;
      List<dynamic> statusList = data['STATUS'] ?? [];
      
      if (statusList.isNotEmpty && statusList[0]['status'] == 'S') {
        return {
          'success': true,
          'message': statusList[0]['message'] ?? 'Action processed successfully',
        };
      } else {
        return {
          'success': false,
          'message': statusList.isNotEmpty ? statusList[0]['message'] : 'Failed to process order action',
        };
      }
    } catch (e) {
      dev.log("Ã¢ÂÅ’ ERROR (acceptServiceOrder): $e");
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
      };
    }
  }

  // Ã¢â€â‚¬Ã¢â€â‚¬ Update service request status (Accept / Close) Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
  //
  // Canonical action method for ALL status transitions on a service request:
  //   Ã¢â‚¬Â¢ status = "IN_PROGRESS" Ã¢â€ â€™ Staff/Supervisor accepts the task
  //   Ã¢â‚¬Â¢ status = "CLOSED"      Ã¢â€ â€™ Any authorised user closes the task
  //
  // SP: ScreenSync_update_service_request_status_mobile
  // The SP handles escalation resolution atomically Ã¢â‚¬â€ do NOT call
  // EscalationService.resolveEscalation() after this method.
  //
  // Returns:
  //   success              bool
  //   message              String
  //   current_status       "In Progress" | "Closed"
  //   escalation_status    String? Ã¢â‚¬â€ updated escalation state from SP
  //   next_escalation_at   String? Ã¢â‚¬â€ null when task accepted/closed
  //   closed_by_user_name  String?
  //   current_assigned_to  String?
  //   accepted_by_user_name String?
  //   status_data          Map    Ã¢â‚¬â€ full STATUS[0] row for any extra SP fields
  Future<Map<String, dynamic>> updateServiceRequestStatus({
    required int serviceRequestId,
    required String status,    // "IN_PROGRESS" | "CLOSED"
    String? remarks,
    String stage = AppConfig.stage,
  }) async {
    try {
      final userId = await UserSessionHelper.getUserId();
      if (userId == null) {
        return {'success': false, 'message': 'User session not found'};
      }

      dev.log("Ã°Å¸â€œÂ¤ updateServiceRequestStatus: sr=$serviceRequestId status=$status");

      final response = await _dio.post(
        ApiConstants.updateServiceRequestStatus,
        data: {
          'user_id':            userId,
          'service_request_id': serviceRequestId,
          'status':             status,
          if (remarks != null && remarks.isNotEmpty) 'remarks': remarks,
          'stage':              stage,
        },
      );

      final data       = response.data as Map<String, dynamic>? ?? {};
      final statusList = (data['STATUS'] as List?) ?? [];

      if (statusList.isEmpty) {
        return {'success': false, 'message': 'Invalid server response'};
      }

      final sd = Map<String, dynamic>.from(statusList[0] as Map);

      if (sd['status'] != 'S') {
        return {
          'success': false,
          'message': sd['message'] ?? 'Failed to update status',
        };
      }

      // Normalise current_status from the SP's raw value
      final rawCurrentStatus = (sd['current_status'] as String?) ?? status;
      String normalised;
      switch (rawCurrentStatus.toUpperCase()) {
        case 'IN_PROGRESS':
        case 'INPROGRESS':
        case 'IN PROGRESS':
          normalised = 'In Progress';
          break;
        case 'CLOSED':
          normalised = 'Closed';
          break;
        default:
          normalised = rawCurrentStatus;
      }

      dev.log("Ã¢Å“â€¦ updateServiceRequestStatus: sr=$serviceRequestId Ã¢â€ â€™ $normalised");

      return {
        'success':               true,
        'message':               sd['message'] ?? 'Status updated',
        'current_status':        normalised,
        'escalation_status':     sd['escalation_status'],
        'next_escalation_at':    sd['next_escalation_at'],
        'closed_by_user_name':   sd['closed_by_user_name'],
        'current_assigned_to':   sd['current_assigned_to'],
        'accepted_by_user_name': sd['accepted_by_user_name'],
        'status_data':           sd, // full STATUS[0] row
      };
    } catch (e) {
      dev.log("Ã¢ÂÅ’ ERROR (updateServiceRequestStatus): $e");
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
      };
    }
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

      dev.log("Ã°Å¸â€œÂ¤ acceptServiceRequest: $payload");

      final response = await _dio.post(
        ApiConstants.acceptServiceRequest,
        data: payload,
      );

      final data = response.data as Map? ?? const {};
      final rawStatus = data['STATUS'];
      final statusList = rawStatus is List
          ? rawStatus
          : (rawStatus is Map ? [rawStatus] : const <dynamic>[]);

      if (statusList.isNotEmpty && statusList.first is Map) {
        final statusMap = statusList.first as Map;
        final flag = statusMap['status']?.toString().toUpperCase();
        final message = statusMap['message']?.toString() ?? 'Service request accepted successfully';
        if (flag == 'S') {
          dev.log("Ã¢Å“â€¦ acceptServiceRequest success: $message");
          // RESULT2 is the assignment/audit result set returned by
          // accept_service_request_mobile1. Keep it available for the UI.
          final rawAssignment =
              data['RESULT2'] ?? data['RESULT_2'] ?? data['ASSIGNMENT'];
          final assignmentRows = rawAssignment is List
              ? rawAssignment
              : (rawAssignment is Map ? [rawAssignment] : const <dynamic>[]);
          final assignment = assignmentRows.isNotEmpty && assignmentRows.first is Map
              ? Map<String, dynamic>.from(assignmentRows.first as Map)
              : <String, dynamic>{};
          return {
            'success': true,
            'message': message,
            'assignment': assignment,
            'accepted_at': assignment['accepted_at'],
            'accepted_by_user_name': assignment['accepted_by_user_name'] ??
                assignment['accepted_by_name'],
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
        'message': 'Invalid server response from accept endpoint',
      };
    } catch (e) {
      dev.log("Ã¢ÂÅ’ ERROR (acceptServiceRequest): $e");
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
      };
    }
  }

  /// Reassign a service request to another staff member using ScreenSync_reassign_service_mobile1
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

      dev.log("Ã°Å¸â€œÂ¤ reassignService: $payload");

      final response = await _dio.post(
        ApiConstants.reassignService,
        data: payload,
      );

      final data = response.data as Map? ?? const {};
      final rawStatus = data['STATUS'];
      final statusList = rawStatus is List
          ? rawStatus
          : (rawStatus is Map ? [rawStatus] : const <dynamic>[]);

      if (statusList.isNotEmpty && statusList.first is Map) {
        final statusMap = statusList.first as Map;
        final flag = statusMap['status']?.toString().toUpperCase();
        final message = statusMap['message']?.toString() ?? 'Task reassigned successfully';
        if (flag == 'S') {
          dev.log("Ã¢Å“â€¦ reassignService success: $message");
          final rawUpdate = data['RESULT2'] ?? data['RESULT'] ?? data['ASSIGNMENT'];
          final updateRows = rawUpdate is List
              ? rawUpdate
              : (rawUpdate is Map ? [rawUpdate] : const <dynamic>[]);
          final updatedTask = updateRows.isNotEmpty && updateRows.first is Map
              ? Map<String, dynamic>.from(updateRows.first as Map)
              : <String, dynamic>{};
          return {
            'success': true,
            'message': message,
            'updatedTask': updatedTask,
            'assigned_by_name': updatedTask['assigned_by_name'] ??
                updatedTask['recent_reassigned_by_user_name'],
            'assigned_at': updatedTask['assigned_at'] ??
                updatedTask['recent_reassigned_at'],
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
      dev.log("Ã¢ÂÅ’ ERROR (reassignService): $e");
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

      final data = response.data;
      List<dynamic> statusList = data['STATUS'] ?? [];
      List<dynamic> resultList = data['RESULT'] ?? [];

      if (statusList.isNotEmpty && statusList[0]['status'] == 'S') {
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
      dev.log("Ã¢ÂÅ’ ERROR (addServiceNote): $e");
      return {
        'success': false,
        'message': ErrorHandler.friendlyMessage(e),
        'note': null,
      };
    }
  }

  /// Closes a service request through close_service_mobile1.
  /// The server derives enterprise/department from the request and verifies
  /// the signed-in user's current department assignment.
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
      final statusRows = data['STATUS'] is List ? data['STATUS'] as List : const <dynamic>[];
      final resultRows = data['RESULT'] is List
          ? data['RESULT'] as List
          : (data['RESULT2'] is List ? data['RESULT2'] as List : const <dynamic>[]);
      final status = statusRows.isNotEmpty && statusRows.first is Map
          ? Map<String, dynamic>.from(statusRows.first as Map)
          : <String, dynamic>{};
      final details = resultRows.isNotEmpty && resultRows.first is Map
          ? Map<String, dynamic>.from(resultRows.first as Map)
          : <String, dynamic>{};
      final flag = status['status']?.toString().toUpperCase();
      if (flag != 'S' && flag != '200') {
        return {'success': false, 'message': status['message'] ?? 'Failed to close service request'};
      }

      return {
        'success': true,
        'message': status['message'] ?? 'Service request closed successfully',
        'current_status': 'Closed',
        'closed_at': details['closed_at'],
        'closed_by_user_name': details['closed_by_user_name'],
        'data': details,
      };
    } catch (e) {
      dev.log("Close service mobile1 failed: $e");
      return {'success': false, 'message': ErrorHandler.friendlyMessage(e)};
    }
  }
}

