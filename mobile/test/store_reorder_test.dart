import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:site_photo_mobile/models/project_store.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late ProjectStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sprj_test_');
    final root = '${tempDir.path}/test.sprj';
    store = await ProjectStore.createProject(root, '測試工程');
  });

  tearDown(() async {
    await store.close();
    await tempDir.delete(recursive: true);
  });

  test('moveSection reorders sections', () async {
    // createProject already creates 3 default sections.
    final before = await store.sections();
    expect(before.length, 3);
    final firstName = before[0]['name'].toString();
    final secondName = before[1]['name'].toString();
    final thirdName = before[2]['name'].toString();

    // Move the last section up (direction -1).
    await store.moveSection(before[2]['id'].toString(), -1);

    final after = await store.sections();
    expect(after.length, 3);
    // Order should now be: first, third, second
    expect(after[0]['name'].toString(), firstName);
    expect(after[1]['name'].toString(), thirdName);
    expect(after[2]['name'].toString(), secondName);
  });

  test('moveSection down reorders sections', () async {
    final before = await store.sections();
    final firstName = before[0]['name'].toString();
    final secondName = before[1]['name'].toString();

    // Move the first section down (direction +1).
    await store.moveSection(before[0]['id'].toString(), 1);

    final after = await store.sections();
    expect(after[0]['name'].toString(), secondName);
    expect(after[1]['name'].toString(), firstName);
  });

  test('moveSlot reorders slots within a section', () async {
    final sections = await store.sections();
    // Find a section with multiple slots (the before_during_after one).
    final bdaSection = sections.firstWhere(
      (s) => s['layout_type'] == 'before_during_after',
      orElse: () => sections.first,
    );
    final sectionId = bdaSection['id'].toString();

    // Add extra slots to ensure we have at least 2.
    final slotsBefore = await store.slots(sectionId);
    if (slotsBefore.length < 2) {
      await store.addSlot(sectionId, '額外欄位A');
      await store.addSlot(sectionId, '額外欄位B');
    }

    final before = await store.slots(sectionId);
    expect(before.length, greaterThanOrEqualTo(2));
    final firstName = before[0]['name'].toString();
    final secondName = before[1]['name'].toString();

    // Move the first slot down.
    await store.moveSlot(before[0]['id'].toString(), 1);

    final after = await store.slots(sectionId);
    expect(after[0]['name'].toString(), secondName);
    expect(after[1]['name'].toString(), firstName);
  });
}
