import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/mosaic_renderer.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/number_badge.dart';
import 'image_viewer_screen.dart';
import 'mosaic_editor_screen.dart';

/// Photo detail + edit screen: large preview, caption/location editing,
/// number badge, and quick actions (rotate/move). Matches desktop's
/// right-side property panel.
class PhotoDetailScreen extends StatefulWidget {
  final String photoId;
  final String? slotId;
  const PhotoDetailScreen({
    super.key,
    required this.photoId,
    required this.slotId,
  });

  @override
  State<PhotoDetailScreen> createState() => _PhotoDetailScreenState();
}

class _PhotoDetailScreenState extends State<PhotoDetailScreen> {
  Map<String, dynamic>? _photo;
  Map<String, dynamic>? _placement;
  final _captionCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final store = context.read<AppState>().store!;
    final photo = await store.photo(widget.photoId);
    final placement = await store.placementForPhoto(
      widget.photoId,
      widget.slotId,
    );
    if (!mounted) return;
    setState(() {
      _photo = photo;
      _placement = placement;
      _captionCtrl.text = (placement?['caption'] ?? '').toString();
      _locationCtrl.text = (placement?['construction_location'] ?? '')
          .toString();
      _loading = false;
    });
  }

  Future<void> _save() async {
    final store = context.read<AppState>().store!;
    if (_placement != null) {
      await store.updatePlacement(_placement!['id'].toString(), {
        'caption': _captionCtrl.text.trim(),
        'construction_location': _locationCtrl.text.trim(),
        'is_human_confirmed': 1,
      });
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('照片屬性已儲存')));
    }
  }

  Future<void> _move() async {
    final store = context.read<AppState>().store!;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final sections = await store.sections();
    // Build a flat list of (sectionName, slotId, slotName) targets.
    final targets = <_MoveTarget>[];
    for (final sec in sections) {
      final slots = await store.slots(sec['id']);
      for (final slot in slots) {
        targets.add(
          _MoveTarget(
            sec['name'].toString(),
            slot['id'].toString(),
            slot['name'].toString(),
          ),
        );
      }
    }
    if (!mounted) return;
    final chosen = await showModalBottomSheet<_MoveTarget>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '移動到欄位',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.inbox),
              title: const Text('移回未分類'),
              onTap: () => Navigator.pop(
                ctx,
                _MoveTarget('', '__unclassified__', '未分類'),
              ),
            ),
            ...targets.map(
              (t) => ListTile(
                leading: const Icon(Icons.folder),
                title: Text('${t.section} / ${t.slot}'),
                onTap: () => Navigator.pop(ctx, t),
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    final targetSlot = chosen.slotId == '__unclassified__'
        ? null
        : chosen.slotId;
    await store.relocatePhotos([widget.photoId], widget.slotId, targetSlot);
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text('已移動到 ${chosen.slot}')),
    );
    navigator.pop();
  }

  Future<void> _rotate(int degrees) async {
    final store = context.read<AppState>().store!;
    final current = (_photo!['rotation_degrees'] ?? 0) as int;
    final next = (current + degrees) % 360;
    await store.updatePhoto(widget.photoId, {'rotation_degrees': next});
    _load();
  }

  Future<void> _openViewer() async {
    final store = context.read<AppState>().store!;
    final file = await store.renderedPhotoPath(widget.photoId, maxSide: 2400);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          file: file,
          title: (_photo!['original_filename'] ?? '').toString(),
        ),
      ),
    );
  }

  Future<void> _openMosaic() async {
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    // Source = original file (mosaic is applied to a rendered copy).
    final originalRel = (_photo!['original_rel_path'] ?? '').toString();
    final source = store.originalFile(originalRel);
    if (!await source.exists()) {
      messenger.showSnackBar(const SnackBar(content: Text('找不到原始照片檔')));
      return;
    }
    // Parse existing mosaic_json.
    var existing = <MosaicRegion>[];
    try {
      final raw = (_photo!['mosaic_json'] ?? '').toString();
      if (raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        existing = list
            .map((e) => MosaicRegion.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}

    final result = await navigator.push<List<MosaicRegion>>(
      MaterialPageRoute(
        builder: (_) =>
            MosaicEditorScreen(sourceFile: source, initialRegions: existing),
      ),
    );
    if (result == null || !mounted) return;

    // Save mosaic_json + render the mosaic-applied preview/thumbnail.
    await store.updatePhoto(widget.photoId, {
      'mosaic_json': jsonEncode(result.map((r) => r.toJson()).toList()),
    });
    // Re-render preview + thumbnail with mosaic applied.
    try {
      final previewRel = (_photo!['preview_rel_path'] ?? '').toString();
      final thumbRel = (_photo!['thumbnail_rel_path'] ?? '').toString();
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
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('馬賽克渲染失敗：$e')));
    }
    messenger.showSnackBar(const SnackBar(content: Text('馬賽克已儲存')));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('照片詳情')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_photo == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('照片詳情')),
        body: const Center(child: Text('找不到照片')),
      );
    }
    final store = context.read<AppState>().store!;
    final number = (_placement?['number_text'] ?? '').toString();
    final captured = (_photo!['captured_at'] ?? '').toString();

    return Scaffold(
      appBar: AppBar(
        title: const Text('照片詳情'),
        actions: [IconButton(icon: const Icon(Icons.save), onPressed: _save)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: GestureDetector(
                    onTap: _openViewer,
                    child: FutureBuilder<File>(
                      future: store.renderedPhotoPath(
                        widget.photoId,
                        maxSide: 1600,
                      ),
                      builder: (ctx, snap) {
                        final file = snap.data;
                        if (file != null && file.existsSync()) {
                          return Image.file(file, fit: BoxFit.contain);
                        }
                        final previewPath = store
                            .previewFile(
                              (_photo!['preview_rel_path'] ?? '').toString(),
                            )
                            .path;
                        if (File(previewPath).existsSync()) {
                          return Image.file(
                            File(previewPath),
                            fit: BoxFit.contain,
                          );
                        }
                        return Container(
                          color: const Color(0xFFC8D8E0),
                          child: const Icon(Icons.image, size: 64),
                        );
                      },
                    ),
                  ),
                ),
                if (_placement != null && number.isNotEmpty)
                  NumberBadgeOverlay(placement: _placement!),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  _field('檔名', (_photo!['original_filename'] ?? '').toString()),
                  _field('拍攝', captured.isEmpty ? '未知' : captured),
                  _field('尺寸', '${_photo!['width']}×${_photo!['height']}'),
                  const Divider(height: 20),
                  TextField(
                    controller: _captionCtrl,
                    decoration: const InputDecoration(
                      labelText: '照片說明',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _locationCtrl,
                    decoration: const InputDecoration(
                      labelText: '施工位置',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _rotate(-90),
                  icon: const Icon(Icons.rotate_left),
                  label: const Text('左轉'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _rotate(90),
                  icon: const Icon(Icons.rotate_right),
                  label: const Text('右轉'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openMosaic,
                  icon: const Icon(Icons.blur_on),
                  label: const Text('馬賽克遮蔽'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _move,
                  icon: const Icon(Icons.drive_file_move),
                  label: const Text('移動欄位'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _MoveTarget {
  final String section;
  final String slotId;
  final String slot;
  _MoveTarget(this.section, this.slotId, this.slot);
}
