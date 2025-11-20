class ApiConstants {
  // Base URL
  static const String baseUrl = "https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production";
  static const String apiKey = "sa9F4GyTT45OImNkKjaHu6bsJbk8UWmZfKdzmeoc";

  // Endpoints
  static const String login = "$baseUrl/ScreenSync_login_mobile"; 
  static const String logout = "$baseUrl/ScreenSync_logout_mobile";
  static const String profile = "$baseUrl/ScreenSync_get_profile_mobile";
  static const String tasks = "$baseUrl/ScreenSync_get_tasks_mobile";
  static const String staffList = "$baseUrl/ScreenSync_get_staff_list_mobile";
  static const String reassignTicket = "$baseUrl/ScreenSync_reassign_task_mobile";
  static const String addNotes= "$baseUrl/ScreenSync_add_service_request_note_mobile";
  static const String closeServiceRequest = "$baseUrl/ScreenSync_close_service_request_mobile";
}


//https://m71rjqgt83.execute-api.ap-south-1.amazonaws.com/production/ScreenSync_login_mobile