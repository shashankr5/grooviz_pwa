import 'package:flutter/material.dart';
import 'app_colors.dart';

class DeliveryUtils {
  DeliveryUtils._();

  /// Determine if a delivery task is in an active, non-terminal state.
  static bool isDeliveryActive(String status) {
    final s = status.trim().toLowerCase();
    return s != 'delivered' && s != 'cancelled' && s != 'closed';
  }

  /// Map delivery task statuses to user-friendly UI display labels.
  static String getDeliveryStageName(String status) {
    switch (status.trim().toLowerCase()) {
      case 'pending':
        return 'Pending';
      case 'accepted':
        return 'In Progress';
      case 'delivered':
        return 'Delivered';
      case 'cancelled':
        return 'Cancelled';
      default:
        return status;
    }
  }

  /// Expose appropriate color matching status.
  static Color getDeliveryStageColor(String status) {
    switch (status.trim().toLowerCase()) {
      case 'pending':
        return AppColors.warning;
      case 'accepted':
        return AppColors.orange;
      case 'delivered':
        return AppColors.success;
      case 'cancelled':
        return AppColors.error;
      default:
        return AppColors.textDisabled;
    }
  }
}
