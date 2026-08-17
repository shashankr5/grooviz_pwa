// lib/services/kot_printer_service.dart
import 'package:flutter/services.dart';
import '../models/kot_ticket_model.dart';
import '../utils/date_formatter.dart';

class KOTPrinterService {
  /// Generates a clean 32-character / 48-character thermal receipt text representation
  /// suitable for 58mm/80mm ESC-POS Bluetooth printers or clipboard output.
  static String generateThermalText(KOTTicketModel ticket, {String? enterpriseName}) {
    final StringBuffer sb = StringBuffer();
    const divider = '--------------------------------';
    const doubleDivider = '================================';

    final headerName = (enterpriseName != null && enterpriseName.trim().isNotEmpty)
        ? enterpriseName.trim().toUpperCase()
        : 'GROOVIZ F&B';

    final paddedHeader = headerName.length <= 30
        ? headerName.padLeft((30 + headerName.length) ~/ 2).padRight(30)
        : headerName;
    sb.writeln('         $paddedHeader');
    sb.writeln(doubleDivider);
    sb.writeln('Order #:  ${ticket.orderNumber}');
    sb.writeln('Room #:   ${ticket.roomNumber}');
    if (ticket.guestName != null && ticket.guestName!.isNotEmpty) {
      sb.writeln('Guest:    ${ticket.guestName}');
    }
    sb.writeln('Time:     ${DateFormatter.formatDateTime(ticket.orderTime.toIso8601String().replaceAll('T', ' '))}');
    sb.writeln('Status:   ${ticket.orderStatus.toUpperCase()}');
    sb.writeln(divider);
    sb.writeln('QTY ITEM                  TYPE');
    sb.writeln(divider);

    for (final item in ticket.items) {
      final qty = '${item.quantity}x'.padRight(4);
      final vegTag = (item.isVeg ? 'VEG' : 'NON').padLeft(4);
      final name = item.name.length > 22
          ? item.name.substring(0, 22)
          : item.name.padRight(22);
      sb.writeln('$qty$name$vegTag');
      if (item.instructions != null && item.instructions!.isNotEmpty) {
        sb.writeln('  * ${item.instructions}');
      }
    }

    if (ticket.cookingInstructions != null &&
        ticket.cookingInstructions!.trim().isNotEmpty) {
      sb.writeln(divider);
      sb.writeln('SPECIAL INSTRUCTIONS:');
      sb.writeln(ticket.cookingInstructions!.trim());
    }

    sb.writeln(doubleDivider);
    sb.writeln('Printed: ${DateFormatter.formatDateTime(DateTime.now().toIso8601String().replaceAll('T', ' '))}');
    sb.writeln('         *** KITCHEN COPY ***           ');
    sb.writeln('\n\n');

    return sb.toString();
  }

  /// Copies receipt text to clipboard so it can be pasted into any external thermal print app
  static Future<void> copyReceiptToClipboard(KOTTicketModel ticket,
      {String? enterpriseName}) async {
    final text = generateThermalText(ticket, enterpriseName: enterpriseName);
    await Clipboard.setData(ClipboardData(text: text));
  }
}
