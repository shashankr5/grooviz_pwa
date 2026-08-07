/// API timeout constants shared across all service layers.
///
/// Centralising these prevents silent mismatches between services
/// (e.g. one service timing out in 30 s while another uses 60 s).
class ApiTimeouts {
  ApiTimeouts._();

  /// Standard connect timeout for all Dio clients.
  static const connectTimeout = Duration(seconds: 30);

  /// Standard receive timeout for all Dio clients.
  static const receiveTimeout = Duration(seconds: 60);

  /// Standard send (upload) timeout for all Dio clients.
  static const sendTimeout = Duration(seconds: 60);

  /// Extended send timeout used for file upload operations.
  static const uploadSendTimeout = Duration(seconds: 120);

  /// Extended receive timeout used for file upload operations.
  static const uploadReceiveTimeout = Duration(seconds: 60);

  /// Default timeout for FCM token fetch and related push-notification calls.
  static const fcmTimeout = Duration(seconds: 30);

  /// Default retry delay in [RetryUtils].
  static const retryDelay = Duration(seconds: 2);

  /// Websocket reconnect delay.
  static const wsReconnectDelay = Duration(seconds: 5);

  /// Alert-reload coordinator max wait before forcing a reload.
  static const alertReloadMaxWait = Duration(seconds: 30);
}
