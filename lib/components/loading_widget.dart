import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// A standardized loading indicator for use across all ScreenSync screens.
///
/// Shows a centered [CircularProgressIndicator] with a consistent color.
/// [fullScreen] wraps it in an expanded scaffold-filling container so
/// it can be used as a page-level placeholder.
class LoadingWidget extends StatelessWidget {
  const LoadingWidget({super.key, this.fullScreen = false});

  final bool fullScreen;

  @override
  Widget build(BuildContext context) {
    final indicator = Center(
      child: CircularProgressIndicator(
        valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
      ),
    );

    if (fullScreen) {
      return SizedBox.expand(child: indicator);
    }
    return indicator;
  }
}
