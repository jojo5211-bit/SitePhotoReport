import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import '../models/project_store.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'project_overview_screen.dart';

class ProjectListScreen extends StatefulWidget {
  const ProjectListScreen({super.key});
  @override
  State<ProjectListScreen> createState() => _ProjectListScreenState();
}

class _ProjectSummary {
  final String path;
  final String name;
  final int total;
  final int unclassified;
  final int sectionCount;
  _ProjectSummary({
    required this.path,
    required this.name,
    required this.total,
    required this.unclassified,
    required this.sectionCount,
  });
}

class _ProjectListScreenState extends State<ProjectListScreen> {
  List<_ProjectSummary> _recent = [];
  List<_ProjectSummary> _scanned = [];
  bool _loading = true;
  String _scanRoot = '';
  bool _manageMode = false;
  final Set<String> _busyProjects = <String>{};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Wait for persisted scan root / recent projects to load (no Timer).
    await context.read<AppState>().ready;
    if (!mounted) return;
    await _scan();
  }

  Future<void> _scan() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final appState = context.read<AppState>();

    // Determine scan root: persisted > default external docs > app docs.
    var root = appState.scanRoot;
    if (root.isEmpty || !await Directory(root).exists()) {
      root = '/storage/emulated/0/Documents';
      if (!await Directory(root).exists()) {
        final dir =
            await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
        root = dir.path;
      }
      appState.scanRoot = root;
    }
    _scanRoot = root;

    // Load recent projects (from persisted paths).
    final recent = <_ProjectSummary>[];
    for (final path in appState.recentProjects) {
      final summary = await _loadSummary(path);
      if (summary != null) recent.add(summary);
    }

    // Scan the folder for all projects (recursive).
    final paths = await ProjectStore.findProjects(root);
    final recentPaths = appState.recentProjects.toSet();
    final scanned = <_ProjectSummary>[];
    for (final path in paths) {
      if (recentPaths.contains(path)) continue; // avoid dup with recent
      final summary = await _loadSummary(path);
      if (summary != null) scanned.add(summary);
    }

    if (!mounted) return;
    setState(() {
      _recent = recent;
      _scanned = scanned;
      _loading = false;
    });
  }

  Future<_ProjectSummary?> _loadSummary(String path) async {
    try {
      final store = ProjectStore(path);
      await store.open();
      final proj = await store.project();
      final total = await store.countPhotos();
      final unclassified = await store.countUnclassified();
      final sections = await store.sections();
      await store.close();
      return _ProjectSummary(
        path: path,
        name: (proj['name'] ?? p.basename(path)).toString(),
        total: total,
        unclassified: unclassified,
        sectionCount: sections.length,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _pickFolder() async {
    final appState = context.read<AppState>();
    final controller = TextEditingController(text: _scanRoot);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('掃描資料夾路徑'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '輸入要掃描的資料夾路徑，\n程式會遞迴尋找其中的 .sprj 工程。',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: '/storage/emulated/0/...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('掃描'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      appState.scanRoot = result;
      _scan();
    }
  }

  Future<void> _open(_ProjectSummary summary) async {
    final messenger = ScaffoldMessenger.of(context);
    final appState = context.read<AppState>();
    try {
      await appState.openProject(summary.path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('開啟失敗：$e')));
      return;
    }
    final store = appState.store;
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ProjectOverviewScreen()),
    ).then((_) => _scan());
    // Maintenance is intentionally deferred until the project screen is
    // visible.  Rebuilding missing previews and repairing EXIF timestamps
    // can otherwise make a large legacy project appear to hang at launch.
    if (store != null) {
      unawaited(_maintainProject(store, messenger));
    }
  }

  Future<void> _maintainProject(
    ProjectStore store,
    ScaffoldMessengerState messenger,
  ) async {
    var rebuilt = 0;
    var backfilled = 0;
    try {
      rebuilt = await store.rebuildThumbnails();
      backfilled = await store.backfillCapturedAt();
    } catch (_) {
      return;
    }
    if (!mounted || (rebuilt == 0 && backfilled == 0)) return;
    final parts = <String>[];
    if (rebuilt > 0) parts.add('重建 $rebuilt 張縮圖');
    if (backfilled > 0) parts.add('補回 $backfilled 張拍攝日期');
    messenger.showSnackBar(SnackBar(content: Text(parts.join('，'))));
  }

  Future<void> _newProject() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final appState = context.read<AppState>();
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增工程'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '工程名稱'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('建立'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    final baseDir =
        await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final safeName = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
    final rootPath = p.join(baseDir.path, '$safeName.sprj');
    if (await Directory(rootPath).exists()) {
      messenger.showSnackBar(SnackBar(content: Text('工程已存在：$rootPath')));
      return;
    }
    try {
      final store = await ProjectStore.createProject(rootPath, name);
      await store.close();
      await appState.openProject(rootPath);
      messenger.showSnackBar(SnackBar(content: Text('已建立工程「$name」')));
      navigator
          .push(
            MaterialPageRoute(builder: (_) => const ProjectOverviewScreen()),
          )
          .then((_) => _scan());
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('建立失敗：$e')));
    }
  }

  Future<void> _projectAction(_ProjectSummary summary, String action) async {
    switch (action) {
      case 'backup':
        await _backupProject(summary);
        break;
      case 'remove_recent':
        final messenger = ScaffoldMessenger.of(context);
        final appState = context.read<AppState>();
        await appState.removeRecentProject(summary.path);
        if (!mounted) return;
        await _scan();
        if (!mounted) return;
        messenger.showSnackBar(
          const SnackBar(content: Text('已從最近開啟清單移除，工程檔案仍保留')),
        );
        break;
      case 'delete':
        await _deleteProject(summary);
        break;
    }
  }

  Future<void> _backupProject(_ProjectSummary summary) async {
    if (_busyProjects.contains(summary.path)) return;
    final messenger = ScaffoldMessenger.of(context);
    final appState = context.read<AppState>();
    setState(() => _busyProjects.add(summary.path));
    ProjectStore? temporary;
    try {
      final store = appState.store?.root == summary.path
          ? appState.store!
          : (temporary = ProjectStore(summary.path));
      if (temporary != null) await temporary.open();
      final backupPath = await store.backupProject();
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('備份完成：${p.basename(backupPath)}')),
        );
      }
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('備份失敗：$e')));
    } finally {
      await temporary?.close();
      if (mounted) setState(() => _busyProjects.remove(summary.path));
    }
  }

  Future<void> _deleteProject(_ProjectSummary summary) async {
    final messenger = ScaffoldMessenger.of(context);
    final appState = context.read<AppState>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('永久刪除工程？'),
        content: Text(
          '將刪除「${summary.name}」的整個工程資料夾及照片。\n\n此動作無法復原，建議先使用「備份工程」。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('永久刪除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      if (appState.store?.root == summary.path) {
        await appState.closeProject();
      }
      await Directory(summary.path).delete(recursive: true);
      await appState.removeRecentProject(summary.path);
      if (mounted) {
        await _scan();
        messenger.showSnackBar(const SnackBar(content: Text('工程已刪除')));
      }
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('刪除失敗：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasAny = _recent.isNotEmpty || _scanned.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('📋 我的工程'),
        actions: [
          IconButton(
            icon: Icon(_manageMode ? Icons.close : Icons.manage_accounts),
            tooltip: _manageMode ? '離開工程管理' : '工程管理',
            onPressed: () => setState(() => _manageMode = !_manageMode),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _scan),
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _pickFolder,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newProject,
        icon: const Icon(Icons.add),
        label: const Text('新增工程'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !hasAny
          ? _emptyState()
          : RefreshIndicator(
              onRefresh: _scan,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                children: [
                  if (_manageMode) _managementBanner(),
                  if (_recent.isNotEmpty) ...[
                    _sectionHeader('最近開啟', Icons.history),
                    ..._recent.map(_projectCard),
                    const SizedBox(height: 8),
                  ],
                  if (_scanned.isNotEmpty) ...[
                    _sectionHeader('掃描到的工程', Icons.folder_shared),
                    ..._scanned.map(_projectCard),
                  ],
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Center(
                      child: Text(
                        '掃描路徑：$_scanRoot',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _managementBanner() {
    return Card(
      color: AppColors.sepPillBg,
      margin: const EdgeInsets.only(bottom: 8),
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: AppColors.primary),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '工程管理模式：點右側 ⋮ 可備份、移除最近清單或永久刪除工程。',
                style: TextStyle(fontSize: 12, color: AppColors.sepPillText),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.photo_library_outlined,
              size: 72,
              color: AppColors.primary,
            ),
            const SizedBox(height: 16),
            const Text(
              '還沒有工程',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '建立一個新工程開始整理照片，\n或開啟既有的 .sprj 工程資料夾。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _newProject,
              icon: const Icon(Icons.add),
              label: const Text('新增工程'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 14,
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('選擇掃描資料夾'),
            ),
            const SizedBox(height: 16),
            Text(
              '掃描路徑：$_scanRoot',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _projectCard(_ProjectSummary s) {
    final classified = s.total - s.unclassified;
    final progress = s.total == 0 ? 0.0 : classified / s.total;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(s),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.engineering,
                    color: AppColors.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      s.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '管理工程',
                    onSelected: (value) => _projectAction(s, value),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'backup', child: Text('📦 備份工程')),
                      PopupMenuItem(
                        value: 'remove_recent',
                        child: Text('🧹 從最近開啟移除'),
                      ),
                      PopupMenuItem(value: 'delete', child: Text('🗑️ 永久刪除工程')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${s.total} 張照片 · ${s.sectionCount} 個項目',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '已分類 $classified 張',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.success,
                    ),
                  ),
                  Text(
                    '未分類 ${s.unclassified} 張',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.warning,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
