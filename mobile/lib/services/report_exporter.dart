import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;

import '../models/project_store.dart';

/// PDF page layout choices shown in the export screen.
enum ReportLayout { auto, four, two, six, one }

extension ReportLayoutLabel on ReportLayout {
  String get label {
    switch (this) {
      case ReportLayout.auto:
        return '自動排版（直式最多4張／橫式最多2張）';
      case ReportLayout.four:
        return '每頁最多4張';
      case ReportLayout.two:
        return '每頁最多2張';
      case ReportLayout.six:
        return '每頁最多6張（2×3）';
      case ReportLayout.one:
        return '每頁1張大圖';
    }
  }
}

/// PDF visual templates shared by the desktop and mobile reports.
enum PdfTemplate { inkSaver, modern, warm }

extension PdfTemplateLabel on PdfTemplate {
  String get label {
    switch (this) {
      case PdfTemplate.inkSaver:
        return '黑白省墨版';
      case PdfTemplate.modern:
        return '清爽藍綠版';
      case PdfTemplate.warm:
        return '暖棕工程版';
    }
  }
}

/// Generates PDF and Excel reports matching the desktop app's format.
class ReportExporter {
  final ProjectStore store;
  PdfTemplate _template = PdfTemplate.modern;
  ReportExporter(this.store);

  _PdfPalette get _palette {
    switch (_template) {
      case PdfTemplate.inkSaver:
        return _PdfPalette.inkSaver;
      case PdfTemplate.modern:
        return _PdfPalette.modern;
      case PdfTemplate.warm:
        return _PdfPalette.warm;
    }
  }

  pdf.PdfColor get _accent => _palette.accent;
  pdf.PdfColor get _dark => _palette.dark;
  pdf.PdfColor get _muted => _palette.muted;
  pdf.PdfColor get _line => _palette.line;
  pdf.PdfColor get _panel => _palette.panel;
  pdf.PdfColor get _stripe => _palette.stripe;
  pdf.PdfColor get _banner => _palette.banner;
  pdf.PdfColor get _bannerLine => _palette.bannerLine;
  pdf.PdfColor get _soft => _palette.soft;
  pdf.PdfColor get _white => _palette.white;

  /// Load the bundled CJK font so Chinese text renders in the PDF.
  Future<pw.Font> _loadCjkFont() async {
    final data = await rootBundle.load('assets/fonts/NotoSansTC.ttf');
    return pw.Font.ttf(data);
  }

  /// Build a polished report with a cover page and auto-sized photo grids.
  ///
  /// In [ReportLayout.auto], portrait photos are placed four per page and
  /// landscape photos two per page.  Other modes let the user choose the
  /// maximum number of photos per page; every image keeps its aspect ratio.
  Future<Uint8List> buildPdf({
    bool showDate = true,
    bool showFilename = true,
    bool showCaption = true,
    bool showLocation = true,
    bool showNumber = true,
    ReportLayout layout = ReportLayout.auto,
    PdfTemplate template = PdfTemplate.modern,
  }) async {
    _template = template;
    final doc = pw.Document();
    final cjk = await _loadCjkFont();
    final project = await store.project();
    final name = (project['name'] ?? '工程照片紀錄').toString();
    final reportTitle = (project['report_title'] ?? name).toString();

    doc.addPage(
      pw.Page(
        margin: const pw.EdgeInsets.fromLTRB(42, 42, 42, 36),
        build: (ctx) => _coverPage(project, reportTitle, name, cjk),
      ),
    );

    final rows = await store.allReportRows();
    final groups = <_ReportGroup>[];
    for (final row in rows) {
      final sectionId = (row['section_id'] ?? '').toString();
      final slotId = (row['slot_id'] ?? '').toString();
      final photoId = (row['photo_id'] ?? '').toString();
      if (sectionId.isEmpty || slotId.isEmpty || photoId.isEmpty) continue;

      final previewRel = (row['preview_rel_path'] ?? '').toString();
      final placementId = (row['placement_id'] ?? '').toString();
      final imgFile = placementId.isNotEmpty
          ? await store.renderedPlacementPath(placementId, maxSide: 1600)
          : store.previewFile(previewRel);
      if (!await imgFile.exists()) continue;

      final bytes = await imgFile.readAsBytes();
      final width = int.tryParse((row['width'] ?? '').toString()) ?? 0;
      final height = int.tryParse((row['height'] ?? '').toString()) ?? 0;
      var landscape = width > height && width > 0 && height > 0;
      final rotation =
          int.tryParse((row['rotation_degrees'] ?? '').toString()) ?? 0;
      if (rotation.abs() % 180 != 0) landscape = !landscape;

      final photo = _ReportPhoto(
        row: row,
        image: pw.MemoryImage(bytes),
        landscape: landscape,
        caption: _caption(
          row,
          showDate: showDate,
          showFilename: showFilename,
          showCaption: showCaption,
          showLocation: showLocation,
          showNumber: showNumber,
        ),
      );
      if (groups.isEmpty ||
          groups.last.sectionId != sectionId ||
          groups.last.slotId != slotId) {
        groups.add(
          _ReportGroup(
            sectionId: sectionId,
            sectionName: (row['section_name'] ?? '').toString(),
            slotId: slotId,
            slotName: (row['slot_name'] ?? '').toString(),
          ),
        );
      }
      groups.last.photos.add(photo);
    }

    final content = <pw.Widget>[];
    var lastSection = '';
    var hasGrid = false;
    for (final group in groups) {
      final groupHeader = <pw.Widget>[];
      if (group.sectionId != lastSection) {
        groupHeader.add(_sectionHeader(group.sectionName, cjk));
        lastSection = group.sectionId;
      }
      groupHeader.add(_slotHeader(group.slotName, cjk));
      var firstChunkOfGroup = true;

      final segments = layout == ReportLayout.auto
          ? _splitByOrientation(group.photos)
          : <List<_ReportPhoto>>[group.photos];
      for (final segment in segments) {
        final landscape = layout == ReportLayout.auto
            ? segment.first.landscape
            : segment.where((photo) => photo.landscape).length >
                  segment.length / 2;
        final pageCapacity = _pageCapacity(layout, landscape);
        for (var start = 0; start < segment.length; start += pageCapacity) {
          final end = (start + pageCapacity).clamp(0, segment.length);
          final chunk = segment.sublist(start, end);
          // Every item/field starts on a fresh page.  Within that field,
          // automatic layout may still place a following orientation segment
          // on the same page when there is room.  Chunks beyond the selected
          // capacity always start a continuation page.
          final mustStartNewPage = hasGrid && (firstChunkOfGroup || start > 0);
          if (mustStartNewPage) {
            content.add(pw.NewPage());
          }
          final header = firstChunkOfGroup
              ? groupHeader
              : start > 0
              ? <pw.Widget>[
                  _continuationHeader(group.sectionName, group.slotName, cjk),
                ]
              : const <pw.Widget>[];
          // A non-spanning container makes the field heading and its first
          // photo row move together when the remaining page space is too
          // small.  Without this wrapper, MultiPage may leave the heading at
          // the bottom of one page and move the photos to the next page.
          content.add(
            pw.Container(
              child: pw.Column(
                mainAxisSize: pw.MainAxisSize.min,
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  ...header,
                  _photoGrid(chunk, layout, landscape, cjk),
                ],
              ),
            ),
          );
          hasGrid = true;
          firstChunkOfGroup = false;
        }
      }
    }

    if (content.isNotEmpty) {
      doc.addPage(
        pw.MultiPage(
          margin: const pw.EdgeInsets.fromLTRB(32, 30, 32, 34),
          maxPages: 1000,
          header: (ctx) => pw.Align(
            alignment: pw.Alignment.topRight,
            child: pw.Text(
              reportTitle,
              style: pw.TextStyle(font: cjk, fontSize: 8, color: _muted),
            ),
          ),
          footer: (ctx) => pw.Align(
            alignment: pw.Alignment.center,
            child: pw.Text(
              '工程照片紀錄  ·  第 ${ctx.pageNumber} 頁',
              style: pw.TextStyle(font: cjk, fontSize: 8, color: _muted),
            ),
          ),
          build: (ctx) => List<pw.Widget>.unmodifiable(content),
        ),
      );
    }

    return doc.save();
  }

  pw.Widget _coverPage(
    Map<String, dynamic> project,
    String reportTitle,
    String name,
    pw.Font cjk,
  ) {
    final allFields = _coverFields(project);
    final description = allFields
        .where((field) => field.$1 == '工程說明')
        .map((field) => field.$2)
        .firstOrNull;
    final fields = allFields.where((field) => field.$1 != '工程說明').toList();
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: pw.BoxDecoration(
            color: _banner,
            border: pw.Border.all(color: _bannerLine, width: 0.8),
            borderRadius: pw.BorderRadius.circular(7),
          ),
          child: pw.Row(
            children: [
              pw.Expanded(
                child: pw.Text(
                  'SITE PHOTO REPORT',
                  style: pw.TextStyle(
                    font: cjk,
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    color: _accent,
                  ),
                ),
              ),
              pw.Text(
                '工程照片整理與施工紀錄',
                style: pw.TextStyle(
                  font: cjk,
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: _dark,
                ),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 18),
        pw.Text(
          reportTitle,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            font: cjk,
            fontSize: 28,
            fontWeight: pw.FontWeight.bold,
            color: _dark,
          ),
        ),
        pw.SizedBox(height: 5),
        pw.Text(
          name,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(font: cjk, fontSize: 13, color: _muted),
        ),
        pw.SizedBox(height: 18),
        pw.Container(
          padding: const pw.EdgeInsets.fromLTRB(14, 13, 14, 14),
          decoration: pw.BoxDecoration(
            color: _panel,
            border: pw.Border.all(color: _line, width: 0.8),
            borderRadius: pw.BorderRadius.circular(7),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text(
                '工程基本資料',
                style: pw.TextStyle(
                  font: cjk,
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                  color: _dark,
                ),
              ),
              pw.SizedBox(height: 8),
              ..._metadataRows(fields, cjk),
            ],
          ),
        ),
        if (description != null) ...[
          pw.SizedBox(height: 10),
          pw.Container(
            padding: const pw.EdgeInsets.fromLTRB(12, 9, 12, 9),
            decoration: pw.BoxDecoration(
              color: _soft,
              border: pw.Border.all(color: _line, width: 0.7),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(
                  width: 70,
                  child: pw.Text(
                    '工程說明',
                    style: pw.TextStyle(font: cjk, fontSize: 9, color: _muted),
                  ),
                ),
                pw.Expanded(
                  child: pw.Text(
                    description,
                    style: pw.TextStyle(font: cjk, fontSize: 9, color: _dark),
                  ),
                ),
              ],
            ),
          ),
        ],
        pw.Spacer(),
        pw.Divider(color: _line),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            '由工程照片整理器產生',
            style: pw.TextStyle(font: cjk, fontSize: 9, color: _muted),
          ),
        ),
      ],
    );
  }

  List<(String, String)> _coverFields(Map<String, dynamic> project) {
    final fields = [
      ('工程名稱', project['name']),
      ('報告名稱', project['report_title']),
      ('工程編號', project['project_code']),
      ('工程地點', project['location']),
      ('業主', project['client_name']),
      ('承包商', project['contractor_name']),
      ('承辦人', project['manager_name']),
      ('公司名稱', project['company_name']),
      ('開工日期', project['start_date']),
      ('完工日期', project['end_date']),
      ('工程說明', project['description']),
    ];
    return fields
        .where((f) => (f.$2 ?? '').toString().trim().isNotEmpty)
        .map((f) => (f.$1, f.$2.toString()))
        .toList();
  }

  List<pw.Widget> _metadataRows(List<(String, String)> fields, pw.Font cjk) {
    final rows = <pw.Widget>[];
    for (var index = 0; index < fields.length; index += 2) {
      final pair = fields.skip(index).take(2).toList();
      rows.add(
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 6),
          decoration: index ~/ 2 % 2 == 0
              ? pw.BoxDecoration(color: _stripe)
              : null,
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (var column = 0; column < 2; column++)
                pw.Expanded(
                  child: pair.length > column
                      ? _metadataCell(pair[column], cjk)
                      : pw.SizedBox(),
                ),
            ],
          ),
        ),
      );
    }
    return rows;
  }

  pw.Widget _metadataCell((String, String) field, pw.Font cjk) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 7),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 45,
            child: pw.Text(
              field.$1,
              style: pw.TextStyle(font: cjk, fontSize: 8.5, color: _muted),
            ),
          ),
          pw.Expanded(
            child: pw.Text(
              field.$2,
              maxLines: 2,
              overflow: pw.TextOverflow.clip,
              style: pw.TextStyle(font: cjk, fontSize: 9, color: _dark),
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _sectionHeader(String name, pw.Font cjk) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 2, bottom: 8),
      padding: const pw.EdgeInsets.only(bottom: 6),
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _bannerLine, width: 1)),
      ),
      child: pw.Row(
        children: [
          pw.Container(width: 5, height: 20, color: _accent),
          pw.SizedBox(width: 8),
          pw.Text(
            name,
            style: pw.TextStyle(
              font: cjk,
              fontSize: 17,
              fontWeight: pw.FontWeight.bold,
              color: _dark,
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _slotHeader(String name, pw.Font cjk) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 4, bottom: 7),
      child: pw.Row(
        children: [
          pw.Container(width: 4, height: 18, color: _accent),
          pw.SizedBox(width: 7),
          pw.Text(
            name,
            style: pw.TextStyle(
              font: cjk,
              fontSize: 13,
              fontWeight: pw.FontWeight.bold,
              color: _dark,
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _continuationHeader(String section, String slot, pw.Font cjk) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Text(
        '$section／$slot（續）',
        style: pw.TextStyle(font: cjk, fontSize: 11, color: _muted),
      ),
    );
  }

  pw.Widget _photoGrid(
    List<_ReportPhoto> photos,
    ReportLayout layout,
    bool landscape,
    pw.Font cjk,
  ) {
    final columns = switch (layout) {
      ReportLayout.auto => landscape ? 1 : 2,
      ReportLayout.four => 2,
      ReportLayout.two || ReportLayout.one => 1,
      ReportLayout.six => 2,
    };
    final cardHeight = switch (layout) {
      ReportLayout.auto => landscape ? 285.0 : 315.0,
      ReportLayout.four => 315.0,
      ReportLayout.two => landscape ? 285.0 : 315.0,
      ReportLayout.six => 190.0,
      ReportLayout.one => 600.0,
    };
    final rows = <pw.Widget>[];
    for (var index = 0; index < photos.length; index += columns) {
      final rowPhotos = photos.skip(index).take(columns).toList();
      final cells = <pw.Widget>[];
      for (final photo in rowPhotos) {
        cells.add(
          pw.Expanded(
            child: pw.Container(
              height: cardHeight,
              margin: const pw.EdgeInsets.only(right: 5),
              child: _photoCard(photo, cjk),
            ),
          ),
        );
      }
      while (cells.length < columns) {
        cells.add(pw.Expanded(child: pw.SizedBox(height: cardHeight)));
      }
      rows.add(pw.Row(children: cells));
      if (index + columns < photos.length) {
        rows.add(pw.SizedBox(height: 10));
      }
    }
    return pw.Column(mainAxisSize: pw.MainAxisSize.min, children: rows);
  }

  pw.Widget _photoCard(_ReportPhoto photo, pw.Font cjk) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(7),
      decoration: pw.BoxDecoration(
        color: _white,
        border: pw.Border.all(color: _line, width: 0.7),
        borderRadius: pw.BorderRadius.circular(7),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Expanded(
            child: pw.Center(
              child: pw.Image(photo.image, fit: pw.BoxFit.contain),
            ),
          ),
          pw.SizedBox(height: 5),
          pw.Text(
            photo.caption.isEmpty ? ' ' : photo.caption,
            maxLines: 2,
            overflow: pw.TextOverflow.clip,
            style: pw.TextStyle(font: cjk, fontSize: 8, color: _dark),
          ),
        ],
      ),
    );
  }

  String _caption(
    Map<String, dynamic> row, {
    required bool showDate,
    required bool showFilename,
    required bool showCaption,
    required bool showLocation,
    required bool showNumber,
  }) {
    final parts = <String>[];
    final number = (row['number_text'] ?? '').toString();
    if (showNumber && number.isNotEmpty) parts.add('#$number');
    if (showDate && (row['captured_at'] ?? '').toString().isNotEmpty) {
      parts.add(row['captured_at'].toString());
    }
    if (showLocation &&
        (row['construction_location'] ?? '').toString().isNotEmpty) {
      parts.add(row['construction_location'].toString());
    }
    if (showFilename) parts.add((row['original_filename'] ?? '').toString());
    if (showCaption && (row['caption'] ?? '').toString().isNotEmpty) {
      parts.add(row['caption'].toString());
    }
    return parts.join('｜');
  }

  List<List<_ReportPhoto>> _splitByOrientation(List<_ReportPhoto> photos) {
    final result = <List<_ReportPhoto>>[];
    for (final photo in photos) {
      if (result.isEmpty || result.last.first.landscape != photo.landscape) {
        result.add(<_ReportPhoto>[]);
      }
      result.last.add(photo);
    }
    return result;
  }

  int _pageCapacity(ReportLayout layout, bool landscape) {
    switch (layout) {
      case ReportLayout.auto:
        return landscape ? 2 : 4;
      case ReportLayout.four:
        return 4;
      case ReportLayout.two:
        return 2;
      case ReportLayout.six:
        return 6;
      case ReportLayout.one:
        return 1;
    }
  }

  /// Build a simple Excel-compatible CSV (photo index).
  Future<String> buildCsv() async {
    final rows = await store.allReportRows();
    final buffer = StringBuffer();
    buffer.writeln('編號,項目,欄位,檔名,拍攝時間,位置,說明');
    for (final row in rows) {
      if (row['photo_id'] == null) continue;
      final number = (row['number_text'] ?? '').toString();
      final section = (row['section_name'] ?? '').toString();
      final slot = (row['slot_name'] ?? '').toString();
      final filename = (row['original_filename'] ?? '').toString();
      final captured = (row['captured_at'] ?? '').toString();
      final location = (row['construction_location'] ?? '').toString();
      final caption = (row['caption'] ?? '').toString();
      buffer.writeln(
        '"$number","$section","$slot","$filename","$captured","$location","$caption"',
      );
    }
    return buffer.toString();
  }
}

class _ReportGroup {
  final String sectionId;
  final String sectionName;
  final String slotId;
  final String slotName;
  final List<_ReportPhoto> photos = [];

  _ReportGroup({
    required this.sectionId,
    required this.sectionName,
    required this.slotId,
    required this.slotName,
  });
}

class _ReportPhoto {
  final Map<String, dynamic> row;
  final pw.MemoryImage image;
  final bool landscape;
  final String caption;

  _ReportPhoto({
    required this.row,
    required this.image,
    required this.landscape,
    required this.caption,
  });
}

class _PdfPalette {
  final pdf.PdfColor accent;
  final pdf.PdfColor dark;
  final pdf.PdfColor muted;
  final pdf.PdfColor line;
  final pdf.PdfColor panel;
  final pdf.PdfColor stripe;
  final pdf.PdfColor banner;
  final pdf.PdfColor bannerLine;
  final pdf.PdfColor soft;
  final pdf.PdfColor white;

  const _PdfPalette({
    required this.accent,
    required this.dark,
    required this.muted,
    required this.line,
    required this.panel,
    required this.stripe,
    required this.banner,
    required this.bannerLine,
    required this.soft,
    required this.white,
  });

  static const modern = _PdfPalette(
    accent: pdf.PdfColor.fromInt(0xff29758a),
    dark: pdf.PdfColor.fromInt(0xff143b50),
    muted: pdf.PdfColor.fromInt(0xff6b7d84),
    line: pdf.PdfColor.fromInt(0xffc7d3d8),
    panel: pdf.PdfColor.fromInt(0xfff5f7f8),
    stripe: pdf.PdfColor.fromInt(0xffeaf3f7),
    banner: pdf.PdfColor.fromInt(0xffe5f2f4),
    bannerLine: pdf.PdfColor.fromInt(0xffa9cfd8),
    soft: pdf.PdfColor.fromInt(0xfff8fbfc),
    white: pdf.PdfColor.fromInt(0xffffffff),
  );

  static const inkSaver = _PdfPalette(
    accent: pdf.PdfColor.fromInt(0xff333333),
    dark: pdf.PdfColor.fromInt(0xff111111),
    muted: pdf.PdfColor.fromInt(0xff555555),
    line: pdf.PdfColor.fromInt(0xff999999),
    panel: pdf.PdfColor.fromInt(0xffffffff),
    stripe: pdf.PdfColor.fromInt(0xffffffff),
    banner: pdf.PdfColor.fromInt(0xffffffff),
    bannerLine: pdf.PdfColor.fromInt(0xff666666),
    soft: pdf.PdfColor.fromInt(0xffffffff),
    white: pdf.PdfColor.fromInt(0xffffffff),
  );

  static const warm = _PdfPalette(
    accent: pdf.PdfColor.fromInt(0xff9a5b34),
    dark: pdf.PdfColor.fromInt(0xff4a2d22),
    muted: pdf.PdfColor.fromInt(0xff806c62),
    line: pdf.PdfColor.fromInt(0xffd8c2b4),
    panel: pdf.PdfColor.fromInt(0xfffaf4ef),
    stripe: pdf.PdfColor.fromInt(0xfff5e9df),
    banner: pdf.PdfColor.fromInt(0xfff4e5d9),
    bannerLine: pdf.PdfColor.fromInt(0xffd8ad8b),
    soft: pdf.PdfColor.fromInt(0xfffdf9f6),
    white: pdf.PdfColor.fromInt(0xffffffff),
  );
}
