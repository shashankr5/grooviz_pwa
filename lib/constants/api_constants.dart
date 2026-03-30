class ApiConstants {
  // Base URL
  static const String baseUrl = "https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production";
  static const String apiKey = "sa9F4GyTT45OImNkKjaHu6bsJbk8UWmZfKdzmeoc";
  // Endpoints
  // Authentication
  static const String login = "$baseUrl/ScreenSync_login_mobile";
  static const String logout = "$baseUrl/ScreenSync_logout_mobile";
  static const String sendOtp = "$baseUrl/ScreenSync_send_otp_mobile";
  static const String verifyOtp = "$baseUrl/ScreenSync_verify_otp_mobile";
  static const String resetPassword = "$baseUrl/ScreenSync_reset_password_mobile";
  // Profile Page
  static const String profile = "$baseUrl/ScreenSync_get_profile_mobile";
  // Home Page
  static const String tasks = "$baseUrl/ScreenSync_get_tasks_mobile";
  static const String acceptTask = "$baseUrl/ScreenSync_task_accept_mobile";
  // Ticket Details Page
  static const String staffList = "$baseUrl/ScreenSync_get_staff_list_mobile";
  static const String reassignTicket = "$baseUrl/ScreenSync_reassign_task_mobile";
  static const String addNotes= "$baseUrl/ScreenSync_add_service_request_note_mobile";
  static const String closeServiceRequest = "$baseUrl/ScreenSync_close_service_request_mobile";
  // Task Summary Page
  static const String taskSummary = "$baseUrl/ScreenSync_get_tasks_summary_mobile";
  // Food Orders Tab
  static const String getReadyOrders = "$baseUrl/ScreenSync_get_ready_orders_for_room_service_mobile";
  static const String updateRoomServiceStatus = "$baseUrl/ScreenSync_update_room_service_status_mobile";
  static const String getAcceptedOrders = "$baseUrl/ScreenSync_get_accepted_orders_for_room_service_mobile";
  static const String getDeliveredOrders = "$baseUrl/ScreenSync_get_delivered_orders_for_room_service_mobile";
  // Food Order Details Page
  static const String foodOrderDetails = "$baseUrl/ScreenSync_get_food_orders_for_fnb";
  static const String updateFoodOrderStatus = "$baseUrl/ScreenSync_update_food_order_status_mobile";
  static const String orderSummary = "$baseUrl/ScreenSync_get_order_summary_mobile";
  // Camera Page
  static const String getRooms = "$baseUrl/ScreenSync_get_rooms_web";
  static const String uploadImage = "$baseUrl/ScreenSync_add_image_from_mobile";
  static const String getContents = "$baseUrl/ScreenSync_get_contents_mobile";
  static const String updateContent = "$baseUrl/ScreenSync_update_image_from_mobile";
  static const String deleteContent = "$baseUrl/ScreenSync_delete_content_web";
  // Checkout
  static const String checkoutReport = "$baseUrl/ScreenSync_get_guest_checkout_report_mobile";
}