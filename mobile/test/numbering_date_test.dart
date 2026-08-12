import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:site_photo_mobile/models/project_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('numbering and clearing are isolated to the selected slot', () async {
    final tempDir = await Directory.systemTemp.createTemp('sprj_number_test_');
    final store = await ProjectStore.createProject(
      p.join(tempDir.path, 'test.sprj'),
      '編號測試工程',
    );
    try {
      final sections = await store.sections();
      final firstSlots = await store.slots(sections[0]['id'].toString());
      final secondSlots = await store.slots(sections[1]['id'].toString());
      final firstSlotId = firstSlots.first['id'].toString();
      final secondSlotId = secondSlots.first['id'].toString();

      for (var i = 0; i < 3; i++) {
        await store.importFile(
          await _writeJpeg(tempDir.path, 'first_$i.jpg', 40 + i * 30),
          targetSlotId: firstSlotId,
        );
      }
      await store.importFile(
        await _writeJpeg(tempDir.path, 'second.jpg', 180),
        targetSlotId: secondSlotId,
      );

      await store.numberSlot(firstSlotId, size: '64');
      await store.numberSlot(secondSlotId, size: '64');
      final numberedFirst = await store.placementsForSlot(firstSlotId);
      expect(numberedFirst.map((r) => r['number_text']).toList(), [
        '1',
        '2',
        '3',
      ]);
      expect(
        (await store.placementsForSlot(secondSlotId)).first['number_text'],
        '1',
      );

      await store.clearSlotNumbers(firstSlotId);
      expect(
        (await store.placementsForSlot(
          firstSlotId,
        )).every((r) => (r['number_text'] ?? '').toString().isEmpty),
        isTrue,
      );
      expect(
        (await store.placementsForSlot(secondSlotId)).first['number_text'],
        '1',
      );
    } finally {
      await store.close();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'relocatePhotos moves unclassified photos into the selected slot',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sprj_relocate_test_',
      );
      final store = await ProjectStore.createProject(
        p.join(tempDir.path, 'test.sprj'),
        '快速分類測試工程',
      );
      try {
        final section = (await store.sections()).first;
        final slotId = (await store.slots(
          section['id'].toString(),
        )).first['id'].toString();
        final photoId = await store.importFile(
          await _writeJpeg(tempDir.path, 'unclassified.jpg', 90),
        );

        await store.relocatePhotos([photoId!], null, slotId);

        expect(await store.countUnclassified(), 0);
        final placed = await store.placementsForSlot(slotId);
        expect(placed.map((row) => row['photo_id']).toList(), [photoId]);
        expect(placed.first['is_human_confirmed'], 1);
      } finally {
        await store.close();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'capture dates are imported and legacy originals can be backfilled',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('sprj_date_test_');
      final store = await ProjectStore.createProject(
        p.join(tempDir.path, 'test.sprj'),
        '日期測試工程',
      );
      try {
        final datedPath = await _writeJpeg(
          tempDir.path,
          'dated.jpg',
          70,
          captureDate: '2026:07:27 13:38:00',
        );
        final datedId = await store.importFile(datedPath);
        expect(
          (await store.photo(datedId!))!['captured_at'],
          '2026-07-27 13:38:00',
        );

        final legacyPath = await _writeJpeg(tempDir.path, 'legacy.jpg', 150);
        final legacyId = await store.importFile(legacyPath);
        final legacyPhoto = await store.photo(legacyId!);
        final legacyOriginal = store.originalFile(
          legacyPhoto!['original_rel_path'].toString(),
        );
        await legacyOriginal.writeAsBytes(
          await _jpegBytes(150, captureDate: '2026:07:28 09:10:11'),
        );

        expect((await store.photo(legacyId))!['captured_at'], '');
        expect(await store.backfillCapturedAt(), 1);
        expect(
          (await store.photo(legacyId))!['captured_at'],
          '2026-07-28 09:10:11',
        );

        final rows = await store.placementsForSlot(null);
        expect(rows[0]['captured_at'], '2026-07-27 13:38:00');
        expect(rows[1]['captured_at'], '2026-07-28 09:10:11');
      } finally {
        await store.close();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('all slot sort modes keep manual positions unchanged', () async {
    final tempDir = await Directory.systemTemp.createTemp('sprj_sort_test_');
    final store = await ProjectStore.createProject(
      p.join(tempDir.path, 'test.sprj'),
      '欄位排序測試工程',
    );
    try {
      final section = (await store.sections()).first;
      final slotId = (await store.slots(
        section['id'].toString(),
      )).first['id'].toString();
      final first = await store.importFile(
        await _writeJpeg(tempDir.path, 'photo_10.jpg', 40),
        targetSlotId: slotId,
      );
      final second = await store.importFile(
        await _writeJpeg(tempDir.path, 'photo_2.jpg', 80),
        targetSlotId: slotId,
      );

      final manual = await store.placementsForSlot(slotId);
      expect(manual.map((row) => row['photo_id']).toList(), [first, second]);
      expect(
        (await store.placementsForSlot(
          slotId,
          sortMode: 'filename_asc',
        )).map((row) => row['original_filename']).toList(),
        ['photo_2.jpg', 'photo_10.jpg'],
      );
      expect(
        (await store.placementsForSlot(
          slotId,
          sortMode: 'filename_desc',
        )).map((row) => row['original_filename']).toList(),
        ['photo_10.jpg', 'photo_2.jpg'],
      );
      expect(
        (await store.placementsForSlot(
          slotId,
          sortMode: 'manual',
        )).map((row) => row['photo_id']).toList(),
        [first, second],
      );
    } finally {
      await store.close();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'direct slot import survives closing and reopening the project',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sprj_import_test_',
      );
      final projectPath = p.join(tempDir.path, 'camera.sprj');
      final store = await ProjectStore.createProject(projectPath, '拍照保存測試工程');
      try {
        final section = (await store.sections()).first;
        final slotId = (await store.slots(
          section['id'].toString(),
        )).first['id'].toString();
        final sourcePath = await _writeJpeg(tempDir.path, 'camera.jpg', 120);
        final photoId = await store.importFile(
          sourcePath,
          targetSlotId: slotId,
        );

        expect(photoId, isNotNull);
        final savedPhoto = await store.photo(photoId!);
        final savedOriginal = store.originalFile(
          savedPhoto!['original_rel_path'].toString(),
        );
        expect(await savedOriginal.exists(), isTrue);
        expect(
          (await store.placementsForSlot(slotId)).map((r) => r['photo_id']),
          [photoId],
        );
      } finally {
        await store.close();
      }

      final reopened = ProjectStore(projectPath);
      try {
        await reopened.open();
        final sections = await reopened.sections();
        final slotId = (await reopened.slots(
          sections.first['id'].toString(),
        )).first['id'].toString();
        final rows = await reopened.placementsForSlot(slotId);
        expect(rows, hasLength(1));
        expect(
          await reopened
              .originalFile(rows.first['original_rel_path'].toString())
              .exists(),
          isTrue,
        );
      } finally {
        await reopened.close();
        await tempDir.delete(recursive: true);
      }
    },
  );
}

Future<String> _writeJpeg(
  String directory,
  String filename,
  int red, {
  String? captureDate,
}) async {
  final file = File(p.join(directory, filename));
  await file.writeAsBytes(await _jpegBytes(red, captureDate: captureDate));
  return file.path;
}

Future<Uint8List> _jpegBytes(int red, {String? captureDate}) async {
  final image = img.Image(width: 120, height: 90);
  img.fill(image, color: img.ColorRgb8(red, 80, 140));
  if (captureDate == null) {
    return Uint8List.fromList(img.encodeJpg(image, quality: 90));
  }
  image.exif.imageIfd['DateTime'] = captureDate;
  image.exif.exifIfd['DateTimeOriginal'] = captureDate;
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}
