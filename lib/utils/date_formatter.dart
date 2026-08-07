class DateFormatter {
  DateFormatter._();

  /// Formats a time String matching the screensync canonical behavior.
  /// Expects "YYYY-MM-DD HH:MM:SS" and returns "HH:MM".
  static String formatTime(String? s) {
    if (s == null || s.trim().isEmpty) return '—';
    try {
      final parts = s.trim().split(' ');
      if (parts.length < 2) return s;
      final timeParts = parts[1].split(':');
      if (timeParts.length < 2) return parts[1];
      return '${timeParts[0]}:${timeParts[1]}';
    } catch (_) {
      return s;
    }
  }

  /// Formats a datetime String matching the screensync canonical behavior.
  /// Expects "YYYY-MM-DD HH:MM:SS" and returns "DD/MM/YY · HH:MM".
  static String formatDateTime(String? s) {
    if (s == null || s.trim().isEmpty) return '—';
    try {
      final parts = s.trim().split(' ');
      if (parts.length < 2) return s;
      final dateParts = parts[0].split('-');
      final timeParts = parts[1].split(':');
      if (dateParts.length < 3 || timeParts.length < 2) return s;
      
      final year = dateParts[0].length >= 4 
          ? dateParts[0].substring(2) 
          : dateParts[0];
      return '${dateParts[2]}/${dateParts[1]}/$year · ${timeParts[0]}:${timeParts[1]}';
    } catch (_) {
      return s;
    }
  }

  /// Formats a date-only String matching the screensync canonical behavior.
  /// Expects "YYYY-MM-DD HH:MM:SS" or "YYYY-MM-DD" and returns "DD/MM/YY".
  static String formatDateOnly(String? s) {
    if (s == null || s.trim().isEmpty) return '—';
    try {
      final parts = s.trim().split(' ');
      final dateStr = parts[0];
      final dateParts = dateStr.split('-');
      if (dateParts.length < 3) return dateStr;
      
      final year = dateParts[0].length >= 4 
          ? dateParts[0].substring(2) 
          : dateParts[0];
      return '${dateParts[2]}/${dateParts[1]}/$year';
    } catch (_) {
      return s;
    }
  }

  /// Formats timestamp as "H:MM • DD/MM" (used in home_service.dart)
  static String formatTimeDayMonth(String? timestamp) {
    if (timestamp == null || timestamp.trim().isEmpty) return '-';
    try {
      String s = timestamp.trim();
      if (s.contains(' ') && !s.contains('T')) s = s.replaceFirst(' ', 'T');
      if (s.endsWith('Z') || s.endsWith('z')) s = s.substring(0, s.length - 1);
      final dt = DateTime.parse(s);
      final mm = dt.minute.toString().padLeft(2, '0');
      return '${dt.hour}:$mm • ${dt.day}/${dt.month}';
    } catch (_) {
      return '-';
    }
  }

  /// Formats timestamp as "H:MM • DD/MM/YYYY" (used in food_order_service.dart)
  static String formatTimeDayMonthYear(String? timestamp) {
    if (timestamp == null || timestamp.trim().isEmpty) return '-';
    try {
      String s = timestamp.trim();
      if (s.contains(' ') && !s.contains('T')) s = s.replaceFirst(' ', 'T');
      if (s.endsWith('Z') || s.endsWith('z')) s = s.substring(0, s.length - 1);
      final dt = DateTime.parse(s);
      final mm = dt.minute.toString().padLeft(2, '0');
      return '${dt.hour}:$mm • ${dt.day}/${dt.month}/${dt.year}';
    } catch (_) {
      return '-';
    }
  }

  /// Formats timestamp as "DD/MM/YYYY • H:MM AM/PM" (used in ticket_details_page.dart)
  static String formatDateTimeAmPm(String? ts) {
    if (ts == null || ts.trim().isEmpty) return '—';
    try {
      String s = ts.trim();
      if (s.contains(' ') && !s.contains('T')) s = s.replaceFirst(' ', 'T');
      if (s.endsWith('Z') || s.endsWith('z')) s = s.substring(0, s.length - 1);
      final d = DateTime.parse(s);

      final h = d.hour > 12
          ? d.hour - 12
          : d.hour == 0
              ? 12
              : d.hour;
      final p = d.hour >= 12 ? 'PM' : 'AM';
      final dayStr = d.day.toString().padLeft(2, '0');
      final monthStr = d.month.toString().padLeft(2, '0');
      final minStr = d.minute.toString().padLeft(2, '0');
      return '$dayStr/$monthStr/${d.year} • $h:$minStr $p';
    } catch (_) {
      return ts;
    }
  }

  /// Formats a DateTime object as "HH:MM".
  static String formatDateTimeToTime(DateTime d) {
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// Formats a DateTime object as "DD/MM/YYYY • H:MM AM/PM" (used in food_orders_page.dart)
  static String formatDateTimeObjectAmPm(DateTime time) {
    final d   = time.day.toString().padLeft(2, '0');
    final m   = time.month.toString().padLeft(2, '0');
    final h   = time.hour > 12 ? time.hour - 12 : time.hour;
    final min = time.minute.toString().padLeft(2, '0');
    final p   = time.hour >= 12 ? 'PM' : 'AM';
    return '$d/$m/${time.year} • ${h == 0 ? 12 : h}:$min $p';
  }

  /// Formats timestamp as "H:MM AM/PM" (used in guest_checkout_page.dart)
  static String formatTimeOnlyAmPm(String? ts) {
    if (ts == null || ts.trim().isEmpty) return '—';
    try {
      String s = ts.trim();
      if (s.contains(' ') && !s.contains('T')) s = s.replaceFirst(' ', 'T');
      if (s.endsWith('Z') || s.endsWith('z')) s = s.substring(0, s.length - 1);
      final d = DateTime.parse(s);

      final h = d.hour > 12
          ? d.hour - 12
          : d.hour == 0
              ? 12
              : d.hour;
      final p = d.hour >= 12 ? 'PM' : 'AM';
      final minStr = d.minute.toString().padLeft(2, '0');
      return '$h:$minStr $p';
    } catch (_) {
      return ts;
    }
  }

  /// Formats date-only String as "DD/MM/YYYY" (used in guest_checkout_history_page.dart)
  static String formatDateOnlyFullYear(String? s) {
    if (s == null || s.trim().isEmpty) return '—';
    try {
      final parts = s.trim().split(' ');
      final dateStr = parts[0];
      final dateParts = dateStr.split('-');
      if (dateParts.length < 3) return dateStr;
      return '${dateParts[2]}/${dateParts[1]}/${dateParts[0]}';
    } catch (_) {
      return s;
    }
  }

  /// Converts a DateTime object to standard string format "YYYY-MM-DD HH:MM:SS".
  static String toStandardString(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }
}
