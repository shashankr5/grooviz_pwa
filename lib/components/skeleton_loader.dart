import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';

/// A reusable animated skeleton loader widget for placeholders.
class SkeletonLoader extends StatefulWidget {
  const SkeletonLoader({
    super.key,
    this.width,
    this.height,
    this.borderRadius,
    this.margin,
    this.padding,
  });

  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;

  @override
  State<SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<SkeletonLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _animation = Tween<double>(begin: -2.0, end: 2.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = widget.borderRadius ?? AppRadius.rMd;

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          margin: widget.margin,
          padding: widget.padding,
          decoration: BoxDecoration(
            borderRadius: effectiveRadius,
            gradient: LinearGradient(
              begin: Alignment(_animation.value - 1.0, 0.0),
              end: Alignment(_animation.value + 1.0, 0.0),
              colors: const [
                Color(0xFFE2E8F0),
                Color(0xFFF1F5F9),
                Color(0xFFE2E8F0),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }
}

/// Composite skeleton widget matching task card dimensions on Home Page.
class SkeletonTaskCard extends StatelessWidget {
  const SkeletonTaskCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SkeletonLoader(width: 80, height: 22, borderRadius: AppRadius.rSm),
              SkeletonLoader(width: 60, height: 18, borderRadius: AppRadius.rSm),
            ],
          ),
          const SizedBox(height: 10),
          SkeletonLoader(width: double.infinity, height: 16, borderRadius: AppRadius.rXs),
          const SizedBox(height: 6),
          SkeletonLoader(width: 140, height: 14, borderRadius: AppRadius.rXs),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SkeletonLoader(width: 90, height: 14, borderRadius: AppRadius.rXs),
              SkeletonLoader(width: 70, height: 14, borderRadius: AppRadius.rXs),
            ],
          ),
        ],
      ),
    );
  }
}

/// Composite skeleton widget matching stat card dimensions on Tasks Page.
class SkeletonStatCard extends StatelessWidget {
  const SkeletonStatCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SkeletonLoader(
            width: 36,
            height: 36,
            borderRadius: BorderRadius.all(Radius.circular(18)),
          ),
          const SizedBox(height: 8),
          SkeletonLoader(width: 28, height: 20, borderRadius: AppRadius.rXs),
          const SizedBox(height: 4),
          SkeletonLoader(width: 44, height: 10, borderRadius: AppRadius.rXs),
        ],
      ),
    );
  }
}

/// Composite skeleton widget matching food order card on Food Orders Page.
class SkeletonFoodOrderCard extends StatelessWidget {
  const SkeletonFoodOrderCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              SkeletonLoader(width: 90, height: 20, borderRadius: BorderRadius.all(Radius.circular(6))),
              SkeletonLoader(width: 70, height: 22, borderRadius: BorderRadius.all(Radius.circular(12))),
            ],
          ),
          const SizedBox(height: 12),
          const SkeletonLoader(width: 130, height: 16, borderRadius: BorderRadius.all(Radius.circular(4))),
          const SizedBox(height: 8),
          const SkeletonLoader(width: double.infinity, height: 14, borderRadius: BorderRadius.all(Radius.circular(4))),
          const SizedBox(height: 6),
          const SkeletonLoader(width: 180, height: 14, borderRadius: BorderRadius.all(Radius.circular(4))),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              SkeletonLoader(width: 100, height: 14, borderRadius: BorderRadius.all(Radius.circular(4))),
              SkeletonLoader(width: 80, height: 32, borderRadius: BorderRadius.all(Radius.circular(10))),
            ],
          ),
        ],
      ),
    );
  }
}
