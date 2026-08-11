import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../services/mosaic_renderer.dart';

/// Touch-based mosaic editor. User paints regions (brush/rect/ellipse) over
/// the photo; regions are stored normalized (0–1) matching the desktop format.
class MosaicEditorScreen extends StatefulWidget {
  final File sourceFile;
  final List<MosaicRegion> initialRegions;
  const MosaicEditorScreen({
    super.key,
    required this.sourceFile,
    required this.initialRegions,
  });

  /// Show the editor; returns the edited region list, or null if cancelled.
  static Future<List<MosaicRegion>?> show(
    BuildContext context,
    File sourceFile,
    List<MosaicRegion> initial,
  ) {
    return Navigator.push<List<MosaicRegion>>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            MosaicEditorScreen(sourceFile: sourceFile, initialRegions: initial),
      ),
    );
  }

  @override
  State<MosaicEditorScreen> createState() => _MosaicEditorScreenState();
}

class _MosaicEditorScreenState extends State<MosaicEditorScreen> {
  late List<MosaicRegion> _regions;
  String _mode = 'brush'; // brush | rectangle | ellipse
  int _strength = 2;
  double _brushSize = 0.05;
  bool _preview = false;
  bool _busy = false;

  ui.Image? _image;
  File? _previewFile;

  // Active drawing state.
  final List<List<double>> _activePoints = [];
  List<double>? _activeBoxStart;
  List<double>? _activeBoxCurrent;

  // The rect where the image is actually drawn on screen (BoxFit.contain).
  Rect _imageRect = Rect.zero;

  @override
  void initState() {
    super.initState();
    _regions = List.of(widget.initialRegions);
    _loadImage();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    final bytes = await widget.sourceFile.readAsBytes();
    final decoded = await _decode(bytes);
    if (!mounted) return;
    setState(() => _image = decoded);
  }

  Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  /// Map a screen point to normalized image coords (0–1), or null if outside.
  List<double>? _toNormalized(Offset local) {
    if (_imageRect.isEmpty) return null;
    final x = (local.dx - _imageRect.left) / _imageRect.width;
    final y = (local.dy - _imageRect.top) / _imageRect.height;
    if (x < 0 || x > 1 || y < 0 || y > 1) return null;
    return [x, y];
  }

  void _onPanStart(DragStartDetails d) {
    final pt = _toNormalized(d.localPosition);
    if (pt == null) return;
    setState(() {
      _preview = false;
      if (_mode == 'brush') {
        _activePoints
          ..clear()
          ..add(pt);
      } else {
        _activeBoxStart = pt;
        _activeBoxCurrent = pt;
      }
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final pt = _toNormalized(d.localPosition);
    if (pt == null) return;
    setState(() {
      if (_mode == 'brush') {
        _activePoints.add(pt);
      } else {
        _activeBoxCurrent = pt;
      }
    });
  }

  void _onPanEnd(DragEndDetails d) {
    setState(() {
      if (_mode == 'brush') {
        if (_activePoints.length >= 2) {
          _regions.add(
            MosaicRegion(
              type: 'brush',
              points: List.of(_activePoints),
              size: _brushSize,
              strength: _strength,
            ),
          );
        }
        _activePoints.clear();
      } else {
        final s = _activeBoxStart;
        final c = _activeBoxCurrent;
        if (s != null && c != null) {
          final box = [
            math.min(s[0], c[0]),
            math.min(s[1], c[1]),
            math.max(s[0], c[0]),
            math.max(s[1], c[1]),
          ];
          if (box[2] - box[0] > 0.01 && box[3] - box[1] > 0.01) {
            _regions.add(
              MosaicRegion(type: _mode, box: box, strength: _strength),
            );
          }
        }
        _activeBoxStart = null;
        _activeBoxCurrent = null;
      }
    });
  }

  Future<void> _togglePreview() async {
    if (_preview) {
      setState(() => _preview = false);
      return;
    }
    setState(() => _busy = true);
    try {
      final out = File('${widget.sourceFile.path}.mosaic_preview.jpg');
      await MosaicRenderer.renderToFile(widget.sourceFile, out, _regions);
      if (!mounted) return;
      final bytes = await out.readAsBytes();
      final decoded = await _decode(bytes);
      setState(() {
        _image?.dispose();
        _image = decoded;
        _previewFile = out;
        _preview = true;
        _busy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('預覽失敗：$e')));
      }
    }
  }

  void _undo() {
    setState(() {
      _preview = false;
      if (_regions.isNotEmpty) _regions.removeLast();
    });
  }

  void _clear() {
    setState(() {
      _preview = false;
      _regions.clear();
    });
  }

  void _save() {
    // Clean up preview temp file.
    _previewFile?.delete().catchError((_) => _previewFile!);
    Navigator.pop(context, _regions);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('馬賽克遮蔽'),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: _undo,
            tooltip: '上一步',
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: _clear,
            tooltip: '清除全部',
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _save,
            tooltip: '儲存',
          ),
        ],
      ),
      body: Column(
        children: [
          _toolbar(),
          Expanded(
            child: _busy
                ? const Center(child: CircularProgressIndicator())
                : GestureDetector(
                    onPanStart: _preview ? null : _onPanStart,
                    onPanUpdate: _preview ? null : _onPanUpdate,
                    onPanEnd: _preview ? null : _onPanEnd,
                    child: LayoutBuilder(
                      builder: (ctx, constraints) {
                        return CustomPaint(
                          size: Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          ),
                          painter: _MosaicPainter(
                            image: _image,
                            regions: _preview ? [] : _regions,
                            activePoints: _mode == 'brush' ? _activePoints : [],
                            activeBoxStart: _activeBoxStart,
                            activeBoxCurrent: _activeBoxCurrent,
                            mode: _mode,
                            brushSize: _brushSize,
                            onImageRect: (r) => _imageRect = r,
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.white,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _modeChip('筆刷', 'brush', Icons.brush),
          _modeChip('方框', 'rectangle', Icons.crop_square),
          _modeChip('圓形', 'ellipse', Icons.circle_outlined),
          const SizedBox(width: 8),
          DropdownButton<int>(
            value: _strength,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 3, child: Text('輕度')),
              DropdownMenuItem(value: 2, child: Text('中度')),
              DropdownMenuItem(value: 1, child: Text('重度')),
            ],
            onChanged: (v) => setState(() {
              _strength = v!;
              _preview = false;
            }),
          ),
          if (_mode == 'brush')
            SizedBox(
              width: 120,
              child: Slider(
                value: _brushSize,
                min: 0.02,
                max: 0.15,
                onChanged: (v) => setState(() {
                  _brushSize = v;
                  _preview = false;
                }),
              ),
            ),
          OutlinedButton.icon(
            onPressed: _togglePreview,
            icon: Icon(_preview ? Icons.edit : Icons.visibility),
            label: Text(_preview ? '繼續編輯' : '預覽'),
          ),
        ],
      ),
    );
  }

  Widget _modeChip(String label, String mode, IconData icon) {
    final selected = _mode == mode;
    return ChoiceChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, size: 16), const SizedBox(width: 4), Text(label)],
      ),
      selected: selected,
      onSelected: (_) => setState(() {
        _mode = mode;
        _preview = false;
      }),
    );
  }
}

/// Paints the image (BoxFit.contain) + region overlays + active drawing.
class _MosaicPainter extends CustomPainter {
  final ui.Image? image;
  final List<MosaicRegion> regions;
  final List<List<double>> activePoints;
  final List<double>? activeBoxStart;
  final List<double>? activeBoxCurrent;
  final String mode;
  final double brushSize;
  final void Function(Rect) onImageRect;

  _MosaicPainter({
    required this.image,
    required this.regions,
    required this.activePoints,
    required this.activeBoxStart,
    required this.activeBoxCurrent,
    required this.mode,
    required this.brushSize,
    required this.onImageRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (image == null) return;
    // Compute BoxFit.contain rect.
    final scale = math.min(
      size.width / image!.width,
      size.height / image!.height,
    );
    final w = image!.width * scale;
    final h = image!.height * scale;
    final rect = Rect.fromLTWH(
      (size.width - w) / 2,
      (size.height - h) / 2,
      w,
      h,
    );
    onImageRect(rect);

    canvas.drawImageRect(
      image!,
      Rect.fromLTWH(0, 0, image!.width.toDouble(), image!.height.toDouble()),
      rect,
      Paint(),
    );

    final overlayPaint = Paint()
      ..color = Colors.red.withValues(alpha: 0.35)
      ..style = PaintingStyle.fill;
    final outlinePaint = Paint()
      ..color = Colors.red.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // Committed regions.
    for (final region in regions) {
      _drawRegion(canvas, rect, region, overlayPaint, outlinePaint);
    }

    // Active drawing.
    if (mode == 'brush' && activePoints.length >= 2) {
      final radius = brushSize * rect.width;
      for (final pt in activePoints) {
        final c = Offset(
          rect.left + pt[0] * rect.width,
          rect.top + pt[1] * rect.height,
        );
        canvas.drawCircle(c, radius, overlayPaint);
      }
    } else if (activeBoxStart != null && activeBoxCurrent != null) {
      final s = activeBoxStart!;
      final c = activeBoxCurrent!;
      final r = Rect.fromLTRB(
        rect.left + math.min(s[0], c[0]) * rect.width,
        rect.top + math.min(s[1], c[1]) * rect.height,
        rect.left + math.max(s[0], c[0]) * rect.width,
        rect.top + math.max(s[1], c[1]) * rect.height,
      );
      if (mode == 'ellipse') {
        canvas.drawOval(r, overlayPaint);
        canvas.drawOval(r, outlinePaint);
      } else {
        canvas.drawRect(r, overlayPaint);
        canvas.drawRect(r, outlinePaint);
      }
    }
  }

  void _drawRegion(
    Canvas canvas,
    Rect rect,
    MosaicRegion region,
    Paint fill,
    Paint outline,
  ) {
    if (region.type == 'rectangle' && region.box.length == 4) {
      final r = _boxToRect(rect, region.box);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, outline);
    } else if (region.type == 'ellipse' && region.box.length == 4) {
      final r = _boxToRect(rect, region.box);
      canvas.drawOval(r, fill);
      canvas.drawOval(r, outline);
    } else if (region.type == 'brush') {
      final radius = region.size * rect.width;
      for (final pt in region.points) {
        final c = Offset(
          rect.left + pt[0] * rect.width,
          rect.top + pt[1] * rect.height,
        );
        canvas.drawCircle(c, radius, fill);
      }
    } else if (region.type == 'lasso' && region.points.length >= 3) {
      final path = Path();
      final first = region.points.first;
      path.moveTo(
        rect.left + first[0] * rect.width,
        rect.top + first[1] * rect.height,
      );
      for (final pt in region.points.skip(1)) {
        path.lineTo(
          rect.left + pt[0] * rect.width,
          rect.top + pt[1] * rect.height,
        );
      }
      path.close();
      canvas.drawPath(path, fill);
      canvas.drawPath(path, outline);
    }
  }

  Rect _boxToRect(Rect rect, List<double> box) {
    return Rect.fromLTRB(
      rect.left + box[0] * rect.width,
      rect.top + box[1] * rect.height,
      rect.left + box[2] * rect.width,
      rect.top + box[3] * rect.height,
    );
  }

  @override
  bool shouldRepaint(covariant _MosaicPainter old) => true;
}
