class ApiConstants {
  // Base URL
  static const String baseUrl = "https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production";
  static const String apiKey = "sa9F4GyTT45OImNkKjaHu6bsJbk8UWmZfKdzmeoc";

  // ── Authentication ─────────────────────────────────────────────
  // login_mobile SP — new enterprise-grade version (same Lambda URL)
  static const String login          = "$baseUrl/ScreenSync_login_mobile";
  static const String logout         = "$baseUrl/ScreenSync_logout_mobile";
  static const String sendOtp        = "$baseUrl/ScreenSync_send_otp_mobile";
  static const String verifyOtp      = "$baseUrl/ScreenSync_verify_otp_mobile";
  static const String resetPassword  = "$baseUrl/ScreenSync_reset_password_mobile";

  // ── Profile ───────────────────────────────────────────────────
  static const String profile        = "$baseUrl/ScreenSync_get_profile_mobile";

  // ── User Dept Details (v1) ────────────────────────────────────
  // get_user_dept_details_mobile — returns dept + escalation rule.
  // Called at login to seed role/dept (replaces old login 'role'+'departments').
  // Input:  { user_id, stage }
  // Output: STATUS[0] + RESULT[]  (one row per department the user belongs to)
  static const String userDeptDetails = "$baseUrl/ScreenSync_get_user_dept_details_mobile";

  // ── Home Page & Service Requests ──────────────────────────────
  // Enterprise service request feed. Replaces the deprecated
  // ScreenSync_get_all_services_mobile route.
  static const String tasks          = "$baseUrl/ScreenSync_get_all_services_mobile1";
  static const String getAllServices = "$baseUrl/ScreenSync_get_all_services_mobile1";
  static const String acceptTask     = "$baseUrl/ScreenSync_accept_service_request_mobile1";
  static const String acceptServiceRequest = "$baseUrl/ScreenSync_accept_service_request_mobile1";
  static const String acceptServiceOrder = "$baseUrl/ScreenSync_accept_service_order_mobile";
  static const String updateServiceRequestStatus = "$baseUrl/ScreenSync_update_service_request_status_mobile";

  // ── Ticket Details ────────────────────────────────────────────
  static const String staffList            = "$baseUrl/ScreenSync_get_staff_list_mobile";
  static const String addServiceNote = "$baseUrl/ScreenSync_add_service_note_mobile";
  static const String closeService = "$baseUrl/ScreenSync_close_service_mobile1";
  static const String reassignService      = "$baseUrl/ScreenSync_reassign_service_mobile1";
  static const String escalationHistoryForTask = "$baseUrl/ScreenSync_get_escalation_history_for_task_mobile";

  // ── Task Operations Reporting ─────────────────────────────────
  // Role-aware operations report. Replaces the retired task summary,
  // tasks-by-role, and team-performance endpoints in the app.
  static const String serviceOperationsReport =
      "$baseUrl/ScreenSync_get_service_operations_report_mobile";

  // ── Food Orders — F&B (v1, enterprise-grade) ─────────────────
  // All v1 F&B endpoints use order_id (summary_id from order_status_summary)
  // NOT order_number. The 'stage' key is mandatory in every payload.

  /// GET orders — input: { user_id, stage } (enterprise_id derived server-side)
  /// Output: STATUS[0] + RESULT[] with summary_id, final_eta_time, eta_tap_count, etc.
  static const String getFoodOrdersV1 = "$baseUrl/ScreenSync_get_food_orders_mobile1";

  /// ACCEPT order — input: { user_id, enterprise_id, order_id (summary_id), stage }
  /// Output: STATUS[0] only (Lambda discards RESULT)
  static const String acceptFoodOrderV1 = "$baseUrl/ScreenSync_accept_food_order_mobile1";

  /// UPDATE status (Ready/Delivered/Cancelled) — input: { user_id, enterprise_id, order_id, status, cancel_reason, stage }
  /// Output: STATUS[0] only
  static const String updateFoodOrderV1 = "$baseUrl/ScreenSync_update_food_order_mobile1";

  /// ETA TAP — input: { user_id, enterprise_id, order_id (summary_id), stage }
  /// Server reads tap config from enterprise_food_service_rule and updates ETA.
  /// Output: STATUS[0] + RESULT[0] with updated eta_tap_count, final_eta_time, etc.
  static const String tapFoodOrderEtaV1 = "$baseUrl/ScreenSync_update_food_tap_count";

  // ── Rush Hour — F&B (v1) ──────────────────────────────────────
  /// SET rush hour ON/OFF — input: { user_id, rush_hour_active (0|1), stage }
  /// Output: STATUS[0] with current_rush_hour, rush_hour_status, enterprise_id
  static const String setRushHourV1 = "$baseUrl/ScreenSync_set_rush_hour_state_mobile";

  // ── Food Orders — Room Service Tab ────────────────────────────

  // ── Camera / Content ──────────────────────────────────────────
  static const String getRooms         = "$baseUrl/ScreenSync_get_rooms_for_mobile";
  static const String updateGuestPhoto = "$baseUrl/ScreenSync_update_guest_photo_from_mobile";
  static const String getContents      = "$baseUrl/ScreenSync_get_guest_images_mobile";
  static const String deleteContent    = "$baseUrl/ScreenSync_delete_content_web";

  // ── Checkout ──────────────────────────────────────────────────
  static const String checkoutReport = "$baseUrl/ScreenSync_get_guest_checkout_report_mobile";
  static const String guestBill      = "$baseUrl/ScreenSync_get_guest_bill_mobile";

  // ── Deprecated Endpoints (DO NOT USE — kept for historical reference) ────
  // These endpoints are superseded by v1 equivalents above.
  // Remove from production after all devices are updated.
  //
  // static const String foodOrderDetails      = "$baseUrl/ScreenSync_get_food_orders_mobile";       // → getFoodOrdersV1
  // static const String updateFoodOrderStatus = "$baseUrl/ScreenSync_update_food_order_status_mobile"; // → updateFoodOrderV1 + tapFoodOrderEtaV1
  // static const String orderSummary          = "$baseUrl/ScreenSync_get_order_summary_mobile";      // → not migrated yet
  // static const String getRushHour           = "$baseUrl/ScreenSync_get_rush_hour_state_mobile";    // → setRushHourV1 response / login cache
  //
  // Legacy escalation / service endpoints (no v1 equivalent):
  // static const String acceptTaskOld              = "$baseUrl/ScreenSync_task_accept_mobile";
  // static const String reassignTicketOld          = "$baseUrl/ScreenSync_reassign_task_mobile";
  // static const String escalationBadgeCountOld    = "$baseUrl/ScreenSync_get_escalation_badge_count_mobile";
  // static const String escalatedTasksOld          = "$baseUrl/ScreenSync_get_escalated_tasks_mobile";
  // static const String logEscalationOld           = "$baseUrl/ScreenSync_log_escalation_mobile";
  // static const String escalationReportOld        = "$baseUrl/ScreenSync_get_escalation_report_mobile";
  // static const String notifyReassignOld          = "$baseUrl/ScreenSync_notify_reassign_mobile";
  // static const String escalationStatusOld        = "$baseUrl/ScreenSync_get_escalation_status_mobile";
  // static const String resolveEscalationOld       = "$baseUrl/ScreenSync_sp_resolve_escalation_mobile";
  // static const String checkAndEscalateOld        = "$baseUrl/ScreenSync_sp_check_and_escalate_mobile";
  // static const String legacyCheckAndEscalateOld  = "$baseUrl/ScreenSync_check_and_escalate_mobile";
  // static const String escalateOneLevelOld        = "$baseUrl/ScreenSync_sp_escalate_one_level_mobile";
  // static const String addNotes                   = "$baseUrl/ScreenSync_add_service_request_note_mobile";
  // static const String closeServiceRequestOld     = "$baseUrl/ScreenSync_close_service_request_mobile";
}
