// food_order_status.dart
enum FoodOrderStatus {
  pending,
  preparing,
  ready,
  delivered,
  cancelled,
}

extension FoodOrderStatusX on FoodOrderStatus {
  /// For API payload matching MySQL enum:
  /// enum('Pending','Accepted','Preparing','Ready','Delivered','Cancelled')
  String get api {
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