import 'package:flutter/material.dart';

class AppSpacing {
  AppSpacing._();

  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 20.0;
  static const double xxl = 24.0;
  static const double xxxl = 32.0;

  // Spacing Edge Insets utility constants
  static const EdgeInsets pAllXs = EdgeInsets.all(xs);
  static const EdgeInsets pAllSm = EdgeInsets.all(sm);
  static const EdgeInsets pAllMd = EdgeInsets.all(md);
  static const EdgeInsets pAllLg = EdgeInsets.all(lg);
  static const EdgeInsets pAllXl = EdgeInsets.all(xl);
  static const EdgeInsets pAllXxl = EdgeInsets.all(xxl);

  // Horizontal Edge Insets
  static const EdgeInsets pxSm = EdgeInsets.symmetric(horizontal: sm);
  static const EdgeInsets pxMd = EdgeInsets.symmetric(horizontal: md);
  static const EdgeInsets pxLg = EdgeInsets.symmetric(horizontal: lg);
  static const EdgeInsets pxXl = EdgeInsets.symmetric(horizontal: xl);
  static const EdgeInsets pxXxl = EdgeInsets.symmetric(horizontal: xxl);

  // Vertical Edge Insets
  static const EdgeInsets pySm = EdgeInsets.symmetric(vertical: sm);
  static const EdgeInsets pyMd = EdgeInsets.symmetric(vertical: md);
  static const EdgeInsets pyLg = EdgeInsets.symmetric(vertical: lg);
  static const EdgeInsets pyXl = EdgeInsets.symmetric(vertical: xl);
  static const EdgeInsets pyXxl = EdgeInsets.symmetric(vertical: xxl);
}
