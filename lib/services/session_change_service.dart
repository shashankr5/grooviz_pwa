// lib/services/session_change_service.dart
//
// Broadcasts role / department changes to all listening pages so they can
// reload their state without waiting for the next app-resume cycle.

import 'dart:async';

class SessionChangeService {
  SessionChangeService._();
  static final SessionChangeService instance = SessionChangeService._();

  final StreamController<String> _roleChangeController =
      StreamController<String>.broadcast();

  Stream<String> get onRoleChange => _roleChangeController.stream;

  void notifyRoleChange(String newRole) {
    if (!_roleChangeController.isClosed) {
      _roleChangeController.add(newRole);
    }
  }

  void dispose() {
    _roleChangeController.close();
  }
}