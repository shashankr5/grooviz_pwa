// components/home/kpi_command_grid.dart
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

class KpiCommandGrid extends StatelessWidget {
  final int escalationCount;
  final int openCount;
  final int inProgressCount;
  final int closedCount;
  final String activeFilter;
  final Function(String filter) onFilterSelected;

  const KpiCommandGrid({
    super.key,
    required this.escalationCount,
    required this.openCount,
    required this.inProgressCount,
    required this.closedCount,
    required this.activeFilter,
    required this.onFilterSelected,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double itemWidth = (constraints.maxWidth - 12) / 2;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _KpiTile(
              width: itemWidth,
              title: 'Escalated',
              count: escalationCount,
              icon: Icons.warning_amber_rounded,
              bgColor: AppColors.errorLight,
              accentColor: AppColors.error,
              isSelected: activeFilter == 'Escalated',
              onTap: () => onFilterSelected('Escalated'),
            ),

            // Open Requests
            _KpiTile(
              width: itemWidth,
              title: 'Open Requests',
              count: openCount,
              icon: Icons.assignment_outlined,
              bgColor: AppColors.infoLight,
              accentColor: AppColors.info,
              isSelected: activeFilter == 'Open',
              onTap: () => onFilterSelected('Open'),
            ),

            // Tile 3: In Progress
            _KpiTile(
              width: itemWidth,
              title: 'In Progress',
              count: inProgressCount,
              icon: Icons.hourglass_top_rounded,
              bgColor: AppColors.orangeLight,
              accentColor: AppColors.orange,
              isSelected: activeFilter == 'In Progress',
              onTap: () => onFilterSelected('In Progress'),
            ),

            // Tile 4: Completed
            _KpiTile(
              width: itemWidth,
              title: 'Completed Today',
              count: closedCount,
              icon: Icons.check_circle_outline_rounded,
              bgColor: AppColors.successLight,
              accentColor: AppColors.success,
              isSelected: activeFilter == 'Closed',
              onTap: () => onFilterSelected('Closed'),
            ),
          ],
        );
      },
    );
  }
}

class _KpiTile extends StatelessWidget {
  final double width;
  final String title;
  final int count;
  final IconData icon;
  final Color bgColor;
  final Color accentColor;
  final bool isSelected;
  final VoidCallback onTap;

  const _KpiTile({
    required this.width,
    required this.title,
    required this.count,
    required this.icon,
    required this.bgColor,
    required this.accentColor,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? accentColor.withOpacity(0.08) : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? accentColor : AppColors.border.withOpacity(0.5),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.shadow,
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            // Icon container
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                color: accentColor,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),

            // Text / Count column
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$count',
                    style: AppTypography.h1.copyWith(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    title,
                    style: AppTypography.caption.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
