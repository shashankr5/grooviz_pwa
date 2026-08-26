// notification_permission_manager.dart
//
// Handles all Android runtime permissions needed for reliable background alerts:
//   1. POST_NOTIFICATIONS (Android 13+)
//   2. Foreground service notification permission
//   3. Battery optimisation exemption — asked ONCE ONLY, launches the system
//      "Unrestricted" battery settings page directly (no intermediate dialog).
//
// The battery prompt is gated by a SharedPreferences key so it is never
// shown more than once per install, even across app restarts.

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationPermissionManager {

  static const String _kBatteryPromptShown = 'battery_prompt_shown_v1';

  // ── Public entry points ───────────────────────────────────────────────────

  /// Silent (no UI) permission check called from main() before runApp().
  /// Only requests notification permission — battery prompt needs a context.
  static Future<void> requestNotificationOnly() async {
    if (!Platform.isAndroid) return;
    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 33) {
        final status = await Permission.notification.status;
        if (status.isDenied) {
          await Permission.notification.request();
        }
      }
      final fgStatus = await FlutterForegroundTask.checkNotificationPermission();
      if (fgStatus != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (e) {
      debugPrint('Permission request error (non-fatal): $e');
    }
  }

  /// Full permission flow including the one-time battery optimisation dialog.
  /// Call this from a live BuildContext (e.g. MainNavigation.initState via
  /// post-frame callback) so we can show the in-app explanation sheet first.
  static Future<void> requestAllPermissions(BuildContext context) async {
    if (!Platform.isAndroid) return;
    try {
      // ── Notification & Foreground service ─────────────────────────────────
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 33) {
        final status = await Permission.notification.status;
        if (status.isDenied) {
          await Permission.notification.request();
        }
      }
      final fgStatus = await FlutterForegroundTask.checkNotificationPermission();
      if (fgStatus != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      // ── Battery optimisation — ONE TIME ONLY ──────────────────────────────
      await _requestBatteryOnce(context);
    } catch (e) {
      debugPrint('Permission request failed: $e');
    }
  }

  // ── Battery optimisation gated flow ──────────────────────────────────────

  static Future<void> _requestBatteryOnce(BuildContext context) async {
    // Already granted? Nothing to do.
    final alreadyGranted =
        await Permission.ignoreBatteryOptimizations.isGranted;
    if (alreadyGranted) return;

    // Already shown the dialog once? Never ask again.
    final prefs = await SharedPreferences.getInstance();
    final alreadyAsked = prefs.getBool(_kBatteryPromptShown) ?? false;
    if (alreadyAsked) return;

    // Mark as shown immediately so we never loop even if the user force-closes.
    await prefs.setBool(_kBatteryPromptShown, true);

    // Need a live context to show the sheet.
    // ignore: use_build_context_synchronously
    if (!context.mounted) return;

    // Show the explanation sheet, then open system settings on confirm.
    await _showBatteryExplanationSheet(context);
  }

  static Future<void> _showBatteryExplanationSheet(BuildContext context) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: true,
      enableDrag: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _BatteryExplainerSheet(),
    );

    if (confirmed == true) {
      // Deep-links directly to the app's battery optimisation page
      // (Android 12+ shows the "Unrestricted" toggle straight away).
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }
}

// ── Explanation bottom sheet ──────────────────────────────────────────────────

class _BatteryExplainerSheet extends StatelessWidget {
  const _BatteryExplainerSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          const SizedBox(height: 20),

          // Icon
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(
              Icons.battery_charging_full_rounded,
              size: 36,
              color: Color(0xFFF57C00),
            ),
          ),

          const SizedBox(height: 20),

          const Text(
            'Allow Background Alerts',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1A2E),
            ),
          ),

          const SizedBox(height: 10),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 28),
            child: Text(
              'To receive real-time alerts for new orders and service requests '
              'even when the app is in the background or closed, please set '
              'ScreenSync to "Unrestricted" battery mode.\n\n'
              'We\'ll take you directly to the setting — just tap "Unrestricted".',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF6B7280),
                height: 1.55,
              ),
            ),
          ),

          const SizedBox(height: 28),

          // Confirm button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4F46E5),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text(
                  'Allow Background Activity',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Dismiss link
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Not now',
              style: TextStyle(
                color: Color(0xFF9CA3AF),
                fontSize: 13,
              ),
            ),
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}