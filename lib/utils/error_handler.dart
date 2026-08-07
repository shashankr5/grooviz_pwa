// utils/error_handler.dart
//
// Fixes Bugs 11 & 12: raw Dart/DioException text ("DioException [connection
// error]: The connection errored: Connection refused...") was being shown
// directly to users in SnackBars whenever a request failed offline.
//
// Every service catch block should use ErrorHandler.friendlyMessage(e)
// instead of "Error: $e" — this maps known DioException types to short,
// human-readable messages and falls back to a generic message for anything
// unrecognized, so a raw stack/exception string is never user-facing.

import 'package:dio/dio.dart';

class ErrorHandler {
  ErrorHandler._();

  static String friendlyMessage(dynamic error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
          return 'No internet connection. Please check your network and try again.';
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return 'The request timed out. Please try again.';
        case DioExceptionType.badResponse:
          return 'Something went wrong on our end. Please try again.';
        case DioExceptionType.cancel:
          return 'Request was cancelled.';
        default:
          return 'No internet connection. Please check your network and try again.';
      }
    }
    // Any non-Dio exception (parsing errors, null checks, etc.) — never
    // surface the raw exception text to the user.
    return 'Something went wrong. Please try again.';
  }
}