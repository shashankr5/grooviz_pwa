// Minimal notification constants for backward compatibility

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Fixed notification IDs - mapped to Lambda message types
class NotifId {
  // Legacy constants for page compatibility (FIXED TO MATCH _getNotificationId)
  static const int foodOrder = 1001;     // Maps to NEW_FOOD_ORDER
  static const int delivery = 1003;      // Maps to FOOD_ORDER_STATUS (FIXED: was 1002, now 1003)
  static const int serviceTask = 1002;   // Maps to NEW_SERVICE_REQUEST (FIXED: was 1003, now 1002)
  static const int escalation = 1004;    // Maps to ESCALATION
  
  // Additional Lambda types (not used by pages directly)
  static const int taskReassigned = 1006; // TASK_REASSIGNED
  static const int groupSummary = 1000;   // Fallback
}

/// Lambda message type to notification ID mapping
/// Used by _getNotificationId() function
class LambdaNotificationTypes {
  static const String newFoodOrder = 'NEW_FOOD_ORDER';
  static const String foodOrderStatus = 'FOOD_ORDER_STATUS'; 
  static const String newServiceRequest = 'NEW_SERVICE_REQUEST';
  static const String serviceOrder = 'SERVICE_ORDER';
  static const String taskReassigned = 'TASK_REASSIGNED';
  static const String escalation = 'ESCALATION';
  
  // Action types (don't need visual notifications, just alert control)
  static const String orderAccepted = 'ORDER_ACCEPTED';
  static const String orderCancelled = 'ORDER_CANCELLED';  
  static const String orderDelivered = 'ORDER_DELIVERED';
  static const String serviceTaskAccepted = 'SERVICE_TASK_ACCEPTED';
  static const String accepted = 'ACCEPTED';
  static const String deliveryAccepted = 'DELIVERY_ACCEPTED';
  static const String deliveryDelivered = 'DELIVERY_DELIVERED';
  static const String taskClosed = 'TASK_CLOSED';
}

/// Export localNotifications instance for page imports
final FlutterLocalNotificationsPlugin localNotifications = 
    FlutterLocalNotificationsPlugin();

/// Export updateGroupSummary function for page imports
Future<void> updateGroupSummary() async {
  // No-op: Lambda notifications handle grouping automatically
}