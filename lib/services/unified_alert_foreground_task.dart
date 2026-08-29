// services/unified_alert_foreground_task.dart
//
// Single foreground task handler for all alert sounds.
// Receives sound commands via sendDataToTask() from AlertStateManager.
// No SharedPreferences race conditions - data is passed directly.

import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';

/// Sound key constants - maps alert types to audio files
class AlertSoundKey {
  AlertSoundKey._();
  static const String food = 'alert';
  static const String task = 'alert';
  static const String delivery = 'alert';
  static const String escalation = 'escalation';
}

class UnifiedAlertTaskHandler extends TaskHandler {
  AudioPlayer? _player;
  AudioSession? _audioSession;
  bool _looping = false;
  String? _currentSound;
  bool _destroyed = false;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print('UnifiedAlertTaskHandler.onStart called');
    await _configureAudioSession();

    // Wait briefly for sendDataToTask to arrive (AlertStateManager sends it after startService)
    // If no data arrives, we'll get it via onReceiveData
    await Future.delayed(const Duration(milliseconds: 200));
  }

  /// Receives sound commands from AlertStateManager._startOrSwitch()
  /// This is the PRIMARY way sounds are started/switched - no restart needed.
  @override
  void onReceiveData(dynamic data) {
    print('UnifiedAlertTaskHandler.onReceiveData: $data');
    try {
      final map = _parseTaskData(data as String?);
      final sound = map['sound'] as String? ?? AlertSoundKey.food;
      final loop = map['loop'] as bool? ?? true;
      _playSound(sound, loop);
    } catch (e) {
      print('UnifiedAlertTaskHandler.onReceiveData error: $e');
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    print('UnifiedAlertTaskHandler.onDestroy - releasing audio');
    _destroyed = true;
    _looping = false;
    try {
      await _player?.stop();
      await _player?.dispose();
      _player = null;
      await _audioSession?.setActive(false);
      _audioSession = null;
      print('UnifiedAlertTaskHandler.onDestroy completed');
    } catch (e) {
      print('UnifiedAlertTaskHandler.onDestroy error: $e');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Not used - looping is handled by just_audio LoopMode.one
  }

  // ── Audio ─────────────────────────────────────────────────────────────────

  Future<void> _playSound(String soundName, bool shouldLoop) async {
    if (_destroyed) {
      print('UnifiedAlertTaskHandler._playSound: destroyed, ignoring');
      return;
    }

    // Guard: same sound already playing
    if (_currentSound == soundName && (_player?.playing ?? false)) {
      print('UnifiedAlertTaskHandler._playSound: already playing $soundName - skipped');
      return;
    }

    print('UnifiedAlertTaskHandler._playSound: starting $soundName (loop=$shouldLoop)');
    _currentSound = soundName;
    _looping = shouldLoop;

    try {
      final file = await _extractAsset(soundName);

      // Tear down previous player cleanly before creating a new one
      await _player?.stop();
      await _player?.dispose();
      _player = AudioPlayer();

      await _player!.setFilePath(file.path);
      await _player!.setLoopMode(shouldLoop ? LoopMode.one : LoopMode.off);
      await _player!.play();
      HapticFeedback.vibrate();
      print('UnifiedAlertTaskHandler._playSound: playing $soundName (loop=$shouldLoop)');

      // Single consolidated state listener.
      // LoopMode.one should handle looping; this is a safety net only.
      _player!.playerStateStream.listen((state) async {
        if (_destroyed || !_looping) return;
        if (state.processingState == ProcessingState.completed) {
          print('UnifiedAlertTaskHandler: unexpected completion - restarting loop');
          try {
            await _player?.seek(Duration.zero);
            await _player?.play();
          } catch (e) {
            print('UnifiedAlertTaskHandler: loop restart error: $e');
          }
        }
      });
    } catch (e) {
      print('UnifiedAlertTaskHandler._playSound error: $e');
    }
  }

  Future<void> _configureAudioSession() async {
    try {
      _audioSession = await AudioSession.instance;
      await _audioSession!.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.notificationRingtone,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
        androidWillPauseWhenDucked: false,
      ));
      await _audioSession!.setActive(true);
      print('UnifiedAlertTaskHandler: AudioSession ready (ringtone mode)');
    } catch (e) {
      print('UnifiedAlertTaskHandler: AudioSession error: $e');
    }
  }

  Future<File> _extractAsset(String soundName) async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$soundName.wav');
    if (!file.existsSync()) {
      ByteData bytes;
      try {
        bytes = await rootBundle.load('assets/audio/$soundName.wav');
      } catch (_) {
        bytes = await rootBundle.load('assets/audio/alert.wav');
      }
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    }
    return file;
  }

  Map<String, dynamic> _parseTaskData(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}

@pragma('vm:entry-point')
void unifiedAlertStartCallback() {
  FlutterForegroundTask.setTaskHandler(UnifiedAlertTaskHandler());
}
