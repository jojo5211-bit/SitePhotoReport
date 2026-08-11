import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_photo_mobile/widgets/number_badge.dart';

void main() {
  testWidgets('number badge renders one configured number', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: Stack(
              children: [
                Container(color: Colors.grey),
                const NumberBadgeOverlay(
                  placement: {
                    'number_text': '12',
                    'number_position': 'bottom_left',
                    'number_color': '#1565C0',
                    'number_size': '72',
                    'number_background_transparent': 1,
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('12'), findsOneWidget);
    expect(find.byType(NumberBadgeOverlay), findsOneWidget);
  });
}
