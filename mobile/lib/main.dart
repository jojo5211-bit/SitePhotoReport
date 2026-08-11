import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'screens/project_list_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SitePhotoApp());
}

class SitePhotoApp extends StatelessWidget {
  const SitePhotoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..init(),
      child: MaterialApp(
        title: 'SitePhoto Report',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        // Android edge-to-edge layouts can place page content underneath the
        // three-button navigation bar.  Consume the bottom system inset once
        // at the app root; nested SafeArea widgets remain compatible.
        builder: (context, child) =>
            SafeArea(top: false, child: child ?? const SizedBox.shrink()),
        home: const ProjectListScreen(),
      ),
    );
  }
}
