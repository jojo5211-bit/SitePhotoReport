import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Quick classification with two modes:
/// 1. Single mode (default): one photo at a time, tap slot to file.
/// 2. Batch mode: grid of all unclassified photos, multi-select, then file into a slot.
class QuickClassifyScreen extends StatefulWidget {
  const QuickClassifyScreen({super.key});
  @override
  State<QuickClassifyScreen> createState() => _QuickClassifyScreenState();
}

class _QuickClassifyScreenState extends State<QuickClassifyScreen> {
  List<Map<String, dynamic>> _queue = [];
  List<_SlotTarget> _targets = [];
  int _done = 0;
  int _total = 0;
  bool _loading = true;
  bool _batchMode = false;
  bool _actionBusy = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = context.read<AppState>().store!;
    // sqflite may return an unmodifiable list on Android.  The screen removes
    // classified items from this queue, so always keep a mutable copy.
    final queue = List<Map<String, dynamic>>.from(
      await store.unclassifiedPhotos(),
    );
    final targets = <_SlotTarget>[];
    for (final sec in await store.sections()) {
      for (final slot in await store.slots(sec['id'])) {
        targets.add(
          _SlotTarget(
            sec['name'].toString(),
            slot['id'].toString(),
            slot['name'].toString(),
          ),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _queue = queue;
      _targets = targets;
      _total = queue.length;
      _done = 0;
      _loading = false;
      _selected.clear();
    });
  }

  Map<String, dynamic>? get _current => _queue.isEmpty ? null : _queue.first;

  // ── Single mode ───────────────────────────────────────────────────
  Future<void> _classifyTo(String? targetSlotId) async {
    if (_actionBusy) return;
    final current = _current;
    if (current == null) return;
    final photoId = current['id'].toString();
    final store = context.read<AppState>().store!;
    setState(() => _actionBusy = true);
    try {
      // “留未分類”只是略過本次整理，不需要把照片從未分類位置
      // 搬到同一個位置，避免資料庫操作後畫面沒有更新。
      if (targetSlotId != null) {
        await store.relocatePhotos([photoId], null, targetSlotId);
      }
      if (!mounted) return;
      setState(() {
        _queue.removeWhere((p) => p['id'].toString() == photoId);
        _done++;
        _actionBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _actionBusy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('分類失敗，照片仍保留在目前畫面：$e')));
    }
  }

  void _skip() {
    if (_queue.isEmpty || _actionBusy) return;
    setState(() {
      final item = _queue.removeAt(0);
      _queue.add(item);
    });
  }

  // ── Batch mode ────────────────────────────────────────────────────
  void _toggleSelect(String photoId) {
    setState(() {
      if (_selected.contains(photoId)) {
        _selected.remove(photoId);
      } else {
        _selected.add(photoId);
      }
    });
  }

  void _selectAll() {
    setState(() {
      if (_selected.length == _queue.length) {
        _selected.clear();
      } else {
        _selected.addAll(_queue.map((p) => p['id'].toString()));
      }
    });
  }

  Future<void> _batchClassifyTo(String? targetSlotId) async {
    if (_selected.isEmpty || _actionBusy) return;
    final ids = _selected.toList();
    final store = context.read<AppState>().store!;
    setState(() => _actionBusy = true);
    try {
      if (targetSlotId != null) {
        await store.relocatePhotos(ids, null, targetSlotId);
      }
      if (!mounted) return;
      setState(() {
        _queue.removeWhere((p) => _selected.contains(p['id'].toString()));
        _done += ids.length;
        _selected.clear();
        _actionBusy = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已將 ${ids.length} 張照片分類')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _actionBusy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('分類失敗，照片仍保留在目前畫面：$e')));
    }
  }

  void _showBatchSlotPicker() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '將 ${_selected.length} 張照片分類到…',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ..._targets.map(
              (t) => ListTile(
                leading: const Icon(Icons.folder),
                title: Text('${t.section} / ${t.slot}'),
                onTap: () {
                  Navigator.pop(ctx);
                  _batchClassifyTo(t.slotId);
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.inbox),
              title: const Text('留未分類'),
              onTap: () {
                Navigator.pop(ctx);
                _batchClassifyTo(null);
              },
            ),
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
        title: const Text('快速分類'),
        actions: [
          IconButton(
            icon: Icon(_batchMode ? Icons.looks_one : Icons.grid_view),
            tooltip: _batchMode ? '切換單張模式' : '切換批次多選',
            onPressed: () => setState(() {
              _batchMode = !_batchMode;
              _selected.clear();
            }),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                '${_done + (_queue.isEmpty ? 0 : (_batchMode ? 0 : 1))}/$_total',
                style: const TextStyle(fontSize: 15),
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _queue.isEmpty
          ? _doneView()
          : _batchMode
          ? _batchView()
          : _classifyView(),
    );
  }

  Widget _doneView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, size: 80, color: AppColors.success),
          const SizedBox(height: 16),
          Text(
            '分類完成！共處理 $_done 張',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }

  // ── Single mode view ──────────────────────────────────────────────
  Widget _classifyView() {
    final store = context.read<AppState>().store!;
    final current = _current!;
    final previewPath = store
        .previewFile((current['preview_rel_path'] ?? '').toString())
        .path;
    final captured = (current['captured_at'] ?? '').toString();
    final filename = (current['original_filename'] ?? '').toString();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: _total == 0 ? 0 : _done / _total,
              minHeight: 6,
              backgroundColor: Colors.grey.shade200,
              valueColor: const AlwaysStoppedAnimation(AppColors.primary),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: const Color(0xFFC8D8E0)),
                  if (File(previewPath).existsSync())
                    Image.file(File(previewPath), fit: BoxFit.contain),
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            filename,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                          if (captured.isNotEmpty)
                            Text(
                              captured,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: _targets.map((t) {
              return ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
                onPressed: _actionBusy ? null : () => _classifyTo(t.slotId),
                child: Text('${t.section} / ${t.slot}'),
              );
            }).toList(),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _actionBusy ? null : _skip,
                    icon: const Icon(Icons.skip_next),
                    label: const Text('跳過'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _actionBusy ? null : () => _classifyTo(null),
                    icon: const Icon(Icons.inbox),
                    label: const Text('留未分類'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Batch mode view ───────────────────────────────────────────────
  Widget _batchView() {
    final store = context.read<AppState>().store!;
    return Column(
      children: [
        // Toolbar: select all + count
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: _selectAll,
                icon: Icon(
                  _selected.length == _queue.length
                      ? Icons.deselect
                      : Icons.select_all,
                  size: 18,
                ),
                label: Text(_selected.length == _queue.length ? '取消全選' : '全選'),
              ),
              const Spacer(),
              Text(
                '已選 ${_selected.length} 張',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        // Photo grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: 0.85,
            ),
            itemCount: _queue.length,
            itemBuilder: (ctx, i) {
              final photo = _queue[i];
              final photoId = photo['id'].toString();
              final selected = _selected.contains(photoId);
              final thumbPath = store
                  .thumbnailFile((photo['thumbnail_rel_path'] ?? '').toString())
                  .path;
              return GestureDetector(
                onTap: () => _toggleSelect(photoId),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: File(thumbPath).existsSync()
                          ? Image.file(File(thumbPath), fit: BoxFit.cover)
                          : Container(
                              color: const Color(0xFFC8D8E0),
                              child: const Icon(
                                Icons.image,
                                color: Colors.white54,
                              ),
                            ),
                    ),
                    // Selection overlay
                    if (selected)
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: AppColors.primary,
                            width: 3,
                          ),
                          color: AppColors.primary.withValues(alpha: 0.2),
                        ),
                      ),
                    Positioned(
                      top: 4,
                      left: 4,
                      child: Icon(
                        selected ? Icons.check_circle : Icons.circle_outlined,
                        color: selected ? AppColors.primary : Colors.white70,
                        size: 24,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        // Bottom action bar
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: _selected.isEmpty
                ? const Text(
                    '點選照片以選取，再分類到欄位',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _actionBusy ? null : _showBatchSlotPicker,
                          icon: const Icon(Icons.drive_file_move),
                          label: Text('分類 ${_selected.length} 張'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () => setState(() => _selected.clear()),
                        child: const Text('清除'),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _SlotTarget {
  final String section;
  final String slotId;
  final String slot;
  _SlotTarget(this.section, this.slotId, this.slot);
}
