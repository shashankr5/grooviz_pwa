// models/deep_link_payload.dart

enum DeepLinkEntityType { foodOrder, serviceTask, delivery, escalation }

class DeepLinkPayload {
  final String targetTab; // 'home', 'food', 'delivery'
  final String? entityId;
  final DeepLinkEntityType? entityType;
  final String source; // 'fcm', 'local_notification', 'websocket', 'deep_link'
  final DateTime timestamp;
  final Map<String, dynamic> rawData;

  const DeepLinkPayload({
    required this.targetTab,
    this.entityId,
    this.entityType,
    this.source = 'fcm',
    required this.timestamp,
    required this.rawData,
  });

  factory DeepLinkPayload.fromData(
    Map<String, dynamic> data, {
    String source = 'fcm',
  }) {
    final String rawType = (data['type'] ??
            data['event_type'] ??
            data['alert_type'] ??
            '')
        .toString()
        .toUpperCase();

    String targetTab = 'home';
    DeepLinkEntityType? entityType;
    String? entityId;

    if (rawType == 'NEW_FOOD_ORDER' ||
        rawType == 'ORDER_ACCEPTED' ||
        rawType == 'ORDER_CANCELLED' ||
        rawType == 'FOOD_ORDER') {
      targetTab = 'food';
      entityType = DeepLinkEntityType.foodOrder;
      entityId = (data['order_id'] ?? data['order_number'])?.toString();
    } else if (rawType == 'NEW_SERVICE_TASK' ||
        rawType == 'SERVICE_TASK_ACCEPTED' ||
        rawType == 'ACCEPTED' ||
        rawType == 'SERVICE_TASK' ||
        rawType == 'TASK' ||
        rawType == 'ESCALATION_STARTED' ||
        rawType == 'PENDING_ACCEPTANCE' ||
        rawType == 'ESCALATION_STAGE_1' ||
        rawType == 'SERVICE_STATUS_UPDATE' ||
        rawType == 'NEW_SERVICE_REQUEST' ||
        rawType == 'TASK_REASSIGNED' ||
        rawType == 'ESCALATION_PULSE') {
      targetTab = 'home';
      entityType = DeepLinkEntityType.serviceTask;
      entityId = (data['service_request_id'] ?? data['task_id'] ?? data['order_id'] ?? data['instance_id'])?.toString();
    } else if (rawType == 'ESCALATION' || rawType == 'ESCALATION_ALERT') {
      targetTab = 'home';
      entityType = DeepLinkEntityType.escalation;
      entityId = (data['service_request_id'] ?? data['task_id'] ?? data['order_id'])?.toString();
    } else if (rawType == 'NEW_DELIVERY_TASK' ||
        rawType == 'ORDER_READY' ||
        rawType == 'FOOD_ORDER_READY' ||
        rawType == 'DELIVERY_READY' ||
        rawType == 'DELIVERY_NOTIFICATION' ||
        rawType == 'DELIVERY') {
      targetTab = 'delivery';
      entityType = DeepLinkEntityType.delivery;
      entityId = (data['order_id'] ?? data['order_number'])?.toString();
    } else if (rawType == 'ORDER_STATUS_CHANGED') {
      final orderStatus = (data['order_status'] ?? data['status'] ?? '')
          .toString()
          .toUpperCase();
      if (orderStatus == 'READY') {
        targetTab = 'delivery';
        entityType = DeepLinkEntityType.delivery;
        entityId = (data['order_id'] ?? data['order_number'])?.toString();
      } else {
        targetTab = 'food';
        entityType = DeepLinkEntityType.foodOrder;
        entityId = (data['order_id'] ?? data['order_number'])?.toString();
      }
    }

    return DeepLinkPayload(
      targetTab: targetTab,
      entityId: entityId,
      entityType: entityType,
      source: source,
      timestamp: DateTime.now(),
      rawData: data,
    );
  }
}
