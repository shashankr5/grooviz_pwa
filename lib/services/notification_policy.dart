/// Decides whether an incoming event deserves a user-visible notification.
///
/// Queue reconciliation events are intentionally silent: they update the
/// foreground service/list state but must never replace a genuine new-request
/// notification when a user opens a page or pulls to refresh.
class NotificationPolicy {
  NotificationPolicy._();

  static final Map<String, DateTime> _recentVisibleEvents = {};
  static const Duration _duplicateWindow = Duration(seconds: 45);

  static bool shouldShowLocalNotification(Map<String, dynamic> data) {
    // Only the 5 canonical backend types produce a user-visible notification.
    // Everything else reconciles state silently.
    switch ((data['type'] ?? '').toString().toUpperCase()) {
      case 'NEW_FOOD_ORDER':
      case 'SERVICE_ORDER':
      case 'NEW_SERVICE_REQUEST':
      case 'TASK_REASSIGNED':
      case 'ESCALATION':
        return !_isDuplicate(data);
      default:
        return false;
    }
  }

  static bool _isDuplicate(Map<String, dynamic> data) {
    final type = (data['type'] ?? '').toString().toUpperCase();
    final id = data['event_id'] ??
        data['message_id'] ??
        data['service_request_id'] ??
        data['task_id'] ??
        data['order_id'] ??
        data['order_number'];

    // Do not invent a dedupe key. Without a server entity/event identifier,
    // two genuine requests cannot safely be distinguished.
    if (id == null || id.toString().trim().isEmpty) return false;

    final now = DateTime.now();
    _recentVisibleEvents.removeWhere(
      (_, seenAt) => now.difference(seenAt) > _duplicateWindow,
    );
    final key = '$type:${id.toString().trim()}';
    if (_recentVisibleEvents.containsKey(key)) return true;
    _recentVisibleEvents[key] = now;
    return false;
  }
}
