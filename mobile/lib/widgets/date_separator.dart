import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A full-width date separator: gradient line with a pill date label.
/// Matches the desktop app's separator style.
class DateSeparator extends StatelessWidget {
  final String date;
  const DateSeparator({super.key, required this.date});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          Expanded(child: _gradientLine()),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.sepPillBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.sepLineLight),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('📅 ', style: TextStyle(fontSize: 12)),
                Text(
                  date,
                  style: const TextStyle(
                    color: AppColors.sepPillText,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: _gradientLine(reverse: true)),
        ],
      ),
    );
  }

  Widget _gradientLine({bool reverse = false}) {
    return Container(
      height: 2,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: reverse
              ? [AppColors.sepLine, AppColors.sepLineLight]
              : [AppColors.sepLineLight, AppColors.sepLine],
        ),
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}
