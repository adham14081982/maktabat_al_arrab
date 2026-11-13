import 'package:flutter/services.dart';
import '../models/reader_settings.dart';

/// Service for page flip effects (haptic feedback)
class PageFlipService {
  /// Trigger haptic feedback on page turn
  static Future<void> triggerHaptic(ReaderSettings settings) async {
    if (settings.hapticFeedback) {
      await HapticFeedback.lightImpact();
    }
  }

  /// Calculate page curl progress (0.0 to 1.0) based on drag
  static double curlProgress(double dragDelta, double pageWidth) {
    return (dragDelta.abs() / pageWidth).clamp(0.0, 1.0);
  }

  /// Determine if drag should trigger page turn
  static bool shouldTurnPage(double dragDelta, double pageWidth) {
    return dragDelta.abs() > pageWidth * 0.25;
  }
}
