import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:site_photo_mobile/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App boots to project list', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const SitePhotoApp());
    // Pump a few frames (not pumpAndSettle — the loading spinner is an
    // infinite animation that would never settle).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('📋 我的工程'), findsOneWidget);
  });
}
