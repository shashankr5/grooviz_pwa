// lib/services/session_change_service.dart
import 'dart:async';

class SessionChangeService {
  SessionChangeService._();
  static final SessionChangeService instance = SessionChangeService._();

  final StreamController<String> _roleChangeController =
      StreamController<String>.broadcast();

  Stream<String> get onRoleChange => _roleChangeController.stream;

  String _changeReason = 'Your account details have been updated.';
  String get changeReason => _changeReason;

  void setChangeReason(String reason) {
    _changeReason = reason;
  }

  void notifyRoleChange(String newRole) {
    if (!_roleChangeController.isClosed) {
      _roleChangeController.add(newRole);
    }
  }

  void dispose() {
    _roleChangeController.close();
  }
}