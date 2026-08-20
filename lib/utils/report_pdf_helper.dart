import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Shared colour palette (mirrors AppColors for PDF context)
// ─────────────────────────────────────────────────────────────────────────────
class _C {
  static const navy      = PdfColor.fromInt(0xFF0F172A);
  static const navyMid   = PdfColor.fromInt(0xFF1E3A5F);
  static const primary   = PdfColor.fromInt(0xFF1565C0);
  static const green     = PdfColor.fromInt(0xFF16A34A);
  static const greenLt   = PdfColor.fromInt(0xFFDCFCE7);
  static const amber     = PdfColor.fromInt(0xFFD97706);
  static const amberLt   = PdfColor.fromInt(0xFFFEF3C7);
  static const red       = PdfColor.fromInt(0xFFDC2626);
  static const redLt     = PdfColor.fromInt(0xFFFEF2F2);
  static const orange    = PdfColor.fromInt(0xFFEA580C);
  static const teal      = PdfColor.fromInt(0xFF0D9488);
  static const slate600  = PdfColor.fromInt(0xFF475569);
  static const slate400  = PdfColor.fromInt(0xFF94A3B8);
  static const slate200  = PdfColor.fromInt(0xFFE2E8F0);
  static const slate100  = PdfColor.fromInt(0xFFF1F5F9);
  static const white     = PdfColors.white;

  // Role-badge colour
  static PdfColor forRole(int tier) {
    if (tier >= 4) return navy;
    if (tier == 3) return primary;
    if (tier == 2) return teal;
    return slate600;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main export class
// ─────────────────────────────────────────────────────────────────────────────
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

    // Loading overlay
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
                CircularProgressIndicator(color: Color(0xFF1565C0), strokeWidth: 3),
                SizedBox(height: 18),
                Text('Compiling report…',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      // ── Metrics ────────────────────────────────────────────────────────────
      final total      = tasks.length;
      final closed     = tasks.where((t) => _status(t) == 'Closed').length;
      final inProgress = tasks.where((t) => _status(t) == 'In Progress').length;
      final open       = tasks.where((t) {
        final s = _status(t);
        return s != 'Closed' && s != 'In Progress';
      }).length;
      final escList    = tasks.where(_isEsc).toList();
      final escalated  = escList.length;

      final closureRate    = total == 0 ? 0.0  : (closed    / total * 100).clamp(0.0, 100.0);
      final escalationRate = total == 0 ? 0.0  : (escalated / total * 100).clamp(0.0, 100.0);
      final complianceRate = 100.0 - escalationRate;

      final avgResMins = _calcAvgResMins(tasks.where((t) => _status(t) == 'Closed').toList());
      final avgTimeStr = _fmtMins(avgResMins);

      // ── Fonts ──────────────────────────────────────────────────────────────
      final fN = pw.Font.helvetica();
      final fB = pw.Font.helveticaBold();
      final fI = pw.Font.helveticaOblique();

      final isStaff = userTierLevel <= 1;

      // ── Build PDF ──────────────────────────────────────────────────────────
      final pdf = pw.Document();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          header: (ctx) => _buildPageHeader(
            fN: fN, fB: fB,
            enterpriseId: enterpriseId,
            userRole: userRole,
            userName: userName,
            monthYear: monthYear,
            departmentName: departmentName,
            tier: userTierLevel,
            pageNumber: ctx.pageNumber,
            pagesCount: ctx.pagesCount,
          ),
          footer: (ctx) => _buildPageFooter(fN: fN, fI: fI, ctx: ctx),
          build: (pw.Context ctx) {
            return [
              // Body padding wrapper
              pw.Padding(
                padding: const pw.EdgeInsets.fromLTRB(28, 0, 28, 24),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.SizedBox(height: 20),

                    // ── KPI Dashboard ───────────────────────────────────────
                    _sectionTitle('PERFORMANCE OVERVIEW', fB),
                    pw.SizedBox(height: 8),
                    _buildKpiGrid(
                      fN: fN, fB: fB,
                      total: total, closed: closed, inProgress: inProgress,
                      open: open, escalated: escalated,
                      complianceRate: complianceRate,
                      closureRate: closureRate,
                      escalationRate: escalationRate,
                      avgTimeStr: avgTimeStr,
                    ),

                    pw.SizedBox(height: 20),

                    // ── Status Distribution Bar ─────────────────────────────
                    if (total > 0) ...[
                      _sectionTitle('TASK STATUS DISTRIBUTION', fB),
                      pw.SizedBox(height: 8),
                      _buildDistributionBar(
                        fN: fN, fB: fB,
                        total: total, closed: closed,
                        inProgress: inProgress, open: open, escalated: escalated,
                      ),
                      pw.SizedBox(height: 20),
                    ],

                    // ── Department table (supervisor+) ─────────────────────
                    if (!isStaff) ...[
                      _buildDepartmentTable(tasks, fN, fB),
                      pw.SizedBox(height: 20),
                    ],

                    // ── Staff table (supervisor+) ───────────────────────────
                    if (!isStaff) ...[
                      _sectionTitle('INDIVIDUAL STAFF PERFORMANCE', fB),
                      pw.SizedBox(height: 8),
                      _buildStaffTable(tasks, fN, fB),
                      pw.SizedBox(height: 20),
                    ],

                    // ── My Tasks (staff role only) ─────────────────────────
                    if (isStaff) ...[
                      _sectionTitle('MY TASK LOG', fB),
                      pw.SizedBox(height: 8),
                      _buildPersonalTaskLog(tasks, fN, fB, fI),
                      pw.SizedBox(height: 20),
                    ],

                    // ── Escalation audit (all roles if any esc exists) ──────
                    if (escList.isNotEmpty) ...[
                      _sectionTitle(
                        'CRITICAL SLA ESCALATION AUDIT  ·  ${escList.length} BREACH${escList.length == 1 ? '' : 'ES'}',
                        fB,
                        accent: _C.red,
                      ),
                      pw.SizedBox(height: 8),
                      _buildEscalationTable(escList, fN, fB),
                    ],
                  ],
                ),
              ),
            ];
          },
        ),
      );

      navigator.pop();

      final filename = getReportFilename(
        enterpriseId: enterpriseId,
        departmentName: departmentName,
        roleLabel: userRole,
        period: periodLabel,
      );

      _showPreviewDialog(
        context: context, pdf: pdf, filename: filename,
        period: periodLabel, department: departmentName, taskCount: total,
      );
    } catch (e) {
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text('⚠️ Failed to compile report: $e'),
        backgroundColor: const Color(0xFFDC2626),
      ));
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Page Chrome: Header & Footer
  // ───────────────────────────────────────────────────────────────────────────

  static pw.Widget _buildPageHeader({
    required pw.Font fN, required pw.Font fB,
    required String enterpriseId, required String userRole,
    required String userName,  required String monthYear,
    required String departmentName, required int tier,
    required int pageNumber,   required int pagesCount,
  }) {
    final roleColor = _C.forRole(tier);
    return pw.Column(
      children: [
        // Navy gradient band
        pw.Container(
          width: double.infinity,
          color: _C.navy,
          padding: const pw.EdgeInsets.fromLTRB(28, 18, 28, 16),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Branding block
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'SCREENSYNC ENTERPRISE',
                      style: pw.TextStyle(font: fB, fontSize: 14, color: _C.white, letterSpacing: 1),
                    ),
                    pw.SizedBox(height: 3),
                    pw.Text(
                      'Operational Performance & SLA Compliance Report',
                      style: pw.TextStyle(font: fN, fontSize: 8.5, color: _C.slate400),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(width: 16),
              // Meta block
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  // Role badge
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: pw.BoxDecoration(
                      color: roleColor,
                      borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                    ),
                    child: pw.Text(
                      userRole.toUpperCase(),
                      style: pw.TextStyle(font: fB, fontSize: 7, color: _C.white, letterSpacing: 0.5),
                    ),
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    enterpriseId,
                    style: pw.TextStyle(font: fB, fontSize: 9, color: _C.white),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    '$departmentName  ·  $monthYear',
                    style: pw.TextStyle(font: fN, fontSize: 7.5, color: _C.slate400),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    'By: $userName',
                    style: pw.TextStyle(font: fN, fontSize: 7.5, color: _C.slate400),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Thin accent line
        pw.Container(
          width: double.infinity,
          height: 3,
          color: _C.primary,
        ),
      ],
    );
  }

  static pw.Widget _buildPageFooter({
    required pw.Font fN, required pw.Font fI, required pw.Context ctx,
  }) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.fromLTRB(28, 8, 28, 10),
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _C.slate200, width: 0.5)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'CONFIDENTIAL — Internal Use Only',
            style: pw.TextStyle(font: fI, fontSize: 7, color: _C.slate400),
          ),
          pw.Text(
            'Page ${ctx.pageNumber} of ${ctx.pagesCount}  ·  Generated ${_fmtNow()}',
            style: pw.TextStyle(font: fN, fontSize: 7, color: _C.slate400),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Section title
  // ───────────────────────────────────────────────────────────────────────────

  static pw.Widget _sectionTitle(String label, pw.Font fB, {PdfColor? accent}) {
    final accentColor = accent ?? _C.primary;
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Container(width: 3, height: 14, color: accentColor),
        pw.SizedBox(width: 8),
        pw.Text(
          label,
          style: pw.TextStyle(font: fB, fontSize: 9.5, color: _C.navy, letterSpacing: 0.4),
        ),
      ],
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // KPI Grid (2 rows × 3 cols)
  // ───────────────────────────────────────────────────────────────────────────

  static pw.Widget _buildKpiGrid({
    required pw.Font fN, required pw.Font fB,
    required int total, required int closed, required int inProgress,
    required int open, required int escalated,
    required double complianceRate, required double closureRate,
    required double escalationRate, required String avgTimeStr,
  }) {
    final escColor = escalationRate <= 5.0 ? _C.green : (escalationRate <= 15.0 ? _C.amber : _C.red);
    final slaColor = complianceRate >= 95 ? _C.green : (complianceRate >= 85 ? _C.amber : _C.red);

    return pw.Column(
      children: [
        pw.Row(children: [
          _kpiCard(fN: fN, fB: fB, label: 'TOTAL TASKS',      value: '$total',
              sub: 'Period volume', accent: _C.primary,
              progress: null),
          pw.SizedBox(width: 8),
          _kpiCard(fN: fN, fB: fB, label: 'COMPLETED',         value: '$closed',
              sub: '${closureRate.toStringAsFixed(1)}% closure rate', accent: _C.green,
              progress: closureRate / 100),
          pw.SizedBox(width: 8),
          _kpiCard(fN: fN, fB: fB, label: 'AVG RESOLUTION',    value: avgTimeStr,
              sub: 'Mean turnaround time', accent: _C.teal,
              progress: null),
        ]),
        pw.SizedBox(height: 8),
        pw.Row(children: [
          _kpiCard(fN: fN, fB: fB, label: 'IN PROGRESS',       value: '$inProgress',
              sub: 'Active tasks', accent: _C.orange,
              progress: total == 0 ? 0.0 : inProgress / total),
          pw.SizedBox(width: 8),
          _kpiCard(fN: fN, fB: fB, label: 'ESCALATION RATE',   value: '${escalationRate.toStringAsFixed(1)}%',
              sub: '$escalated breach event${escalated == 1 ? '' : 's'}', accent: escColor,
              progress: escalationRate / 100, invertProgressColor: true),
          pw.SizedBox(width: 8),
          _kpiCard(fN: fN, fB: fB, label: 'SLA COMPLIANCE',    value: '${complianceRate.toStringAsFixed(1)}%',
              sub: _slaLabel(complianceRate), accent: slaColor,
              progress: complianceRate / 100),
        ]),
      ],
    );
  }

  static pw.Widget _kpiCard({
    required pw.Font fN, required pw.Font fB,
    required String label,  required String value,
    required String sub,    required PdfColor accent,
    required double? progress,
    bool invertProgressColor = false,
  }) {
    return pw.Expanded(
      child: pw.Container(
        decoration: pw.BoxDecoration(
          color: _C.white,
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
          border: pw.Border.all(color: _C.slate200, width: 0.5),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            // Accent top bar
            pw.Container(
              height: 3,
              decoration: pw.BoxDecoration(
                color: accent,
                borderRadius: const pw.BorderRadius.only(
                  topLeft:  pw.Radius.circular(8),
                  topRight: pw.Radius.circular(8),
                ),
              ),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(label,
                      style: pw.TextStyle(font: fB, fontSize: 7, color: _C.slate600, letterSpacing: 0.3)),
                  pw.SizedBox(height: 5),
                  pw.Text(value,
                      style: pw.TextStyle(font: fB, fontSize: 18, color: _C.navy)),
                  pw.SizedBox(height: 3),
                  pw.Text(sub,
                      style: pw.TextStyle(font: fN, fontSize: 7, color: _C.slate400),
                      maxLines: 1),
                  if (progress != null) ...[
                    pw.SizedBox(height: 6),
                    _miniBar(progress.clamp(0.0, 1.0), accent, invertProgressColor),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static pw.Widget _miniBar(double ratio, PdfColor accent, bool invert) {
    final barColor = invert
        ? (ratio <= 0.05 ? _C.green : (ratio <= 0.15 ? _C.amber : _C.red))
        : accent;
    final filledPart = (ratio * 1000).round().clamp(0, 1000);
    final emptyPart = 1000 - filledPart;

    return pw.Container(
      height: 4,
      decoration: const pw.BoxDecoration(
        color: _C.slate200,
        borderRadius: pw.BorderRadius.all(pw.Radius.circular(2)),
      ),
      child: pw.Row(
        children: [
          if (filledPart > 0)
            pw.Expanded(
              flex: filledPart,
              child: pw.Container(
                height: 4,
                decoration: pw.BoxDecoration(
                  color: barColor,
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(2)),
                ),
              ),
            ),
          if (emptyPart > 0)
            pw.Expanded(
              flex: emptyPart,
              child: pw.SizedBox(height: 4),
            ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Status Distribution Bar
  // ───────────────────────────────────────────────────────────────────────────

  static pw.Widget _buildDistributionBar({
    required pw.Font fN, required pw.Font fB,
    required int total,  required int closed,
    required int inProgress, required int open, required int escalated,
  }) {
    final barH = 14.0;
    final closedW    = total == 0 ? 0.0 : (closed     / total);
    final ipW        = total == 0 ? 0.0 : (inProgress / total);
    final openW      = total == 0 ? 0.0 : (open       / total);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        // Stacked bar
        pw.Container(
          height: barH,
          decoration: const pw.BoxDecoration(
            color: _C.slate200,
            borderRadius: pw.BorderRadius.all(pw.Radius.circular(6)),
          ),
          child: pw.Row(children: [
            if (closed > 0)
              _barSeg(closedW, _C.green,  first: true, last: inProgress == 0 && open == 0),
            if (inProgress > 0)
              _barSeg(ipW,    _C.orange, first: closed == 0,   last: open == 0),
            if (open > 0)
              _barSeg(openW,  _C.primary, first: closed == 0 && inProgress == 0, last: true),
          ]),
        ),
        pw.SizedBox(height: 8),
        // Legend row
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.start,
          children: [
            _legendDot(_C.green,  'Completed ($closed)',    fN),
            pw.SizedBox(width: 16),
            _legendDot(_C.orange, 'In Progress ($inProgress)', fN),
            pw.SizedBox(width: 16),
            _legendDot(_C.primary,'Open ($open)',           fN),
            if (escalated > 0) ...[
              pw.SizedBox(width: 16),
              _legendDot(_C.red,  'Escalated ($escalated)', fN),
            ],
          ],
        ),
      ],
    );
  }

  static pw.Widget _barSeg(double frac, PdfColor color, {bool first = false, bool last = false}) {
    return pw.Flexible(
      flex: (frac * 1000).round(),
      child: pw.Container(
        decoration: pw.BoxDecoration(
          color: color,
          borderRadius: pw.BorderRadius.only(
            topLeft:     first ? const pw.Radius.circular(6) : pw.Radius.zero,
            bottomLeft:  first ? const pw.Radius.circular(6) : pw.Radius.zero,
            topRight:    last  ? const pw.Radius.circular(6) : pw.Radius.zero,
            bottomRight: last  ? const pw.Radius.circular(6) : pw.Radius.zero,
          ),
        ),
      ),
    );
  }

  static pw.Widget _legendDot(PdfColor color, String label, pw.Font fN) {
    return pw.Row(children: [
      pw.Container(width: 8, height: 8, decoration: pw.BoxDecoration(color: color, shape: pw.BoxShape.circle)),
      pw.SizedBox(width: 4),
      pw.Text(label, style: pw.TextStyle(font: fN, fontSize: 7.5, color: _C.slate600)),
    ]);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Department Table
  // ───────────────────────────────────────────────────────────────────────────

  static pw.Widget _buildDepartmentTable(
      List<dynamic> tasks, pw.Font fN, pw.Font fB) {
    final Map<String, Map<String, dynamic>> deptStats = {};

    for (final t in tasks) {
      final dept   = (t['department_name'] ?? t['department'] ?? 'Operations').toString();
      final status = _status(t);
      final isEsc  = _isEsc(t);

      deptStats.putIfAbsent(dept, () => {
        'total': 0, 'closed': 0, 'inProgress': 0,
        'escalated': 0, 'totalDurMins': 0.0, 'closedDurCnt': 0,
      });

      deptStats[dept]!['total'] = (deptStats[dept]!['total'] as int) + 1;
      if (status == 'Closed') {
        deptStats[dept]!['closed'] = (deptStats[dept]!['closed'] as int) + 1;
        final m = _taskResMins(t);
        if (m > 0) {
          deptStats[dept]!['totalDurMins'] = (deptStats[dept]!['totalDurMins'] as double) + m;
          deptStats[dept]!['closedDurCnt'] = (deptStats[dept]!['closedDurCnt'] as int) + 1;
        }
      } else if (status == 'In Progress') {
        deptStats[dept]!['inProgress'] = (deptStats[dept]!['inProgress'] as int) + 1;
      }
      if (isEsc) {
        deptStats[dept]!['escalated'] = (deptStats[dept]!['escalated'] as int) + 1;
      }
    }

    if (deptStats.isEmpty) return pw.SizedBox.shrink();

    const headers = ['Department', 'Volume', 'Closed', 'In Prog.', 'Avg Time', 'Esc.', 'Esc %', 'SLA Health'];
    final colWidths = {
      0: const pw.FixedColumnWidth(110),
      1: const pw.FixedColumnWidth(45),
      2: const pw.FixedColumnWidth(45),
      3: const pw.FixedColumnWidth(45),
      4: const pw.FixedColumnWidth(55),
      5: const pw.FixedColumnWidth(35),
      6: const pw.FixedColumnWidth(40),
      7: const pw.FixedColumnWidth(65),
    };

    final List<pw.TableRow> rows = [
      // Header
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _C.navy),
        children: headers.asMap().entries.map((e) {
          final isRight = e.key > 0 && e.key < 7;
          return pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: pw.Text(e.value,
                textAlign: e.key == 7 ? pw.TextAlign.center
                    : isRight ? pw.TextAlign.right : pw.TextAlign.left,
                style: pw.TextStyle(font: fB, fontSize: 7.5, color: _C.white)),
          );
        }).toList(),
      ),
    ];

    var idx = 0;
    deptStats.forEach((dept, s) {
      final total = s['total'] as int;
      final closed = s['closed'] as int;
      final ip     = s['inProgress'] as int;
      final esc    = s['escalated'] as int;
      final durMins= (s['totalDurMins'] as double);
      final durCnt = s['closedDurCnt'] as int;
      final avgMins = durCnt > 0 ? durMins / durCnt : 0.0;
      final escRate = total == 0 ? 0.0 : (esc / total * 100);
      final isOpt   = escRate <= 5.0;
      final isElev  = escRate > 5.0 && escRate <= 15.0;
      final healthLabel = isOpt ? 'Optimal' : (isElev ? 'Elevated' : 'Critical');
      final healthBg    = isOpt ? _C.greenLt : (isElev ? _C.amberLt : _C.redLt);
      final healthColor = isOpt ? _C.green   : (isElev ? _C.amber   : _C.red);

      rows.add(pw.TableRow(
        decoration: pw.BoxDecoration(
          color: idx % 2 == 0 ? _C.white : _C.slate100,
        ),
        children: [
          _tCell(dept,              fB, fN, left: true),
          _tCell('$total',          fN, fN),
          _tCell('$closed',         fB, fN, color: _C.green),
          _tCell('$ip',             fN, fN),
          _tCell(_fmtMins(avgMins), fN, fN),
          _tCell('$esc',            fB, fN, color: esc > 0 ? _C.red : _C.slate400),
          _tCell('${escRate.toStringAsFixed(1)}%', fB, fN,
              color: isOpt ? _C.green : (isElev ? _C.amber : _C.red)),
          // Health pill
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: pw.Center(
              child: pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: pw.BoxDecoration(
                  color: healthBg,
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                ),
                child: pw.Text(healthLabel,
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(font: fB, fontSize: 7.5, color: healthColor)),
              ),
            ),
          ),
        ],
      ));
      idx++;
    });

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('DEPARTMENT-WISE SLA BENCHMARK', fB),
        pw.SizedBox(height: 8),
        pw.Table(
          columnWidths: colWidths,
          border: pw.TableBorder.all(color: _C.slate200, width: 0.5),
          children: rows,
        ),
      ],
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Staff Performance Table
  // ───────────────────────────────────────────────────────────────────────────

  static pw.Widget _buildStaffTable(
      List<dynamic> tasks, pw.Font fN, pw.Font fB) {
    if (tasks.isEmpty) return pw.SizedBox.shrink();

    final Map<String, Map<String, dynamic>> staffStats = {};

    for (final t in tasks) {
      final staff  = (t['assignedTo'] ?? t['assigned_to_name'] ?? t['assignee_name'] ?? 'Unassigned').toString();
      final status = _status(t);
      final isEsc  = _isEsc(t);

      staffStats.putIfAbsent(staff, () => {
        'total': 0, 'open': 0, 'inProgress': 0, 'closed': 0,
        'escalated': 0, 'totalDurMins': 0.0, 'closedDurCnt': 0,
      });

      staffStats[staff]!['total'] = (staffStats[staff]!['total'] as int) + 1;
      if (status == 'Closed') {
        staffStats[staff]!['closed'] = (staffStats[staff]!['closed'] as int) + 1;
        final m = _taskResMins(t);
        if (m > 0) {
          staffStats[staff]!['totalDurMins'] = (staffStats[staff]!['totalDurMins'] as double) + m;
          staffStats[staff]!['closedDurCnt'] = (staffStats[staff]!['closedDurCnt'] as int) + 1;
        }
      } else if (status == 'In Progress') {
        staffStats[staff]!['inProgress'] = (staffStats[staff]!['inProgress'] as int) + 1;
      } else {
        staffStats[staff]!['open'] = (staffStats[staff]!['open'] as int) + 1;
      }
      if (isEsc) staffStats[staff]!['escalated'] = (staffStats[staff]!['escalated'] as int) + 1;
    }

    const headers = ['Staff Member', 'Assigned', 'Closed', 'In Prog.', 'Avg Time', 'Esc.', 'SLA %', 'Allocation'];
    final colWidths = {
      0: const pw.FixedColumnWidth(110),
      1: const pw.FixedColumnWidth(45),
      2: const pw.FixedColumnWidth(45),
      3: const pw.FixedColumnWidth(45),
      4: const pw.FixedColumnWidth(50),
      5: const pw.FixedColumnWidth(35),
      6: const pw.FixedColumnWidth(40),
      7: const pw.FlexColumnWidth(),
    };

    final List<pw.TableRow> rows = [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _C.navyMid),
        children: headers.asMap().entries.map((e) {
          final isRight = e.key > 0 && e.key < 7;
          return pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 6),
            child: pw.Text(e.value,
                textAlign: isRight ? pw.TextAlign.right : pw.TextAlign.left,
                style: pw.TextStyle(font: fB, fontSize: 7.5, color: _C.white)),
          );
        }).toList(),
      ),
    ];

    var idx = 0;
    staffStats.forEach((staff, s) {
      final total    = s['total'] as int;
      final open     = s['open'] as int;
      final ip       = s['inProgress'] as int;
      final closed   = s['closed'] as int;
      final esc      = s['escalated'] as int;
      final durMins  = (s['totalDurMins'] as double);
      final durCnt   = s['closedDurCnt'] as int;
      final avgMins  = durCnt > 0 ? durMins / durCnt : 0.0;
      final slaRate  = total == 0 ? 100.0 : ((total - esc) / total * 100).clamp(0.0, 100.0);
      final slaColor = slaRate >= 90 ? _C.green : (slaRate >= 75 ? _C.amber : _C.red);

      // bar widths (out of 60px available)
      const bW = 60.0;
      final cW = total == 0 ? 0.0 : (closed / total) * bW;
      final iW = total == 0 ? 0.0 : (ip     / total) * bW;
      final oW = total == 0 ? 0.0 : (open   / total) * bW;

      rows.add(pw.TableRow(
        decoration: pw.BoxDecoration(color: idx % 2 == 0 ? _C.white : _C.slate100),
        children: [
          _tCell(staff,                fB, fN, left: true),
          _tCell('$total',             fN, fN),
          _tCell('$closed',            fB, fN, color: _C.green),
          _tCell('$ip',                fN, fN),
          _tCell(_fmtMins(avgMins),    fN, fN),
          _tCell('$esc',               fB, fN, color: esc > 0 ? _C.red : _C.slate400),
          _tCell('${slaRate.toStringAsFixed(0)}%', fB, fN, color: slaColor),
          // Stacked allocation bar
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 7),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Container(
                  height: 7,
                  decoration: const pw.BoxDecoration(
                    color: _C.slate200,
                    borderRadius: pw.BorderRadius.all(pw.Radius.circular(3)),
                  ),
                  child: pw.Row(children: [
                    if (closed > 0)
                      pw.Container(width: cW, height: 7, color: _C.green),
                    if (ip > 0)
                      pw.Container(width: iW, height: 7, color: _C.orange),
                    if (open > 0)
                      pw.Container(width: oW, height: 7, color: _C.primary),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ));
      idx++;
    });

    return pw.Table(
      columnWidths: colWidths,
      border: pw.TableBorder.all(color: _C.slate200, width: 0.5),
      children: rows,
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Personal Task Log (Staff role only)
  // ───────────────────────────────────────────────────────────────────────────

  static pw.Widget _buildPersonalTaskLog(
      List<dynamic> tasks, pw.Font fN, pw.Font fB, pw.Font fI) {
    if (tasks.isEmpty) {
      return pw.Container(
        padding: const pw.EdgeInsets.all(16),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: _C.slate200),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        ),
        child: pw.Center(
          child: pw.Text('No tasks found for this period.',
              style: pw.TextStyle(font: fI, fontSize: 9, color: _C.slate400)),
        ),
      );
    }

    const headers = ['#', 'Room', 'Task / Request', 'Status', 'Date Created', 'Resolved At'];
    final colWidths = {
      0: const pw.FixedColumnWidth(25),
      1: const pw.FixedColumnWidth(40),
      2: const pw.FlexColumnWidth(),
      3: const pw.FixedColumnWidth(60),
      4: const pw.FixedColumnWidth(65),
      5: const pw.FixedColumnWidth(65),
    };

    final List<pw.TableRow> rows = [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _C.navy),
        children: headers.map((h) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 6),
          child: pw.Text(h, style: pw.TextStyle(font: fB, fontSize: 7.5, color: _C.white)),
        )).toList(),
      ),
    ];

    for (var i = 0; i < tasks.length; i++) {
      final t      = tasks[i] as Map<String, dynamic>;
      final isEsc  = _isEsc(t);
      final status = _status(t);
      final rawRoom = (t['room_number'] ?? t['room_id'] ?? t['room'] ?? '—').toString();
      final room    = (rawRoom == '0' || rawRoom == 'null' || rawRoom.isEmpty) ? 'General' : rawRoom;
      final rawTitle= (t['task_name'] ?? t['title'] ?? t['question'] ?? 'Service Request').toString();
      final title   = rawTitle.replaceFirst(RegExp(r'^Order\s+#[A-Z0-9]+\s*-\s*', caseSensitive: false), '');
      final created = _shortDate(t['created_at'] ?? t['time']);
      final closed  = status == 'Closed' ? _shortDate(t['closed_at'] ?? t['completed_at']) : '—';

      final statusColor = isEsc ? _C.red
          : (status == 'Closed' ? _C.green
          : (status == 'In Progress' ? _C.orange : _C.primary));
      final rowBg = isEsc ? _C.redLt : (i % 2 == 0 ? _C.white : _C.slate100);

      rows.add(pw.TableRow(
        decoration: pw.BoxDecoration(color: rowBg),
        children: [
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Text('${i + 1}', style: pw.TextStyle(font: fN, fontSize: 7.5, color: _C.slate400)),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Text(room, style: pw.TextStyle(font: fB, fontSize: 7.5, color: _C.navy)),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Row(children: [
              if (isEsc) ...[
                pw.Container(
                  width: 5, height: 5,
                  decoration: const pw.BoxDecoration(color: _C.red, shape: pw.BoxShape.circle),
                ),
                pw.SizedBox(width: 4),
              ],
              pw.Expanded(
                child: pw.Text(title,
                    style: pw.TextStyle(font: fN, fontSize: 7.5, color: _C.navy),
                    maxLines: 2),
              ),
            ]),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Text(isEsc ? 'Escalated' : status,
                style: pw.TextStyle(font: fB, fontSize: 7.5, color: statusColor)),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Text(created, style: pw.TextStyle(font: fN, fontSize: 7, color: _C.slate600)),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Text(closed, style: pw.TextStyle(font: fN, fontSize: 7, color: _C.slate600)),
          ),
        ],
      ));
    }

    return pw.Table(
      columnWidths: colWidths,
      border: pw.TableBorder.all(color: _C.slate200, width: 0.5),
      children: rows,
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Escalation Audit Log
  // ───────────────────────────────────────────────────────────────────────────

  static pw.Widget _buildEscalationTable(
      List<dynamic> escList, pw.Font fN, pw.Font fB) {
    const headers = ['Ticket', 'Room', 'Service Request', 'Assignee', 'Stage', 'Severity', 'Status', 'Raised At'];
    final colWidths = {
      0: const pw.FixedColumnWidth(38),
      1: const pw.FixedColumnWidth(38),
      2: const pw.FlexColumnWidth(),
      3: const pw.FixedColumnWidth(70),
      4: const pw.FixedColumnWidth(45),
      5: const pw.FixedColumnWidth(55),
      6: const pw.FixedColumnWidth(50),
      7: const pw.FixedColumnWidth(68),
    };

    final List<pw.TableRow> rows = [
      pw.TableRow(
        decoration: pw.BoxDecoration(color: _C.red),
        children: headers.map((h) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 6),
          child: pw.Text(h, style: pw.TextStyle(font: fB, fontSize: 7.5, color: _C.white)),
        )).toList(),
      ),
    ];

    for (var i = 0; i < escList.length; i++) {
      final t       = escList[i] as Map<String, dynamic>;
      final ticketId= (t['service_request_id'] ?? t['id'] ?? t['ticket_id'] ?? '—').toString();
      final rawRoom = (t['room_number'] ?? t['room_id'] ?? t['room'] ?? '—').toString();
      final room    = (rawRoom == '0' || rawRoom == 'null' || rawRoom.isEmpty) ? 'General' : rawRoom;
      final rawTitle= (t['task_name'] ?? t['title'] ?? t['question'] ?? 'Service Request').toString();
      final title   = rawTitle.replaceFirst(RegExp(r'^Order\s+#[A-Z0-9]+\s*-\s*', caseSensitive: false), '');
      final staff   = (t['assignedTo'] ?? t['assigned_to_name'] ?? t['assignee_name'] ?? 'Unassigned').toString();
      final level   = t['escalation_level_reached'] ?? t['escalation_level'];
      final stage   = (t['current_stage_name'] ?? t['stage_name'] ?? (level != null ? 'L$level' : 'L1')).toString();
      final status  = (t['status'] ?? t['task_flag'] ?? 'Escalated').toString();
      final created = _shortDate(t['created_at'] ?? t['time']);

      // Severity derived from escalation level
      final lvlNum  = int.tryParse(level?.toString() ?? '1') ?? 1;
      final severity      = lvlNum >= 3 ? 'Critical' : (lvlNum == 2 ? 'High' : 'Medium');
      final severityBg    = lvlNum >= 3 ? _C.red      : (lvlNum == 2 ? _C.amber : _C.orange);
      final severityColor = _C.white;

      final statusColor = status == 'Closed' ? _C.green : _C.red;

      rows.add(pw.TableRow(
        decoration: pw.BoxDecoration(color: i % 2 == 0 ? _C.white : _C.redLt),
        children: [
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Text('#$ticketId', style: pw.TextStyle(font: fB, fontSize: 7.5, color: _C.navy)),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Text(room, style: pw.TextStyle(font: fB, fontSize: 7.5, color: _C.navy)),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Text(title, style: pw.TextStyle(font: fN, fontSize: 7.5, color: _C.navy), maxLines: 2),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Text(staff, style: pw.TextStyle(font: fN, fontSize: 7.5, color: _C.slate600), maxLines: 1),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Text(stage, style: pw.TextStyle(font: fB, fontSize: 7.5, color: _C.red)),
          ),
          // Severity pill
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            child: pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: pw.BoxDecoration(
                color: severityBg,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
              ),
              child: pw.Text(severity,
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(font: fB, fontSize: 7, color: severityColor)),
            ),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Text(status, style: pw.TextStyle(font: fB, fontSize: 7.5, color: statusColor)),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: pw.Text(created, style: pw.TextStyle(font: fN, fontSize: 7, color: _C.slate600)),
          ),
        ],
      ));
    }

    return pw.Table(
      columnWidths: colWidths,
      border: pw.TableBorder.all(color: PdfColors.red200, width: 0.5),
      children: rows,
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Preview Dialog
  // ───────────────────────────────────────────────────────────────────────────

  static void _showPreviewDialog({
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
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 320,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 24, offset: Offset(0, 8))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon
                Container(
                  width: 60, height: 60,
                  decoration: BoxDecoration(color: const Color(0xFFE8F5E9), shape: BoxShape.circle),
                  child: const Icon(Icons.check_circle_outline, color: Color(0xFF2E7D32), size: 36),
                ),
                const SizedBox(height: 16),
                const Text('Report Ready',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
                const SizedBox(height: 6),
                Text('Performance report for $department is compiled.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 16),
                // Stats box
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8F9FA),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Column(children: [
                    _statRow('Scope',   department),
                    const SizedBox(height: 4),
                    _statRow('Period',  period),
                    const SizedBox(height: 4),
                    _statRow('Tasks',   '$taskCount'),
                    const SizedBox(height: 4),
                    _statRow('Format',  'PDF — A4'),
                  ]),
                ),
                const SizedBox(height: 20),
                // Print button
                ElevatedButton.icon(
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Preview & Print'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1565C0),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 44),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                // Share button
                OutlinedButton.icon(
                  icon: const Icon(Icons.share_outlined, size: 18),
                  label: const Text('Share Document'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF1565C0),
                    side: const BorderSide(color: Color(0xFF1565C0)),
                    minimumSize: const Size(double.infinity, 44),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                  child: const Text('Dismiss', style: TextStyle(color: Colors.grey)),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // File naming
  // ───────────────────────────────────────────────────────────────────────────

  static String getReportFilename({
    required String enterpriseId,
    required String departmentName,
    required String roleLabel,
    required String period,
  }) {
    final now = DateTime.now();
    final ymd = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    String deptCode = 'ALL';
    final dl = departmentName.toLowerCase();
    if (dl.contains('house')) {
      deptCode = 'HK';
    } else if (dl.contains('food') || dl.contains('beverage') || dl.contains('fnb')) {
      deptCode = 'FB';
    } else if (dl.contains('front')) {
      deptCode = 'FO';
    } else if (dl.contains('maint')) {
      deptCode = 'MAINT';
    } else if (dl.contains('it')) {
      deptCode = 'IT';
    } else if (dl.contains('service')) {
      deptCode = 'RS';
    } else if (departmentName.isNotEmpty && departmentName != 'All Departments') {
      deptCode = departmentName.split(' ').map((s) => s.isNotEmpty ? s[0] : '').join().toUpperCase();
    }
    final roleNorm   = roleLabel.replaceAll(' ', '');
    final periodNorm = period.split(' ').first;
    return '${enterpriseId}_${deptCode}_${roleNorm}_${periodNorm}_$ymd.pdf';
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Private helpers
  // ───────────────────────────────────────────────────────────────────────────

  static String _status(dynamic t) =>
      (t['status'] ?? t['task_flag'] ?? 'Open').toString();

  static bool _isEsc(dynamic t) =>
      t['is_escalated'] == 1 ||
      t['is_escalated'] == true ||
      t['task_flag'] == 'Escalated' ||
      t['escalation_instance_id'] != null ||
      t['escalation_status'] != null;

  static double _taskResMins(dynamic t) {
    if (t['avg_resolution_minutes'] != null) {
      final m = (t['avg_resolution_minutes'] as num).toDouble();
      return m > 0 ? m : 0;
    }
    try {
      final cStr  = (t['created_at']  ?? t['time']         ?? '').toString();
      final clStr = (t['closed_at']   ?? t['completed_at'] ?? '').toString();
      if (cStr.isEmpty || clStr.isEmpty) return 0;
      final cDt  = DateTime.tryParse(cStr.replaceFirst(' ', 'T'));
      final clDt = DateTime.tryParse(clStr.replaceFirst(' ', 'T'));
      if (cDt == null || clDt == null) return 0;
      final diff = clDt.difference(cDt).inMinutes;
      return (diff >= 0 && diff < 10080) ? diff.toDouble() : 0;
    } catch (_) { return 0; }
  }

  static double _calcAvgResMins(List<dynamic> closedTasks) {
    double total = 0; int cnt = 0;
    for (final t in closedTasks) {
      final m = _taskResMins(t);
      if (m > 0) { total += m; cnt++; }
    }
    return cnt > 0 ? total / cnt : 0;
  }

  static String _fmtMins(double mins) {
    if (mins <= 0) return '—';
    if (mins < 60) return '${mins.toStringAsFixed(0)}m';
    return '${(mins / 60).toStringAsFixed(1)}h';
  }

  static String _shortDate(dynamic raw) {
    if (raw == null) return '—';
    final s = raw.toString().replaceFirst(' ', 'T');
    if (s.isEmpty || s == 'null') return '—';
    final dt = DateTime.tryParse(s)?.toLocal();
    if (dt == null) return s.length > 10 ? s.substring(0, 10) : s;
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  static String _fmtNow() {
    final n = DateTime.now();
    return '${n.day.toString().padLeft(2, '0')}/${n.month.toString().padLeft(2, '0')}/${n.year}'
        '  ${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  static String _slaLabel(double rate) {
    if (rate >= 95) return 'Excellent — No breaches';
    if (rate >= 85) return 'Good — Minimal impact';
    if (rate >= 75) return 'Fair — Review required';
    return 'Poor — Action required';
  }

  static pw.Widget _tCell(
    String text, pw.Font fPrimary, pw.Font fFallback, {
    bool left = false, PdfColor? color,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
      child: pw.Text(text,
          textAlign: left ? pw.TextAlign.left : pw.TextAlign.right,
          style: pw.TextStyle(font: fPrimary, fontSize: 7.5, color: color ?? _C.navy)),
    );
  }

  static Widget _statRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w500)),
        Text(value, style: const TextStyle(fontSize: 11, color: Color(0xFF1E293B), fontWeight: FontWeight.w600)),
      ],
    );
  }
}
