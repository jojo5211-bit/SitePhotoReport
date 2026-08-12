import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/mosaic_renderer.dart';
import '../services/photo_capture_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/date_separator.dart';
import '../widgets/number_badge.dart';
import '../widgets/numbering_dialog.dart';
import 'mosaic_editor_screen.dart';
import 'photo_detail_screen.dart';

/// A grid of photos for one slot (or unclassified), grouped by capture date.
/// Built as a ListView of rows so date separators can span the full width
/// (a GridView item cannot span columns — that was the desktop bug).
class PhotoGridScreen extends StatefulWidget {
  final String? slotId;
  final String title;
  const PhotoGridScreen({super.key, required this.slotId, required this.title});

  @override
  State<PhotoGridScreen> createState() => _PhotoGridScreenState();
}

class _PhotoGridScreenState extends State<PhotoGridScreen> {
  static const int columns = 3;
  final _capture = PhotoCaptureService();
  List<_Row> _rows = [];
  List<Map<String, dynamic>> _flatPhotos = [];
  bool _loading = true;
  bool _importing = false;
  bool _reorderMode = false;
  String _sortMode = 'manual';
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    _sortMode = widget.slotId == null ? 'time_asc' : 'manual';
    _load();
  }

  Future<void> _capturePhoto() async {
    final path = await _capture.takePhoto();
    if (path == null || !mounted) return;
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    final title = widget.title;
    setState(() => _importing = true);
    String? id;
    Object? error;
    try {
      id = await store.importFile(path, targetSlotId: widget.slotId);
      // Await the refresh so the newly captured photo is visible before the
      // completion message is shown.  The load request token prevents an
      // older, slower refresh from overwriting this result.
      if (id != null) await _load();
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _importing = false);
    }
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error != null
              ? '照片保存失敗：$error'
              : id == null
              ? '照片重複或無效'
              : '已拍入「$title」',
        ),
      ),
    );
  }

  Future<void> _pickGallery() async {
    final paths = await _capture.pickFromGallery();
    if (paths.isEmpty || !mounted) return;
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    final title = widget.title;
    var imported = 0;
    Object? error;
    setState(() => _importing = true);
    try {
      for (final path in paths) {
        final id = await store.importFile(path, targetSlotId: widget.slotId);
        if (id != null) {
          imported++;
          // Refresh after every file so a large gallery import is observable
          // immediately instead of appearing only after leaving the page.
          await _load();
        }
      }
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _importing = false);
    }
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error != null ? '匯入失敗：$error' : '已匯入 $imported 張到「$title」',
        ),
      ),
    );
  }

  void _showAddSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: Text('拍照直接放入「${widget.title}」'),
              onTap: () {
                Navigator.pop(ctx);
                _capturePhoto();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('從相簿選取'),
              onTap: () {
                Navigator.pop(ctx);
                _pickGallery();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _load() async {
    final request = ++_loadRequest;
    final store = context.read<AppState>().store!;
    final photos = await store.placementsForSlot(
      widget.slotId,
      sortMode: _sortMode,
    );

    final rows = <_Row>[];
    var buffer = <Map<String, dynamic>>[];
    String? lastDay;

    void flush() {
      if (buffer.isNotEmpty) {
        rows.add(_Row.photos(List.of(buffer)));
        buffer = [];
      }
    }

    for (final row in photos) {
      final raw = (row['captured_at'] ?? '').toString().trim();
      final day = raw.length >= 10
          ? raw.substring(0, 10).replaceAll(':', '-')
          : '';
      if (widget.slotId == null && day.isNotEmpty && day != lastDay) {
        flush();
        rows.add(_Row.separator(day));
        lastDay = day;
      }
      buffer.add(row);
      if (buffer.length == columns) flush();
    }
    flush();

    if (!mounted || request != _loadRequest) return;
    setState(() {
      _rows = rows;
      _flatPhotos = List.of(photos);
      _loading = false;
    });
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    setState(() {
      final item = _flatPhotos.removeAt(oldIndex);
      _flatPhotos.insert(newIndex, item);
    });
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    final ids = _flatPhotos.map((p) => p['photo_id'].toString()).toList();
    await store.setOrder(widget.slotId, ids);
    messenger.showSnackBar(const SnackBar(content: Text('順序已儲存')));
  }

  Future<void> _toggleReorderMode() async {
    // Dragging always edits the stored manual order.  Switch from a temporary
    // time/filename view first so the user does not drag one order and then
    // immediately see a different order after saving.
    if (!_reorderMode && _sortMode != 'manual') {
      setState(() => _sortMode = 'manual');
      await _load();
      if (!mounted) return;
    }
    setState(() => _reorderMode = !_reorderMode);
  }

  Future<void> _showSortMenu() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(leading: Icon(Icons.sort), title: Text('目前欄位排列方式')),
            for (final option in _sortOptions)
              RadioListTile<String>(
                value: option.$1,
                groupValue: _sortMode,
                title: Text(option.$2),
                onChanged: (value) => Navigator.pop(ctx, value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || selected == _sortMode || !mounted) return;
    setState(() {
      _sortMode = selected;
      _reorderMode = false;
      _loading = true;
    });
    await _load();
  }

  Future<void> _numberThisSlot() async {
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    final opts = await NumberingDialog.show(context);
    if (opts == null) return;
    await store.numberSlot(
      widget.slotId,
      position: opts.position,
      color: opts.color,
      size: '${opts.size}',
      transparent: opts.transparent,
    );
    messenger.showSnackBar(const SnackBar(content: Text('已為此欄位生成編號（從 1 開始）')));
    await _load();
  }

  Future<void> _clearThisSlotNumbers() async {
    final store = context.read<AppState>().store!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消此欄位編號'),
        content: Text('確定取消「${widget.title}」所有照片的編號嗎？\n照片與排序不會受到影響。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('取消編號'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await store.clearSlotNumbers(widget.slotId);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('目前欄位編號已取消')));
    await _load();
  }

  void _openPhoto(Map<String, dynamic> row) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoDetailScreen(
          photoId: row['photo_id'].toString(),
          slotId: widget.slotId,
        ),
      ),
    ).then((_) => _load());
  }

  void _showPhotoMenu(Map<String, dynamic> row) {
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    final photoId = row['photo_id'].toString();
    final inSlot = widget.slotId != null;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (inSlot)
              ListTile(
                leading: const Icon(Icons.inbox),
                title: const Text('移回未分類'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await store.removePlacements([photoId], widget.slotId);
                  messenger.showSnackBar(
                    const SnackBar(content: Text('已移回未分類')),
                  );
                  _load();
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('建立馬賽克副本（保留原圖）'),
              onTap: () async {
                Navigator.pop(ctx);
                await _makeMosaicCopy(row);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text(
                '刪除照片（保留原始檔）',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                await store.deletePhotos([photoId]);
                messenger.showSnackBar(
                  const SnackBar(content: Text('已刪除（原始檔保留）')),
                );
                _load();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _makeMosaicCopy(Map<String, dynamic> row) async {
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    final photoId = row['photo_id'].toString();
    final originalRel = (row['original_rel_path'] ?? '').toString();
    final source = store.originalFile(originalRel);
    if (!await source.exists()) {
      messenger.showSnackBar(const SnackBar(content: Text('找不到原始照片檔')));
      return;
    }
    // Parse existing mosaic (if any) as the starting point.
    var existing = <MosaicRegion>[];
    try {
      final raw = (row['mosaic_json'] ?? '').toString();
      if (raw.isNotEmpty) {
        existing = (jsonDecode(raw) as List)
            .map((e) => MosaicRegion.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}
    if (!mounted) return;
    final result = await Navigator.push<List<MosaicRegion>>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            MosaicEditorScreen(sourceFile: source, initialRegions: existing),
      ),
    );
    if (result == null || !mounted) return;
    try {
      final newId = await store.duplicatePhotoWithMosaic(
        photoId,
        jsonEncode(result.map((r) => r.toJson()).toList()),
        widget.slotId,
      );
      // Render the mosaic copy's thumbnail/preview.
      final newPhoto = await store.photo(newId);
      if (newPhoto != null) {
        final previewRel = (newPhoto['preview_rel_path'] ?? '').toString();
        final thumbRel = (newPhoto['thumbnail_rel_path'] ?? '').toString();
        if (previewRel.isNotEmpty) {
          await MosaicRenderer.renderToFile(
            source,
            store.previewFile(previewRel),
            result,
            maxSide: 1600,
          );
        }
        if (thumbRel.isNotEmpty) {
          await MosaicRenderer.renderToFile(
            source,
            store.thumbnailFile(thumbRel),
            result,
            maxSide: 320,
          );
        }
      }
      messenger.showSnackBar(const SnackBar(content: Text('已建立馬賽克副本（原圖保留）')));
      _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('建立副本失敗：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (widget.slotId != null)
            IconButton(
              icon: const Icon(Icons.format_list_numbered),
              tooltip: '此欄位編號',
              onPressed: _numberThisSlot,
            ),
          if (widget.slotId != null)
            IconButton(
              icon: const Icon(Icons.playlist_remove),
              tooltip: '取消此欄位編號',
              onPressed: _clearThisSlotNumbers,
            ),
          IconButton(
            icon: const Icon(Icons.sort),
            tooltip: '排列方式',
            onPressed: _showSortMenu,
          ),
          IconButton(
            icon: Icon(_reorderMode ? Icons.check : Icons.swap_vert),
            tooltip: _reorderMode ? '完成排序' : '調整順序',
            onPressed: _toggleReorderMode,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_importing) ...[
            const LinearProgressIndicator(minHeight: 3),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '照片載入中，已加入的照片會即時顯示',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ),
          ],
          Expanded(child: _buildContent()),
        ],
      ),
      floatingActionButton: _reorderMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _importing ? null : _showAddSheet,
              icon: const Icon(Icons.camera_alt),
              label: const Text('拍照／匯入'),
            ),
    );
  }

  Widget _buildContent() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_rows.isEmpty) {
      return const Center(
        child: Text('這個欄位還沒有照片', style: TextStyle(color: Colors.grey)),
      );
    }
    if (_reorderMode) {
      return ReorderableListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _flatPhotos.length,
        onReorder: _onReorder,
        itemBuilder: (ctx, i) {
          final row = _flatPhotos[i];
          return _reorderTile(row, i);
        },
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _rows.length,
        itemBuilder: (ctx, i) {
          final row = _rows[i];
          if (row.isSeparator) return DateSeparator(date: row.date!);
          return _photoRow(row.photos!);
        },
      ),
    );
  }

  Widget _reorderTile(Map<String, dynamic> row, int index) {
    final store = context.read<AppState>().store!;
    final thumbPath = store
        .thumbnailFile((row['thumbnail_rel_path'] ?? '').toString())
        .path;
    final filename = (row['original_filename'] ?? '').toString();
    return Card(
      key: ValueKey(row['photo_id']),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: SizedBox(
          width: 56,
          height: 56,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: File(thumbPath).existsSync()
                ? Image.file(File(thumbPath), fit: BoxFit.cover)
                : Container(
                    color: const Color(0xFFC8D8E0),
                    child: const Icon(Icons.image, color: Colors.white54),
                  ),
          ),
        ),
        title: Text(filename, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('第 ${index + 1} 張'),
        trailing: const Icon(Icons.drag_handle),
      ),
    );
  }

  Widget _photoRow(List<Map<String, dynamic>> photos) {
    final cells = photos.map(_photoCell).toList();
    // Pad with invisible spacers so the last row stays left-aligned.
    while (cells.length < columns) {
      cells.add(const Spacer());
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < cells.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(child: cells[i]),
          ],
        ],
      ),
    );
  }

  Widget _photoCell(Map<String, dynamic> row) {
    final store = context.read<AppState>().store!;
    final photoId = (row['photo_id'] ?? '').toString();
    final number = (row['number_text'] ?? '').toString();
    final filename = (row['original_filename'] ?? '').toString();
    return GestureDetector(
      onTap: () => _openPhoto(row),
      onLongPress: () => _showPhotoMenu(row),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: FutureBuilder<File>(
                    future: store.renderedPhotoPath(photoId, maxSide: 320),
                    builder: (ctx, snap) {
                      final file = snap.data;
                      if (file != null && file.existsSync()) {
                        return Image.file(file, fit: BoxFit.cover);
                      }
                      // Fallback to raw thumbnail while rendering.
                      final thumbPath = store
                          .thumbnailFile(
                            (row['thumbnail_rel_path'] ?? '').toString(),
                          )
                          .path;
                      if (File(thumbPath).existsSync()) {
                        return Image.file(File(thumbPath), fit: BoxFit.cover);
                      }
                      return Container(
                        color: const Color(0xFFC8D8E0),
                        child: const Icon(Icons.image, color: Colors.white54),
                      );
                    },
                  ),
                ),
                if (number.isNotEmpty) NumberBadgeOverlay(placement: row),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Row {
  final bool isSeparator;
  final String? date;
  final List<Map<String, dynamic>>? photos;
  _Row.separator(String d) : isSeparator = true, date = d, photos = null;
  _Row.photos(List<Map<String, dynamic>> p)
    : isSeparator = false,
      date = null,
      photos = p;
}

const _sortOptions = <(String, String)>[
  ('manual', '手動排序（保留拖曳順序）'),
  ('time_asc', '拍攝時間：由早到晚'),
  ('time_desc', '拍攝時間：由晚到早'),
  ('filename_asc', '檔名：遞增'),
  ('filename_desc', '檔名：遞減'),
];
