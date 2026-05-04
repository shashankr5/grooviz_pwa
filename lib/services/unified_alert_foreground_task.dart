// services/unified_alert_foreground_task.dart
//
// Updated for flutter_foreground_task 8.17.0
//
// API changes in v8.x:
//   - onStart: SendPort? → TaskStarter (second param name/type changed)
//   - onDestroy: SendPort? second param REMOVED
//   - onRepeatEvent: SendPort? second param REMOVED
//   - taskData / getData() REMOVED — sound name goes via SharedPreferences
//   - ForegroundTaskOptions requires eventAction (new required param)

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AlertSoundKey {
  static const String food   = 'bell_notification';
  static const String task   = 'task_notification';
  // SharedPreferences key — written by _ensureRunning() before startService()
  // so the handler can read it synchronously in onStart().
  // The await on prefs.setString() completes before startService() is called,
  // so the value is flushed to disk before the isolate's onStart() reads it.
  static const String prefKey = 'active_alert_sound';
}

class UnifiedAlertTaskHandler extends TaskHandler {
  AudioPlayer? _player;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      final prefs     = await SharedPreferences.getInstance();
      final soundName = prefs.getString(AlertSoundKey.prefKey) ?? AlertSoundKey.food;

      final assetPath = 'assets/audio/$soundName.wav';
      final tempDir   = await getTemporaryDirectory();
      final file      = File('${tempDir.path}/$soundName.wav');

      if (!file.existsSync()) {
        final byteData = await rootBundle.load(assetPath);
        await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      }

      _player = AudioPlayer();
      await _player!.setFilePath(file.path);
      await _player!.setLoopMode(LoopMode.one);
      await _player!.play();

      print('UnifiedAlertTaskHandler: playing $soundName');
    } catch (e) {
      print('UnifiedAlertTaskHandler.onStart error: $e');
      await FlutterForegroundTask.stopService();
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
    // Audio loops via LoopMode.one — nothing needed here.
  }
}

@pragma('vm:entry-point')
void unifiedAlertStartCallback() {
  FlutterForegroundTask.setTaskHandler(UnifiedAlertTaskHandler());
}