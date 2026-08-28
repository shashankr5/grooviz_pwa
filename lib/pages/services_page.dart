// lib/pages/services_page.dart
//
// Services Page — displays service department requests passed from parent.
// No longer makes direct API calls to avoid duplication with home page.
// Bifurcates rendering on is_from_order:
//   0 → DirectRequestCard (text/chat style)
//   1 → CatalogOrderCard  (invoice/booking style)

import 'dart:async';
import 'package:flutter/material.dart';
import '../models/service_request.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../theme/app_spacing.dart';
import '../components/skeleton_loader.dart';
import '../widgets/direct_request_card.dart';
import '../widgets/catalog_order_card.dart';
import 'ticket_details_page.dart' show TicketDetailPage;

// ── Filter enum ───────────────────────────────────────────────────────────────

enum ServiceFilter { all, open, inProgress, closed, direct, orders }

extension _ServiceFilterLabel on ServiceFilter {
  String get label {
    switch (this) {
      case ServiceFilter.all:        return 'All';
      case ServiceFilter.open:       return 'Open';
      case ServiceFilter.inProgress: return 'In Progress';
      case ServiceFilter.closed:     return 'Closed';
      case ServiceFilter.direct:     return 'Direct';
      case ServiceFilter.orders:     return 'Orders';
    }
  }

  bool matches(ServiceRequest r) {
    switch (this) {
      case ServiceFilter.all:        return true;
      case ServiceFilter.open:       return r.isOpen;
      case ServiceFilter.inProgress: return r.isInProgress;
      case ServiceFilter.closed:     return r.isClosed;
      case ServiceFilter.direct:     return !r.isCatalogOrder;
      case ServiceFilter.orders:     return r.isCatalogOrder;
    }
  }
}

// ── Page ──────────────────────────────────────────────────────────────────────

class ServicesPage extends StatefulWidget {
  final List<ServiceRequest>? initialServices;
  final void Function()? onRefreshRequested;
  
  const ServicesPage({
    super.key,
    this.initialServices,
    this.onRefreshRequested,
  });

  @override
  State<ServicesPage> createState() => ServicesPageState();
}

class ServicesPageState extends State<ServicesPage> {
  // Remove TaskService since we're no longer making API calls
  List<ServiceRequest> _allServices = [];
  bool _isLoading = false; // Changed default to false since we'll get data from props
  String? _errorMessage;
  ServiceFilter _activeFilter = ServiceFilter.all;

  // ── Computed filtered list ──────────────────────────────────────────────────

  List<ServiceRequest> get _filtered =>
      _allServices.where(_activeFilter.matches).toList();

  int _countFor(ServiceFilter f) => _allServices.where(f.matches).length;

  // ── Active count (open + in-progress) ──────────────────────────────────────

  int get _activeCount =>
      _allServices.where((r) => r.isOpen || r.isInProgress).length;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // Initialize with passed data or empty list
    if (widget.initialServices != null) {
      _allServices = widget.initialServices!;
    }
  }

  // ── Data refresh callback ──────────────────────────────────────────────────
  void _requestRefresh() {
    if (widget.onRefreshRequested != null) {
      widget.onRefreshRequested!();
    }
  }

  // ── Method to update services from parent ──────────────────────────────────
  void updateServices(List<ServiceRequest> newServices, {String? errorMessage}) {
    if (mounted) {
      setState(() {
        _allServices = newServices;
        _errorMessage = errorMessage;
        _isLoading = false;
      });
    }
  }

  // ── Accept handler (stub — wires to TicketDetailsPage flow) ────────────────

  /// Build the minimal task map that TicketDetailPage expects.
  Map<String, dynamic> _taskMap(ServiceRequest req) => {
        'service_request_id': req.serviceRequestId,
        'room': req.roomNumber,
        'room_number': req.roomNumber,
        'department': req.departmentName,
        'department_id': req.departmentId,
        'enterprise_id': req.enterpriseId,
        'status': req.status,
        'title': req.displayTitle,
        'task_name': req.requestName,
        'question': req.question,
        'answer': req.answer,
        'guest_name': req.guestName ?? '',
        'guest_phone': req.guestPhone ?? '',
        'is_from_order': req.isFromOrder,
        'is_service_request': true,
        'assigned_to': req.assignedTo,
        'assignedTo': req.assignedToName ?? 'Unassigned',
        'assigned_to_name': req.assignedToName,
        'assigned_to_phone': req.assignedToPhone ?? '',
        'is_escalated': req.isEscalated ? 1 : 0,
        'escalation_instance_id': req.escalationInstanceId,
        'escalation_status': req.escalationStatus,
        'current_stage_name': req.currentStageName,
        'raw': <String, dynamic>{
          'service_request_id': req.serviceRequestId,
          'room_number': req.roomNumber,
          'department_name': req.departmentName,
          'department_id': req.departmentId,
          'enterprise_id': req.enterpriseId,
          'status': req.status,
          'task_name': req.requestName,
          'question': req.question,
          'answer': req.answer,
          'guest_name': req.guestName ?? '',
          'guest_phone': req.guestPhone ?? '',
          'is_from_order': req.isFromOrder,
          'is_service_request': true,
          'assigned_to': req.assignedTo,
          'assigned_to_name': req.assignedToName,
          'assigned_to_phone': req.assignedToPhone ?? '',
          'is_escalated': req.isEscalated ? 1 : 0,
          'escalation_instance_id': req.escalationInstanceId,
          'escalation_status': req.escalationStatus,
          'current_stage_name': req.currentStageName,
        },
      };

  void _onAccept(ServiceRequest req) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TicketDetailPage(
          task: _taskMap(req),
        ),
      ),
    ).then((_) => _requestRefresh()); // Request refresh from parent instead
  }

  void _onTap(ServiceRequest req) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TicketDetailPage(
          task: _taskMap(req),
        ),
      ),
    ).then((_) => _requestRefresh()); // Request refresh from parent instead
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _buildAppBar(),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: () async => _requestRefresh(), // Request refresh from parent
        child: _buildBody(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: AppColors.surface,
      elevation: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Services', style: AppTypography.appBarTitle),
          if (!_isLoading && _activeCount > 0)
            Text(
              '$_activeCount active',
              style: AppTypography.appBarSubtitle,
            ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh, color: AppColors.primary),
          onPressed: _requestRefresh, // Request refresh from parent
          tooltip: 'Refresh',
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildBody() {
    if (_isLoading) return _buildSkeleton();
    if (_errorMessage != null) return _buildError();

    final items = _filtered;

    return Column(
      children: [
        // ── Filter chips ──────────────────────────────────────────────────
        _FilterChipRow(
          allServices: _allServices,
          activeFilter: _activeFilter,
          countFor: _countFor,
          onFilterChanged: (f) => setState(() => _activeFilter = f),
        ),

        // ── List ──────────────────────────────────────────────────────────
        Expanded(
          child: items.isEmpty
              ? _buildEmpty()
              : ListView.builder(
                  padding: const EdgeInsets.only(
                      top: AppSpacing.sm, bottom: AppSpacing.xxxl),
                  itemCount: items.length,
                  itemBuilder: (_, i) => _buildTile(items[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildTile(ServiceRequest req) {
    if (req.isCatalogOrder) {
      return CatalogOrderCard(
        request: req,
        onTap: () => _onTap(req),
        onAccept: req.isClosed ? null : () => _onAccept(req),
      );
    }
    return DirectRequestCard(
      request: req,
      onTap: () => _onTap(req),
      onAccept: req.isClosed ? null : () => _onAccept(req),
    );
  }

  // ── State widgets ───────────────────────────────────────────────────────────

  Widget _buildSkeleton() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      itemCount: 5,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: SkeletonLoader(
          width: double.infinity,
          height: 120,
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_off_outlined,
                size: 52, color: AppColors.textDisabled),
            const SizedBox(height: AppSpacing.md),
            Text(
              _errorMessage!,
              style: AppTypography.bodySecondary,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            ElevatedButton.icon(
              onPressed: _requestRefresh, // Request refresh from parent
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    final isFiltered = _activeFilter != ServiceFilter.all;
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.22),
        Center(
          child: Column(
            children: [
              Icon(
                isFiltered
                    ? Icons.filter_list_off
                    : Icons.room_service_outlined,
                size: 64,
                color: AppColors.textDisabled,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                isFiltered
                    ? 'No ${_activeFilter.label} requests'
                    : 'No service requests yet',
                style: AppTypography.bodyPrimary.copyWith(
                    color: AppColors.textSecondary),
              ),
              if (isFiltered) ...[
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: () =>
                      setState(() => _activeFilter = ServiceFilter.all),
                  child: const Text('Show all'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ── Filter Chip Row ───────────────────────────────────────────────────────────

class _FilterChipRow extends StatelessWidget {
  final List<ServiceRequest> allServices;
  final ServiceFilter activeFilter;
  final int Function(ServiceFilter) countFor;
  final ValueChanged<ServiceFilter> onFilterChanged;

  const _FilterChipRow({
    required this.allServices,
    required this.activeFilter,
    required this.countFor,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        child: Row(
          children: ServiceFilter.values.map((f) {
            final count = countFor(f);
            final isActive = f == activeFilter;
            return Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: GestureDetector(
                onTap: () => onFilterChanged(f),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color:
                        isActive ? AppColors.primary : AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isActive
                          ? AppColors.primary
                          : AppColors.border,
                    ),
                  ),
                  child: Text(
                    f == ServiceFilter.all
                        ? '${f.label} ($count)'
                        : '${f.label} ($count)',
                    style: AppTypography.caption.copyWith(
                      color: isActive
                          ? Colors.white
                          : AppColors.textSecondary,
                      fontWeight: isActive
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
