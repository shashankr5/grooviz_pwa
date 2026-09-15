// components/home/executive_header_card.dart
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../services/websocket_service.dart';

class ExecutiveHeaderCard extends StatefulWidget {
  final String userName;
  final String userRole;
  final String enterpriseName;

  const ExecutiveHeaderCard({
    super.key,
    required this.userName,
    required this.userRole,
    this.enterpriseName = "",
  });

  @override
  State<ExecutiveHeaderCard> createState() => _ExecutiveHeaderCardState();
}

class _ExecutiveHeaderCardState extends State<ExecutiveHeaderCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  String _greetingText() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary,
            AppColors.primaryDark,
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Connection dot (right-aligned, no label, no profile avatar)
          Align(
            alignment: Alignment.centerRight,
            child: ValueListenableBuilder<bool>(
              valueListenable: WebSocketService().isConnected,
              builder: (context, isConnected, _) {
                return FadeTransition(
                  opacity: _pulseAnimation,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isConnected
                          ? AppColors.success
                          : AppColors.warning,
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 4),
          Text(
            '${_greetingText()}, ${widget.userName}',
            style: AppTypography.h2.copyWith(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),

          const SizedBox(height: 6),

          // Row 3: User Role & Department Badge
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.userRole.isNotEmpty ? widget.userRole : 'Staff',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.enterpriseName.isNotEmpty
                      ? '• ${widget.enterpriseName}'
                      : '• Operations Command Center',
                  style: AppTypography.bodySecondary.copyWith(
                    color: Colors.white.withOpacity(0.85),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
