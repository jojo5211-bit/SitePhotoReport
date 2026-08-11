import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/numbering_dialog.dart';
import 'ai_classify_screen.dart';
import 'export_screen.dart';
import 'help_screen.dart';
import 'photo_grid_screen.dart';
import 'project_info_screen.dart';
import 'project_manage_screen.dart';
import 'quick_classify_screen.dart';
import 'restore_deleted_screen.dart';
import 'settings_screen.dart';

class ProjectOverviewScreen extends StatefulWidget {
  const ProjectOverviewScreen({super.key});
  @override
  State<ProjectOverviewScreen> createState() => _ProjectOverviewScreenState();
}

class _ProjectOverviewScreenState extends State<ProjectOverviewScreen> {
  Map<String, dynamic> _project = {};
  List<Map<String, dynamic>> _sections = [];
  final Map<String, List<Map<String, dynamic>>> _slotsBySection = {};
  final Map<String, int> _counts = {};
  int _unclassified = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = context.read<AppState>().store!;
    final project = await store.project();
    final sections = await store.sections();
    final slotsBySection = <String, List<Map<String, dynamic>>>{};
    final counts = <String, int>{};
    for (final sec in sections) {
      final slots = await store.slots(sec['id']);
      slotsBySection[sec['id']] = slots;
      for (final slot in slots) {
        counts[slot['id']] = await store.countForSlot(slot['id']);
      }
    }
    final unclassified = await store.countUnclassified();
    if (!mounted) return;
    setState(() {
      _project = project;
      _sections = sections;
      _slotsBySection
        ..clear()
        ..addAll(slotsBySection);
      _counts
        ..clear()
        ..addAll(counts);
      _unclassified = unclassified;
      _loading = false;
    });
  }

  void _openSlot(String? slotId, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoGridScreen(slotId: slotId, title: title),
      ),
    ).then((_) => _load());
  }

  void _openClassify() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const QuickClassifyScreen()),
    ).then((_) => _load());
  }

  Future<void> _onMenu(String value) async {
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    switch (value) {
      case 'info':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ProjectInfoScreen()),
        ).then((_) => _load());
        break;
      case 'manage':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ProjectManageScreen()),
        ).then((_) => _load());
        break;
      case 'ai':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AiClassifyScreen()),
        ).then((_) => _load());
        break;
      case 'number_all':
        final opts = await NumberingDialog.show(context);
        if (opts == null) return;
        var count = 0;
        for (final sec in await store.sections()) {
          for (final slot in await store.slots(sec['id'].toString())) {
            final photos = await store.placementsForSlot(slot['id'].toString());
            if (photos.isNotEmpty) {
              await store.numberSlot(
                slot['id'].toString(),
                position: opts.position,
                color: opts.color,
                size: '${opts.size}',
                transparent: opts.transparent,
              );
              count++;
            }
          }
        }
        messenger.showSnackBar(
          SnackBar(content: Text('已為 $count 個欄位生成編號（各自從 1 開始）')),
        );
        _load();
        break;
      case 'clear_all':
        var count = 0;
        for (final sec in await store.sections()) {
          for (final slot in await store.slots(sec['id'].toString())) {
            await store.clearSlotNumbers(slot['id'].toString());
            count++;
          }
        }
        messenger.showSnackBar(
          SnackBar(content: Text('已取消所有欄位編號（$count 個欄位）')),
        );
        _load();
        break;
      case 'restore':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const RestoreDeletedScreen()),
        ).then((_) => _load());
        break;
      case 'export':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ExportScreen()),
        );
        break;
      case 'settings':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        );
        break;
      case 'save':
        await store.saveManifest();
        messenger.showSnackBar(
          const SnackBar(content: Text('專案已儲存（project.json）')),
        );
        break;
      case 'help':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const HelpScreen()),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = (_project['name'] ?? '工程').toString();
    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          PopupMenuButton<String>(
            onSelected: _onMenu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'info', child: Text('📝 工程資料')),
              PopupMenuItem(value: 'manage', child: Text('🗂️ 管理項目／欄位')),
              PopupMenuItem(value: 'ai', child: Text('✨ AI 自動分類')),
              PopupMenuItem(value: 'number_all', child: Text('🔢 一鍵全部編號')),
              PopupMenuItem(value: 'clear_all', child: Text('🧹 一鍵取消編號')),
              PopupMenuItem(value: 'restore', child: Text('♻️ 復原已刪除')),
              PopupMenuItem(value: 'export', child: Text('📤 匯出報告')),
              PopupMenuItem(value: 'save', child: Text('💾 儲存專案')),
              PopupMenuItem(value: 'settings', child: Text('⚙️ 設定')),
              PopupMenuItem(value: 'help', child: Text('❓ 使用說明')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _importBanner(),
                  const SizedBox(height: 12),
                  ..._sections.map(_sectionCard),
                  _unclassifiedCard(),
                ],
              ),
            ),
    );
  }

  Widget _importBanner() {
    return InkWell(
      onTap: _openClassify,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.sepPillBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.camera_alt, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '拍照或快速分類',
                    style: TextStyle(
                      color: AppColors.sepPillText,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_unclassified > 0)
                    Text(
                      '$_unclassified 張待整理',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.warning,
                      ),
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.primary),
          ],
        ),
      ),
    );
  }

  Widget _sectionCard(Map<String, dynamic> section) {
    final slots = _slotsBySection[section['id']] ?? [];
    final sectionTotal = slots.fold<int>(
      0,
      (sum, s) => sum + (_counts[s['id']] ?? 0),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  section['name'].toString(),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.sepPillBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$sectionTotal 張',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.sepPillText,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: slots.map((slot) {
                final count = _counts[slot['id']] ?? 0;
                return ActionChip(
                  label: Text('${slot['name']} ($count)'),
                  onPressed: () =>
                      _openSlot(slot['id'], slot['name'].toString()),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _unclassifiedCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.grey.shade300, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openSlot(null, '未分類'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '📥 未分類',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$_unclassified 張待整理',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.warning,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
