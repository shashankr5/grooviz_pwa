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
      await _player!.setLoopMode(LoopMode.off);

      // Single-Chime Server Pulse (Industry Standard):
      // Play alert chime once per pulse, trigger one 200ms haptic vibration, then stop player.
      // The foreground service remains active as a silent watcher for the next FCM pulse.
      await _player!.play();
      HapticFeedback.vibrate();
      await _player!.processingStateStream.firstWhere(
        (state) => state == ProcessingState.completed,
      );
      await _player!.stop();

      print('UnifiedAlertTaskHandler: played $soundName once');
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
