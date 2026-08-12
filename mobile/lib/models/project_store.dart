import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../services/mosaic_renderer.dart';

/// Reads and writes the desktop-compatible .sprj project format.
/// A .sprj is a folder containing project.sqlite plus image subfolders.
class ProjectStore {
  final String root;
  late final Database db;

  ProjectStore(this.root);

  String get dbPath => p.join(root, 'project.sqlite');
  String get originalsDir => p.join(root, 'originals');
  String get thumbnailsDir => p.join(root, 'thumbnails');
  String get previewsDir => p.join(root, 'previews');

  Future<void> open() async {
    db = await openDatabase(dbPath, readOnly: false);
    await _initSchema();
  }

  Future<void> close() async => db.close();

  /// Create the full desktop-compatible schema (idempotent).
  Future<void> _initSchema() async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS project (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        name TEXT NOT NULL,
        project_code TEXT DEFAULT '',
        report_title TEXT DEFAULT '',
        client_name TEXT DEFAULT '',
        contractor_name TEXT DEFAULT '',
        manager_name TEXT DEFAULT '',
        location TEXT DEFAULT '',
        start_date TEXT DEFAULT '',
        end_date TEXT DEFAULT '',
        company_name TEXT DEFAULT '',
        logo_rel_path TEXT DEFAULT '',
        description TEXT DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        schema_version INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sections (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        location TEXT DEFAULT '',
        description TEXT DEFAULT '',
        layout_type TEXT NOT NULL DEFAULT 'single',
        position INTEGER NOT NULL,
        include_in_report INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS slots (
        id TEXT PRIMARY KEY,
        section_id TEXT NOT NULL REFERENCES sections(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        stage_type TEXT NOT NULL DEFAULT 'custom',
        position INTEGER NOT NULL,
        default_caption TEXT DEFAULT '',
        include_in_report INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS photos (
        id TEXT PRIMARY KEY,
        original_filename TEXT NOT NULL,
        original_rel_path TEXT NOT NULL,
        thumbnail_rel_path TEXT NOT NULL,
        preview_rel_path TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        mime_type TEXT DEFAULT '',
        file_size INTEGER NOT NULL DEFAULT 0,
        width INTEGER NOT NULL DEFAULT 0,
        height INTEGER NOT NULL DEFAULT 0,
        captured_at TEXT DEFAULT '',
        imported_at TEXT NOT NULL,
        camera_make TEXT DEFAULT '',
        camera_model TEXT DEFAULT '',
        rotation_degrees INTEGER NOT NULL DEFAULT 0,
        crop_json TEXT DEFAULT '',
        mosaic_json TEXT DEFAULT '',
        global_notes TEXT DEFAULT '',
        is_missing INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS placements (
        id TEXT PRIMARY KEY,
        photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
        slot_id TEXT REFERENCES slots(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        caption TEXT DEFAULT '',
        construction_location TEXT DEFAULT '',
        include_in_report INTEGER NOT NULL DEFAULT 1,
        is_primary INTEGER NOT NULL DEFAULT 0,
        is_human_confirmed INTEGER NOT NULL DEFAULT 0,
        number_text TEXT DEFAULT '',
        number_position TEXT DEFAULT 'top_right',
        number_color TEXT DEFAULT '#D32F2F',
        number_size TEXT DEFAULT 'medium',
        number_background_transparent INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS suggestions (
        id TEXT PRIMARY KEY,
        photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
        suggested_section_id TEXT REFERENCES sections(id) ON DELETE SET NULL,
        suggested_slot_id TEXT REFERENCES slots(id) ON DELETE SET NULL,
        confidence REAL NOT NULL DEFAULT 0,
        reason TEXT DEFAULT '',
        engine_name TEXT NOT NULL DEFAULT 'metadata',
        status TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT NOT NULL,
        reviewed_at TEXT DEFAULT ''
      )
    ''');
    await db.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_photos_sha256 ON photos(sha256)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_placements_slot ON placements(slot_id, position)',
    );
    // Seed the singleton project row if missing.
    final existing = await db.query('project', where: 'id = 1');
    if (existing.isEmpty) {
      final now = DateTime.now().toIso8601String();
      final folderName = p.basename(root);
      final name = folderName.endsWith('.sprj')
          ? folderName.substring(0, folderName.length - 5)
          : folderName;
      await db.insert('project', {
        'id': 1,
        'name': name,
        'report_title': name,
        'created_at': now,
        'updated_at': now,
        'schema_version': 1,
      });
    }
  }

  /// Create a new .sprj project folder with subfolders + schema.
  static Future<ProjectStore> createProject(
    String rootPath,
    String name,
  ) async {
    final root = Directory(rootPath);
    await root.create(recursive: true);
    for (final sub in [
      'originals',
      'thumbnails',
      'previews',
      'edits',
      'assets',
      'exports',
      'backups',
      'logs',
    ]) {
      await Directory(p.join(rootPath, sub)).create(recursive: true);
    }
    final store = ProjectStore(rootPath);
    await store.open();
    await store.updateProject({'name': name, 'report_title': name});
    await store.ensureDefaultSections();
    return store;
  }

  // ── Project metadata ──────────────────────────────────────────────
  Future<Map<String, dynamic>> project() async {
    final rows = await db.query('project', where: 'id = 1');
    return rows.isEmpty ? {} : rows.first;
  }

  // ── Sections ──────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> sections() async {
    return db.query('sections', orderBy: 'position, name');
  }

  // ── Slots ─────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> slots(String sectionId) async {
    return db.query(
      'slots',
      where: 'section_id = ?',
      whereArgs: [sectionId],
      orderBy: 'position, name',
    );
  }

  // ── Photos ────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> photos() async {
    return db.query(
      'photos',
      where: "deleted_at = ''",
      orderBy: 'imported_at, original_filename',
    );
  }

  Future<Map<String, dynamic>?> photo(String id) async {
    final rows = await db.query('photos', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// Unclassified photos sorted by capture date (EXIF), matching desktop.
  Future<List<Map<String, dynamic>>> unclassifiedPhotos() async {
    return db.rawQuery('''
      SELECT ph.* FROM photos ph
      JOIN placements pl ON pl.photo_id = ph.id AND pl.slot_id IS NULL
      WHERE ph.deleted_at = ''
        AND NOT EXISTS (SELECT 1 FROM placements placed
                        WHERE placed.photo_id = ph.id AND placed.slot_id IS NOT NULL)
      ORDER BY CASE WHEN ph.captured_at != '' THEN 0 ELSE 1 END,
               ph.captured_at, pl.position, pl.created_at
    ''');
  }

  /// Photos placed in a slot.  Sorting is a view preference and never changes
  /// the stored manual positions used by drag-and-drop and report output.
  Future<List<Map<String, dynamic>>> placementsForSlot(
    String? slotId, {
    String? sortMode,
  }) async {
    final rows = List<Map<String, dynamic>>.from(
      await db.rawQuery('''
      SELECT pl.*, ph.original_filename, ph.thumbnail_rel_path,
             ph.preview_rel_path, ph.original_rel_path, ph.captured_at,
             ph.width, ph.height, ph.rotation_degrees
      FROM placements pl JOIN photos ph ON ph.id = pl.photo_id
      WHERE ${slotId == null ? 'pl.slot_id IS NULL' : 'pl.slot_id = ?'}
        AND ph.deleted_at = ''
      ORDER BY pl.position, pl.created_at
    ''', slotId == null ? null : [slotId]),
    );
    final mode = sortMode ?? (slotId == null ? 'time_asc' : 'manual');
    if (mode == 'manual') return rows;

    int positionOf(Map<String, dynamic> row) =>
        int.tryParse('${row['position'] ?? 0}') ?? 0;
    String capturedOf(Map<String, dynamic> row) =>
        (row['captured_at'] ?? '').toString().trim();

    if (mode == 'filename_asc' || mode == 'filename_desc') {
      rows.sort((a, b) {
        final result = _naturalFilenameCompare(
          (a['original_filename'] ?? '').toString(),
          (b['original_filename'] ?? '').toString(),
        );
        if (result != 0) return mode == 'filename_desc' ? -result : result;
        return positionOf(a).compareTo(positionOf(b));
      });
      return rows;
    }

    rows.sort((a, b) {
      final aDate = capturedOf(a);
      final bDate = capturedOf(b);
      final aMissing = aDate.isEmpty;
      final bMissing = bDate.isEmpty;
      if (aMissing != bMissing) return aMissing ? 1 : -1;
      final result = aDate.compareTo(bDate);
      if (result != 0) return mode == 'time_desc' ? -result : result;
      return positionOf(a).compareTo(positionOf(b));
    });
    return rows;
  }

  int _naturalFilenameCompare(String left, String right) {
    final pattern = RegExp(r'(\d+|\D+)');
    final a = pattern
        .allMatches(left.toLowerCase())
        .map((m) => m.group(0)!)
        .toList();
    final b = pattern
        .allMatches(right.toLowerCase())
        .map((m) => m.group(0)!)
        .toList();
    for (var i = 0; i < a.length && i < b.length; i++) {
      final aPart = a[i];
      final bPart = b[i];
      final aNumber = int.tryParse(aPart);
      final bNumber = int.tryParse(bPart);
      final result = aNumber != null && bNumber != null
          ? aNumber.compareTo(bNumber)
          : aPart.compareTo(bPart);
      if (result != 0) return result;
    }
    return a.length.compareTo(b.length);
  }

  // ── Counts ────────────────────────────────────────────────────────
  Future<int> countPhotos() async {
    final r = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM photos WHERE deleted_at = ''",
    );
    return Sqflite.firstIntValue(r) ?? 0;
  }

  Future<int> countUnclassified() async {
    final r = await db.rawQuery('''
      SELECT COUNT(DISTINCT ph.id) AS c FROM photos ph
      JOIN placements pl ON pl.photo_id = ph.id AND pl.slot_id IS NULL
      WHERE ph.deleted_at = ''
        AND NOT EXISTS (SELECT 1 FROM placements placed
                        WHERE placed.photo_id = ph.id AND placed.slot_id IS NOT NULL)
    ''');
    return Sqflite.firstIntValue(r) ?? 0;
  }

  Future<int> countForSlot(String slotId) async {
    final r = await db.rawQuery(
      '''
      SELECT COUNT(*) AS c FROM placements pl JOIN photos ph ON ph.id = pl.photo_id
      WHERE pl.slot_id = ? AND ph.deleted_at = ''
    ''',
      [slotId],
    );
    return Sqflite.firstIntValue(r) ?? 0;
  }

  // ── Mutations ─────────────────────────────────────────────────────
  Future<void> updatePhoto(String id, Map<String, dynamic> values) async {
    final allowed = {
      'rotation_degrees',
      'crop_json',
      'mosaic_json',
      'global_notes',
    };
    final filtered = {
      for (final e in values.entries)
        if (allowed.contains(e.key)) e.key: e.value,
    };
    if (filtered.isEmpty) return;
    await db.update('photos', filtered, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updatePlacement(String id, Map<String, dynamic> values) async {
    final allowed = {
      'caption',
      'construction_location',
      'include_in_report',
      'is_human_confirmed',
      'number_text',
    };
    final filtered = {
      for (final e in values.entries)
        if (allowed.contains(e.key)) e.key: e.value,
    };
    if (filtered.isEmpty) return;
    filtered['updated_at'] = DateTime.now().toIso8601String();
    await db.update('placements', filtered, where: 'id = ?', whereArgs: [id]);
  }

  /// Move photos from source slot to target slot (cross-field classify).
  Future<void> relocatePhotos(
    List<String> photoIds,
    String? sourceSlotId,
    String? targetSlotId, {
    bool confirmed = true,
  }) async {
    if (photoIds.isEmpty) return;
    final now = DateTime.now().toIso8601String();
    // Keep the delete and insert in one transaction.  Older Android project
    // databases can reject a sqflite Batch commit with a misleading
    // "Unsupported operation: read-only" error even though normal updates
    // work.  A transaction also prevents a failed classification from
    // leaving the photo without a placement.
    await db.transaction((txn) async {
      for (final pid in photoIds) {
        await txn.delete(
          'placements',
          where: sourceSlotId == null
              ? 'photo_id = ? AND slot_id IS NULL'
              : 'photo_id = ? AND slot_id = ?',
          whereArgs: sourceSlotId == null ? [pid] : [pid, sourceSlotId],
        );
      }

      final maxPos = await txn.rawQuery(
        "SELECT COALESCE(MAX(position), -1) + 1 AS np FROM placements WHERE slot_id ${targetSlotId == null ? 'IS NULL' : '= ?'}",
        targetSlotId == null ? null : [targetSlotId],
      );
      var pos = Sqflite.firstIntValue(maxPos) ?? 0;
      for (final pid in photoIds) {
        await txn.insert('placements', {
          'id': 'PLC-${DateTime.now().microsecondsSinceEpoch}-$pos',
          'photo_id': pid,
          'slot_id': targetSlotId,
          'position': pos++,
          'created_at': now,
          'updated_at': now,
          'is_human_confirmed': confirmed ? 1 : 0,
          'include_in_report': 1,
        });
      }
    });
  }

  Future<Map<String, dynamic>?> placementForPhoto(
    String photoId,
    String? slotId,
  ) async {
    final rows = slotId == null
        ? await db.query(
            'placements',
            where: 'photo_id = ? AND slot_id IS NULL',
            whereArgs: [photoId],
            orderBy: 'created_at',
            limit: 1,
          )
        : await db.query(
            'placements',
            where: 'photo_id = ? AND slot_id = ?',
            whereArgs: [photoId, slotId],
            orderBy: 'created_at',
            limit: 1,
          );
    return rows.isEmpty ? null : rows.first;
  }

  // ── Project metadata mutation ─────────────────────────────────────
  Future<void> updateProject(Map<String, dynamic> values) async {
    const allowed = {
      'name',
      'project_code',
      'report_title',
      'client_name',
      'contractor_name',
      'manager_name',
      'location',
      'start_date',
      'end_date',
      'company_name',
      'logo_rel_path',
      'description',
    };
    final filtered = {
      for (final e in values.entries)
        if (allowed.contains(e.key)) e.key: e.value,
    };
    if (filtered.isEmpty) return;
    filtered['updated_at'] = DateTime.now().toIso8601String();
    await db.update('project', filtered, where: 'id = 1');
  }

  // ── Section management ────────────────────────────────────────────
  Future<String> addSection(String name, {String layoutType = 'single'}) async {
    final sectionId = 'SEC-${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().toIso8601String();
    final maxPos = await db.rawQuery(
      'SELECT COALESCE(MAX(position), -1) + 1 AS np FROM sections',
    );
    final position = Sqflite.firstIntValue(maxPos) ?? 0;
    await db.insert('sections', {
      'id': sectionId,
      'name': name,
      'layout_type': layoutType,
      'position': position,
      'include_in_report': 1,
      'created_at': now,
      'updated_at': now,
    });
    await _ensureSlots(sectionId, layoutType);
    return sectionId;
  }

  Future<void> _ensureSlots(String sectionId, String layoutType) async {
    final existing = await slots(sectionId);
    if (existing.isNotEmpty) return;
    const layouts = {
      'single': [
        ['項目照片', 'custom'],
      ],
      'before_during_after': [
        ['施工前', 'before'],
        ['施工中', 'during'],
        ['施工後', 'after'],
      ],
      'before_after': [
        ['改善前', 'before'],
        ['改善後', 'after'],
      ],
    };
    final names = layouts[layoutType] ?? layouts['single']!;
    final now = DateTime.now().toIso8601String();
    for (var i = 0; i < names.length; i++) {
      await db.insert('slots', {
        'id': 'SLOT-${DateTime.now().microsecondsSinceEpoch}-$i',
        'section_id': sectionId,
        'name': names[i][0],
        'stage_type': names[i][1],
        'position': i,
        'include_in_report': 1,
        'created_at': now,
        'updated_at': now,
      });
    }
  }

  Future<void> ensureDefaultSections() async {
    final existing = await sections();
    if (existing.isNotEmpty) return;
    await addSection('施工前現況', layoutType: 'single');
    await addSection('施工中紀錄', layoutType: 'before_during_after');
    await addSection('完工照片', layoutType: 'single');
  }

  Future<void> renameSection(String sectionId, String name) async {
    await db.update(
      'sections',
      {'name': name, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [sectionId],
    );
  }

  Future<void> deleteSection(String sectionId) async {
    await db.rawUpdate(
      'UPDATE placements SET slot_id = NULL WHERE slot_id IN (SELECT id FROM slots WHERE section_id = ?)',
      [sectionId],
    );
    await db.delete('sections', where: 'id = ?', whereArgs: [sectionId]);
    await _normalizeSectionPositions();
  }

  Future<void> moveSection(String sectionId, int direction) async {
    final rows = List<Map<String, dynamic>>.from(await sections());
    final index = rows.indexWhere((r) => r['id'] == sectionId);
    if (index < 0) return;
    final other = index + direction;
    if (other < 0 || other >= rows.length) return;
    final tmp = rows[index];
    rows[index] = rows[other];
    rows[other] = tmp;
    final now = DateTime.now().toIso8601String();
    for (var i = 0; i < rows.length; i++) {
      await db.update(
        'sections',
        {'position': i, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [rows[i]['id']],
      );
    }
  }

  Future<void> _normalizeSectionPositions() async {
    final rows = await sections();
    for (var i = 0; i < rows.length; i++) {
      await db.update(
        'sections',
        {'position': i},
        where: 'id = ?',
        whereArgs: [rows[i]['id']],
      );
    }
  }

  // ── Slot management ───────────────────────────────────────────────
  Future<String> addSlot(
    String sectionId,
    String name, {
    String stageType = 'custom',
  }) async {
    final slotId = 'SLOT-${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().toIso8601String();
    final maxPos = await db.rawQuery(
      'SELECT COALESCE(MAX(position), -1) + 1 AS np FROM slots WHERE section_id = ?',
      [sectionId],
    );
    final position = Sqflite.firstIntValue(maxPos) ?? 0;
    await db.insert('slots', {
      'id': slotId,
      'section_id': sectionId,
      'name': name,
      'stage_type': stageType,
      'position': position,
      'include_in_report': 1,
      'created_at': now,
      'updated_at': now,
    });
    return slotId;
  }

  Future<void> renameSlot(String slotId, String name) async {
    await db.update(
      'slots',
      {'name': name, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [slotId],
    );
  }

  Future<void> deleteSlot(String slotId) async {
    await db.update(
      'placements',
      {'slot_id': null},
      where: 'slot_id = ?',
      whereArgs: [slotId],
    );
    await db.delete('slots', where: 'id = ?', whereArgs: [slotId]);
  }

  /// Move a slot up/down within its section.
  Future<void> moveSlot(String slotId, int direction) async {
    // Find the slot's section.
    final slotRows = await db.query(
      'slots',
      where: 'id = ?',
      whereArgs: [slotId],
    );
    if (slotRows.isEmpty) return;
    final sectionId = slotRows.first['section_id'].toString();
    final rows = List<Map<String, dynamic>>.from(await slots(sectionId));
    final index = rows.indexWhere((r) => r['id'] == slotId);
    if (index < 0) return;
    final other = index + direction;
    if (other < 0 || other >= rows.length) return;
    final tmp = rows[index];
    rows[index] = rows[other];
    rows[other] = tmp;
    final now = DateTime.now().toIso8601String();
    for (var i = 0; i < rows.length; i++) {
      await db.update(
        'slots',
        {'position': i, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [rows[i]['id']],
      );
    }
  }

  // ── Numbering ─────────────────────────────────────────────────────
  Future<void> numberSlot(
    String? slotId, {
    String position = 'top_right',
    String color = '#D32F2F',
    String size = '72',
    bool transparent = false,
  }) async {
    final rows = await placementsForSlot(slotId);
    final now = DateTime.now().toIso8601String();
    for (var i = 0; i < rows.length; i++) {
      await db.update(
        'placements',
        {
          'number_text': '${i + 1}',
          'number_position': position,
          'number_color': color,
          'number_size': size,
          'number_background_transparent': transparent ? 1 : 0,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [rows[i]['id']],
      );
    }
  }

  Future<void> clearSlotNumbers(String? slotId) async {
    final now = DateTime.now().toIso8601String();
    if (slotId == null) {
      await db.rawUpdate(
        "UPDATE placements SET number_text = '', updated_at = ? WHERE slot_id IS NULL",
        [now],
      );
    } else {
      await db.rawUpdate(
        "UPDATE placements SET number_text = '', updated_at = ? WHERE slot_id = ?",
        [now, slotId],
      );
    }
  }

  // ── Report rows ───────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> allReportRows() async {
    return db.rawQuery('''
      SELECT s.id AS section_id, s.name AS section_name, s.position AS section_position,
             sl.id AS slot_id, sl.name AS slot_name, sl.position AS slot_position,
             p.id AS placement_id, p.photo_id AS photo_id,
             p.position AS photo_position, p.caption,
             p.construction_location, p.include_in_report, p.number_text, ph.*
      FROM sections s JOIN slots sl ON sl.section_id = s.id
      LEFT JOIN placements p ON p.slot_id = sl.id AND p.include_in_report = 1
      LEFT JOIN photos ph ON ph.id = p.photo_id AND ph.deleted_at = ''
      WHERE s.include_in_report = 1 AND sl.include_in_report = 1
      ORDER BY s.position, sl.position, p.position, p.created_at
    ''');
  }

  // ── Deleted photos / restore ──────────────────────────────────────
  Future<List<Map<String, dynamic>>> deletedPhotos() async {
    return db.query(
      'photos',
      where: "deleted_at != ''",
      orderBy: 'deleted_at DESC',
    );
  }

  Future<int> restorePhotos(List<String> photoIds) async {
    var restored = 0;
    for (final photoId in photoIds) {
      final rows = await db.query(
        'photos',
        where: "id = ? AND deleted_at != ''",
        whereArgs: [photoId],
        limit: 1,
      );
      if (rows.isEmpty) continue;
      await db.update(
        'photos',
        {'deleted_at': ''},
        where: 'id = ?',
        whereArgs: [photoId],
      );
      final existing = await db.query(
        'placements',
        where: 'photo_id = ? AND slot_id IS NULL',
        whereArgs: [photoId],
        limit: 1,
      );
      if (existing.isEmpty) {
        final now = DateTime.now().toIso8601String();
        final maxPos = await db.rawQuery(
          'SELECT COALESCE(MAX(position), -1) + 1 AS np FROM placements WHERE slot_id IS NULL',
        );
        final pos = Sqflite.firstIntValue(maxPos) ?? 0;
        await db.insert('placements', {
          'id': 'PLC-${DateTime.now().microsecondsSinceEpoch}',
          'photo_id': photoId,
          'slot_id': null,
          'position': pos,
          'created_at': now,
          'updated_at': now,
          'is_human_confirmed': 0,
          'include_in_report': 1,
        });
      }
      restored++;
    }
    return restored;
  }

  /// Soft-delete photos (keeps originals on disk).
  Future<void> deletePhotos(List<String> photoIds) async {
    final now = DateTime.now().toIso8601String();
    for (final photoId in photoIds) {
      await db.delete(
        'placements',
        where: 'photo_id = ?',
        whereArgs: [photoId],
      );
      await db.update(
        'photos',
        {'deleted_at': now},
        where: 'id = ?',
        whereArgs: [photoId],
      );
    }
  }

  // ── AI suggestions ────────────────────────────────────────────────
  static String _normalizeLabel(String value) {
    return value.toLowerCase().replaceAll(' ', '').replaceAll('／', '/');
  }

  /// Recent human-confirmed placements as few-shot examples for AI.
  Future<List<Map<String, dynamic>>> confirmedExamples({int limit = 5}) async {
    return db.rawQuery('''
      SELECT ph.original_filename AS filename, s.name AS section, sl.name AS slot
      FROM placements p
      JOIN photos ph ON ph.id = p.photo_id
      JOIN slots sl ON sl.id = p.slot_id
      JOIN sections s ON s.id = sl.section_id
      WHERE p.is_human_confirmed = 1 AND p.slot_id IS NOT NULL AND ph.deleted_at = ''
      ORDER BY p.updated_at DESC
      LIMIT $limit
    ''');
  }

  /// Save AI suggestions and auto-place confident results. Returns (added, autoPlaced).
  Future<(int, int)> addAiSuggestions(
    List<Map<String, dynamic>> results,
  ) async {
    final allSections = await sections();
    var added = 0;
    var autoPlaced = 0;
    final now = DateTime.now().toIso8601String();
    for (final result in results) {
      final photoId = (result['photo_id'] ?? '').toString();
      if (photoId.isEmpty) continue;
      final sectionName = _normalizeLabel((result['section'] ?? '').toString());
      final slotName = _normalizeLabel((result['slot'] ?? '').toString());
      Map<String, dynamic>? section;
      for (final s in allSections) {
        if (_normalizeLabel(s['name'].toString()) == sectionName) {
          section = s;
          break;
        }
      }
      Map<String, dynamic>? slot;
      if (section != null) {
        final slotRows = await slots(section['id'].toString());
        for (final sl in slotRows) {
          if (_normalizeLabel(sl['name'].toString()) == slotName) {
            slot = sl;
            break;
          }
        }
      }
      await db.delete(
        'suggestions',
        where: "photo_id = ? AND status = 'pending'",
        whereArgs: [photoId],
      );
      var confidence = 0.0;
      final rawConf = result['confidence'];
      if (rawConf is num) confidence = rawConf.toDouble();
      await db.insert('suggestions', {
        'id': 'SUG-${DateTime.now().microsecondsSinceEpoch}-$added',
        'photo_id': photoId,
        'suggested_section_id': section?['id'],
        'suggested_slot_id': slot?['id'],
        'confidence': confidence,
        'reason': (result['reason'] ?? 'AI 視覺分類建議').toString(),
        'engine_name': 'vision_api',
        'status': 'pending',
        'created_at': now,
      });
      added++;
      if (slot != null && confidence >= 0.55) {
        await relocatePhotos(
          [photoId],
          null,
          slot['id'].toString(),
          confirmed: false,
        );
        autoPlaced++;
      }
    }
    return (added, autoPlaced);
  }

  Future<List<Map<String, dynamic>>> suggestions() async {
    return db.rawQuery('''
      SELECT sug.*, ph.original_filename, s.name AS section_name, sl.name AS slot_name
      FROM suggestions sug JOIN photos ph ON ph.id = sug.photo_id
      LEFT JOIN sections s ON s.id = sug.suggested_section_id
      LEFT JOIN slots sl ON sl.id = sug.suggested_slot_id
      WHERE sug.status = 'pending' ORDER BY sug.confidence DESC
    ''');
  }

  Future<void> acceptSuggestions(List<String> suggestionIds) async {
    final now = DateTime.now().toIso8601String();
    for (final id in suggestionIds) {
      final rows = await db.query(
        'suggestions',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (rows.isEmpty || rows.first['suggested_slot_id'] == null) continue;
      final photoId = rows.first['photo_id'].toString();
      final targetSlot = rows.first['suggested_slot_id'].toString();
      final placements = await db.query(
        'placements',
        where: 'photo_id = ?',
        whereArgs: [photoId],
        orderBy: 'created_at',
      );
      final alreadyThere = placements.any((p) => p['slot_id'] == targetSlot);
      final humanConfirmed = placements.any(
        (p) => (p['is_human_confirmed'] ?? 0) == 1,
      );
      String status;
      if (alreadyThere) {
        status = 'accepted';
      } else if (humanConfirmed) {
        status = 'corrected';
      } else {
        final source = placements.firstWhere(
          (p) => p['slot_id'] != null,
          orElse: () => <String, dynamic>{},
        );
        await relocatePhotos(
          [photoId],
          source['slot_id']?.toString(),
          targetSlot,
          confirmed: true,
        );
        status = 'accepted';
      }
      await db.update(
        'suggestions',
        {'status': status, 'reviewed_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  Future<void> rejectSuggestions(List<String> suggestionIds) async {
    final now = DateTime.now().toIso8601String();
    for (final id in suggestionIds) {
      final rows = await db.query(
        'suggestions',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (rows.isEmpty) continue;
      final photoId = rows.first['photo_id'].toString();
      final placements = await db.query(
        'placements',
        where: 'photo_id = ? AND slot_id IS NOT NULL',
        whereArgs: [photoId],
        orderBy: 'created_at',
      );
      final source = placements.isNotEmpty
          ? placements.first['slot_id'].toString()
          : null;
      await relocatePhotos([photoId], source, null, confirmed: true);
      await db.update(
        'suggestions',
        {'status': 'rejected', 'reviewed_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  // ── File helpers ──────────────────────────────────────────────────
  File thumbnailFile(String relPath) => File(p.join(root, relPath));
  File previewFile(String relPath) => File(p.join(root, relPath));
  File originalFile(String relPath) => File(p.join(root, relPath));

  /// Render a photo with rotation + mosaic applied (cached in edits/).
  /// FAST PATH: if no rotation and no mosaic, returns the pre-generated
  /// thumbnail/preview directly without any decode/re-encode.
  Future<File> renderedPhotoPath(String photoId, {int maxSide = 1600}) async {
    final photo = await this.photo(photoId);
    if (photo == null) return originalFile('');
    final rotation = (photo['rotation_degrees'] ?? 0) as int;
    final mosaicJson = (photo['mosaic_json'] ?? '').toString();

    // Fast path: nothing to apply → use pre-generated files (no re-encoding).
    if (rotation == 0 && mosaicJson.isEmpty) {
      if (maxSide <= 400) {
        final thumb = thumbnailFile(
          (photo['thumbnail_rel_path'] ?? '').toString(),
        );
        if (await thumb.exists()) return thumb;
      }
      final preview = previewFile((photo['preview_rel_path'] ?? '').toString());
      if (await preview.exists()) return preview;
      return originalFile((photo['original_rel_path'] ?? '').toString());
    }

    // Slow path: apply rotation/mosaic with caching.
    final original = originalFile(
      (photo['original_rel_path'] ?? '').toString(),
    );
    if (!await original.exists()) return original;
    final cacheKey = sha1
        .convert(utf8.encode('$photoId:$rotation:$mosaicJson:$maxSide'))
        .toString()
        .substring(0, 12);
    final output = File(p.join(root, 'edits', '${photoId}_$cacheKey.jpg'));
    if (await output.exists()) return output;
    try {
      final decoded = img.decodeImage(await original.readAsBytes());
      if (decoded == null) return original;
      img.Image image = img.bakeOrientation(decoded); // apply EXIF orientation
      if (rotation != 0) {
        image = img.copyRotate(image, angle: -rotation.toDouble());
      }
      if (mosaicJson.isNotEmpty) {
        try {
          final regions = (jsonDecode(mosaicJson) as List)
              .map((e) => MosaicRegion.fromJson(e as Map<String, dynamic>))
              .toList();
          if (regions.isNotEmpty) {
            image = MosaicRenderer.apply(image, regions);
          }
        } catch (_) {}
      }
      if (image.width > maxSide || image.height > maxSide) {
        image = img.copyResize(
          image,
          width: image.width > image.height ? maxSide : null,
          height: image.height >= image.width ? maxSide : null,
        );
      }
      await Directory(p.join(root, 'edits')).create(recursive: true);
      await output.writeAsBytes(img.encodeJpg(image, quality: 90));
      return output;
    } catch (_) {
      return original;
    }
  }

  /// Render a placement's photo with the number badge overlaid (cached).
  /// FAST PATH: if no number badge, delegates to renderedPhotoPath (which
  /// itself fast-paths when there's no rotation/mosaic).
  Future<File> renderedPlacementPath(
    String placementId, {
    int maxSide = 1600,
  }) async {
    final rows = await db.query(
      'placements',
      where: 'id = ?',
      whereArgs: [placementId],
    );
    if (rows.isEmpty) return originalFile('');
    final placement = rows.first;
    final number = (placement['number_text'] ?? '').toString().trim();
    // No number badge → just return the base rendered photo (fast path applies).
    if (number.isEmpty) {
      return renderedPhotoPath(
        placement['photo_id'].toString(),
        maxSide: maxSide,
      );
    }
    // Has number badge → need to render base + overlay badge.
    final base = await renderedPhotoPath(
      placement['photo_id'].toString(),
      maxSide: maxSide,
    );
    final photo = await this.photo(placement['photo_id'].toString());
    final cacheKey = sha1
        .convert(
          utf8.encode(
            '$placementId:${photo?['rotation_degrees']}:${photo?['mosaic_json']}:$number:${placement['number_position']}:${placement['number_color']}:${placement['number_size']}:${placement['number_background_transparent']}:$maxSide',
          ),
        )
        .toString()
        .substring(0, 12);
    final output = File(
      p.join(root, 'edits', 'placement_${placementId}_$cacheKey.jpg'),
    );
    if (await output.exists()) return output;
    try {
      var image = img.decodeImage(await base.readAsBytes());
      if (image == null) return base;
      image = _drawNumberBadge(image, number, placement);
      await Directory(p.join(root, 'edits')).create(recursive: true);
      await output.writeAsBytes(img.encodeJpg(image, quality: 92));
      return output;
    } catch (_) {
      return base;
    }
  }

  img.Image _drawNumberBadge(
    img.Image image,
    String number,
    Map<String, dynamic> placement,
  ) {
    final rawSize = (placement['number_size'] ?? '72')
        .toString()
        .trim()
        .toLowerCase();
    const legacy = {'small': 48, 'medium': 72, 'large': 108};
    var diameter = int.tryParse(rawSize) ?? legacy[rawSize] ?? 72;
    diameter = diameter.clamp(
      16,
      math.max(16, math.min(image.width, image.height) ~/ 2),
    );
    final margin = math.max(8, diameter ~/ 4);
    final colorHex = (placement['number_color'] ?? '#D32F2F').toString();
    final color = _hexColor(colorHex);
    final transparent = (placement['number_background_transparent'] ?? 0) == 1;
    final position = (placement['number_position'] ?? 'top_right').toString();

    // Approx text size.
    final fontSize = math.max(14, (diameter * 0.55).round());
    final textWidth = number.length * (fontSize * 0.6);
    final badgeW = math.max(diameter, textWidth + diameter ~/ 2).round();
    final badgeH = math.max(diameter, fontSize + diameter ~/ 2).round();

    int left, top;
    switch (position) {
      case 'top_left':
        left = margin;
        top = margin;
        break;
      case 'bottom_left':
        left = margin;
        top = image.height - margin - badgeH;
        break;
      case 'bottom_right':
        left = image.width - margin - badgeW;
        top = image.height - margin - badgeH;
        break;
      default: // top_right
        left = image.width - margin - badgeW;
        top = margin;
    }

    if (!transparent) {
      // image package has no fillRoundRect; draw a solid rect badge.
      img.fillRect(
        image,
        x1: left,
        y1: top,
        x2: left + badgeW,
        y2: top + badgeH,
        color: color,
      );
    }
    // Draw text (centered in badge). The image package's text drawing is
    // bitmap-font based; good enough for short number labels.
    img.drawString(
      image,
      number,
      font: img.arial24,
      x: left + (badgeW - number.length * 12) ~/ 2,
      y: top + (badgeH - 24) ~/ 2,
      color: transparent ? color : img.ColorRgba8(255, 255, 255, 255),
    );
    return image;
  }

  img.Color _hexColor(String hex) {
    var h = hex.replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    final v = int.tryParse(h, radix: 16) ?? 0xFFD32F2F;
    return img.ColorRgba8(
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
      (v >> 24) & 0xFF,
    );
  }

  /// Save a project.json manifest backup (matches desktop save_manifest).
  Future<void> saveManifest() async {
    final project = await this.project();
    final sections = await this.sections();
    final data = {...project, 'sections': sections};
    await File(
      p.join(root, 'project.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  /// Creates a complete sibling-folder backup without changing the project.
  /// A sibling destination is used so the backup cannot recursively contain
  /// itself when the source project already has a backups folder.
  Future<String> backupProject() async {
    final source = Directory(root);
    if (!await source.exists()) throw StateError('找不到工程資料夾');
    final parent = source.parent;
    final base = p.basename(root).replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[-:]'), '')
        .replaceFirst('T', '_')
        .split('.')
        .first;
    var destination = Directory(p.join(parent.path, '${base}_備份_$stamp.sprj'));
    var suffix = 1;
    while (await destination.exists()) {
      destination = Directory(
        p.join(parent.path, '${base}_備份_${stamp}_$suffix.sprj'),
      );
      suffix++;
    }
    await _copyDirectory(source, destination);
    return destination.path;
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final target = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(target));
      } else if (entity is File) {
        await entity.copy(target);
      }
    }
  }

  /// Rebuild missing thumbnail/preview images. Returns count rebuilt.
  Future<int> rebuildThumbnails() async {
    final marker = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['thumbnail_rebuild_v1'],
      limit: 1,
    );
    if (marker.isNotEmpty && marker.first['value'] == '1') return 0;

    final photos = await this.photos();
    var rebuilt = 0;
    try {
      for (final photo in photos) {
        final thumb = thumbnailFile(
          (photo['thumbnail_rel_path'] ?? '').toString(),
        );
        final preview = previewFile(
          (photo['preview_rel_path'] ?? '').toString(),
        );
        final original = originalFile(
          (photo['original_rel_path'] ?? '').toString(),
        );
        if (await thumb.exists() && await preview.exists()) continue;
        if (!await original.exists()) continue;
        try {
          final decoded = img.decodeImage(await original.readAsBytes());
          if (decoded == null) continue;
          final oriented = img.bakeOrientation(decoded);
          if (!await thumb.exists()) {
            final t = img.copyResize(oriented, width: 320);
            await thumb.writeAsBytes(img.encodeJpg(t, quality: 82));
          }
          if (!await preview.exists()) {
            final pv = img.copyResize(oriented, width: 1600);
            await preview.writeAsBytes(img.encodeJpg(pv, quality: 88));
          }
          rebuilt++;
        } catch (_) {}
      }
    } finally {
      try {
        await db.insert('settings', {
          'key': 'thumbnail_rebuild_v1',
          'value': '1',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } catch (_) {}
    }
    return rebuilt;
  }

  /// Fill missing capture timestamps from the original photo EXIF metadata.
  /// Existing projects created before EXIF import support can be repaired
  /// without changing the original files.
  Future<int> backfillCapturedAt() async {
    final marker = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['captured_at_backfill_v1'],
      limit: 1,
    );
    if (marker.isNotEmpty && marker.first['value'] == '1') return 0;

    final rows = await db.query(
      'photos',
      columns: ['id', 'original_rel_path'],
      where: "deleted_at = '' AND (captured_at = '' OR captured_at IS NULL)",
    );
    var updated = 0;
    try {
      for (final row in rows) {
        final file = originalFile((row['original_rel_path'] ?? '').toString());
        if (!await file.exists()) continue;
        try {
          final extension = p.extension(file.path).toLowerCase();
          // JPEG EXIF can be read without decoding the full image.  This is
          // important when opening an older project containing hundreds of
          // large originals.
          if (extension != '.jpg' && extension != '.jpeg') continue;
          final bytes = await file.readAsBytes();
          final capturedAt = _extractCapturedAt(bytes, extension, null);
          if (capturedAt.isEmpty) continue;
          await db.update(
            'photos',
            {'captured_at': capturedAt},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
          updated++;
        } catch (_) {
          // A damaged or unsupported image should not prevent the project
          // from opening; it simply remains without a capture timestamp.
        }
      }
    } finally {
      // The scan is a one-time repair for projects created before EXIF
      // import support.  New imports already save captured_at themselves.
      try {
        await db.insert('settings', {
          'key': 'captured_at_backfill_v1',
          'value': '1',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } catch (_) {}
    }
    return updated;
  }

  /// Per-slot numbering status for the export preview.
  Future<List<Map<String, dynamic>>> slotNumberSummary() async {
    return db.rawQuery('''
      SELECT s.name AS section_name, sl.name AS slot_name,
             COUNT(*) AS total,
             SUM(CASE WHEN p.number_text != '' THEN 1 ELSE 0 END) AS numbered
      FROM placements p
      JOIN slots sl ON sl.id = p.slot_id
      JOIN sections s ON s.id = sl.section_id
      JOIN photos ph ON ph.id = p.photo_id AND ph.deleted_at = ''
      WHERE p.slot_id IS NOT NULL AND p.include_in_report = 1
      GROUP BY sl.id
      ORDER BY s.position, sl.position
    ''');
  }

  /// Remove placements (move photos back to unclassified by deleting slot placement).
  Future<void> removePlacements(List<String> photoIds, String? slotId) async {
    for (final photoId in photoIds) {
      if (slotId == null) {
        await db.delete(
          'placements',
          where: 'photo_id = ? AND slot_id IS NULL',
          whereArgs: [photoId],
        );
      } else {
        await db.delete(
          'placements',
          where: 'photo_id = ? AND slot_id = ?',
          whereArgs: [photoId, slotId],
        );
      }
    }
  }

  /// Reorder photos within a slot.
  Future<void> setOrder(String? slotId, List<String> photoIds) async {
    final now = DateTime.now().toIso8601String();
    for (var i = 0; i < photoIds.length; i++) {
      if (slotId == null) {
        await db.rawUpdate(
          'UPDATE placements SET position = ?, updated_at = ? WHERE photo_id = ? AND slot_id IS NULL',
          [i, now, photoIds[i]],
        );
      } else {
        await db.rawUpdate(
          'UPDATE placements SET position = ?, updated_at = ? WHERE photo_id = ? AND slot_id = ?',
          [i, now, photoIds[i], slotId],
        );
      }
    }
  }

  /// Duplicate a photo as a mosaic version (keeps original). Returns new photo id.
  Future<String> duplicatePhotoWithMosaic(
    String photoId,
    String mosaicJson,
    String? slotId,
  ) async {
    final source = await photo(photoId);
    if (source == null) throw Exception('找不到要建立馬賽克副本的照片');
    final newPhotoId = 'PHO-${DateTime.now().microsecondsSinceEpoch}';
    final sourceName = p.basename(
      (source['original_filename'] ?? 'photo').toString(),
    );
    final stem = p.basenameWithoutExtension(sourceName);
    final ext = p.extension(sourceName);
    final dupName = '${stem}_馬賽克$ext';
    final now = DateTime.now().toIso8601String();
    await db.insert('photos', {
      'id': newPhotoId,
      'original_filename': dupName,
      'original_rel_path': source['original_rel_path'],
      'thumbnail_rel_path': source['thumbnail_rel_path'],
      'preview_rel_path': source['preview_rel_path'],
      'sha256': source['sha256'],
      'mime_type': source['mime_type'],
      'file_size': source['file_size'],
      'width': source['width'],
      'height': source['height'],
      'captured_at': source['captured_at'],
      'imported_at': now,
      'camera_make': source['camera_make'],
      'camera_model': source['camera_model'],
      'rotation_degrees': source['rotation_degrees'],
      'crop_json': source['crop_json'],
      'mosaic_json': mosaicJson,
      'global_notes': source['global_notes'],
      'is_missing': source['is_missing'],
      'deleted_at': '',
    });
    final sourcePlacement = await placementForPhoto(photoId, slotId);
    if (sourcePlacement != null) {
      final position = ((sourcePlacement['position'] ?? 0) as int) + 1;
      await db.insert('placements', {
        'id': 'PLC-${DateTime.now().microsecondsSinceEpoch}',
        'photo_id': newPhotoId,
        'slot_id': slotId,
        'position': position,
        'caption': sourcePlacement['caption'],
        'construction_location': sourcePlacement['construction_location'],
        'include_in_report': sourcePlacement['include_in_report'],
        'is_primary': 0,
        'is_human_confirmed': 1,
        'created_at': now,
        'updated_at': now,
      });
    } else {
      final maxPos = await db.rawQuery(
        'SELECT COALESCE(MAX(position), -1) + 1 AS np FROM placements WHERE slot_id ${slotId == null ? 'IS NULL' : '= ?'}',
        slotId == null ? null : [slotId],
      );
      final pos = Sqflite.firstIntValue(maxPos) ?? 0;
      await db.insert('placements', {
        'id': 'PLC-${DateTime.now().microsecondsSinceEpoch}',
        'photo_id': newPhotoId,
        'slot_id': slotId,
        'position': pos,
        'created_at': now,
        'updated_at': now,
        'is_human_confirmed': 1,
        'include_in_report': 1,
      });
    }
    return newPhotoId;
  }

  /// Offline classifier: match filename tokens to section names (no API needed).
  Future<int> createSuggestions() async {
    final sections = await this.sections();
    if (sections.isEmpty) return 0;
    final photos = await this.photos();
    final now = DateTime.now().toIso8601String();
    var count = 0;
    for (final photo in photos) {
      final filename = (photo['original_filename'] ?? '')
          .toString()
          .toLowerCase();
      Map<String, dynamic>? bestSection;
      var bestScore = 0;
      for (final section in sections) {
        final tokens = (section['name'] ?? '')
            .toString()
            .toLowerCase()
            .replaceAll('／', ' ')
            .split(' ')
            .where((t) => t.length > 1)
            .toList();
        final score = tokens.where((t) => filename.contains(t)).length;
        if (score > 0 && score > bestScore) {
          bestScore = score;
          bestSection = section;
        }
      }
      await db.delete(
        'suggestions',
        where: "photo_id = ? AND status = 'pending'",
        whereArgs: [photo['id']],
      );
      if (bestSection != null) {
        final sectionSlots = await slots(bestSection['id'].toString());
        final slot = sectionSlots.isNotEmpty ? sectionSlots.first : null;
        final confidence = math.min(0.55 + bestScore * 0.15, 0.95);
        await db.insert('suggestions', {
          'id': 'SUG-${DateTime.now().microsecondsSinceEpoch}-$count',
          'photo_id': photo['id'],
          'suggested_section_id': bestSection['id'],
          'suggested_slot_id': slot?['id'],
          'confidence': confidence,
          'reason': '檔名包含項目名稱關鍵字',
          'engine_name': 'metadata',
          'status': 'pending',
          'created_at': now,
        });
        count++;
      }
    }
    return count;
  }

  /// Scan a directory for .sprj projects (folders with project.sqlite).
  static Future<List<String>> findProjects(String dir) async {
    final results = <String>[];
    final root = Directory(dir);
    if (!await root.exists()) return results;
    await _scanRecursive(root, results, 0, 4);
    return results;
  }

  static Future<void> _scanRecursive(
    Directory dir,
    List<String> results,
    int depth,
    int maxDepth,
  ) async {
    if (depth > maxDepth) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          final name = p.basename(entity.path);
          // Skip hidden/system dirs.
          if (name.startsWith('.') ||
              name == 'Android' ||
              name == 'node_modules') {
            continue;
          }
          final sqlite = File(p.join(entity.path, 'project.sqlite'));
          if (await sqlite.exists()) {
            results.add(entity.path);
          } else {
            await _scanRecursive(entity, results, depth + 1, maxDepth);
          }
        }
      }
    } catch (_) {
      // Permission denied or other I/O error — skip this subtree.
    }
  }

  // ── Import (camera / gallery) ─────────────────────────────────────
  /// Import a photo file into the project as unclassified.
  /// Generates thumbnail + preview, computes sha256 (dedup), writes DB rows
  /// in the desktop-compatible schema. Returns the new photo id, or null if
  /// the file is a duplicate or invalid.
  Future<String?> importFile(String sourcePath, {String? targetSlotId}) async {
    final source = File(sourcePath);
    if (!await source.exists()) return null;

    final bytes = await source.readAsBytes();
    final digest = sha256.convert(bytes).toString();

    // Dedup against existing photos.
    final dup = await db.query(
      'photos',
      where: "sha256 = ? AND deleted_at = ''",
      whereArgs: [digest],
      limit: 1,
    );
    if (dup.isNotEmpty) return null;

    final ext = p.extension(sourcePath).toLowerCase();
    final photoId = 'PHO-${DateTime.now().microsecondsSinceEpoch}';
    final originalName = p.basename(sourcePath);
    final storedName = '${photoId}_$originalName';
    final originalRel = p.join('originals', storedName);
    final thumbRel = p.join('thumbnails', '$photoId.jpg');
    final previewRel = p.join('previews', '$photoId.jpg');

    // Persist the source bytes into the project folder before touching the
    // database.  Camera providers commonly return a temporary cache path;
    // keeping a flushed copy here makes direct camera imports survive closing
    // the picker, restarting the app, and later cache cleanup.
    await Directory(originalsDir).create(recursive: true);
    final storedOriginal = File(p.join(root, originalRel));
    final createdFiles = <File>[storedOriginal];
    await storedOriginal.writeAsBytes(bytes, flush: true);

    // Decode + generate thumbnail (320) and preview (1600).
    final decoded = img.decodeImage(bytes);
    final capturedAt = _extractCapturedAt(bytes, ext, decoded);
    var width = 0, height = 0;
    if (decoded != null) {
      width = decoded.width;
      height = decoded.height;
      await Directory(thumbnailsDir).create(recursive: true);
      await Directory(previewsDir).create(recursive: true);
      final thumb = img.copyResize(decoded, width: 320);
      final storedThumb = File(p.join(root, thumbRel));
      createdFiles.add(storedThumb);
      await storedThumb.writeAsBytes(
        img.encodeJpg(thumb, quality: 82),
        flush: true,
      );
      final preview = img.copyResize(decoded, width: 1600);
      final storedPreview = File(p.join(root, previewRel));
      createdFiles.add(storedPreview);
      await storedPreview.writeAsBytes(
        img.encodeJpg(preview, quality: 88),
        flush: true,
      );
    }

    final now = DateTime.now().toIso8601String();
    try {
      // Keep photo + placement + project timestamp atomic.  This avoids a
      // partially saved direct-camera import if Android interrupts the write.
      await db.transaction((txn) async {
        await txn.insert('photos', {
          'id': photoId,
          'original_filename': originalName,
          'original_rel_path': originalRel,
          'thumbnail_rel_path': thumbRel,
          'preview_rel_path': previewRel,
          'sha256': digest,
          'mime_type': 'image/${ext.replaceFirst('.', '')}',
          'file_size': bytes.length,
          'width': width,
          'height': height,
          'captured_at': capturedAt,
          'imported_at': now,
          'rotation_degrees': 0,
          'is_missing': 0,
          'deleted_at': '',
        });

        // Create placement (unclassified or directly into target slot).
        final maxPos = await txn.rawQuery(
          'SELECT COALESCE(MAX(position), -1) + 1 AS np FROM placements WHERE slot_id ${targetSlotId == null ? 'IS NULL' : '= ?'}',
          targetSlotId == null ? null : [targetSlotId],
        );
        final pos = Sqflite.firstIntValue(maxPos) ?? 0;
        await txn.insert('placements', {
          'id': 'PLC-${DateTime.now().microsecondsSinceEpoch}',
          'photo_id': photoId,
          'slot_id': targetSlotId,
          'position': pos,
          'created_at': now,
          'updated_at': now,
          'is_human_confirmed': targetSlotId != null ? 1 : 0,
          'include_in_report': 1,
        });
        await txn.update('project', {'updated_at': now}, where: 'id = 1');
      });
      return photoId;
    } catch (_) {
      // Do not leave orphaned originals/previews when the database commit
      // fails.  The source file outside the project is never touched.
      for (final file in createdFiles.reversed) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  String _extractCapturedAt(
    Uint8List bytes,
    String extension,
    img.Image? decoded,
  ) {
    img.ExifData? exif;
    if (extension == '.jpg' || extension == '.jpeg') {
      exif = img.decodeJpgExif(bytes);
    }
    exif ??= decoded?.exif;
    if (exif == null) return '';

    final values = [
      exif.exifIfd['DateTimeOriginal'],
      exif.exifIfd['DateTimeDigitized'],
      exif.imageIfd['DateTime'],
    ];
    for (final value in values) {
      final normalized = _normalizeExifDate(value?.toString() ?? '');
      if (normalized.isNotEmpty) return normalized;
    }
    return '';
  }

  String _normalizeExifDate(String raw) {
    final text = raw.replaceAll('\u0000', '').trim();
    final match = RegExp(
      r'^(\d{4})[:\-](\d{2})[:\-](\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?',
    ).firstMatch(text);
    if (match == null) return '';

    final year = int.tryParse(match.group(1)!) ?? 0;
    final month = int.tryParse(match.group(2)!) ?? 0;
    final day = int.tryParse(match.group(3)!) ?? 0;
    final hour = int.tryParse(match.group(4)!) ?? 0;
    final minute = int.tryParse(match.group(5)!) ?? 0;
    final second = int.tryParse(match.group(6) ?? '0') ?? 0;
    final parsed = DateTime.tryParse(
      '$year-${match.group(2)}-${match.group(3)}T'
      '${match.group(4)}:${match.group(5)}:${match.group(6) ?? '00'}',
    );
    if (parsed == null ||
        parsed.year != year ||
        parsed.month != month ||
        parsed.day != day ||
        parsed.hour != hour ||
        parsed.minute != minute ||
        parsed.second != second) {
      return '';
    }
    return '${year.toString().padLeft(4, '0')}-'
        '${month.toString().padLeft(2, '0')}-'
        '${day.toString().padLeft(2, '0')} '
        '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}:'
        '${second.toString().padLeft(2, '0')}';
  }
}
