import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:site_photo_mobile/models/project_store.dart';
import 'package:site_photo_mobile/services/report_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('PDF report keeps all photo content across multiple pages', () async {
    final tempDir = await Directory.systemTemp.createTemp('sprj_pdf_test_');
    final root = p.join(tempDir.path, 'test.sprj');
    final store = await ProjectStore.createProject(root, '多頁測試工程');
    try {
      final section = (await store.sections()).first;
      final slot = (await store.slots(section['id'].toString())).first;
      final slotId = slot['id'].toString();

      for (var i = 0; i < 8; i++) {
        final image = img.Image(width: 800, height: 600);
        img.fill(image, color: img.ColorRgb8(20 + i * 20, 80, 140));
        final source = File(p.join(tempDir.path, 'photo_$i.jpg'));
        await source.writeAsBytes(img.encodeJpg(image, quality: 90));
        await store.importFile(source.path, targetSlotId: slotId);
      }
      await store.numberSlot(slotId, size: '64');

      for (final layout in ReportLayout.values) {
        final bytes = await ReportExporter(store).buildPdf(layout: layout);
        final rawPdf = latin1.decode(bytes, allowInvalid: true);
        final pageCount = RegExp(r'/Type\s*/Page\b').allMatches(rawPdf).length;
        expect(pageCount, greaterThan(1), reason: 'layout=$layout');
      }
    } finally {
      await store.close();
      await tempDir.delete(recursive: true);
    }
  });

  test('PDF templates build successfully', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'sprj_template_test_',
    );
    final root = p.join(tempDir.path, 'test.sprj');
    final store = await ProjectStore.createProject(root, '模板測試工程');
    try {
      final section = (await store.sections()).first;
      final slot = (await store.slots(section['id'].toString())).first;
      final image = img.Image(width: 800, height: 600);
      img.fill(image, color: img.ColorRgb8(80, 120, 160));
      final source = File(p.join(tempDir.path, 'template.jpg'));
      await source.writeAsBytes(img.encodeJpg(image, quality: 90));
      await store.importFile(source.path, targetSlotId: slot['id'].toString());

      for (final template in PdfTemplate.values) {
        final bytes = await ReportExporter(store).buildPdf(template: template);
        expect(bytes.length, greaterThan(1000), reason: 'template=$template');
      }
    } finally {
      await store.close();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'automatic layout keeps a short mixed-orientation group together',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sprj_compact_layout_test_',
      );
      final root = p.join(tempDir.path, 'test.sprj');
      final store = await ProjectStore.createProject(root, '自動排版測試工程');
      try {
        final section = (await store.sections()).first;
        final slotId = (await store.slots(
          section['id'].toString(),
        )).first['id'].toString();
        final sizes = [(800, 1200), (800, 1200), (1200, 800)];
        for (var i = 0; i < sizes.length; i++) {
          final image = img.Image(width: sizes[i].$1, height: sizes[i].$2);
          img.fill(image, color: img.ColorRgb8(30 + i * 30, 100, 150));
          final source = File(p.join(tempDir.path, 'mixed_$i.jpg'));
          await source.writeAsBytes(img.encodeJpg(image, quality: 90));
          await store.importFile(source.path, targetSlotId: slotId);
        }

        final bytes = await ReportExporter(
          store,
        ).buildPdf(layout: ReportLayout.auto);
        final rawPdf = latin1.decode(bytes, allowInvalid: true);
        final pageCount = RegExp(r'/Type\s*/Page\b').allMatches(rawPdf).length;
        expect(pageCount, 2);
      } finally {
        await store.close();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('PDF starts every item and field on a new page', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'sprj_new_field_page_test_',
    );
    final store = await ProjectStore.createProject(
      p.join(tempDir.path, 'test.sprj'),
      '欄位分頁測試工程',
    );
    try {
      final sections = await store.sections();
      final firstSlot = (await store.slots(
        sections[0]['id'].toString(),
      )).first['id'].toString();
      final secondSlot = (await store.slots(
        sections[1]['id'].toString(),
      )).first['id'].toString();
      for (final item in [
        (slotId: firstSlot, name: 'first', red: 40),
        (slotId: secondSlot, name: 'second', red: 80),
      ]) {
        final image = img.Image(width: 800, height: 600);
        img.fill(image, color: img.ColorRgb8(item.red, 100, 140));
        final source = File(p.join(tempDir.path, '${item.name}.jpg'));
        await source.writeAsBytes(img.encodeJpg(image, quality: 90));
        await store.importFile(source.path, targetSlotId: item.slotId);
      }

      final bytes = await ReportExporter(
        store,
      ).buildPdf(layout: ReportLayout.auto);
      final rawPdf = latin1.decode(bytes, allowInvalid: true);
      final pageCount = RegExp(r'/Type\s*/Page\b').allMatches(rawPdf).length;
      expect(pageCount, 3);
    } finally {
      await store.close();
      await tempDir.delete(recursive: true);
    }
  });
}
