// lib/widgets/kot_preview_sheet.dart
//
// CHANGES FROM DEMO VERSION:
//  • "Print KOT" now calls the real BluetoothPrinterService instead of
//    clipboard copy.
//  • If no printer is connected, a printer-selection sheet opens first.
//  • PrinterStatus is observed via ValueListenableBuilder so the button
//    disables itself and shows a spinner while printing.
//  • "Copy Receipt" keeps the clipboard path as a demo/fallback.
//  • All error states surface as readable snackbar messages.
//
// BLUETOOTH ENABLE FLOW (v2):
//  • "Enable Bluetooth" in the Bluetooth-off dialog calls
//    AppSettings.openAppSettings(type: AppSettingsType.bluetooth) which
//    deep-links to the system Bluetooth settings screen — not the app
//    permissions page.
//  • KOTPreviewSheet is now a StatefulWidget + WidgetsBindingObserver.
//    When the user returns from Settings with BT now on, the widget
//    automatically re-checks and resumes the print flow — no second tap needed.

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import '../models/kot_ticket_model.dart';
import '../services/kot_printer_service.dart';
import '../services/bluetooth_printer_service.dart';
import '../services/printer_service.dart';
import '../utils/date_formatter.dart';
import '../utils/user_session_helper.dart';
import '../theme/app_colors.dart';

class KOTPreviewSheet extends StatefulWidget {
  final KOTTicketModel ticket;

  const KOTPreviewSheet({super.key, required this.ticket});

  static void show(BuildContext context, Map<String, dynamic> order) {
    final ticket = KOTTicketModel.fromFoodOrder(order);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => KOTPreviewSheet(ticket: ticket),
    );
  }

  @override
  State<KOTPreviewSheet> createState() => _KOTPreviewSheetState();
}

class _KOTPreviewSheetState extends State<KOTPreviewSheet>
    with WidgetsBindingObserver {
  // Set to true when we've sent the user to BT settings so that on the next
  // AppLifecycleState.resumed we automatically continue the print flow.
  bool _waitingForBtEnable = false;
  String _enterpriseName = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadEnterpriseName();
  }

  Future<void> _loadEnterpriseName() async {
    final name = await UserSessionHelper.getEnterpriseName();
    if (mounted && name != null && name.trim().isNotEmpty) {
      setState(() => _enterpriseName = name.trim());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ── Lifecycle observer ────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForBtEnable) {
      _waitingForBtEnable = false;
      _resumePrintAfterBtEnable();
    }
  }

  /// Called automatically when the app resumes after going to BT settings.
  Future<void> _resumePrintAfterBtEnable() async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final btOn = await bluetoothPrinterService.isBluetoothEnabled();
    if (!mounted) return;
    if (!btOn) {
      _showError(messenger,
          'Bluetooth is still off. Please enable it and tap Print again.');
      return;
    }
    await _continuePrint(context);
  }

  // ── Print KOT action ──────────────────────────────────────────────────────

  Future<void> _onPrintKot(BuildContext context) async {
    final svc = bluetoothPrinterService;

    // 1 ── Request Bluetooth runtime permissions
    final messenger = ScaffoldMessenger.of(context);
    final granted = await svc.requestPermissions();
    if (!granted) {
      if (context.mounted) {
        _showError(messenger,
            'Bluetooth permission is required to print. Please grant it in Settings.');
      }
      return;
    }

    // 2 ── Check whether the Bluetooth adapter is actually switched on
    if (!context.mounted) return;
    final btOn = await svc.isBluetoothEnabled();
    if (!btOn) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          title: const Row(children: [
            Icon(Icons.bluetooth_disabled_rounded,
                color: Color(0xFFEF4444), size: 22),
            SizedBox(width: 8),
            Text('Bluetooth Off',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ]),
          content: const Text(
            'Bluetooth is required for KOT printing.\n'
            'Enable Bluetooth and the print will resume automatically.',
            style: TextStyle(fontSize: 14),
          ),
          actionsPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel',
                  style: TextStyle(color: Color(0xFF6B7280))),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.bluetooth_rounded, size: 16),
              label: const Text('Enable Bluetooth'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                // Flag auto-resume, then deep-link to system BT settings.
                _waitingForBtEnable = true;
                AppSettings.openAppSettings(
                    type: AppSettingsType.bluetooth);
              },
            ),
          ],
        ),
      );
      // Print flow stops here; _resumePrintAfterBtEnable() takes over on resume.
      return;
    }

    // 3+ ── BT is on — proceed
    await _continuePrint(context);
  }

  /// Steps 3-4: connect if needed, then print.
  /// Extracted so both _onPrintKot and _resumePrintAfterBtEnable can call it.
  Future<void> _continuePrint(BuildContext context) async {
    final svc = bluetoothPrinterService;

    if (!svc.isConnected) {
      if (!context.mounted) return;
      final connected = await _showDevicePicker(context);
      if (!connected || !context.mounted) return;
    }

    // Capture BEFORE popping, while context is still fully mounted.
    final messenger = ScaffoldMessenger.of(context);

    if (context.mounted) Navigator.pop(context);

    try {
      await svc.enqueueAndPrint(widget.ticket);
      _showSuccessWithReprint(messenger, widget.ticket);
    } on PrinterException catch (e) {
      _showError(messenger, _friendlyError(e));
    }
  }

  /// Opens a device-picker sheet that scans in the background.
  /// Returns true if a connection was successfully established.
  Future<bool> _showDevicePicker(BuildContext context) async {
    final selected = await showModalBottomSheet<KotPrinterDevice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => const _PrinterPickerSheet(),
    );

    if (selected == null || !context.mounted) return false;
    return true; // _PrinterPickerSheet already called connect()
  }

  // ── Error helpers ─────────────────────────────────────────────────────────

  String _friendlyError(PrinterException e) {
    switch (e.code) {
      case PrinterException.btDisabled:
        return 'Please turn on Bluetooth to print.';
      case PrinterException.permissionDenied:
        return 'Bluetooth permission denied. Enable it in app Settings.';
      case PrinterException.deviceNotFound:
        return 'Printer not found. Make sure it is powered on and paired.';
      case PrinterException.connectionFailed:
        return 'Could not connect to printer. Check that it is on and nearby.';
      case PrinterException.connectionLost:
        return 'Printer connection lost during printing. Please retry.';
      case PrinterException.sendFailed:
        return 'Failed to send data to printer. Check paper and power.';
      case PrinterException.notConnected:
        return 'No printer connected. Please select a printer first.';
      case PrinterException.paperOut:
        return 'Printer is out of paper. Please reload and retry.';
      default:
        return 'Printing failed. ${e.message}';
    }
  }

  /// Success snackbar with a "Reprint" action so staff can reprint without
  /// navigating back to the order data.
  void _showSuccessWithReprint(
      ScaffoldMessengerState messenger, KOTTicketModel printedTicket) {
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text('KOT #${printedTicket.orderNumber} printed 🖨️',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ]),
      backgroundColor: AppColors.primary,
      duration: const Duration(seconds: 6),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      action: SnackBarAction(
        label: 'Reprint',
        textColor: Colors.white,
        onPressed: () async {
          try {
            await bluetoothPrinterService.reprint(printedTicket);
            _showSuccess(
                messenger, 'Reprinted KOT #${printedTicket.orderNumber}');
          } on PrinterException catch (e) {
            _showError(messenger, _friendlyError(e));
          }
        },
      ),
    ));
  }

  void _showError(ScaffoldMessengerState messenger, String msg) {
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.warning_rounded, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(
            child: Text(msg,
                style: const TextStyle(fontWeight: FontWeight.w600))),
      ]),
      backgroundColor: AppColors.error,
      duration: const Duration(seconds: 5),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _showSuccess(ScaffoldMessengerState messenger, String msg) {
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(
            child: Text(msg,
                style: const TextStyle(fontWeight: FontWeight.bold))),
      ]),
      backgroundColor: AppColors.primary,
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        top: 12,
        left: 18,
        right: 18,
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),

          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.receipt_long_rounded,
                  color: AppColors.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Kitchen Order Ticket (KOT)',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded,
                    color: AppColors.textDisabled, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Receipt slip (unchanged from original)
          Flexible(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: _buildReceiptSlip(),
            ),
          ),
          const SizedBox(height: 14),

          // Actions — observe printer status for button state
          ValueListenableBuilder<PrinterStatus>(
            valueListenable: bluetoothPrinterService.status,
            builder: (_, status, __) {
              final isPrinting = status == PrinterStatus.printing ||
                  status == PrinterStatus.connecting ||
                  status == PrinterStatus.discovering;

              return Row(
                children: [
                  // Copy receipt (clipboard fallback)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isPrinting
                          ? null
                          : () async {
                              await KOTPrinterService
                                  .copyReceiptToClipboard(widget.ticket,
                                      enterpriseName: _enterpriseName.isNotEmpty
                                          ? _enterpriseName
                                          : null);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(SnackBar(
                                  content: const Text(
                                    'KOT copied to clipboard 📋',
                                    style: TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  backgroundColor: Colors.indigo,
                                  duration: const Duration(seconds: 2),
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10)),
                                ));
                              }
                            },
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('Copy Receipt'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),

                  // Print KOT (real hardware)
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: isPrinting
                          ? null
                          : () => _onPrintKot(context),
                      icon: isPrinting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.print_rounded, size: 16),
                      label: Text(isPrinting ? 'Printing…' : 'Print KOT'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            AppColors.primary.withOpacity(0.6),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Receipt slip ──────────────────────────────────────────────────────────
  // Identical to the original demo preview — just extracted to keep build() clean.

  Widget _buildReceiptSlip() {
    final ticket = widget.ticket;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade300, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Center(child: Text('KITCHEN ORDER TICKET',
              style: TextStyle(fontFamily: 'monospace', fontSize: 14,
                  fontWeight: FontWeight.bold, letterSpacing: 1.2,
                  color: Colors.black87))),
          Center(child: Text(
              _enterpriseName.isNotEmpty ? _enterpriseName.toUpperCase() : 'GROOVIZ F&B ROOM SERVICE',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10,
                  color: Colors.black54))),
          const SizedBox(height: 10),
          _buildDashedLine(),
          const SizedBox(height: 12),

          // Order header card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                        color: Colors.indigo.shade50,
                        borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.meeting_room_rounded,
                          size: 14, color: Colors.indigo),
                      const SizedBox(width: 4),
                      Text('ROOM ${ticket.roomNumber}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Colors.indigo)),
                    ]),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                        color: AppColors.successLight,
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(ticket.orderStatus.toUpperCase(),
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: AppColors.success)),
                  ),
                ]),
                const SizedBox(height: 10),

                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  const Text('Order #: ',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 12,
                          fontWeight: FontWeight.w600, color: Colors.black54)),
                  Expanded(
                    child: SelectableText(ticket.orderNumber,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                            letterSpacing: 0.5)),
                  ),
                ]),

                if (ticket.guestName != null &&
                    ticket.guestName!.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.person_rounded,
                        size: 14, color: Colors.black54),
                    const SizedBox(width: 5),
                    const Text('Guest: ',
                        style: TextStyle(fontFamily: 'monospace', fontSize: 11,
                            fontWeight: FontWeight.w600, color: Colors.black54)),
                    Expanded(
                      child: Text(ticket.guestName!,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87)),
                    ),
                  ]),
                ],

                const SizedBox(height: 6),
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  const Icon(Icons.access_time_rounded,
                      size: 13, color: Colors.black54),
                  const SizedBox(width: 5),
                  const Text('Time: ',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 11,
                          fontWeight: FontWeight.w600, color: Colors.black54)),
                  Text(
                    DateFormatter.formatDateTime(ticket.orderTime
                        .toIso8601String()
                        .replaceAll('T', ' ')),
                    style: const TextStyle(fontFamily: 'monospace',
                        fontSize: 11, fontWeight: FontWeight.w600,
                        color: Colors.black87),
                  ),
                ]),
              ],
            ),
          ),

          const SizedBox(height: 12),
          _buildDashedLine(),
          const SizedBox(height: 10),

          // Items table
          const Row(children: [
            SizedBox(width: 32, child: Text('QTY',
                style: TextStyle(fontFamily: 'monospace',
                    fontWeight: FontWeight.bold, fontSize: 11,
                    color: Colors.black87))),
            Expanded(child: Text('ITEM',
                style: TextStyle(fontFamily: 'monospace',
                    fontWeight: FontWeight.bold, fontSize: 11,
                    color: Colors.black87))),
            Text('TYPE',
                style: TextStyle(fontFamily: 'monospace',
                    fontWeight: FontWeight.bold, fontSize: 11,
                    color: Colors.black87)),
          ]),
          const SizedBox(height: 6),

          ...ticket.items.map((item) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 32,
                    child: Text('${item.quantity}x',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primary))),
                  Expanded(child: Text(item.name,
                      style: const TextStyle(fontFamily: 'monospace',
                          fontSize: 12, fontWeight: FontWeight.w600,
                          color: Colors.black87))),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: item.isVeg ? AppColors.successLight : AppColors.errorLight,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(item.isVeg ? 'VEG' : 'NON-VEG',
                        style: TextStyle(fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: item.isVeg ? AppColors.success : AppColors.error)),
                  ),
                ]),
                if (item.instructions != null &&
                    item.instructions!.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Padding(
                    padding: const EdgeInsets.only(left: 32),
                    child: Text('* ${item.instructions}',
                        style: const TextStyle(fontFamily: 'monospace',
                            fontSize: 10, fontStyle: FontStyle.italic,
                            color: Colors.black54)),
                  ),
                ],
              ],
            ),
          )),

          if (ticket.cookingInstructions != null &&
              ticket.cookingInstructions!.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            _buildDashedLine(),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: AppColors.warningLight,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.warning.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [
                    Icon(Icons.note_alt_outlined,
                        size: 13, color: AppColors.warning),
                    SizedBox(width: 4),
                    Text('SPECIAL INSTRUCTIONS',
                        style: TextStyle(fontFamily: 'monospace',
                            fontSize: 10, fontWeight: FontWeight.bold,
                            color: AppColors.warning)),
                  ]),
                  const SizedBox(height: 4),
                  Text(ticket.cookingInstructions!.trim(),
                      style: const TextStyle(fontFamily: 'monospace',
                          fontSize: 11, color: Colors.black87)),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),
          _buildDashedLine(),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Printed: ${DateFormatter.formatDateTime(DateTime.now().toIso8601String().replaceAll('T', ' '))}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 9,
                  color: Colors.black45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashedLine() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth  = constraints.maxWidth;
        const dashWidth = 5.0;
        const dashH     = 1.0;
        final dashCount = (boxWidth / (2 * dashWidth)).floor();
        return Flex(
          direction: Axis.horizontal,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(dashCount, (_) => SizedBox(
            width: dashWidth,
            height: dashH,
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.grey.shade400)),
          )),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Printer Picker Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _PrinterPickerSheet extends StatefulWidget {
  const _PrinterPickerSheet();

  @override
  State<_PrinterPickerSheet> createState() => _PrinterPickerSheetState();
}

class _PrinterPickerSheetState extends State<_PrinterPickerSheet> {
  List<KotPrinterDevice> _devices = [];
  bool _scanning = true;
  String? _scanError;
  String? _connectingAddress;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanError = null;
      _devices = [];
    });
    try {
      final found = await bluetoothPrinterService.discoverDevices();
      if (mounted) {
        setState(() {
          _devices = found;
          _scanning = false;
        });
      }
    } on PrinterException catch (e) {
      if (mounted) {
        setState(() {
          _scanning = false;
          _scanError = _friendlyError(e);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _scanning = false;
          _scanError = 'Scan failed. $e';
        });
      }
    }
  }

  String _friendlyError(PrinterException e) {
    switch (e.code) {
      case PrinterException.btDisabled:
        return 'Please turn on Bluetooth to scan for printers.';
      case PrinterException.permissionDenied:
        return 'Bluetooth permission denied. Enable it in app Settings.';
      default:
        return 'Scan failed. ${e.message}';
    }
  }

  Future<void> _select(KotPrinterDevice device) async {
    setState(() => _connectingAddress = device.address);
    try {
      await bluetoothPrinterService.connect(device);
      if (mounted) Navigator.pop(context, device);
    } on PrinterException catch (e) {
      if (mounted) {
        setState(() => _connectingAddress = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Connection failed: ${e.message}'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ──────────────────────────────────────────────────
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 36, height: 4,
            decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2)),
          ),

          // ── Header ───────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(children: [
              const Icon(Icons.print_rounded,
                  color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              const Text('Select Printer',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary)),
              const Spacer(),
              if (_scanning)
                const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primary),
                )
              else
                GestureDetector(
                  onTap: _scan,
                  child: const Row(children: [
                    Icon(Icons.refresh_rounded,
                        size: 16, color: AppColors.primary),
                    SizedBox(width: 4),
                    Text('Scan again',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.primary,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
            ]),
          ),

          const Divider(height: 1, color: AppColors.borderLight),

          // ── Body ─────────────────────────────────────────────────────────
          if (_scanning)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.bluetooth_searching_rounded,
                    size: 36, color: AppColors.primary),
                SizedBox(height: 12),
                Text('Scanning for paired printers…',
                    style: TextStyle(
                        fontSize: 13, color: AppColors.textSecondary)),
              ]),
            )
          else if (_scanError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline_rounded,
                    size: 36, color: Color(0xFFEF4444)),
                const SizedBox(height: 10),
                Text(_scanError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textSecondary)),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Retry scan'),
                  onPressed: _scan,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ]),
            )
          else if (_devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.bluetooth_disabled_rounded,
                    size: 36, color: AppColors.textDisabled),
                const SizedBox(height: 10),
                const Text(
                  'No paired Bluetooth printers found.\n'
                  'Pair your printer in device Settings, then scan again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Scan again'),
                  onPressed: _scan,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ]),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: _devices.map((device) {
                  final isConnecting = _connectingAddress == device.address;
                  return ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: AppColors.primaryLight,
                          borderRadius: BorderRadius.circular(10)),
                      child: const Icon(Icons.bluetooth_rounded,
                          color: AppColors.primary, size: 20),
                    ),
                    title: Text(device.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14,
                            color: AppColors.textPrimary)),
                    subtitle: Text(device.address,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary,
                            fontFamily: 'monospace')),
                    trailing: isConnecting
                        ? const SizedBox(width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2,
                                color: AppColors.primary))
                        : const Icon(Icons.chevron_right_rounded,
                            color: AppColors.textDisabled),
                    onTap: isConnecting ? null : () => _select(device),
                  );
                }).toList(),
              ),
            ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
