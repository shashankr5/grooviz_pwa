import 'package:flutter/material.dart';

class AppRadius {
  AppRadius._();

  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 14.0;
  static const double xl = 16.0;
  static const double xxl = 24.0;
  static const double circular = 999.0;

  // BorderRadius objects
  static final rXs = BorderRadius.circular(xs);
  static final rSm = BorderRadius.circular(sm);
  static final rMd = BorderRadius.circular(md);
  static final rLg = BorderRadius.circular(lg);
  static final rXl = BorderRadius.circular(xl);
  static final rXxl = BorderRadius.circular(xxl);
  static final rCircular = BorderRadius.circular(circular);
}
