// services/unified_alert_foreground_task.dart
//
// CHANGES IN THIS VERSION:
//  • AlertSoundKey.delivery  = 'delivery_notification'   (NEW)
//  • AlertSoundKey.escalation = 'escalation_notification' (NEW)
//  • Non-loop mode remains available for alert types that should play once.
//  • Escalation uses loop mode and is stopped when its task is actioned.

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
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

/// Serialises operations on the one shared Android foreground-alert service.
/// Without this gate, rapid FCM pulses can restart the service while its
/// previous task handler is still configuring just_audio.
class AlertServiceRestartGate {
  AlertServiceRestartGate._();

  static Future<bool>? _operation;
  static String? _lastSound;
  static DateTime? _lastStartedAt;
  static const _sameSoundCooldown = Duration(seconds: 4);

  static Future<bool> run({
    required String soundName,
    required Future<bool> Function() operation,
  }) {
    final currentOperation = _operation;
    if (currentOperation != null) return currentOperation;

    final lastStartedAt = _lastStartedAt;
    if (_lastSound == soundName &&
        lastStartedAt != null &&
        DateTime.now().difference(lastStartedAt) < _sameSoundCooldown) {
      print('AlertServiceRestartGate: skipped duplicate $soundName pulse');
      return Future.value(true);
    }

    final nextOperation = _run(soundName, operation);
    _operation = nextOperation;
    return nextOperation;
  }

  static Future<bool> _run(
    String soundName,
    Future<bool> Function() operation,
  ) async {
    try {
      final started = await operation();
      if (started) {
        _lastSound = soundName;
        _lastStartedAt = DateTime.now();
      }
      return started;
    } finally {
      _operation = null;
    }
  }
}

// ── Foreground task handler ────────────────────────────────────────────────

class UnifiedAlertTaskHandler extends TaskHandler {
  AudioPlayer? _player;
  AudioSession? _audioSession;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      final prefs     = await SharedPreferences.getInstance();
      final soundName = prefs.getString(AlertSoundKey.prefKey) ?? AlertSoundKey.food;
      // shouldLoop=true → active alerts continue until their action clears them
      final shouldLoop = prefs.getString(AlertSoundKey.loopKey) == 'true';

      final assetPath = 'assets/audio/$soundName.wav';
      final tempDir   = await getTemporaryDirectory();
      final file      = File('${tempDir.path}/$soundName.wav');

      // Copy asset to temp dir if not already there
      if (!file.existsSync()) {
        ByteData byteData;
        try {
          byteData = await rootBundle.load(assetPath);
        } catch (_) {
          byteData = await rootBundle.load('assets/audio/bell_notification.wav');
        }
        await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      }

      // ── Configure AudioSession for Operational Alerts ────────────────────
      try {
        _audioSession = await AudioSession.instance;
        await _audioSession!.configure(const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.sonification,
            usage: AndroidAudioUsage.notificationRingtone,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
          androidWillPauseWhenDucked: false,
        ));
        await _audioSession!.setActive(true);
      } catch (e) {
        print('UnifiedAlertTaskHandler AudioSession setup notice: $e');
      }

      _player = AudioPlayer();
      await _player!.setFilePath(file.path);
      // Loop mode: food/service alerts loop until explicitly stopped (stopAll/stopOneServiceAlert).
      // The service remains alive only while an alert state is active.
      await _player!.setLoopMode(shouldLoop ? LoopMode.one : LoopMode.off);

      await _player!.play();
      HapticFeedback.vibrate();

      if (!shouldLoop) {
        // Play-once mode: wait for the clip to finish, then stop the player.
        // The foreground service remains alive as a silent watcher for the next FCM pulse.
        await _player!.processingStateStream.firstWhere(
          (state) => state == ProcessingState.completed,
        );
        await _player!.stop();
        print('UnifiedAlertTaskHandler: played $soundName once (no-loop)');
      } else {
        // Loop mode: audio runs until onDestroy() is called (i.e., stopAll / stopOneServiceAlert).
        print('UnifiedAlertTaskHandler: looping $soundName — will stop on explicit stopAll()');
      }
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
      await _audioSession?.setActive(false);
      _audioSession = null;
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
