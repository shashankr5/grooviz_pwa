// utils/order_alert_sound.dart
import 'dart:async';
import 'package:just_audio/just_audio.dart';

class OrderAlertSound {
  static final AudioPlayer _player = AudioPlayer();
  static bool _isPlaying = false;
  static Timer? _autoStopTimer;

  static Future<void> start({Duration maxDuration = const Duration(seconds: 30)}) async {
    if (_isPlaying) return;

    try {
      await _player.setAsset('assets/audio/bell_notification.wav');
      _player.setLoopMode(LoopMode.all);
      await _player.play();
      _isPlaying = true;

      print('🔔 Order alert started');

      // ⏱ Auto-stop after given duration
      _autoStopTimer?.cancel();
      _autoStopTimer = Timer(maxDuration, () {
        stop(reason: 'auto-timeout');
      });

    } catch (e) {
      print('❌ Failed to start alert sound: $e');
    }
  }

  static Future<void> stop({String reason = 'manual'}) async {
    if (!_isPlaying) return;

    try {
      _autoStopTimer?.cancel();
      _autoStopTimer = null;

      await _player.stop();
      _isPlaying = false;

      print('🛑 Order alert stopped ($reason)');
    } catch (e) {
      print('❌ Failed to stop alert sound: $e');
    }
  }
}
