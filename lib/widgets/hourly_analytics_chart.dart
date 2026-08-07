// lib/widgets/hourly_analytics_chart.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class HourlyAnalyticsChart extends StatelessWidget {
  final Map<int, int> hourlyVolume;

  const HourlyAnalyticsChart({
    super.key,
    required this.hourlyVolume,
  });

  @override
  Widget build(BuildContext context) {
    // Determine peak hour
    int peakHour = 0;
    int maxVolume = 0;
    hourlyVolume.forEach((hour, count) {
      if (count > maxVolume) {
        maxVolume = count;
        peakHour = hour;
      }
    });

    final maxVal = maxVolume > 0 ? maxVolume : 1;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.bar_chart_rounded, size: 18, color: AppColors.primary),
                  SizedBox(width: 8),
                  Text(
                    'Order Volume by Hour',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              if (maxVolume > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.warningLight,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.local_fire_department_rounded,
                          size: 12, color: AppColors.warning),
                      const SizedBox(width: 3),
                      Text(
                        'Peak ${peakHour.toString().padLeft(2, '0')}:00',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: AppColors.warning,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),

          // Hourly Bars Container
          SizedBox(
            height: 110,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(24, (hour) {
                final count = hourlyVolume[hour] ?? 0;
                final isPeak = hour == peakHour && count > 0;
                final barHeight = count > 0 ? (count / maxVal) * 55.0 : 4.0;

                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (count > 0)
                          Text(
                            '$count',
                            style: TextStyle(
                              fontSize: 9,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              color: isPeak ? AppColors.warning : AppColors.primary,
                            ),
                          )
                        else
                          const SizedBox(height: 11),
                        const SizedBox(height: 2),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          height: barHeight,
                          decoration: BoxDecoration(
                            color: isPeak
                                ? AppColors.warning
                                : count > 0
                                    ? AppColors.primary
                                    : Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          hour % 4 == 0 ? '${hour.toString().padLeft(2, '0')}' : '',
                          style: const TextStyle(
                            fontSize: 9,
                            fontFamily: 'monospace',
                            color: Colors.black45,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}
