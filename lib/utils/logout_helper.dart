// utils/logout_helper.dart
//
// Centralizes all logout cleanup in one place.
//
import 'package:flutter/material.dart';
import '../services/fcm_service.dart';
import '../services/websocket_service.dart';
import '../utils/user_session_helper.dart';

class LogoutHelper {
  LogoutHelper._();

  static Future<void> logout(BuildContext context) async {
    await FCMService.deregisterToken();
    WebSocketService().disconnect();

    await UserSessionHelper.logout();

    if (context.mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/login',
        (route) => false,
      );
    }
  }
}