import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Displays one non-destructive photo number overlay.
///
/// The widget intentionally owns the complete badge rendering so a photo is
/// not numbered once by the cached image and a second time by the UI.
class NumberBadgeOverlay extends StatelessWidget {
  final Map<String, dynamic> placement;

  const NumberBadgeOverlay({super.key, required this.placement});

  @override
  Widget build(BuildContext context) {
    final number = (placement['number_text'] ?? '').toString().trim();
    if (number.isEmpty) return const SizedBox.shrink();

    final position = (placement['number_position'] ?? 'top_right').toString();
    final color = _parseColor(
      (placement['number_color'] ?? '#D32F2F').toString(),
    );
    final transparent = (placement['number_background_transparent'] ?? 0) == 1;
    final selectedSize = _parseSize(placement['number_size']);

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final shortest = math.min(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          // number_size is stored in source-image pixels.  Scale it against
          // the 320px thumbnail baseline so a desktop-sized value cannot
          // cover a whole phone thumbnail.
          final requested = selectedSize * (shortest / 320.0);
          final diameter = math.max(16.0, math.min(requested, shortest * 0.28));
          final margin = math.max(4.0, diameter * 0.12);
          final fontSize = math.max(10.0, diameter * 0.48);
          final badgeWidth = math.max(
            diameter,
            diameter * (number.length > 2 ? 1.28 : 1.0),
          );
          final alignment = switch (position) {
            'top_left' => Alignment.topLeft,
            'bottom_left' => Alignment.bottomLeft,
            'bottom_right' => Alignment.bottomRight,
            _ => Alignment.topRight,
          };

          return Align(
            alignment: alignment,
            child: Padding(
              padding: EdgeInsets.all(margin),
              child: SizedBox(
                width: badgeWidth,
                height: diameter,
                child: Container(
                  alignment: Alignment.center,
                  decoration: transparent
                      ? null
                      : BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(diameter * 0.24),
                        ),
                  child: Text(
                    number,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: color == Colors.transparent
                          ? color
                          : transparent
                          ? color
                          : Colors.white,
                      fontSize: fontSize,
                      height: 1,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  static double _parseSize(Object? raw) {
    final text = (raw ?? '72').toString().trim().toLowerCase();
    const legacy = {'small': 48.0, 'medium': 72.0, 'large': 108.0};
    return double.tryParse(text) ?? legacy[text] ?? 72.0;
  }

  static Color _parseColor(String raw) {
    var hex = raw.replaceFirst('#', '').trim();
    if (hex.length == 6) hex = 'FF$hex';
    final value = int.tryParse(hex, radix: 16);
    return value == null ? const Color(0xFFD32F2F) : Color(value);
  }
}
