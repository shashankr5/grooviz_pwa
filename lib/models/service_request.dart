// lib/models/service_request.dart
//
// Unified domain model for ScreenSync_get_all_services_mobile.
// Two rendering modes, one model:
//   • isCatalogOrder == false → DirectRequestCard (Type A — text/chat)
//   • isCatalogOrder == true  → CatalogOrderCard  (Type B — invoice/booking)

import 'dart:convert';

// ── Service Order Line Item ────────────────────────────────────────────────────

class ServiceOrderItem {
  final int orderItemId;
  final String serviceName;
  final String? optionName;
  final double? optionPrice;
  final int quantity;
  final double totalAmount;
  final String? bookingDate;
  final String? bookingTime;
  final String? specialRequest;
  final String? itemRequestStatus;
  final String? remarks;

  const ServiceOrderItem({
    required this.orderItemId,
    required this.serviceName,
    this.optionName,
    this.optionPrice,
    required this.quantity,
    required this.totalAmount,
    this.bookingDate,
    this.bookingTime,
    this.specialRequest,
    this.itemRequestStatus,
    this.remarks,
  });

  factory ServiceOrderItem.fromJson(Map<String, dynamic> j) {
    double toDouble(dynamic v) {
      if (v == null) return 0.0;
      if (v is double) return v;
      if (v is int) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0.0;
    }

    return ServiceOrderItem(
      orderItemId:       (j['order_item_id'] as num?)?.toInt() ?? 0,
      serviceName:       j['service_name']?.toString() ?? '',
      optionName:        j['option_name']?.toString(),
      optionPrice:       toDouble(j['option_price']),
      quantity:          (j['quantity'] as num?)?.toInt() ?? 1,
      totalAmount:       toDouble(j['total_amount']),
      bookingDate:       j['booking_date']?.toString(),
      bookingTime:       j['booking_time']?.toString(),
      specialRequest:    j['special_request']?.toString(),
      itemRequestStatus: j['item_request_status']?.toString(),
      remarks:           j['remarks']?.toString(),
    );
  }
}

// ── Unified Service Request ────────────────────────────────────────────────────

class ServiceRequest {
  // Identifiers
  final int serviceRequestId;
  final int roomId;
  final String roomNumber;
  final int enterpriseId;
  final int departmentId;
  final String departmentName;

  // Request metadata
  final String category;
  final String requestName;
  final String question;
  final String answer;
  final DateTime timestamp;
  final String status;
  final bool closed;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Guest info
  final int? guestId;
  final String? guestName;
  final String? guestPhone;

  // Discriminator: 0 = Type A (direct text), 1 = Type B (catalog order)
  final int isFromOrder;

  // Type B: Catalog order fields
  final int? orderId;
  final String? orderNumber;
  final double? grandTotal;
  final String? orderStatus;
  final String? orderRemarks;
  final List<ServiceOrderItem> orderItems;

  // Escalation
  final int? escalationInstanceId;
  final String? escalationStatus;
  final String? currentStageName;

  // User role
  final int? userRoleId;

  // Assignee Details
  final int? assignedTo;
  final String? assignedToName;
  final String? assignedToPhone;

  const ServiceRequest({
    required this.serviceRequestId,
    required this.roomId,
    required this.roomNumber,
    required this.enterpriseId,
    required this.departmentId,
    required this.departmentName,
    required this.category,
    required this.requestName,
    required this.question,
    required this.answer,
    required this.timestamp,
    required this.status,
    required this.closed,
    required this.createdAt,
    required this.updatedAt,
    this.guestId,
    this.guestName,
    this.guestPhone,
    required this.isFromOrder,
    this.orderId,
    this.orderNumber,
    this.grandTotal,
    this.orderStatus,
    this.orderRemarks,
    this.orderItems = const [],
    this.escalationInstanceId,
    this.escalationStatus,
    this.currentStageName,
    this.userRoleId,
    this.assignedTo,
    this.assignedToName,
    this.assignedToPhone,
  });

  // ── Computed helpers ──────────────────────────────────────────────────────

  bool get isCatalogOrder => isFromOrder == 1;

  bool get hasBooking =>
      orderItems.any((i) => i.bookingDate != null && i.bookingDate!.isNotEmpty);

  bool get hasSpecialRequest =>
      orderItems.any((i) => i.specialRequest != null && i.specialRequest!.isNotEmpty);

  bool get isEscalated =>
      escalationInstanceId != null && escalationStatus != null;

  String get displayTitle {
    if (requestName.isNotEmpty) return requestName;
    if (question.isNotEmpty) return question;
    return 'Service Request';
  }

  bool get isOpen =>
      !closed &&
      (status.toLowerCase() == 'open' || status.toLowerCase() == 'pending');

  bool get isInProgress => !closed && status.toLowerCase() == 'in progress';

  bool get isClosed =>
      closed || status.toLowerCase() == 'closed';

  // ── Factory constructor ───────────────────────────────────────────────────

  factory ServiceRequest.fromJson(Map<String, dynamic> j) {
    DateTime parseDate(dynamic v) =>
        v != null ? (DateTime.tryParse(v.toString()) ?? DateTime.now()) : DateTime.now();

    double? toDoubleNull(dynamic v) {
      if (v == null) return null;
      if (v is double) return v;
      if (v is int) return v.toDouble();
      return double.tryParse(v.toString());
    }

    List<ServiceOrderItem> parseItems(dynamic raw) {
      if (raw == null) return const [];
      try {
        final decoded = raw is String ? jsonDecode(raw) : raw;
        if (decoded is List) {
          return decoded
              .whereType<Map<String, dynamic>>()
              .map(ServiceOrderItem.fromJson)
              .toList();
        }
      } catch (_) {}
      return const [];
    }

    return ServiceRequest(
      serviceRequestId:    (j['service_request_id'] as num?)?.toInt() ?? 0,
      roomId:              (j['room_id'] as num?)?.toInt() ?? 0,
      roomNumber:          j['room_number']?.toString() ?? '',
      enterpriseId:        (j['enterprise_id'] as num?)?.toInt() ?? 0,
      departmentId:        (j['department_id'] as num?)?.toInt() ?? 0,
      departmentName:      j['department_name']?.toString() ?? '',
      category:            j['category']?.toString() ?? 'service',
      requestName:         j['request_name']?.toString() ?? '',
      question:            j['question']?.toString() ?? '',
      answer:              j['answer']?.toString() ?? '',
      timestamp:           parseDate(j['timestamp']),
      status:              j['status']?.toString() ?? 'Open',
      closed:              j['closed'] == 1 || j['closed'] == true,
      createdAt:           parseDate(j['created_at']),
      updatedAt:           parseDate(j['updated_at']),
      guestId:             (j['guest_id'] as num?)?.toInt(),
      guestName:           j['guest_name']?.toString(),
      guestPhone:          j['guest_phone']?.toString(),
      isFromOrder:         (j['is_from_order'] as num?)?.toInt() ?? 0,
      orderId:             (j['order_id'] as num?)?.toInt(),
      orderNumber:         j['order_number']?.toString(),
      grandTotal:          toDoubleNull(j['grand_total']),
      orderStatus:         j['order_status']?.toString(),
      orderRemarks:        j['order_remarks']?.toString(),
      orderItems:          parseItems(j['order_items_json']),
      escalationInstanceId:(j['escalation_instance_id'] as num?)?.toInt(),
      escalationStatus:    j['escalation_status']?.toString(),
      currentStageName:    j['current_stage_name']?.toString(),
      userRoleId:          (j['user_role_id'] as num?)?.toInt(),
      assignedTo:          (j['assigned_to'] as num?)?.toInt(),
      assignedToName:      j['assigned_to_name']?.toString() ?? j['full_name']?.toString(),
      assignedToPhone:     j['assigned_to_phone']?.toString() ?? j['phone_number']?.toString(),
    );
  }
}
