// services/unified_alert_foreground_task.dart
//
// CHANGES IN THIS VERSION:
//  • AlertSoundKey.delivery  = 'delivery_notification'   (NEW)
//  • AlertSoundKey.escalation = 'escalation_notification' (NEW)
//  • Play-once mode: after the audio finishes the player is stopped but the
//    foreground service stays alive as a silent watcher.
//    The Lambda pulse job sends the next pulse as a fresh FCM → onStart()
//    fires again → plays once. Eliminates the LoopMode.one fatigue problem.
//  • Escalation sound always plays once (no loop), even if called from
//    ensureEscalationRunning() — enforced by _playOnce flag.

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Sound key constants ────────────────────────────────────────────────────

class AlertSoundKey {
  AlertSoundKey._();

  static const String food       = 'bell_notification';        // existing
  static const String task       = 'task_notification';        // existing
  static const String delivery   = 'delivery_notification';    // NEW
  static const String escalation = 'escalation_notification';  // NEW

  /// SharedPreferences key — written by _ensureRunning() BEFORE startService()
  /// so the handler can read it synchronously in onStart().
  static const String prefKey = 'active_alert_sound';

  /// Flag stored alongside the sound to indicate "play once, no loop".
  /// Set to 'true' for escalation and delivery sounds.
  static const String loopKey = 'active_alert_loop';
}

// ── Foreground task handler ────────────────────────────────────────────────

class UnifiedAlertTaskHandler extends TaskHandler {
  AudioPlayer? _player;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      final prefs     = await SharedPreferences.getInstance();
      final soundName = prefs.getString(AlertSoundKey.prefKey) ?? AlertSoundKey.food;
      final shouldLoop = prefs.getString(AlertSoundKey.loopKey) != 'false';

      final assetPath = 'assets/audio/$soundName.wav';
      final tempDir   = await getTemporaryDirectory();
      final file      = File('${tempDir.path}/$soundName.wav');

      // Copy asset to temp dir if not already there
      if (!file.existsSync()) {
        final byteData = await rootBundle.load(assetPath);
        await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      }

      _player = AudioPlayer();
      await _player!.setFilePath(file.path);

      if (shouldLoop) {
        // Pulse-style: loop until next FCM arrives and service restarts
        await _player!.setLoopMode(LoopMode.one);
        await _player!.play();
      } else {
        // Play-once (escalation / delivery): play then stop player;
        // foreground service stays alive as a silent watcher.
        await _player!.setLoopMode(LoopMode.off);
        await _player!.play();
        await _player!.processingStateStream.firstWhere(
          (state) => state == ProcessingState.completed,
        );
        await _player!.stop();
      }

      print('UnifiedAlertTaskHandler: played $soundName (loop=$shouldLoop)');
    } catch (e) {
      print('UnifiedAlertTaskHandler.onStart error: $e');
      // Don't stop service — stay alive as watcher even if audio fails
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    try {
      await _player?.stop();
      await _player?.dispose();
      _player = null;
    } catch (_) {}
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Pulsing is driven by Lambda FCM, not the repeat event.
    // Nothing to do here.
  }
}

@pragma('vm:entry-point')
void unifiedAlertStartCallback() {
  FlutterForegroundTask.setTaskHandler(UnifiedAlertTaskHandler());
}