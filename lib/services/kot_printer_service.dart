// lib/services/kot_printer_service.dart
import 'package:flutter/services.dart';
import '../models/kot_ticket_model.dart';
import '../utils/date_formatter.dart';

class KOTPrinterService {
  /// Generates a clean 32-character / 48-character thermal receipt text representation
  /// suitable for 58mm/80mm ESC-POS Bluetooth printers or clipboard output.
  static String generateThermalText(KOTTicketModel ticket, {String? enterpriseName, bool isReprint = false}) {
    final StringBuffer sb = StringBuffer();
    const divider = '--------------------------------';

    final headerName = (enterpriseName != null && enterpriseName.trim().isNotEmpty)
        ? enterpriseName.trim().toUpperCase()
        : 'GROOVIZ F&B';

    final paddedHeader = headerName.length <= 30
        ? headerName.padLeft((30 + headerName.length) ~/ 2).padRight(30)
        : headerName;
    
    sb.writeln('         $paddedHeader');
    sb.writeln('            KOT');
    sb.writeln(divider);
    sb.writeln('Room: ${ticket.roomNumber} | Order: ${ticket.orderNumber}');
    if (ticket.guestName != null && ticket.guestName!.isNotEmpty) {
      sb.writeln('Guest: ${ticket.guestName}');
    }
    sb.writeln(DateFormatter.formatDateTime(ticket.orderTime.toIso8601String().replaceAll('T', ' ')));
    sb.writeln(divider);

    for (final item in ticket.items) {
      final price = item.totalPrice > 0 ? item.totalPrice : (item.price > 0 ? item.price * item.quantity : 0.0);
      final priceStr = price > 0 ? ' [Rs.${price.toStringAsFixed(price.truncateToDouble() == price ? 0 : 2)}]' : '';
      sb.writeln('${item.quantity}x ${item.name} (${item.isVeg ? 'VEG' : 'NON-VEG'})$priceStr');
      if (item.instructions != null && item.instructions!.isNotEmpty) {
        sb.writeln('  * ${item.instructions}');
      }
    }

    if (ticket.totalOrderPrice > 0) {
      sb.writeln(divider);
      final totalStr = ticket.totalOrderPrice.toStringAsFixed(ticket.totalOrderPrice.truncateToDouble() == ticket.totalOrderPrice ? 0 : 2);
      sb.writeln('TOTAL AMOUNT: Rs.$totalStr');
    }

    if (ticket.cookingInstructions != null &&
        ticket.cookingInstructions!.trim().isNotEmpty) {
      sb.writeln(divider);
      sb.writeln('INSTRUCTIONS:');
      sb.writeln(ticket.cookingInstructions!.trim());
    }

    sb.writeln(divider);
    final copyLabel = isReprint ? '*** GUEST COPY ***' : '*** KITCHEN COPY ***';
    sb.writeln('          $copyLabel');
    sb.writeln('\n');

    return sb.toString();
  }

  /// Copies receipt text to clipboard so it can be pasted into any external thermal print app
  static Future<void> copyReceiptToClipboard(KOTTicketModel ticket,
      {String? enterpriseName, bool isReprint = false}) async {
    final text = generateThermalText(ticket, enterpriseName: enterpriseName, isReprint: isReprint);
    await Clipboard.setData(ClipboardData(text: text));
  }
}
