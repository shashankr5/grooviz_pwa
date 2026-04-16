// food_order_status.dart
enum FoodOrderStatus {
  pending,
  preparing,
  ready,
  delivered,
  cancelled,
}

extension FoodOrderStatusX on FoodOrderStatus {
  /// For API payload
  String get api {
    switch (this) {
      case FoodOrderStatus.pending:
        return "PENDING";
      case FoodOrderStatus.preparing:
        return "PREPARING";
      case FoodOrderStatus.ready:
        return "READY";
      case FoodOrderStatus.delivered:
        return "DELIVERED";
      case FoodOrderStatus.cancelled:
        return "CANCELLED";
    }
  }

  /// For UI text
  String get label {
    switch (this) {
      case FoodOrderStatus.pending:
        return "Pending";
      case FoodOrderStatus.preparing:
        return "Preparing";
      case FoodOrderStatus.ready:
        return "Ready";
      case FoodOrderStatus.delivered:
        return "Delivered";
      case FoodOrderStatus.cancelled:
        return "Cancelled";
    }
  }
}