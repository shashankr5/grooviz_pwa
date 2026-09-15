class ApiErrorMapper {
  ApiErrorMapper._();

  /// Maps HTTP status codes to user-friendly messages.
  static String mapStatusCodeToMessage(int? statusCode) {
    if (statusCode == null) {
      return 'Connection error. Please verify your internet and try again.';
    }
    switch (statusCode) {
      case 400:
        return 'Invalid request details. Please verify input fields.';
      case 401:
        return 'Session expired. Please log in again to continue.';
      case 403:
        return 'Access denied. You do not have permissions for this action.';
      case 404:
        return 'Requested information could not be found.';
      case 500:
        return 'A server-side error occurred. System administrators have been notified.';
      default:
        return 'Communication failure ($statusCode). Please retry.';
    }
  }

  /// Extracts error message from standard API JSON response formats.
  static String mapResponseToErrorMessage(Map<String, dynamic>? response, {String fallback = 'An unexpected response was received'}) {
    if (response == null) return fallback;

    // Check message field
    if (response['message'] != null && response['message'].toString().isNotEmpty) {
      return response['message'].toString();
    }

    // Check RESULT list formatting
    final results = response['RESULT'];
    if (results is List && results.isNotEmpty) {
      final first = results[0];
      if (first is Map && first['message'] != null && first['message'].toString().isNotEmpty) {
        return first['message'].toString();
      }
    }

    return fallback;
  }
}
