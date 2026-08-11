import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/project_store.dart';

/// Global app state: which project is open, scan roots, recent projects.
/// Persists scan root + recent projects so the home screen remembers them.
class AppState extends ChangeNotifier {
  static const _keyScanRoot = 'scan_root';
  static const _keyRecent = 'recent_projects';

  ProjectStore? _store;
  String _scanRoot = '';
  List<String> _recentProjects = [];
  final Completer<void> _readyCompleter = Completer<void>();

  ProjectStore? get store => _store;
  bool get hasProject => _store != null;
  String get scanRoot => _scanRoot;
  List<String> get recentProjects => List.unmodifiable(_recentProjects);

  /// Completes once persisted state (scan root + recent projects) is loaded.
  Future<void> get ready => _readyCompleter.future;

  set scanRoot(String value) {
    _scanRoot = value;
    _persistScanRoot();
    notifyListeners();
  }

  /// Load persisted scan root + recent projects on startup.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _scanRoot = prefs.getString(_keyScanRoot) ?? '';
    _recentProjects = prefs.getStringList(_keyRecent) ?? [];
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    notifyListeners();
  }

  Future<void> _persistScanRoot() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyScanRoot, _scanRoot);
  }

  Future<void> _persistRecent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyRecent, _recentProjects);
  }

  Future<void> openProject(String root) async {
    await _store?.close();
    final store = ProjectStore(root);
    await store.open();
    _store = store;
    _recentProjects.remove(root);
    _recentProjects.insert(0, root);
    if (_recentProjects.length > 10) _recentProjects.removeLast();
    await _persistRecent();
    notifyListeners();
  }

  Future<void> closeProject() async {
    await _store?.close();
    _store = null;
    notifyListeners();
  }

  Future<void> removeRecentProject(String root) async {
    _recentProjects.remove(root);
    await _persistRecent();
    notifyListeners();
  }
}
