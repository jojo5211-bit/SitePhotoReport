import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../state/app_state.dart';

/// Edit project metadata (name, code, client, dates, etc.) — matches desktop ProjectDialog.
/// Includes 5 savable/applicable data templates.
class ProjectInfoScreen extends StatefulWidget {
  const ProjectInfoScreen({super.key});
  @override
  State<ProjectInfoScreen> createState() => _ProjectInfoScreenState();
}

class _ProjectInfoScreenState extends State<ProjectInfoScreen> {
  final _controllers = <String, TextEditingController>{};
  final _settings = SettingsService();
  List<Map<String, String>> _templates = [];
  bool _loading = true;

  static const _fields = [
    ('name', '工程名稱'),
    ('project_code', '工程編號'),
    ('report_title', '報告標題'),
    ('location', '工程地點'),
    ('client_name', '業主'),
    ('contractor_name', '承包商'),
    ('manager_name', '承辦人'),
    ('company_name', '公司名稱'),
    ('start_date', '開工日期'),
    ('end_date', '完工日期'),
    ('description', '工程說明'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final store = context.read<AppState>().store!;
    final project = await store.project();
    final templates = await _settings.loadTemplates();
    for (final f in _fields) {
      _controllers[f.$1] = TextEditingController(
        text: (project[f.$1] ?? '').toString(),
      );
    }
    if (!mounted) return;
    setState(() {
      _templates = templates;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final values = {
      for (final f in _fields) f.$1: _controllers[f.$1]!.text.trim(),
    };
    await store.updateProject(values);
    messenger.showSnackBar(const SnackBar(content: Text('工程資料已儲存')));
    navigator.pop();
  }

  void _applyTemplate(int index) {
    final tpl = _templates[index];
    setState(() {
      for (final f in _fields) {
        final value = tpl[f.$1] ?? '';
        _controllers[f.$1]!.text = value;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已套用「${tpl['name'] ?? '模板 ${index + 1}'}」')),
    );
  }

  Future<void> _saveTemplate(int index) async {
    final values = <String, String>{
      'name': '模板 ${index + 1}',
      for (final f in _fields) f.$1: _controllers[f.$1]!.text.trim(),
    };
    await _settings.saveTemplate(index, values);
    final templates = await _settings.loadTemplates();
    if (!mounted) return;
    setState(() => _templates = templates);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已儲存目前資料到「模板 ${index + 1}」')));
  }

  void _showTemplateSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '工程資料模板',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            ...List.generate(_templates.length, (i) {
              final tpl = _templates[i];
              final label = tpl['name'] ?? '模板 ${i + 1}';
              final hasData =
                  tpl.containsKey('client_name') &&
                  (tpl['client_name'] ?? '').isNotEmpty;
              return ListTile(
                leading: const Icon(Icons.bookmark),
                title: Text(label),
                subtitle: Text(
                  hasData
                      ? '${tpl['client_name'] ?? ''} ${tpl['contractor_name'] ?? ''}'
                            .trim()
                      : '（空）',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _applyTemplate(i);
                      },
                      child: const Text('套用'),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _saveTemplate(i);
                      },
                      child: const Text('存入'),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('工程資料'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark_border),
            tooltip: '資料模板',
            onPressed: _loading ? null : _showTemplateSheet,
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _loading ? null : _save,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: _fields.map((f) {
                final isLong = f.$1 == 'description';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: _controllers[f.$1],
                    decoration: InputDecoration(
                      labelText: f.$2,
                      border: const OutlineInputBorder(),
                    ),
                    maxLines: isLong ? 3 : 1,
                  ),
                );
              }).toList(),
            ),
    );
  }
}
