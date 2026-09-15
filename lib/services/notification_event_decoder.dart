import 'package:firebase_messaging/firebase_messaging.dart';

import '../models/notification_event.dart';

class NotificationEventDecoder {
  NotificationEventDecoder._();

  static NotificationEvent? decode(RemoteMessage message) {
    final data = <String, String>{
      for (final entry in message.data.entries)
        entry.key: entry.value?.toString() ?? '',
    };
    return decodeData(data, id: message.messageId);
  }

  static NotificationEvent? decodeData(
    Map<String, String> data, {
    String? id,
  }) {
    final type = _type(data['type']);
    if (type == NotificationType.unknown) return null;

    return NotificationEvent(
      id: id ?? _eventId(data),
      type: type,
      data: Map.unmodifiable(data),
      title: data['title'] ?? '',
      body: data['body'] ?? '',
      enterpriseId: _value(data, 'enterprise_id'),
      departmentId: _value(data, 'department_id'),
      serviceRequestId: _first(data, const [
        'service_request_id',
        'service_order_id',
      ]),
      orderId: _value(data, 'order_id'),
      orderNumber: _value(data, 'order_number'),
      foodOrderSummaryId: _first(data, const [
        'summary_id',
        'food_order_summary_id',
        'food_summary_id',
      ]),
      orderStatus: _first(data, const ['new_status', 'order_status']),
      actionPerformed: _value(data, 'action_performed'),
      stopAlert: _isTrue(data['stop_alert']),
      timestamp: DateTime.tryParse(data['timestamp'] ?? ''),
    );
  }

  static NotificationType _type(String? raw) {
    switch (raw?.trim().toUpperCase()) {
      case 'NEW_FOOD_ORDER':
        return NotificationType.newFoodOrder;
      case 'NEW_SERVICE_REQUEST':
        return NotificationType.newServiceRequest;
      case 'SERVICE_TASK_ACCEPTED':
      case 'SERVICE_REQUEST_ACCEPTED':
      case 'TASK_ACCEPTED':
      case 'ORDER_ACCEPTED':
      case 'FOOD_ORDER_ACCEPTED':
      case 'DELIVERY_ACCEPTED':
        return NotificationType.serviceTaskAccepted;
      case 'TASK_CLOSED':
      case 'SERVICE_TASK_CLOSED':
      case 'SERVICE_REQUEST_CLOSED':
      case 'ORDER_CLOSED':
      case 'ORDER_DELIVERED':
      case 'DELIVERY_DELIVERED':
      case 'FOOD_ORDER_DELIVERED':
        return NotificationType.taskClosed;
      case 'TASK_REASSIGNED':
      case 'SERVICE_TASK_REASSIGNED':
        return NotificationType.taskReassigned;
      case 'FOOD_ORDER_STATUS':
      case 'ORDER_STATUS_CHANGED':
      case 'ORDER_STATUS_UPDATED':
        return NotificationType.foodOrderStatus;
      case 'SERVICE_ORDER':
        return NotificationType.serviceOrder;
      case 'ESCALATION':
        return NotificationType.escalation;
      default:
        return NotificationType.unknown;
    }
  }

  static String? _value(Map<String, String> data, String key) {
    final value = data[key]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static String? _first(Map<String, String> data, List<String> keys) {
    for (final key in keys) {
      final value = _value(data, key);
      if (value != null) return value;
    }
    return null;
  }

  static bool _isTrue(String? value) {
    return value?.trim().toLowerCase() == 'true' || value == '1';
  }

  static String _eventId(Map<String, String> data) {
    return data['notification_log_id'] ??
        data['event_id'] ??
        '${data['type']}:${data['service_request_id'] ?? data['order_id'] ?? data['order_number'] ?? DateTime.now().microsecondsSinceEpoch}';
  }
}