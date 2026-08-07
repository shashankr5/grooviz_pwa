// lib/services/printer_service.dart
//
// PrinterService — abstract interface for KOT printing.
// KotPrinterDevice wraps the plugin's BluetoothPrinterDevice so the rest of
// the app doesn't import the plugin directly.

import 'package:flutter/foundation.dart';
import '../models/kot_ticket_model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PrinterStatus
// ─────────────────────────────────────────────────────────────────────────────

enum PrinterStatus {
  idle,         // No operation in progress
  discovering,  // Scanning for paired devices
  connecting,   // Opening Bluetooth socket
  printing,     // Sending bytes to printer
  success,      // Last print completed
  failed,       // Last print failed — see PrinterException
  unavailable,  // Bluetooth off, no printer paired, or permission denied
}

// ─────────────────────────────────────────────────────────────────────────────
// KotPrinterDevice — thin wrapper exposed to the app layer
// ─────────────────────────────────────────────────────────────────────────────

@immutable
class KotPrinterDevice {
  final String name;
  final String address; // MAC address

  const KotPrinterDevice({required this.name, required this.address});

  @override
  String toString() => '$name ($address)';
}

// ─────────────────────────────────────────────────────────────────────────────
// PrintRequest
// ─────────────────────────────────────────────────────────────────────────────

@immutable
class PrintRequest {
  final KOTTicketModel ticket;
  final DateTime createdAt;
  final int retryCount;

  const PrintRequest({
    required this.ticket,
    required this.createdAt,
    this.retryCount = 0,
  });

  PrintRequest copyWithRetry() => PrintRequest(
        ticket: ticket,
        createdAt: createdAt,
        retryCount: retryCount + 1,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// PrinterException
// ─────────────────────────────────────────────────────────────────────────────

class PrinterException implements Exception {
  final String code;
  final String message;

  const PrinterException({required this.code, required this.message});

  static const String btDisabled       = 'BT_DISABLED';
  static const String permissionDenied = 'PERMISSION_DENIED';
  static const String deviceNotFound   = 'DEVICE_NOT_FOUND';
  static const String connectionFailed = 'CONNECTION_FAILED';
  static const String connectionLost   = 'CONNECTION_LOST';
  static const String sendFailed       = 'SEND_FAILED';
  static const String invalidPayload   = 'INVALID_PAYLOAD';
  static const String notConnected     = 'NOT_CONNECTED';
  // NOTE: paperOut is defined for interface completeness but CANNOT be thrown
  // over generic Bluetooth SPP — SPP is write-only; no status feedback exists.
  // Only throwable if a specific printer model with real-time status polling
  // is targeted in a future revision.
  static const String paperOut         = 'PAPER_OUT_UNSUPPORTED';
  static const String unknown          = 'UNKNOWN';

  @override
  String toString() => 'PrinterException[$code]: $message';
}

// ─────────────────────────────────────────────────────────────────────────────
// PrinterService — abstract contract
// ─────────────────────────────────────────────────────────────────────────────

abstract class PrinterService {
  Future<List<KotPrinterDevice>> discoverDevices();
  Future<void> connect(KotPrinterDevice device);
  Future<void> disconnect();
  bool get isConnected;
  KotPrinterDevice? get connectedDevice;
  Future<void> print(PrintRequest request);
}
