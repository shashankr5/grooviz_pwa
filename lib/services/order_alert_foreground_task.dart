// order_alert_foreground_task.dart
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:flutter/services.dart';

class OrderAlertTaskHandler extends TaskHandler {
  late AudioPlayer _player;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter taskStarter) async {
    try {
      _player = AudioPlayer();

      // 🔥 Copy asset to temp file (background isolate safe)
      final byteData =
          await rootBundle.load('assets/audio/alert.wav');

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/alert.wav');
      await file.writeAsBytes(byteData.buffer.asUint8List());

      await _player.setFilePath(file.path);

      await _player.setLoopMode(LoopMode.one);

      await _player.play();
    } catch (e) {
      await FlutterForegroundTask.stopService();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _player.stop();
    await _player.dispose();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}
}
