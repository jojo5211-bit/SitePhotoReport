import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';

/// Project structure management: add/rename/delete/reorder sections and slots.
class ProjectManageScreen extends StatefulWidget {
  const ProjectManageScreen({super.key});
  @override
  State<ProjectManageScreen> createState() => _ProjectManageScreenState();
}

class _ProjectManageScreenState extends State<ProjectManageScreen> {
  List<Map<String, dynamic>> _sections = [];
  final Map<String, List<Map<String, dynamic>>> _slots = {};
  bool _loading = true;
  bool _reordering = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = context.read<AppState>().store!;
    final sections = await store.sections();
    final slots = <String, List<Map<String, dynamic>>>{};
    for (final sec in sections) {
      slots[sec['id'].toString()] = await store.slots(sec['id'].toString());
    }
    if (!mounted) return;
    setState(() {
      _sections = sections;
      _slots
        ..clear()
        ..addAll(slots);
      _loading = false;
    });
  }

  Future<void> _addSection() async {
    final store = context.read<AppState>().store!;
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增項目'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: '項目名稱'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('新增'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await store.addSection(name);
    _load();
  }

  Future<void> _renameSection(Map<String, dynamic> section) async {
    final store = context.read<AppState>().store!;
    final ctrl = TextEditingController(text: section['name'].toString());
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新命名項目'),
        content: TextField(controller: ctrl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('儲存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await store.renameSection(section['id'].toString(), name);
    _load();
  }

  Future<void> _deleteSection(Map<String, dynamic> section) async {
    final store = context.read<AppState>().store!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除項目'),
        content: Text('確定刪除「${section['name']}」？\n其中的照片會移回未分類。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await store.deleteSection(section['id'].toString());
    _load();
  }

  Future<void> _addSlot(String sectionId) async {
    final store = context.read<AppState>().store!;
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增欄位'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: '欄位名稱'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('新增'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await store.addSlot(sectionId, name);
    _load();
  }

  Future<void> _renameSlot(Map<String, dynamic> slot) async {
    final store = context.read<AppState>().store!;
    final ctrl = TextEditingController(text: slot['name'].toString());
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新命名欄位'),
        content: TextField(controller: ctrl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('儲存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await store.renameSlot(slot['id'].toString(), name);
    _load();
  }

  Future<void> _deleteSlot(Map<String, dynamic> slot) async {
    final store = context.read<AppState>().store!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除欄位'),
        content: Text('確定刪除「${slot['name']}」？\n其中的照片會移回未分類。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await store.deleteSlot(slot['id'].toString());
    _load();
  }

  Future<void> _moveSection(String sectionId, int direction) async {
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    if (_reordering) return;
    final index = _sections.indexWhere(
      (section) => section['id'].toString() == sectionId,
    );
    final other = index + direction;
    if (index < 0 || other < 0 || other >= _sections.length) return;

    // Update the visible list immediately, then persist and reload from SQLite.
    // This prevents a successful tap from appearing to do nothing while the
    // asynchronous database write and refresh are in flight.
    final reordered = List<Map<String, dynamic>>.from(_sections);
    final moved = reordered.removeAt(index);
    reordered.insert(other, moved);
    setState(() {
      _reordering = true;
      _sections = reordered;
    });
    try {
      await store.moveSection(sectionId, direction);
      await _load();
    } catch (error) {
      if (mounted) {
        await _load();
        messenger.showSnackBar(SnackBar(content: Text('項目排序失敗：$error')));
      }
    } finally {
      if (mounted) setState(() => _reordering = false);
    }
  }

  Future<void> _moveSlot(String slotId, int direction) async {
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    if (_reordering) return;
    final owner = _slots.entries.firstWhere(
      (entry) => entry.value.any((slot) => slot['id'].toString() == slotId),
      orElse: () => const MapEntry('', <Map<String, dynamic>>[]),
    );
    final currentSlots = List<Map<String, dynamic>>.from(owner.value);
    final index = currentSlots.indexWhere(
      (slot) => slot['id'].toString() == slotId,
    );
    final other = index + direction;
    if (index < 0 || other < 0 || other >= currentSlots.length) return;
    final reordered = List<Map<String, dynamic>>.from(currentSlots);
    final moved = reordered.removeAt(index);
    reordered.insert(other, moved);
    setState(() {
      _reordering = true;
      _slots[owner.key] = reordered;
    });
    try {
      await store.moveSlot(slotId, direction);
      await _load();
    } catch (error) {
      if (mounted) {
        await _load();
        messenger.showSnackBar(SnackBar(content: Text('欄位排序失敗：$error')));
      }
    } finally {
      if (mounted) setState(() => _reordering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('管理項目與欄位'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _addSection),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _sections.length,
              itemBuilder: (ctx, i) {
                final section = _sections[i];
                final sectionId = section['id'].toString();
                final slots = _slots[sectionId] ?? [];
                return Card(
                  key: ValueKey(sectionId),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            // Section reorder buttons
                            Column(
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.arrow_upward,
                                    size: 18,
                                  ),
                                  onPressed: _reordering || i <= 0
                                      ? null
                                      : () => _moveSection(sectionId, -1),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.arrow_downward,
                                    size: 18,
                                  ),
                                  onPressed:
                                      _reordering || i >= _sections.length - 1
                                      ? null
                                      : () => _moveSection(sectionId, 1),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                section['name'].toString(),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              onPressed: () => _renameSection(section),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete,
                                size: 20,
                                color: Colors.red,
                              ),
                              onPressed: () => _deleteSection(section),
                            ),
                          ],
                        ),
                        const Divider(height: 12),
                        ...List.generate(slots.length, (si) {
                          final slot = slots[si];
                          return Padding(
                            padding: const EdgeInsets.only(left: 16, bottom: 4),
                            child: Row(
                              children: [
                                // Slot reorder buttons
                                Column(
                                  children: [
                                    IconButton(
                                      icon: const Icon(
                                        Icons.arrow_upward,
                                        size: 14,
                                      ),
                                      onPressed: _reordering || si <= 0
                                          ? null
                                          : () => _moveSlot(
                                              slot['id'].toString(),
                                              -1,
                                            ),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 24,
                                        minHeight: 24,
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.arrow_downward,
                                        size: 14,
                                      ),
                                      onPressed:
                                          _reordering || si >= slots.length - 1
                                          ? null
                                          : () => _moveSlot(
                                              slot['id'].toString(),
                                              1,
                                            ),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 24,
                                        minHeight: 24,
                                      ),
                                    ),
                                  ],
                                ),
                                const Icon(
                                  Icons.subdirectory_arrow_right,
                                  size: 16,
                                  color: Colors.grey,
                                ),
                                const SizedBox(width: 8),
                                Expanded(child: Text(slot['name'].toString())),
                                IconButton(
                                  icon: const Icon(Icons.edit, size: 16),
                                  onPressed: () => _renameSlot(slot),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete,
                                    size: 16,
                                    color: Colors.red,
                                  ),
                                  onPressed: () => _deleteSlot(slot),
                                ),
                              ],
                            ),
                          );
                        }),
                        TextButton.icon(
                          onPressed: () => _addSlot(sectionId),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('新增欄位'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
