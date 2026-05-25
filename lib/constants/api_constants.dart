class ApiConstants {
  // Base URL
  static const String baseUrl = "https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production";
  static const String apiKey = "sa9F4GyTT45OImNkKjaHu6bsJbk8UWmZfKdzmeoc";

  // ── Authentication ────────────────────────────────────────────
  static const String login          = "$baseUrl/ScreenSync_login_mobile";
  static const String logout         = "$baseUrl/ScreenSync_logout_mobile";
  static const String sendOtp        = "$baseUrl/ScreenSync_send_otp_mobile";
  static const String verifyOtp      = "$baseUrl/ScreenSync_verify_otp_mobile";
  static const String resetPassword  = "$baseUrl/ScreenSync_reset_password_mobile";

  // ── Profile ───────────────────────────────────────────────────
  static const String profile        = "$baseUrl/ScreenSync_get_profile_mobile";

  // ── Home Page ─────────────────────────────────────────────────
  static const String tasks          = "$baseUrl/ScreenSync_get_tasks_mobile";
  static const String acceptTask     = "$baseUrl/ScreenSync_task_accept_mobile";

  // ── Ticket Details ────────────────────────────────────────────
  static const String staffList            = "$baseUrl/ScreenSync_get_staff_list_mobile";
  static const String reassignTicket       = "$baseUrl/ScreenSync_reassign_task_mobile";
  static const String addNotes             = "$baseUrl/ScreenSync_add_service_request_note_mobile";
  static const String closeServiceRequest  = "$baseUrl/ScreenSync_close_service_request_mobile";

  // ── Task Summary ──────────────────────────────────────────────
  static const String taskSummary    = "$baseUrl/ScreenSync_get_tasks_summary_mobile";

  // ── Tasks Management (role-based) ─────────────────────────────
  static const String tasksByRole     = "$baseUrl/ScreenSync_get_tasks_by_role_mobile";
  static const String teamPerformance = "$baseUrl/ScreenSync_get_team_performance_mobile";

  // ── Escalation ────────────────────────────────────────────────
  static const String escalationBadgeCount    = "$baseUrl/ScreenSync_get_escalation_badge_count_mobile";
  static const String escalatedTasks          = "$baseUrl/ScreenSync_get_escalated_tasks_mobile";
  static const String logEscalation           = "$baseUrl/ScreenSync_log_escalation_mobile";
  static const String escalationReport        = "$baseUrl/ScreenSync_get_escalation_report_mobile";
  static const String checkAndEscalate        = "$baseUrl/ScreenSync_check_and_escalate_mobile";
  static const String escalationHistoryForTask = "$baseUrl/ScreenSync_get_escalation_history_for_task_mobile";
  static const String notifyReassign           = "$baseUrl/ScreenSync_notify_reassign_mobile";

  // ── Food Orders — Room Service Tab ────────────────────────────
  static const String getReadyOrders          = "$baseUrl/ScreenSync_get_ready_orders_for_room_service_mobile";
  static const String getAcceptedOrders       = "$baseUrl/ScreenSync_get_accepted_orders_for_room_service_mobile";
  static const String getDeliveredOrders      = "$baseUrl/ScreenSync_get_delivered_orders_for_room_service_mobile";
  static const String updateRoomServiceStatus = "$baseUrl/ScreenSync_update_room_service_status_mobile";

  // ── Food Orders — F&B Tab ─────────────────────────────────────
  static const String foodOrderDetails      = "$baseUrl/ScreenSync_get_food_orders_for_fnb";
  static const String updateFoodOrderStatus = "$baseUrl/ScreenSync_update_food_order_status_mobile";
  static const String orderSummary          = "$baseUrl/ScreenSync_get_order_summary_mobile";

  // ── Rush Hour (F&B) ───────────────────────────────────────────
  // Read current rush hour state (dedicated read-only Lambda)
  // Called on page load and app resume by FoodOrdersPage._loadRushHourState()
  static const String getRushHour = "$baseUrl/ScreenSync_get_rush_hour_state_mobile";
  // Toggle rush hour on/off → reuses updateFoodOrderStatus with status='RUSH_HOUR'

  // ── Camera / Content ──────────────────────────────────────────
  static const String getRooms         = "$baseUrl/ScreenSync_get_rooms_for_mobile";
  static const String updateGuestPhoto = "$baseUrl/ScreenSync_update_guest_photo_from_mobile";
  static const String getContents      = "$baseUrl/ScreenSync_get_guest_images_mobile";
  static const String deleteContent    = "$baseUrl/ScreenSync_delete_content_web";

  // ── Checkout ──────────────────────────────────────────────────
  static const String checkoutReport = "$baseUrl/ScreenSync_get_guest_checkout_report_mobile";
  static const String guestBill      = "$baseUrl/ScreenSync_get_guest_bill_mobile";
}