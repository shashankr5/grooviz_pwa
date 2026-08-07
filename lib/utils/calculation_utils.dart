import 'type_converter.dart';

class CalculationUtils {
  CalculationUtils._();

  /// Calculates percentage rate safely. Handles zero division and double mappings.
  static double calculateRate(num part, num total) {
    if (total == 0) return 0.0;
    final rate = (part.toDouble() / total.toDouble()) * 100.0;
    // Format to 1 decimal place limit matching layout style
    return TypeConverter.safeToDouble(rate.toStringAsFixed(1));
  }

  /// safe summation of order totals in lists.
  static double sumListValues(List<dynamic> items, String key) {
    double total = 0.0;
    for (final item in items) {
      if (item is Map) {
        final val = TypeConverter.safeToDouble(item[key]);
        total += val;
      }
    }
    return total;
  }

  /// Calculates task progress rate.
  static double calculateTaskProgress(int completed, int total) {
    return calculateRate(completed, total);
  }
}
