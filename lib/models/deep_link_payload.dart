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
        rawType == 'TASK_REASSIGNED' ||
        rawType == 'SERVICE_TASK_ACCEPTED' ||
        rawType == 'TASK_CLOSED') {
      targetTab = 'home';
      entityType = DeepLinkEntityType.serviceTask;
      final rawId = (data['service_request_id'] ??
              data['task_id'] ??
              data['order_id'] ??
              data['instance_id'])
          ?.toString();
      entityId = (rawId?.isNotEmpty == true) ? rawId : null;
    } else if (rawType == 'FOOD_ORDER_STATUS' ||
      rawType == 'NEW_DELIVERY_TASK' ||
      rawType == 'ORDER_READY' ||
      rawType == 'FOOD_ORDER_READY' ||
      rawType == 'DELIVERY_READY' ||
      rawType == 'DELIVERY_NOTIFICATION') {
      targetTab = 'delivery';
      entityType = DeepLinkEntityType.delivery;
      entityId = (data['service_request_id'] ??
          data['order_id'] ??
          data['order_number'])
        ?.toString();
    } else if (rawType == 'ESCALATION') {
      targetTab = 'home';
      entityType = DeepLinkEntityType.escalation;
      final raw = (data['service_request_id'] ??
              data['task_id'] ??
              data['order_id'])
          ?.toString();
      // Guard: treat empty string same as null so int.tryParse doesn't fail
      entityId = (raw?.isNotEmpty == true) ? raw : null;
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
