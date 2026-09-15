enum NotificationType {
  newFoodOrder,
  newServiceRequest,
  serviceTaskAccepted,
  taskClosed,
  taskReassigned,
  foodOrderStatus,
  serviceOrder,
  escalation,
  unknown,
}

class NotificationEvent {
  const NotificationEvent({
    required this.id,
    required this.type,
    required this.data,
    this.title = '',
    this.body = '',
    this.enterpriseId,
    this.departmentId,
    this.serviceRequestId,
    this.orderId,
    this.orderNumber,
    this.foodOrderSummaryId,
    this.orderStatus,
    this.actionPerformed,
    this.stopAlert = false,
    this.timestamp,
  });

  final String id;
  final NotificationType type;
  final Map<String, String> data;
  final String title;
  final String body;
  final String? enterpriseId;
  final String? departmentId;
  final String? serviceRequestId;
  final String? orderId;
  final String? orderNumber;
  final String? foodOrderSummaryId;
  final String? orderStatus;
  final String? actionPerformed;
  final bool stopAlert;
  final DateTime? timestamp;

  String get typeName => type.name;

  bool get shouldStopAudio {
    if (stopAlert) return true;
    if (type == NotificationType.serviceTaskAccepted) {
      return true;
    }
    if (type == NotificationType.foodOrderStatus) {
      final s = (orderStatus ?? data['order_status'] ?? data['new_status'] ?? '').toUpperCase();
      if (s == 'ACCEPTED' || s == 'PREPARING' || s == 'DELIVERED' || s == 'CANCELLED') {
        return true;
      }
    }
    final action = (actionPerformed ?? data['action_performed'] ?? '').toUpperCase();
    if (action == 'ACCEPTED' || action == 'DELIVERED') {
      return true;
    }
    return false;
  }

  bool get shouldPlayAudio =>
      !shouldStopAudio &&
      (type == NotificationType.newFoodOrder ||
       type == NotificationType.newServiceRequest ||
       type == NotificationType.serviceOrder ||
       type == NotificationType.escalation ||
       (type == NotificationType.foodOrderStatus &&
        (orderStatus ?? '').toUpperCase() == 'READY'));

  String? get notificationSound => type == NotificationType.escalation
      ? 'escalation'
      : shouldPlayAudio
          ? 'alert'
          : null;
}