// utils/logout_helper.dart
//
// Centralizes all logout cleanup in one place.
//
// FIXES APPLIED:
//  FIX-2 (BLOCKER): FCM token deregistration — removes the user's token
//          from the backend so they stop receiving alerts after logout.
//          Previously tokens were never deregistered, causing the old user
//          to receive another user's alerts after a shift change.
//
//  FIX-5: WebSocket disconnect on logout — clears credentials so the old
//          user's channel is closed and no events are received after logout.
//
// USAGE — call this from your profile/logout page instead of calling
// UserSessionHelper.logout() directly:
//
//   await LogoutHelper.logout(context);

import 'package:flutter/material.dart';
import '../services/fcm_service.dart';
import '../services/order_alert_service.dart';
import '../services/task_alert_service.dart';
import '../services/websocket_service.dart';
import '../utils/user_session_helper.dart';

class LogoutHelper {
  LogoutHelper._();

  static Future<void> logout(BuildContext context) async {
    // 1. Stop all alert sounds immediately
    await OrderAlertService.stop();
    await TaskAlertService.stopAll();

    // 2. FIX-2: Deregister FCM token BEFORE clearing session.
    //    Must happen before session clear because deregister needs userId.
    await FCMService.deregisterToken();

    // 3. FIX-5: Disconnect WebSocket and clear credentials.
    //    Prevents old user's channel from receiving events.
    WebSocketService().disconnect();

    // 4. Clear local session
    await UserSessionHelper.logout();

    // 5. Navigate to login
    if (context.mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/login',
        (route) => false,
      );
    }
  }
}