import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// A single mosaic region, matching the desktop app's mosaic_json format.
/// Coordinates are normalized (0.0–1.0) relative to image dimensions.
class MosaicRegion {
  final String type; // 'rectangle', 'ellipse', 'brush', 'lasso'
  final List<double> box; // [left, top, right, bottom] for rect/ellipse
  final List<List<double>> points; // for brush/lasso
  final double size; // brush radius (normalized)
  final int strength; // 1=heavy, 2=medium, 3=light (divisor mapping)

  MosaicRegion({
    required this.type,
    this.box = const [],
    this.points = const [],
    this.size = 0.04,
    this.strength = 2,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    if (box.isNotEmpty) 'box': box,
    if (points.isNotEmpty) 'points': points,
    'size': size,
    'strength': strength,
  };

  factory MosaicRegion.fromJson(Map<String, dynamic> j) => MosaicRegion(
    type: (j['type'] ?? 'rectangle').toString(),
    box: (j['box'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? [],
    points:
        (j['points'] as List?)
            ?.map((e) => (e as List).map((v) => (v as num).toDouble()).toList())
            .toList() ??
        [],
    size: (j['size'] as num?)?.toDouble() ?? 0.04,
    strength: (j['strength'] as num?)?.toInt() ?? 2,
  );
}

/// Applies mosaic (pixelation) to an image, matching the desktop algorithm.
class MosaicRenderer {
  /// Apply all regions to the image and return the modified image.
  static img.Image apply(img.Image image, List<MosaicRegion> regions) {
    final width = image.width;
    final height = image.height;

    for (final region in regions) {
      // Build a mask for this region.
      final mask = Uint8List(width * height); // 0 or 1
      int bboxLeft = width, bboxTop = height, bboxRight = 0, bboxBottom = 0;

      if (region.type == 'rectangle' || region.type == 'ellipse') {
        if (region.box.length != 4) continue;
        final l = (region.box[0] * width).round().clamp(0, width);
        final t = (region.box[1] * height).round().clamp(0, height);
        final r = (region.box[2] * width).round().clamp(0, width);
        final b = (region.box[3] * height).round().clamp(0, height);
        if (r <= l || b <= t) continue;
        bboxLeft = l;
        bboxTop = t;
        bboxRight = r;
        bboxBottom = b;
        if (region.type == 'ellipse') {
          _fillEllipse(mask, width, l, t, r, b);
        } else {
          _fillRect(mask, width, l, t, r, b);
        }
      } else if (region.type == 'brush') {
        final radius = math.max(
          1,
          (math.min(width, height) * region.size).round(),
        );
        for (final pt in region.points) {
          if (pt.length != 2) continue;
          final cx = (pt[0] * width).round();
          final cy = (pt[1] * height).round();
          _fillCircle(mask, width, height, cx, cy, radius);
          bboxLeft = math.min(bboxLeft, (cx - radius).clamp(0, width));
          bboxTop = math.min(bboxTop, (cy - radius).clamp(0, height));
          bboxRight = math.max(bboxRight, (cx + radius).clamp(0, width));
          bboxBottom = math.max(bboxBottom, (cy + radius).clamp(0, height));
        }
      } else if (region.type == 'lasso') {
        final pixelPts = region.points
            .where((pt) => pt.length == 2)
            .map((pt) => [(pt[0] * width).round(), (pt[1] * height).round()])
            .toList();
        if (pixelPts.length < 3) continue;
        _fillPolygon(mask, width, height, pixelPts);
        for (final pt in pixelPts) {
          bboxLeft = math.min(bboxLeft, pt[0].clamp(0, width));
          bboxTop = math.min(bboxTop, pt[1].clamp(0, height));
          bboxRight = math.max(bboxRight, pt[0].clamp(0, width));
          bboxBottom = math.max(bboxBottom, pt[1].clamp(0, height));
        }
      } else {
        continue;
      }

      if (bboxRight <= bboxLeft || bboxBottom <= bboxTop) continue;
      _pixelateMasked(
        image,
        mask,
        bboxLeft,
        bboxTop,
        bboxRight,
        bboxBottom,
        region.strength,
      );
    }
    return image;
  }

  /// Pixelate the masked region: downscale + upscale (NEAREST) + paste back.
  static void _pixelateMasked(
    img.Image image,
    Uint8List mask,
    int left,
    int top,
    int right,
    int bottom,
    int strength,
  ) {
    final divisor = {1: 24, 2: 12, 3: 6}[strength.clamp(1, 3)] ?? 12;
    final w = right - left;
    final h = bottom - top;
    if (w <= 0 || h <= 0) return;

    // Crop the patch.
    final patch = img.copyCrop(image, x: left, y: top, width: w, height: h);
    // Downscale.
    final smallW = math.max(1, w ~/ divisor);
    final smallH = math.max(1, h ~/ divisor);
    final small = img.copyResize(
      patch,
      width: smallW,
      height: smallH,
      interpolation: img.Interpolation.linear,
    );
    // Upscale back with nearest neighbor (blocky).
    final pixelated = img.copyResize(
      small,
      width: w,
      height: h,
      interpolation: img.Interpolation.nearest,
    );

    // Paste back where mask is set.
    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        if (mask[y * image.width + x] == 1) {
          final px = pixelated.getPixel(x - left, y - top);
          image.setPixel(x, y, px);
        }
      }
    }
  }

  static void _fillRect(Uint8List mask, int width, int l, int t, int r, int b) {
    for (var y = t; y < b; y++) {
      for (var x = l; x < r; x++) {
        mask[y * width + x] = 1;
      }
    }
  }

  static void _fillEllipse(
    Uint8List mask,
    int width,
    int l,
    int t,
    int r,
    int b,
  ) {
    final cx = (l + r) / 2;
    final cy = (t + b) / 2;
    final rx = (r - l) / 2;
    final ry = (b - t) / 2;
    if (rx <= 0 || ry <= 0) return;
    for (var y = t; y < b; y++) {
      for (var x = l; x < r; x++) {
        final dx = (x - cx) / rx;
        final dy = (y - cy) / ry;
        if (dx * dx + dy * dy <= 1) {
          mask[y * width + x] = 1;
        }
      }
    }
  }

  static void _fillCircle(
    Uint8List mask,
    int width,
    int height,
    int cx,
    int cy,
    int radius,
  ) {
    for (
      var y = (cy - radius).clamp(0, height - 1);
      y <= (cy + radius).clamp(0, height - 1);
      y++
    ) {
      for (
        var x = (cx - radius).clamp(0, width - 1);
        x <= (cx + radius).clamp(0, width - 1);
        x++
      ) {
        final dx = x - cx;
        final dy = y - cy;
        if (dx * dx + dy * dy <= radius * radius) {
          mask[y * width + x] = 1;
        }
      }
    }
  }

  /// Scanline polygon fill.
  static void _fillPolygon(
    Uint8List mask,
    int width,
    int height,
    List<List<int>> pts,
  ) {
    if (pts.length < 3) return;
    var minY = height, maxY = 0;
    for (final pt in pts) {
      minY = math.min(minY, pt[1]);
      maxY = math.max(maxY, pt[1]);
    }
    minY = minY.clamp(0, height - 1);
    maxY = maxY.clamp(0, height - 1);
    for (var y = minY; y <= maxY; y++) {
      final intersections = <int>[];
      for (var i = 0; i < pts.length; i++) {
        final a = pts[i];
        final b = pts[(i + 1) % pts.length];
        if ((a[1] <= y && b[1] > y) || (b[1] <= y && a[1] > y)) {
          final x = a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1]);
          intersections.add(x.round());
        }
      }
      intersections.sort();
      for (var i = 0; i + 1 < intersections.length; i += 2) {
        final xStart = intersections[i].clamp(0, width - 1);
        final xEnd = intersections[i + 1].clamp(0, width - 1);
        for (var x = xStart; x <= xEnd; x++) {
          mask[y * width + x] = 1;
        }
      }
    }
  }

  /// Render a photo with mosaic applied, save to output path.
  static Future<void> renderToFile(
    File source,
    File output,
    List<MosaicRegion> regions, {
    int maxSide = 1600,
  }) async {
    final bytes = await source.readAsBytes();
    var image = img.decodeImage(bytes);
    if (image == null) return;
    // Resize to maxSide.
    if (image.width > maxSide || image.height > maxSide) {
      image = img.copyResize(
        image,
        width: image.width > image.height ? maxSide : null,
        height: image.height >= image.width ? maxSide : null,
      );
    }
    if (regions.isNotEmpty) {
      image = apply(image, regions);
    }
    await output.writeAsBytes(img.encodeJpg(image, quality: 90));
  }
}
