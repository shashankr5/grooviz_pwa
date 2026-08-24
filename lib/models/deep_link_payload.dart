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

    if (rawType == 'NEW_FOOD_ORDER') {
      targetTab = 'food';
      entityType = DeepLinkEntityType.foodOrder;
      entityId = (data['order_id'] ?? data['order_number'])?.toString();
    } else if (rawType == 'SERVICE_ORDER' ||
        rawType == 'NEW_SERVICE_REQUEST' ||
        rawType == 'TASK_REASSIGNED') {
      targetTab = 'home';
      entityType = DeepLinkEntityType.serviceTask;
      entityId = (data['service_request_id'] ??
              data['task_id'] ??
              data['order_id'] ??
              data['instance_id'])
          ?.toString();
    } else if (rawType == 'ESCALATION') {
      targetTab = 'home';
      entityType = DeepLinkEntityType.escalation;
      entityId = (data['service_request_id'] ??
              data['task_id'] ??
              data['order_id'])
          ?.toString();
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
