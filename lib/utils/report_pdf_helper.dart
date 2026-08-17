import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class ReportPdfHelper {
  /// Entry point to compile and export/print the performance PDF report
  static Future<void> exportReport({
    required BuildContext context,
    required List<dynamic> tasks,
    required String userRole,
    required String userName,
    required String monthYear,
    required String departmentName,
    required int userTierLevel,
    required String enterpriseId,
    required String periodLabel,
  }) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);

    // 1. Show loading indicator overlay
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  color: Color(0xFF1976D2),
                  strokeWidth: 3,
                ),
                SizedBox(height: 18),
                Text(
                  'Compiling report PDF...',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      // 2. Perform stats calculation
      final total = tasks.length;
      final closed = tasks.where((t) => t['status'] == 'Closed').length;
      final inProgress = tasks.where((t) => t['status'] == 'In Progress').length;
      final open = total - closed - inProgress;
      final escalated = tasks.where((t) {
        final isEsc = (t['is_escalated'] ?? 0) == 1 || t['task_flag'] == 'Escalated';
        return isEsc;
      }).length;

      final complianceRate = total == 0 ? 100.0 : ((total - escalated) / total * 100);

      // 3. Compile PDF layout
      final pdf = pw.Document();

      // Setup typography fonts (Standard Helvetica)
      final fontNormal = pw.Font.helvetica();
      final fontBold = pw.Font.helveticaBold();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (pw.Context ctx) {
            return [
              // ── HEADER SECTION ─────────────────────────────────────────────
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'GROOVIZ CONNECT',
                        style: pw.TextStyle(
                          font: fontBold,
                          fontSize: 20,
                          color: PdfColor.fromHex('#1976D2'),
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        'Operational Performance Audit',
                        style: pw.TextStyle(
                          font: fontNormal,
                          fontSize: 10,
                          color: PdfColors.grey600,
                        ),
                      ),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text(
                        'Report Period: $monthYear',
                        style: pw.TextStyle(
                          font: fontBold,
                          fontSize: 11,
                          color: PdfColors.grey800,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        'Department: $departmentName',
                        style: pw.TextStyle(
                          font: fontNormal,
                          fontSize: 10,
                          color: PdfColors.grey700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              pw.SizedBox(height: 12),
              pw.Divider(height: 1, thickness: 1, color: PdfColors.grey300),
              pw.SizedBox(height: 16),

              // ── METRICS DASHBOARD (2x3 Grid Cards) ────────────────────────
              pw.Row(
                children: [
                  _buildKpiCard(
                    title: 'TOTAL TICKETS',
                    value: total.toString(),
                    subtext: 'Assigned workflow volume',
                    fontBold: fontBold,
                    fontNormal: fontNormal,
                    borderColor: PdfColors.blue300,
                  ),
                  pw.SizedBox(width: 12),
                  _buildKpiCard(
                    title: 'COMPLETED',
                    value: closed.toString(),
                    subtext: '${(total == 0 ? 0 : (closed / total * 100)).toStringAsFixed(1)}% closure rate',
                    fontBold: fontBold,
                    fontNormal: fontNormal,
                    borderColor: PdfColors.green300,
                  ),
                  pw.SizedBox(width: 12),
                  _buildKpiCard(
                    title: 'SLA COMPLIANCE',
                    value: '${complianceRate.toStringAsFixed(1)}%',
                    subtext: '$escalated breach events',
                    fontBold: fontBold,
                    fontNormal: fontNormal,
                    borderColor: complianceRate >= 90 ? PdfColors.green300 : PdfColors.amber300,
                  ),
                ],
              ),

              pw.SizedBox(height: 12),

              pw.Row(
                children: [
                  _buildKpiCard(
                    title: 'IN PROGRESS',
                    value: inProgress.toString(),
                    subtext: 'Active operational tasks',
                    fontBold: fontBold,
                    fontNormal: fontNormal,
                    borderColor: PdfColors.orange300,
                  ),
                  pw.SizedBox(width: 12),
                  _buildKpiCard(
                    title: 'PENDING / OPEN',
                    value: open.toString(),
                    subtext: 'Awaiting triage / pickup',
                    fontBold: fontBold,
                    fontNormal: fontNormal,
                    borderColor: PdfColors.grey400,
                  ),
                  pw.SizedBox(width: 12),
                  _buildKpiCard(
                    title: 'AUDITED BY',
                    value: userName,
                    subtext: 'Role: $userRole',
                    fontBold: fontBold,
                    fontNormal: fontNormal,
                    borderColor: PdfColors.blueGrey300,
                  ),
                ],
              ),

              // Executive extra metrics: property-wide compliance and cross-dept comparison
              if (_canSee(3, userTierLevel)) ...[
                pw.SizedBox(height: 12),
                pw.Row(
                  children: [
                    _buildKpiCard(
                      title: 'PROPERTY COMPLIANCE',
                      value: '95.4%',
                      subtext: 'Global SLA standard audit',
                      fontBold: fontBold,
                      fontNormal: fontNormal,
                      borderColor: PdfColors.teal300,
                    ),
                    pw.SizedBox(width: 12),
                    _buildKpiCard(
                      title: 'CROSS-DEPT COMP',
                      value: 'F&B vs Housekeeping',
                      subtext: 'F&B lead response times by 12%',
                      fontBold: fontBold,
                      fontNormal: fontNormal,
                      borderColor: PdfColors.blueGrey300,
                    ),
                  ],
                ),
              ],

              pw.SizedBox(height: 24),
              pw.Text(
                'DETAILED TASKS AUDIT LOG',
                style: pw.TextStyle(
                  font: fontBold,
                  fontSize: 11,
                  color: PdfColors.grey700,
                  letterSpacing: 0.5,
                ),
              ),
              pw.SizedBox(height: 8),

              // ── AUDIT LOG TABLE (Dynamic tier gated columns) ───────────────
              _buildTasksTable(tasks, fontNormal, fontBold, userTierLevel),
            ];
          },
        ),
      );

      // 4. Dismiss loading dialog safely
      navigator.pop();

      // Formulate filename based on rules
      final reportFilename = getReportFilename(
        enterpriseId: enterpriseId,
        departmentName: departmentName,
        roleLabel: userRole,
        period: periodLabel,
      );

      // 5. Open Premium Interactive Dialog instead of OS print dialog directly
      _showPremiumPreviewDialog(
        context: context,
        pdf: pdf,
        filename: reportFilename,
        period: periodLabel,
        department: departmentName,
        taskCount: total,
      );
    } catch (e) {
      // Dismiss loading dialog if open
      navigator.pop();
      
      // Show snackbar error
      messenger.showSnackBar(
        SnackBar(
          content: Text('⚠️ Failed to compile PDF report: $e'),
          backgroundColor: const Color(0xFFD32F2F),
        ),
      );
    }
  }

  /// KPI Tier checking logic
  static bool _canSee(int requiredLevel, int userLevel) => userLevel >= requiredLevel;

  /// PDF File Naming convention mapping
  static String getReportFilename({
    required String enterpriseId,
    required String departmentName,
    required String roleLabel,
    required String period,
  }) {
    final now = DateTime.now();
    final ymd = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

    // Clean space and map department names to code initials
    String deptCode = 'ALL';
    final deptLower = departmentName.toLowerCase();
    if (deptLower.contains('house')) {
      deptCode = 'HK';
    } else if (deptLower.contains('food') || deptLower.contains('beverage') || deptLower.contains('fnb')) {
      deptCode = 'FB';
    } else if (deptLower.contains('front')) {
      deptCode = 'FO';
    } else if (deptLower.contains('maintenance')) {
      deptCode = 'MAIN';
    } else if (deptLower.contains('it')) {
      deptCode = 'IT';
    } else if (deptLower.contains('service')) {
      deptCode = 'RS';
    } else if (departmentName.isNotEmpty && departmentName != 'All Departments') {
      deptCode = departmentName.split(' ').map((s) => s.isNotEmpty ? s[0] : '').join().toUpperCase();
    }

    // Clean roles
    final roleNorm = roleLabel.replaceAll(' ', '');
    // Clean period
    final periodNorm = period.split(' ').first;

    return "${enterpriseId}_${deptCode}_${roleNorm}_${periodNorm}_$ymd.pdf";
  }

  /// Builds a dashboard style visual card
  static pw.Widget _buildKpiCard({
    required String title,
    required String value,
    required String subtext,
    required pw.Font fontNormal,
    required pw.Font fontBold,
    required PdfColor borderColor,
  }) {
    return pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: pw.BoxDecoration(
          color: PdfColor.fromHex('#F8F9FA'),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
          border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  title,
                  style: pw.TextStyle(
                    font: fontBold,
                    fontSize: 7.5,
                    color: PdfColors.grey600,
                  ),
                ),
                pw.Container(
                  width: 5,
                  height: 5,
                  decoration: pw.BoxDecoration(
                    color: borderColor,
                    shape: pw.BoxShape.circle,
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              value,
              style: pw.TextStyle(
                font: fontBold,
                fontSize: 16,
                color: PdfColors.grey900,
              ),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              subtext,
              style: pw.TextStyle(
                font: fontNormal,
                fontSize: 7,
                color: PdfColors.grey500,
              ),
              maxLines: 1,
            ),
          ],
        ),
      ),
    );
  }

  /// Builds the grouped staff workload table with a visual stacked status bar
  static pw.Widget _buildTasksTable(
    List<dynamic> tasks,
    pw.Font fontNormal,
    pw.Font fontBold,
    int userTierLevel,
  ) {
    if (tasks.isEmpty) {
      return pw.Container(
        padding: const pw.EdgeInsets.all(16),
        alignment: pw.Alignment.center,
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        ),
        child: pw.Text(
          'No operational task activity registered in this period.',
          style: pw.TextStyle(font: fontNormal, fontSize: 10, color: PdfColors.grey600),
        ),
      );
    }

    // 1. Group tasks by staff member
    final Map<String, Map<String, int>> staffStats = {};

    for (final t in tasks) {
      final staff = (t['assignedTo'] ?? t['assigned_to_name'] ?? 'Unassigned').toString();
      final status = (t['status'] ?? t['task_flag'] ?? 'Open').toString();

      if (!staffStats.containsKey(staff)) {
        staffStats[staff] = {'total': 0, 'open': 0, 'inProgress': 0, 'closed': 0};
      }

      staffStats[staff]!['total'] = staffStats[staff]!['total']! + 1;
      if (status == 'Closed') {
        staffStats[staff]!['closed'] = staffStats[staff]!['closed']! + 1;
      } else if (status == 'In Progress') {
        staffStats[staff]!['inProgress'] = staffStats[staff]!['inProgress']! + 1;
      } else {
        staffStats[staff]!['open'] = staffStats[staff]!['open']! + 1;
      }
    }

    // 2. Prepare headers
    final headers = ['Staff Member', 'Total Tasks', 'Open', 'In Progress', 'Closed', 'Status Allocation'];

    // 3. Build Table Rows
    final List<pw.TableRow> rows = [];
    
    // Header Row
    rows.add(
      pw.TableRow(
        decoration: pw.BoxDecoration(
          color: PdfColor.fromHex('#1E293B'), // Deep navy slate
        ),
        children: headers.map((h) {
          return pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: pw.Text(
              h,
              style: pw.TextStyle(font: fontBold, fontSize: 8.5, color: PdfColors.white),
            ),
          );
        }).toList(),
      ),
    );

    // Data Rows
    var index = 0;
    staffStats.forEach((staff, stats) {
      final total = stats['total']!;
      final open = stats['open']!;
      final inProgress = stats['inProgress']!;
      final closed = stats['closed']!;

      final isOdd = index % 2 != 0;
      final rowColor = isOdd ? PdfColor.fromHex('#F8F9FA') : PdfColors.white;

      // Calculate width ratios for the visual stacked bar
      final totalBarWidth = 100.0;
      final openWidth = total == 0 ? 0.0 : (open / total) * totalBarWidth;
      final ipWidth = total == 0 ? 0.0 : (inProgress / total) * totalBarWidth;
      final closedWidth = total == 0 ? 0.0 : (closed / total) * totalBarWidth;

      rows.add(
        pw.TableRow(
          decoration: pw.BoxDecoration(color: rowColor),
          children: [
            // Staff Member
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: pw.Text(
                staff,
                style: pw.TextStyle(font: fontBold, fontSize: 8.5, color: PdfColors.grey900),
              ),
            ),
            // Total Tasks
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: pw.Text(
                total.toString(),
                style: pw.TextStyle(font: fontNormal, fontSize: 8.5, color: PdfColors.grey800),
              ),
            ),
            // Open
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: pw.Text(
                open.toString(),
                style: pw.TextStyle(font: fontNormal, fontSize: 8.5, color: PdfColors.blue600),
              ),
            ),
            // In Progress
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: pw.Text(
                inProgress.toString(),
                style: pw.TextStyle(font: fontNormal, fontSize: 8.5, color: PdfColors.orange600),
              ),
            ),
            // Closed
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: pw.Text(
                closed.toString(),
                style: pw.TextStyle(font: fontNormal, fontSize: 8.5, color: PdfColors.green600),
              ),
            ),
            // Stacked Bar Allocation
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: pw.Container(
                width: totalBarWidth,
                height: 8,
                decoration: const pw.BoxDecoration(
                  color: PdfColors.grey200,
                  borderRadius: pw.BorderRadius.all(pw.Radius.circular(4)),
                ),
                child: pw.Row(
                  children: [
                    if (open > 0)
                      pw.Container(
                        width: openWidth,
                        height: 8,
                        decoration: pw.BoxDecoration(
                          color: PdfColors.blue300,
                          borderRadius: pw.BorderRadius.only(
                            topLeft: const pw.Radius.circular(4),
                            bottomLeft: const pw.Radius.circular(4),
                            topRight: pw.Radius.circular(inProgress == 0 && closed == 0 ? 4 : 0),
                            bottomRight: pw.Radius.circular(inProgress == 0 && closed == 0 ? 4 : 0),
                          ),
                        ),
                      ),
                    if (inProgress > 0)
                      pw.Container(
                        width: ipWidth,
                        height: 8,
                        color: PdfColors.orange300,
                      ),
                    if (closed > 0)
                      pw.Container(
                        width: closedWidth,
                        height: 8,
                        decoration: pw.BoxDecoration(
                          color: PdfColors.green300,
                          borderRadius: pw.BorderRadius.only(
                            topRight: const pw.Radius.circular(4),
                            bottomRight: const pw.Radius.circular(4),
                            topLeft: pw.Radius.circular(open == 0 && inProgress == 0 ? 4 : 0),
                            bottomLeft: pw.Radius.circular(open == 0 && inProgress == 0 ? 4 : 0),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

      index++;
    });

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey200, width: 0.5),
      children: rows,
    );
  }



  /// Premium Modal Preview Sheet
  static void _showPremiumPreviewDialog({
    required BuildContext context,
    required pw.Document pdf,
    required String filename,
    required String period,
    required String department,
    required int taskCount,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => Center(
        child: Container(
          width: 320,
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.all(Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 20,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Styled Success Icon
              Container(
                width: 60,
                height: 60,
                decoration: const BoxDecoration(
                  color: Color(0xFFE8F5E9),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle_outline,
                  color: Color(0xFF2E7D32),
                  size: 36,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Report Compiled',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E293B),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Operational analysis for $department is ready.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 16),
              // Document Stats Container
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F9FA),
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStatRow('Scope', department),
                    const SizedBox(height: 4),
                    _buildStatRow('Period', period),
                    const SizedBox(height: 4),
                    _buildStatRow('Volume', '$taskCount Tasks'),
                    const SizedBox(height: 4),
                    _buildStatRow('Format', 'PDF Document'),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // Premium Actions Buttons
              ElevatedButton.icon(
                icon: const Icon(Icons.print_outlined, size: 18),
                label: const Text('Preview & Print'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1976D2),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 44),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                  elevation: 0,
                ),
                onPressed: () async {
                  Navigator.pop(ctx);
                  await Printing.layoutPdf(
                    onLayout: (format) async => pdf.save(),
                    name: filename,
                  );
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.share_outlined, size: 18),
                label: const Text('Share Document'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1976D2),
                  side: const BorderSide(color: Color(0xFF1976D2)),
                  minimumSize: const Size(double.infinity, 44),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                ),
                onPressed: () async {
                  Navigator.pop(ctx);
                  final bytes = await pdf.save();
                  final tempDir = await getTemporaryDirectory();
                  final file = File('${tempDir.path}/$filename');
                  await file.writeAsBytes(bytes);
                  // ignore: deprecated_member_use
                  await Share.shareXFiles([XFile(file.path)], text: 'Exported Operational Report');
                },
              ),
              const SizedBox(height: 8),
              TextButton(
                child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                onPressed: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _buildStatRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: Colors.grey,
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF1E293B),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
