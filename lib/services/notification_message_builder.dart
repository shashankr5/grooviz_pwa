import 'notification_constants.dart';

class NotifMessage {
  final String title;
  final String body;
  final String bigText;
  final String ticker;
  final int    notifId;
  final String channelId;
  final int    color;
  final String icon;

  const NotifMessage({
    required this.title,
    required this.body,
    required this.bigText,
    required this.ticker,
    required this.notifId,
    required this.channelId,
    required this.color,
    required this.icon,
  });
}

class NotificationMessageBuilder {

  /// Builds a professional NotifMessage from raw FCM data map.
  /// Falls back gracefully if payload fields are missing.
  static NotifMessage build(Map<String, dynamic> data) {
    final type        = (data['type'] ?? '').toString();
    final orderNumber = data['order_number']?.toString() ?? '';
    final orderId     = data['order_id']?.toString() ?? '';
    final taskId      = data['task_id']?.toString() ?? '';
    final room        = _extractRoom(data['body']?.toString() ?? '');
    final items       = _extractItems(data['body']?.toString() ?? '');
    final reason      = data['reason']?.toString() ?? 'Your access has been updated by an administrator.';

    switch (type) {

      // ── Food Orders ──────────────────────────────────────────────────────
      case 'NEW_FOOD_ORDER':
        final ref = orderNumber.isNotEmpty ? '#$orderNumber' : (orderId.isNotEmpty ? '#$orderId' : '');
        final roomLabel = room.isNotEmpty ? ' · $room' : '';
        final itemLabel = items.isNotEmpty ? ' · $items' : '';
        return NotifMessage(
          title:     '🍽️ New Food Order',
          body:      'Order $ref$roomLabel$itemLabel'.trim(),
          bigText:   'A new order $ref has arrived from${room.isNotEmpty ? " $room" : " the restaurant"}. '
                     'Tap to review and accept before the guest waits too long.',
          ticker:    'New food order received${room.isNotEmpty ? " — $room" : ""}',
          notifId:   NotifId.foodOrder,
          channelId: NotifChannel.foodOrder,
          color:     NotifColor.foodOrder,
          icon:      NotifIcon.food,
        );

      // ── Service Orders (TV booking) ───────────────────────────────────────
      case 'SERVICE_ORDER':
        final ref = orderNumber.isNotEmpty ? '#$orderNumber' : (orderId.isNotEmpty ? '#$orderId' : '');
        final roomLabel = room.isNotEmpty ? '$room · ' : '';
        final itemLabel = items.isNotEmpty ? items : 'Service booking';
        return NotifMessage(
          title:     '🛎️ New Service Order',
          body:      '$roomLabel$itemLabel'.trim(),
          bigText:   'A new service order $ref has been placed from${room.isNotEmpty ? " $room" : " a guest device"}. '
                     'Tap to review and accept.',
          ticker:    'New service order${room.isNotEmpty ? " — $room" : ""}',
          notifId:   NotifId.serviceTask,
          channelId: NotifChannel.task,
          color:     NotifColor.serviceTask,
          icon:      NotifIcon.task,
        );

      // ── Service Tasks ─────────────────────────────────────────────────────
      case 'NEW_SERVICE_REQUEST':
        final ref = taskId.isNotEmpty ? '#$taskId' : '';
        final roomLabel = room.isNotEmpty ? '$room · ' : '';
        final itemLabel = items.isNotEmpty ? items : 'Service request';
        return NotifMessage(
          title:     '🔧 New Service Request',
          body:      '${roomLabel}$itemLabel · Tap to assign'.trim(),
          bigText:   'A new service request $ref has been submitted from${room.isNotEmpty ? " $room" : " a guest room"}. '
                     'Tap to review, assign, and acknowledge the request.',
          ticker:    'Service request${room.isNotEmpty ? " — $room" : ""}',
          notifId:   NotifId.serviceTask,
          channelId: NotifChannel.task,
          color:     NotifColor.serviceTask,
          icon:      NotifIcon.task,
        );

      // ── Task Reassigned ───────────────────────────────────────────────────
      case 'TASK_REASSIGNED':
        final srId = data['service_request_id']?.toString() ?? '';
        return NotifMessage(
          title:     '🔄 Task Assigned to You',
          body:      'Service request #$srId has been assigned to you',
          bigText:   'A service request has been reassigned to you. Tap to review and begin working.',
          ticker:    'Task assigned to you',
          notifId:   NotifId.serviceTask,
          channelId: NotifChannel.task,
          color:     NotifColor.serviceTask,
          icon:      NotifIcon.task,
        );

      // ── Escalation ────────────────────────────────────────────────────────
      case 'ESCALATION':
        final ref = taskId.isNotEmpty ? '#$taskId' : '';
        final srId = data['service_request_id']?.toString() ?? '';
        final displayRef = ref.isNotEmpty ? ref : (srId.isNotEmpty ? '#$srId' : '');
        final roomLabel = room.isNotEmpty ? '$room · ' : '';
        return NotifMessage(
          title:     '⚠️ Escalation — Immediate Attention Required',
          body:      '${roomLabel}Request $displayRef · SLA threshold breached'.trim(),
          bigText:   'Request $displayRef has exceeded the SLA threshold and requires your immediate review. '
                     'This is a one-time alert — tap to action.',
          ticker:    'Escalation alert — SLA breach',
          notifId:   NotifId.escalation,
          channelId: NotifChannel.escalation,
          color:     NotifColor.escalation,
          icon:      NotifIcon.escalation,
        );

      // ── Default / Unknown ─────────────────────────────────────────────────
      default:
        final fallbackBody = data['body']?.toString() ??
                             data['message']?.toString() ?? 'Tap to view';
        return NotifMessage(
          title:     data['title']?.toString() ?? '📋 ScreenSync Alert',
          body:      fallbackBody,
          bigText:   fallbackBody,
          ticker:    'New alert from ScreenSync',
          notifId:   NotifId.serviceTask,
          channelId: NotifChannel.task,
          color:     NotifColor.serviceTask,
          icon:      NotifIcon.fallback,
        );
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Extracts "Room 204" from body text like "Room 204 ordered 2x Veg Burger"
  static String _extractRoom(String body) {
    final match = RegExp(r'Room\s+\d+', caseSensitive: false).firstMatch(body);
    return match?.group(0) ?? '';
  }

  /// Extracts item description after room reference
  static String _extractItems(String body) {
    // Remove "Room NNN" prefix and connector words
    final cleaned = body
        .replaceAll(RegExp(r'Room\s+\d+\s*(requested?|ordered?|:)?\s*', caseSensitive: false), '')
        .trim();
    // Truncate to 40 chars to keep body line readable
    return cleaned.length > 40 ? '${cleaned.substring(0, 37)}…' : cleaned;
  }
}
