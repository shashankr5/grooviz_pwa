// lib/services/bluetooth_printer_service.dart
//
// BluetoothPrinterService — wraps unified_esc_pos_printer for KOT printing.
//
// Gap status:
//   ✅ Queue persists across app restarts (shared_preferences)
//   ✅ Print history persists, last 20 tickets (shared_preferences)
//   ✅ Reprint from history via reprint()
//   ⏳ Auto-reconnect to last printer — deferred v1.1
//   ❌ Paper-out detection — NOT achievable over generic Bluetooth SPP.
//      SPP is a write-only channel; the OS reports bytes sent to the socket
//      buffer, not whether the printer physically printed. Paper-out signals
//      require vendor-specific status polling (Epson DLE EOT, Star ASB).
//      PrinterException.paperOut exists in the interface for future use but
//      will never be thrown from this implementation.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unified_esc_pos_printer/unified_esc_pos_printer.dart'
    as uep
    hide PrinterDevice; // avoid name clash with our KotPrinterDevice

import 'printer_service.dart';
import '../models/kot_ticket_model.dart';
import '../utils/date_formatter.dart';
import '../utils/user_session_helper.dart';

const uep.PaperSize _kPaperSize = uep.PaperSize.mm58;
const int _kMaxRetries   = 3;
const int _kHistoryLimit = 20;
const String _kQueueKey   = 'kot_print_queue';
const String _kHistoryKey = 'kot_print_history';

// ─────────────────────────────────────────────────────────────────────────────

class BluetoothPrinterService extends PrinterService {

  // ── Observable state ──────────────────────────────────────────────────────

  final ValueNotifier<PrinterStatus> status =
      ValueNotifier(PrinterStatus.idle);
  String? lastMessage;

  // ── Plugin objects ────────────────────────────────────────────────────────

  final uep.PrinterManager _manager = uep.PrinterManager();

  // Tracks which KotPrinterDevice we consider connected.
  KotPrinterDevice? _connectedDevice;

  @override
  bool get isConnected => _connectedDevice != null && _manager.isConnected;

  @override
  KotPrinterDevice? get connectedDevice => isConnected ? _connectedDevice : null;

  // ── Print queue & history ─────────────────────────────────────────────────

  final List<PrintRequest>   _queue   = [];
  final List<KOTTicketModel> _history = [];

  List<PrintRequest>   get pendingJobs  => List.unmodifiable(_queue);
  List<KOTTicketModel> get printHistory => List.unmodifiable(_history);

  // ── Initialization ────────────────────────────────────────────────────────

  Future<void> init() async {
    await _loadQueue();
    await _loadHistory();
    dev.log('[BTPrinter] init queue=${_queue.length} history=${_history.length}');
  }

  // ── Permissions ───────────────────────────────────────────────────────────

  Future<bool> requestPermissions() async {
    // On Android 12+ (API 31+) the runtime permissions that actually gate
    // Bluetooth use are BLUETOOTH_CONNECT and BLUETOOTH_SCAN.
    // The legacy BLUETOOTH permission is ignored by the OS on API 31+ but is
    // still required on older devices, so we request all three and pick the
    // right one to evaluate based on what was actually returned.
    final result = await [
      Permission.bluetooth,        // covers API ≤ 30
      Permission.bluetoothConnect, // required API 31+
      Permission.bluetoothScan,    // required API 31+
    ].request();

    // Prefer the new permissions on API 31+; fall back to legacy on older OS.
    final connectGranted = result[Permission.bluetoothConnect]?.isGranted ?? false;
    final scanGranted    = result[Permission.bluetoothScan]?.isGranted    ?? false;
    final legacyGranted  = result[Permission.bluetooth]?.isGranted        ?? false;

    // On API 31+ both connect AND scan must be granted.
    // On older devices the legacy permission suffices.
    final granted = (connectGranted && scanGranted) || legacyGranted;
    dev.log('[BTPrinter] permissions connectGranted=$connectGranted '
        'scanGranted=$scanGranted legacyGranted=$legacyGranted → granted=$granted');
    return granted;
  }

  /// Returns `true` when the device's Bluetooth adapter is switched on.
  ///
  /// Uses [Permission.bluetooth.serviceStatus] (permission_handler ≥ 11)
  /// which queries the OS adapter state independently of runtime permissions.
  Future<bool> isBluetoothEnabled() async {
    final status = await Permission.bluetooth.serviceStatus;
    final enabled = status.isEnabled;
    dev.log('[BTPrinter] bluetooth adapter enabled=$enabled');
    return enabled;
  }

  // ── Device discovery ──────────────────────────────────────────────────────

  @override
  Future<List<KotPrinterDevice>> discoverDevices() async {
    _setStatus(PrinterStatus.discovering);
    try {
      final found = await _manager.scanPrinters(
        types: const {uep.PrinterConnectionType.bluetooth},
      );
      final devices = found
          .whereType<uep.BluetoothPrinterDevice>()
          .map((p) => KotPrinterDevice(name: p.name, address: p.address))
          .where((d) => d.address.isNotEmpty)
          .toList();

      _setStatus(PrinterStatus.idle);
      dev.log('[BTPrinter] discovered ${devices.length} BT device(s)');
      return devices;
    } on uep.PrinterException catch (e) {
      _setStatus(PrinterStatus.unavailable, message: e.message);
      throw _map(e);
    } catch (e) {
      _setStatus(PrinterStatus.unavailable, message: e.toString());
      throw PrinterException(code: PrinterException.unknown, message: e.toString());
    }
  }

  // ── Connect ───────────────────────────────────────────────────────────────

  @override
  Future<void> connect(KotPrinterDevice device) async {
    _setStatus(PrinterStatus.connecting);
    try {
      await _manager.connect(
        uep.BluetoothPrinterDevice(name: device.name, address: device.address),
      );
      _connectedDevice = device;
      _setStatus(PrinterStatus.idle);
      dev.log('[BTPrinter] connected to ${device.name} (${device.address})');
    } on uep.PrinterException catch (e) {
      _connectedDevice = null;
      _setStatus(PrinterStatus.failed, message: e.message);
      throw _map(e);
    }
  }

  // ── Disconnect ────────────────────────────────────────────────────────────

  @override
  Future<void> disconnect() async {
    try { await _manager.disconnect(); } catch (_) {}
    _connectedDevice = null;
    _setStatus(PrinterStatus.idle);
    dev.log('[BTPrinter] disconnected');
  }

  // ── Print ─────────────────────────────────────────────────────────────────

  @override
  Future<void> print(PrintRequest request) async {
    if (!isConnected) {
      throw const PrinterException(
          code: PrinterException.notConnected,
          message: 'No printer connected. Select a printer first.');
    }

    _setStatus(PrinterStatus.printing);
    try {
      final ticket = await _buildTicket(request.ticket);
      await _manager.printTicket(ticket);
      _setStatus(PrinterStatus.success);
      dev.log('[BTPrinter] printed KOT ${request.ticket.orderNumber}');
    } on PrinterException {
      _setStatus(PrinterStatus.failed);
      rethrow;
    } on uep.PrinterException catch (e) {
      _setStatus(PrinterStatus.failed, message: e.message);
      throw _map(e);
    } catch (e) {
      _setStatus(PrinterStatus.failed, message: e.toString());
      throw PrinterException(code: PrinterException.unknown, message: e.toString());
    }
  }

  // ── Queue / retry ─────────────────────────────────────────────────────────

  Future<void> enqueueAndPrint(KOTTicketModel ticket) async {
    final request = PrintRequest(ticket: ticket, createdAt: DateTime.now());
    _queue.add(request);
    await _saveQueue();
    dev.log('[BTPrinter] enqueued ${ticket.orderNumber} (queue: ${_queue.length})');
    await _attemptPrint(request);
  }

  Future<void> retryQueue() async {
    if (_queue.isEmpty) return;
    dev.log('[BTPrinter] retrying ${_queue.length} queued job(s)');
    for (final job in List<PrintRequest>.from(_queue)) {
      await _attemptPrint(job);
    }
  }

  Future<void> _attemptPrint(PrintRequest request) async {
    try {
      await print(request);
      _queue.remove(request);
      await _saveQueue();
      _history.insert(0, request.ticket);
      if (_history.length > _kHistoryLimit) _history.removeLast();
      await _saveHistory();
    } on PrinterException catch (e) {
      final idx = _queue.indexOf(request);
      if (idx != -1) {
        if (request.retryCount >= _kMaxRetries) {
          _queue.removeAt(idx);
          dev.log('[BTPrinter] ${request.ticket.orderNumber} dropped after '
              '$_kMaxRetries retries: ${e.code}');
        } else {
          _queue[idx] = request.copyWithRetry();
          dev.log('[BTPrinter] ${request.ticket.orderNumber} will retry '
              '(attempt ${request.retryCount + 1}): ${e.code}');
        }
        await _saveQueue();
      }
    }
  }

  Future<void> reprint(KOTTicketModel ticket) async {
    dev.log('[BTPrinter] reprint ${ticket.orderNumber}');
    await enqueueAndPrint(ticket);
  }

  // ── Diagnostics ───────────────────────────────────────────────────────────

  Map<String, dynamic> diagnostics() => {
    'status':          status.value.name,
    'connected':       isConnected,
    'connectedDevice': connectedDevice?.toString(),
    'queuedJobs':      _queue.length,
    'historyCount':    _history.length,
    'lastMessage':     lastMessage,
    'paperOutNote':    'Paper-out NOT detectable over generic BT SPP.',
  };

  // ── ESC/POS ticket builder ────────────────────────────────────────────────

  Future<uep.Ticket> _buildTicket(KOTTicketModel kot) async {
    final ticket = await uep.Ticket.create(_kPaperSize);

    // Use the real enterprise/hotel name stored at login; fall back to generic.
    final rawEntName = await UserSessionHelper.getEnterpriseName();
    final headerName = (rawEntName != null && rawEntName.trim().isNotEmpty)
        ? rawEntName.trim().toUpperCase()
        : 'GROOVIZ F&B ROOM SERVICE';

    ticket.text('KOT',
        style: const uep.PrintTextStyle(bold: true,
            height: uep.TextSize.size2, width: uep.TextSize.size2),
        align: uep.PrintAlign.center);
    ticket.text(headerName, align: uep.PrintAlign.center);
    ticket.separator(char: '=');

    ticket.text('Room #:  ${kot.roomNumber}',
        style: const uep.PrintTextStyle(bold: true));
    ticket.text('Order #: ${kot.orderNumber}');
    if (kot.guestName != null && kot.guestName!.trim().isNotEmpty) {
      ticket.text('Guest:   ${kot.guestName}');
    }
    ticket.text('Time:    ${DateFormatter.formatDateTime(
        kot.orderTime.toIso8601String().replaceAll('T', ' '))}');
    ticket.text('Status:  ${kot.orderStatus.toUpperCase()}');
    ticket.separator();

    // Column headers
    ticket.text(_fmtRow('QTY', 'ITEM', 'TYPE'),
        style: const uep.PrintTextStyle(bold: true));
    ticket.separator();

    for (final item in kot.items) {
      ticket.text(_fmtRow('${item.quantity}x', item.name,
          item.isVeg ? 'VEG' : 'NON'));
      if (item.instructions != null && item.instructions!.trim().isNotEmpty) {
        ticket.text('  * ${item.instructions!.trim()}');
      }
    }

    if (kot.cookingInstructions != null &&
        kot.cookingInstructions!.trim().isNotEmpty) {
      ticket.separator();
      ticket.text('SPECIAL INSTRUCTIONS:',
          style: const uep.PrintTextStyle(bold: true));
      ticket.text(kot.cookingInstructions!.trim());
    }

    ticket.separator(char: '=');
    ticket.text(
        'Printed: ${DateFormatter.formatDateTime(
            DateTime.now().toIso8601String().replaceAll('T', ' '))}',
        align: uep.PrintAlign.center);
    ticket.text('*** KITCHEN COPY ***',
        style: const uep.PrintTextStyle(bold: true),
        align: uep.PrintAlign.center);
    ticket.feed(3);
    ticket.cut();
    return ticket;
  }

  // ── Persistence — queue ───────────────────────────────────────────────────

  Future<void> _saveQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = _queue.map((r) => {
        'orderNumber':         r.ticket.orderNumber,
        'roomNumber':          r.ticket.roomNumber,
        'guestName':           r.ticket.guestName,
        'orderTime':           r.ticket.orderTime.toIso8601String(),
        'orderStatus':         r.ticket.orderStatus,
        'cookingInstructions': r.ticket.cookingInstructions,
        'retryCount':          r.retryCount,
        'createdAt':           r.createdAt.toIso8601String(),
        'items':               r.ticket.items.map((i) => {
          'name':         i.name,
          'quantity':     i.quantity,
          'isVeg':        i.isVeg,
          'instructions': i.instructions,
        }).toList(),
      }).toList();
      await prefs.setString(_kQueueKey, jsonEncode(json));
    } catch (e) {
      dev.log('[BTPrinter] _saveQueue error (non-fatal): $e');
    }
  }

  Future<void> _loadQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_kQueueKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List;
      _queue
        ..clear()
        ..addAll(list.map((m) {
          final map = m as Map<String, dynamic>;
          return PrintRequest(
            ticket:     _ticketFromMap(map),
            createdAt:  DateTime.parse(map['createdAt'] as String),
            retryCount: (map['retryCount'] as int? ?? 0),
          );
        }));
      dev.log('[BTPrinter] loaded ${_queue.length} queued job(s)');
    } catch (e) {
      dev.log('[BTPrinter] _loadQueue error (non-fatal): $e');
    }
  }

  // ── Persistence — history ─────────────────────────────────────────────────

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json  = _history.map((t) => {
        'orderNumber':         t.orderNumber,
        'roomNumber':          t.roomNumber,
        'guestName':           t.guestName,
        'orderTime':           t.orderTime.toIso8601String(),
        'orderStatus':         t.orderStatus,
        'cookingInstructions': t.cookingInstructions,
        'items':               t.items.map((i) => {
          'name':         i.name,
          'quantity':     i.quantity,
          'isVeg':        i.isVeg,
          'instructions': i.instructions,
        }).toList(),
      }).toList();
      await prefs.setString(_kHistoryKey, jsonEncode(json));
    } catch (e) {
      dev.log('[BTPrinter] _saveHistory error (non-fatal): $e');
    }
  }

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_kHistoryKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List;
      _history
        ..clear()
        ..addAll(list.map((m) => _ticketFromMap(m as Map<String, dynamic>)));
      dev.log('[BTPrinter] loaded ${_history.length} history item(s)');
    } catch (e) {
      dev.log('[BTPrinter] _loadHistory error (non-fatal): $e');
    }
  }

  KOTTicketModel _ticketFromMap(Map<String, dynamic> m) {
    return KOTTicketModel(
      orderNumber:         m['orderNumber'] as String,
      roomNumber:          m['roomNumber']  as String,
      guestName:           m['guestName']   as String?,
      orderTime:           DateTime.parse(m['orderTime'] as String),
      orderStatus:         m['orderStatus'] as String,
      cookingInstructions: m['cookingInstructions'] as String?,
      items: (m['items'] as List? ?? []).map<KOTItem>((i) {
        final im = i as Map<String, dynamic>;
        return KOTItem(
          name:         im['name']         as String,
          quantity:     im['quantity']     as int,
          isVeg:        im['isVeg']        as bool? ?? false,
          instructions: im['instructions'] as String?,
        );
      }).toList(),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _setStatus(PrinterStatus s, {String? message}) {
    status.value = s;
    if (message != null) lastMessage = message;
    dev.log('[BTPrinter] status → ${s.name}${message != null ? ' ($message)' : ''}');
  }

  String _fmtRow(String qty, String name, String type,
      {int qtyW = 4, int nameW = 22, int typeW = 4}) {
    final q = qty.length > qtyW ? qty.substring(0, qtyW) : qty.padRight(qtyW);
    final n = name.length > nameW ? name.substring(0, nameW) : name.padRight(nameW);
    final t = type.length > typeW ? type.substring(0, typeW) : type.padLeft(typeW);
    return '$q$n$t';
  }

  PrinterException _map(uep.PrinterException e) {
    final msg = e.message;
    if (e is uep.PrinterPermissionException) {
      return PrinterException(code: PrinterException.permissionDenied, message: msg);
    }
    if (e is uep.PrinterNotFoundException) {
      return PrinterException(code: PrinterException.deviceNotFound, message: msg);
    }
    if (e is uep.PrinterWriteException) {
      return PrinterException(code: PrinterException.sendFailed, message: msg);
    }
    if (e is uep.PrinterStateException) {
      return PrinterException(code: PrinterException.notConnected, message: msg);
    }
    if (e is uep.PrinterConnectionException) {
      return PrinterException(code: PrinterException.connectionFailed, message: msg);
    }
    return PrinterException(code: PrinterException.unknown, message: msg);
  }
}

// ── Singleton ─────────────────────────────────────────────────────────────────
final bluetoothPrinterService = BluetoothPrinterService();
