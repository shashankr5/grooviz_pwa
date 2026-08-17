// services/notification_navigation_coordinator.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../models/deep_link_payload.dart';
import '../pages/main_navigation.dart';
import '../pages/ticket_details_page.dart';
import '../pages/delivery_page.dart';
import '../pages/food_order_detail_page.dart';
import '../utils/user_session_helper.dart';
import '../theme/app_colors.dart';
import 'entity_resolver.dart';

class NotificationNavigationCoordinator {
  NotificationNavigationCoordinator._();
  static final NotificationNavigationCoordinator instance =
      NotificationNavigationCoordinator._();

  DeepLinkPayload? _pendingPayload;

  DeepLinkPayload? get pendingPayload => _pendingPayload;

  /// Main entry point for handling notification taps & deep links
  Future<void> handleDeepLink(DeepLinkPayload payload) async {
    print('🧭 [NotificationNavigationCoordinator] Handling deep link: ${payload.rawData}');

    final isLoggedIn = await UserSessionHelper.isLoggedIn();

    // 1. Authentication & Navigation State Readiness Check
    // If the navigator key is not ready or the tab controller callback is not registered,
    // we must stash the payload so that it is processed after the layout completes.
    final navState = navigatorKey.currentState;
    final isNavReady = navState != null && MainNavigation.tabSwitchCallback != null;

    if (!isLoggedIn || !isNavReady) {
      print('🧭 [NotificationNavigationCoordinator] App not ready (isLoggedIn=$isLoggedIn, isNavReady=$isNavReady). Stashing payload.');
      _pendingPayload = payload;
      return;
    }

    _pendingPayload = null;

    // 2. Tab Navigation
    if (MainNavigation.tabSwitchCallback != null) {
      MainNavigation.tabSwitchCallback!(payload.targetTab);
    }

    if (payload.entityId == null || payload.entityId!.isEmpty) return;

    // 3. Resolve Entity & Deep Navigation
    try {
      if (payload.entityType == DeepLinkEntityType.serviceTask ||
          payload.entityType == DeepLinkEntityType.escalation) {
        final taskId = int.tryParse(payload.entityId!);
        if (taskId == null) return;

        final task = await EntityResolver.instance.resolveServiceTask(taskId);

        if (task != null) {
          print('🧭 [NotificationNavigationCoordinator] Task resolved: $task');
          final navState = navigatorKey.currentState;
          if (navState != null) {
            navState.push(
              MaterialPageRoute(
                builder: (_) => TicketDetailPage(task: task),
              ),
            );
          }
        } else {
          _showStaleWarning('Requested task is no longer available or has been closed.');
        }
      } else if (payload.entityType == DeepLinkEntityType.delivery) {
        final navState = navigatorKey.currentState;
        if (navState != null) {
          navState.push(
            MaterialPageRoute(
              builder: (_) => const DeliveryPage(),
            ),
          );
        }
      } else if (payload.entityType == DeepLinkEntityType.foodOrder) {
        final order = await EntityResolver.instance.resolveFoodOrder(payload.entityId!);

        if (order != null) {
          // BUG 1 FIX: was logging the order and discarding it — no push happened.
          // Now pushes FoodOrderDetailPage, matching the serviceTask/escalation pattern.
          print('🧭 [NotificationNavigationCoordinator] Food order resolved: ${order['orderNo']}');
          final navState = navigatorKey.currentState;
          if (navState != null) {
            navState.push(
              MaterialPageRoute(
                builder: (_) => FoodOrderDetailPage(order: order),
              ),
            );
          }
        } else {
          // BUG 2+3 FIX: resolver now checks cancelled orders and returns a fully
          // grouped order. If still null, the order genuinely doesn't exist.
          _showStaleWarning('Requested food order is no longer active.');
        }
      }
    } catch (e) {
      print('🧭 [NotificationNavigationCoordinator] Error handling deep link: $e');
    }
  }

  /// Post-login hook called when authentication succeeds
  Future<void> onPostLogin() async {
    final payload = _pendingPayload;
    if (payload != null) {
      _pendingPayload = null;
      print('🧭 [NotificationNavigationCoordinator] Consuming stashed post-login payload...');
      await Future.delayed(const Duration(milliseconds: 300));
      await handleDeepLink(payload);
    }
  }

  void _showStaleWarning(String message) {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '⚠️ $message',
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: AppColors.error,
        duration: const Duration(seconds: 4),
      ),
    );
  }
}
