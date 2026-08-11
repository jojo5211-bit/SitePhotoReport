import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// A single API profile (OpenAI-compatible endpoint) for AI classification.
class ApiProfile {
  String name;
  String endpoint;
  String apiKey;
  String model;
  String visionModel;

  ApiProfile({
    required this.name,
    required this.endpoint,
    required this.apiKey,
    required this.model,
    required this.visionModel,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'endpoint': endpoint,
    'api_key': apiKey,
    'model': model,
    'vision_model': visionModel,
  };

  factory ApiProfile.fromJson(Map<String, dynamic> j) => ApiProfile(
    name: j['name'] ?? '',
    endpoint: j['endpoint'] ?? '',
    apiKey: j['api_key'] ?? '',
    model: j['model'] ?? '',
    visionModel: j['vision_model'] ?? '',
  );
}

/// Persists API profiles + active selection, mirroring the desktop settings.json.
class SettingsService {
  static const _keyProfiles = 'api_profiles';
  static const _keyActive = 'active_api_profile';

  Future<List<ApiProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyProfiles);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => ApiProfile.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveProfiles(List<ApiProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyProfiles,
      jsonEncode(profiles.map((p) => p.toJson()).toList()),
    );
  }

  Future<String?> activeProfileName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyActive);
  }

  Future<void> setActiveProfile(String? name) async {
    final prefs = await SharedPreferences.getInstance();
    if (name == null) {
      await prefs.remove(_keyActive);
    } else {
      await prefs.setString(_keyActive, name);
    }
  }

  Future<ApiProfile?> activeProfile() async {
    final name = await activeProfileName();
    if (name == null) return null;
    final profiles = await loadProfiles();
    try {
      return profiles.firstWhere((p) => p.name == name);
    } catch (_) {
      return null;
    }
  }

  // ── General preferences (mirror desktop settings.json) ────────────
  static const _keyShowTimestamp = 'show_timestamp';
  static const _keyShowFilename = 'show_filename';

  Future<bool> showTimestamp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyShowTimestamp) ?? true;
  }

  Future<void> setShowTimestamp(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowTimestamp, v);
  }

  Future<bool> showFilename() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyShowFilename) ?? true;
  }

  Future<void> setShowFilename(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowFilename, v);
  }

  // ── Project data templates (5 slots, mirror desktop) ──────────────
  static const _keyTemplates = 'project_templates';

  Future<List<Map<String, String>>> loadTemplates() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyTemplates);
    // Default: 5 empty templates.
    final defaults = List.generate(
      5,
      (i) => <String, String>{'name': '模板 ${i + 1}'},
    );
    if (raw == null || raw.isEmpty) return defaults;
    try {
      final list = jsonDecode(raw) as List;
      final result = list
          .map(
            (e) =>
                (e as Map).map((k, v) => MapEntry(k.toString(), v.toString())),
          )
          .toList();
      while (result.length < 5) {
        result.add({'name': '模板 ${result.length + 1}'});
      }
      return result;
    } catch (_) {
      return defaults;
    }
  }

  Future<void> saveTemplate(int index, Map<String, String> values) async {
    final templates = await loadTemplates();
    if (index < 0 || index >= templates.length) return;
    templates[index] = values;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyTemplates, jsonEncode(templates));
  }
}
