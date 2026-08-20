import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';

/// Settings screen: manage API profiles for AI classification.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsService();
  List<ApiProfile> _profiles = [];
  String? _activeName;
  bool _loading = true;

  bool _showTimestamp = true;
  bool _showFilename = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profiles = await _settings.loadProfiles();
    final active = await _settings.activeProfileName();
    final showTs = await _settings.showTimestamp();
    final showFn = await _settings.showFilename();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeName = active;
      _showTimestamp = showTs;
      _showFilename = showFn;
      _loading = false;
    });
  }

  Future<void> _editProfile(ApiProfile? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final endpointCtrl = TextEditingController(text: existing?.endpoint ?? '');
    final keyCtrl = TextEditingController(text: existing?.apiKey ?? '');
    final modelCtrl = TextEditingController(text: existing?.model ?? '');
    final visionCtrl = TextEditingController(text: existing?.visionModel ?? '');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '新增 API 設定' : '編輯 API 設定'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '名稱'),
              ),
              TextField(
                controller: endpointCtrl,
                decoration: const InputDecoration(
                  labelText: 'Endpoint (Base URL)',
                ),
              ),
              TextField(
                controller: keyCtrl,
                decoration: const InputDecoration(labelText: 'API Key'),
                obscureText: true,
              ),
              TextField(
                controller: modelCtrl,
                decoration: const InputDecoration(labelText: '模型'),
              ),
              TextField(
                controller: visionCtrl,
                decoration: const InputDecoration(labelText: '視覺模型'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('儲存'),
          ),
        ],
      ),
    );
    if (result != true) return;

    final profile = ApiProfile(
      name: nameCtrl.text.trim(),
      endpoint: endpointCtrl.text.trim(),
      apiKey: keyCtrl.text.trim(),
      model: modelCtrl.text.trim(),
      visionModel: visionCtrl.text.trim(),
    );
    if (profile.name.isEmpty) return;

    final idx = _profiles.indexWhere((p) => p.name == profile.name);
    if (idx >= 0) {
      _profiles[idx] = profile;
    } else {
      _profiles.add(profile);
    }
    await _settings.saveProfiles(_profiles);
    _load();
  }

  Future<void> _deleteProfile(ApiProfile profile) async {
    _profiles.removeWhere((p) => p.name == profile.name);
    await _settings.saveProfiles(_profiles);
    if (_activeName == profile.name) {
      await _settings.setActiveProfile(null);
      _activeName = null;
    }
    _load();
  }

  Future<void> _setActive(ApiProfile profile) async {
    await _settings.setActiveProfile(profile.name);
    setState(() => _activeName = profile.name);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('設定'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '一般'),
              Tab(text: 'AI 分類 API'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(children: [_generalTab(), _apiTab()]),
      ),
    );
  }

  Widget _generalTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '匯出報告內容',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          '這些開關會影響 PDF／Excel 報告中每張照片顯示的資訊。',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('輸出照片拍攝時間戳／日期'),
          value: _showTimestamp,
          onChanged: (v) async {
            await _settings.setShowTimestamp(v);
            setState(() => _showTimestamp = v);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('輸出原始檔名'),
          value: _showFilename,
          onChanged: (v) async {
            await _settings.setShowFilename(v);
            setState(() => _showFilename = v);
          },
        ),
      ],
    );
  }

  Widget _apiTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'AI 分類 API',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          '設定 OpenAI 相容的視覺 API（如 Gemini、OpenRouter）',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 12),
        RadioGroup<String>(
          groupValue: _activeName,
          onChanged: (value) {
            final profile = _profiles.where((item) => item.name == value).firstOrNull;
            if (profile != null) _setActive(profile);
          },
          child: Column(
            children: [
              if (_profiles.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('尚未設定 API', style: TextStyle(color: Colors.grey)),
                ),
              ..._profiles.map(
                (p) => Card(
                  child: ListTile(
                    leading: Radio<String>(value: p.name),
                    title: Text(p.name),
                    subtitle: Text(
                      p.endpoint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, size: 20),
                          onPressed: () => _editProfile(p),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, size: 20, color: Colors.red),
                          onPressed: () => _deleteProfile(p),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => _editProfile(null),
          icon: const Icon(Icons.add),
          label: const Text('新增 API 設定'),
        ),
      ],
    );
  }
}
