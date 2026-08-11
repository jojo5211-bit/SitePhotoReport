from __future__ import annotations

import hashlib
import json
import shutil
import sqlite3
import uuid
from datetime import datetime
from pathlib import Path
from typing import Callable, Iterable

from PIL import Image, ImageDraw, ImageFont, ImageOps


SUPPORTED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


def now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def new_id(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4()}"


class ProjectStore:
    """SQLite-backed project store. Images live on disk, never in SQLite BLOBs."""

    def __init__(self, root: str | Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        for name in ("originals", "thumbnails", "previews", "edits", "assets", "exports", "backups", "logs"):
            (self.root / name).mkdir(exist_ok=True)
        self.db = sqlite3.connect(self.root / "project.sqlite")
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.execute("PRAGMA journal_mode = WAL")
        self._init_schema()

    def close(self) -> None:
        self.db.close()

    def _init_schema(self) -> None:
        self.db.executescript(
            """
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
            );
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
            );
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
            );
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
            );
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
            );
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
            );
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_photos_sha256 ON photos(sha256);
            CREATE INDEX IF NOT EXISTS idx_placements_slot ON placements(slot_id, position);
            """
        )
        self._ensure_column("photos", "mosaic_json", "TEXT DEFAULT ''")
        self._ensure_column("placements", "number_text", "TEXT DEFAULT ''")
        self._ensure_column("placements", "number_position", "TEXT DEFAULT 'top_right'")
        self._ensure_column("placements", "number_color", "TEXT DEFAULT '#D32F2F'")
        self._ensure_column("placements", "number_size", "TEXT DEFAULT 'medium'")
        self._ensure_column("placements", "number_background_transparent", "INTEGER NOT NULL DEFAULT 0")
        self.db.commit()
        if self.db.execute("SELECT 1 FROM project WHERE id = 1").fetchone() is None:
            stamp = now_iso()
            self.db.execute(
                "INSERT INTO project(id, name, report_title, created_at, updated_at) VALUES(1, ?, ?, ?, ?)",
                (self.root.stem, self.root.stem, stamp, stamp),
            )
            self.db.commit()

    def project(self) -> sqlite3.Row:
        return self.db.execute("SELECT * FROM project WHERE id = 1").fetchone()

    def update_project(self, **values: str) -> None:
        allowed = {
            "name", "project_code", "report_title", "client_name", "contractor_name",
            "manager_name", "location", "start_date", "end_date", "company_name",
            "logo_rel_path", "description",
        }
        values = {key: value for key, value in values.items() if key in allowed}
        if not values:
            return
        values["updated_at"] = now_iso()
        assignments = ", ".join(f"{key} = ?" for key in values)
        self.db.execute(f"UPDATE project SET {assignments} WHERE id = 1", tuple(values.values()))
        self.db.commit()

    def sections(self) -> list[sqlite3.Row]:
        return list(self.db.execute("SELECT * FROM sections ORDER BY position, name"))

    def slots(self, section_id: str) -> list[sqlite3.Row]:
        return list(self.db.execute("SELECT * FROM slots WHERE section_id = ? ORDER BY position, name", (section_id,)))

    def add_section(self, name: str, layout_type: str = "single") -> str:
        section_id = new_id("SEC")
        stamp = now_iso()
        position = self.db.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM sections").fetchone()[0]
        self.db.execute(
            "INSERT INTO sections(id, name, layout_type, position, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?)",
            (section_id, name, layout_type, position, stamp, stamp),
        )
        self.db.commit()
        self._ensure_slots(section_id, layout_type)
        return section_id

    def _ensure_slots(self, section_id: str, layout_type: str) -> None:
        if self.slots(section_id):
            return
        names = {
            "single": [("項目照片", "custom")],
            "before_during_after": [("施工前", "before"), ("施工中", "during"), ("施工後", "after")],
            "before_after": [("改善前", "before"), ("改善後", "after")],
        }.get(layout_type, [("項目照片", "custom")])
        stamp = now_iso()
        self.db.executemany(
            "INSERT INTO slots(id, section_id, name, stage_type, position, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?)",
            [(new_id("SLOT"), section_id, name, stage, index, stamp, stamp) for index, (name, stage) in enumerate(names)],
        )
        self.db.commit()

    def ensure_default_sections(self) -> None:
        if self.sections():
            return
        for name, layout in (
            ("施工前現況", "single"),
            ("施工中紀錄", "before_during_after"),
            ("完工照片", "single"),
        ):
            self.add_section(name, layout)

    def rename_section(self, section_id: str, name: str) -> None:
        self.db.execute("UPDATE sections SET name = ?, updated_at = ? WHERE id = ?", (name, now_iso(), section_id))
        self.db.commit()

    def delete_section(self, section_id: str) -> None:
        self.db.execute("UPDATE placements SET slot_id = NULL WHERE slot_id IN (SELECT id FROM slots WHERE section_id = ?)", (section_id,))
        self.db.execute("DELETE FROM sections WHERE id = ?", (section_id,))
        self._normalize_section_positions()
        self.db.commit()

    def move_section(self, section_id: str, direction: int) -> None:
        rows = self.sections()
        index = next((i for i, row in enumerate(rows) if row["id"] == section_id), None)
        if index is None:
            return
        other = index + direction
        if not 0 <= other < len(rows):
            return
        rows[index], rows[other] = rows[other], rows[index]
        self.db.executemany("UPDATE sections SET position = ?, updated_at = ? WHERE id = ?", [(i, now_iso(), row["id"]) for i, row in enumerate(rows)])
        self.db.commit()

    def set_section_order(self, section_ids: list[str]) -> None:
        for position, section_id in enumerate(section_ids):
            self.db.execute("UPDATE sections SET position = ?, updated_at = ? WHERE id = ?", (position, now_iso(), section_id))
        self.db.commit()

    def add_slot(self, section_id: str, name: str, stage_type: str = "custom") -> str:
        slot_id = new_id("SLOT")
        position = self.db.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM slots WHERE section_id = ?", (section_id,)).fetchone()[0]
        stamp = now_iso()
        self.db.execute(
            "INSERT INTO slots(id, section_id, name, stage_type, position, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?)",
            (slot_id, section_id, name, stage_type, position, stamp, stamp),
        )
        self.db.commit()
        return slot_id

    def rename_slot(self, slot_id: str, name: str) -> None:
        self.db.execute("UPDATE slots SET name = ?, updated_at = ? WHERE id = ?", (name, now_iso(), slot_id))
        self.db.commit()

    def delete_slot(self, slot_id: str) -> None:
        self.db.execute("UPDATE placements SET slot_id = NULL WHERE slot_id = ?", (slot_id,))
        self.db.execute("DELETE FROM slots WHERE id = ?", (slot_id,))
        self.db.commit()

    def delete_photos(self, photo_ids: list[str]) -> None:
        """Remove photos from the project while preserving originals on disk."""
        if not photo_ids:
            return
        stamp = now_iso()
        for photo_id in photo_ids:
            self.db.execute("DELETE FROM placements WHERE photo_id = ?", (photo_id,))
            self.db.execute("UPDATE suggestions SET status = 'ignored', reviewed_at = ? WHERE photo_id = ? AND status = 'pending'", (stamp, photo_id))
            self.db.execute("UPDATE photos SET deleted_at = ? WHERE id = ?", (stamp, photo_id))
        self.db.commit()

    def photos(self) -> list[sqlite3.Row]:
        return list(self.db.execute("SELECT * FROM photos WHERE deleted_at = '' ORDER BY imported_at, original_filename"))

    def unclassified_photos(self) -> list[sqlite3.Row]:
        return list(self.db.execute("""
            SELECT ph.* FROM photos ph
            JOIN placements p ON p.photo_id = ph.id AND p.slot_id IS NULL
            WHERE ph.deleted_at = ''
              AND NOT EXISTS (SELECT 1 FROM placements placed WHERE placed.photo_id = ph.id AND placed.slot_id IS NOT NULL)
            ORDER BY CASE WHEN ph.captured_at != '' THEN 0 ELSE 1 END,
                     ph.captured_at, p.position, p.created_at
        """))

    def photo(self, photo_id: str) -> sqlite3.Row | None:
        return self.db.execute("SELECT * FROM photos WHERE id = ?", (photo_id,)).fetchone()

    def update_photo(self, photo_id: str, **values: str | int) -> None:
        allowed = {"rotation_degrees", "crop_json", "mosaic_json", "global_notes"}
        values = {key: value for key, value in values.items() if key in allowed}
        if "rotation_degrees" in values:
            values["rotation_degrees"] = int(values["rotation_degrees"]) % 360
        if not values:
            return
        assignments = ", ".join(f"{key} = ?" for key in values)
        self.db.execute(f"UPDATE photos SET {assignments} WHERE id = ?", (*values.values(), photo_id))
        self.db.commit()

    def rendered_photo_path(self, photo_id: str, max_side: int = 1600, apply_mosaic: bool = True) -> Path | None:
        """Render a derived image with rotation/crop; never changes the original file."""
        photo = self.photo(photo_id)
        if not photo:
            return None
        original = self.root / photo["original_rel_path"]
        if not original.exists():
            return None
        rotation = int(photo["rotation_degrees"] or 0) % 360
        crop_json = photo["crop_json"] or ""
        mosaic_json = photo["mosaic_json"] or "" if apply_mosaic else ""
        cache_key = hashlib.sha1(f"{photo_id}:{rotation}:{crop_json}:{mosaic_json}:{max_side}".encode("utf-8")).hexdigest()[:12]
        output = self.root / "edits" / f"{photo_id}_{cache_key}.jpg"
        if output.exists() and output.stat().st_mtime >= original.stat().st_mtime:
            return output
        try:
            with Image.open(original) as source:
                image = ImageOps.exif_transpose(source).convert("RGB")
                if crop_json:
                    try:
                        crop = json.loads(crop_json)
                        if isinstance(crop, list) and len(crop) == 4:
                            image = image.crop(tuple(int(value) for value in crop))
                    except (TypeError, ValueError, json.JSONDecodeError):
                        pass
                if rotation:
                    image = image.rotate(-rotation, expand=True)
                try:
                    mosaic_regions = json.loads(mosaic_json) if mosaic_json else []
                except json.JSONDecodeError:
                    mosaic_regions = []
                if isinstance(mosaic_regions, list):
                    self._apply_mosaic(image, mosaic_regions)
                image.thumbnail((max_side, max_side))
                image.save(output, "JPEG", quality=90, optimize=True)
            return output
        except (OSError, ValueError):
            return None

    def rendered_placement_path(self, placement_id: str, max_side: int = 1600) -> Path | None:
        placement = self.db.execute("SELECT * FROM placements WHERE id = ?", (placement_id,)).fetchone()
        if not placement:
            return None
        photo = self.photo(placement["photo_id"])
        base = self.rendered_photo_path(placement["photo_id"], max_side=max_side)
        if not photo or not base:
            return base
        number = str(placement["number_text"] or "").strip()
        if not number:
            return base
        cache_key = hashlib.sha1(
            f"{placement_id}:{photo['rotation_degrees']}:{photo['crop_json']}:{photo['mosaic_json']}:{number}:"
            f"{placement['number_position']}:{placement['number_color']}:{placement['number_size']}:"
            f"{placement['number_background_transparent']}:{max_side}".encode("utf-8")
        ).hexdigest()[:12]
        output = self.root / "edits" / f"placement_{placement_id}_{cache_key}.jpg"
        if output.exists() and output.stat().st_mtime >= base.stat().st_mtime:
            return output
        try:
            with Image.open(base) as source:
                image = source.convert("RGB")
                draw = ImageDraw.Draw(image)
                # New projects store a pixel size selected by the user. Keep
                # the old named values readable for projects created before
                # the manual size control was added.
                raw_size = str(placement["number_size"] or "72").strip().lower()
                legacy_sizes = {"small": 48, "medium": 72, "large": 108}
                try:
                    diameter = int(raw_size)
                except ValueError:
                    diameter = legacy_sizes.get(raw_size, 72)
                diameter = max(16, min(diameter, max(16, min(image.size) // 2)))
                margin = max(8, diameter // 4)
                font = self._number_font(max(14, int(diameter * 0.55)))
                bbox = draw.textbbox((0, 0), number, font=font)
                text_width, text_height = bbox[2] - bbox[0], bbox[3] - bbox[1]
                badge_width = max(diameter, text_width + diameter // 2)
                badge_height = max(diameter, text_height + diameter // 2)
                position = placement["number_position"] or "top_right"
                if position == "top_left":
                    left, top = margin, margin
                elif position == "bottom_left":
                    left, top = margin, image.height - margin - badge_height
                elif position == "bottom_right":
                    left, top = image.width - margin - badge_width, image.height - margin - badge_height
                else:
                    left, top = image.width - margin - badge_width, margin
                color = placement["number_color"] or "#D32F2F"
                text_position = (left + (badge_width - text_width) / 2 - bbox[0], top + (badge_height - text_height) / 2 - bbox[1])
                if not placement["number_background_transparent"]:
                    draw.rounded_rectangle((left, top, left + badge_width, top + badge_height), radius=badge_height // 4, fill=color)
                    draw.text(text_position, number, font=font, fill="#FFFFFF")
                else:
                    draw.text(text_position, number, font=font, fill=color)
                image.save(output, "JPEG", quality=92, optimize=True)
            return output
        except (OSError, ValueError):
            return base

    @staticmethod
    def _number_font(size: int):
        candidates = [Path(r"C:\Windows\Fonts\msjh.ttc"), Path(r"C:\Windows\Fonts\arial.ttf")]
        for path in candidates:
            if path.exists():
                try:
                    return ImageFont.truetype(str(path), size=size)
                except OSError:
                    pass
        return ImageFont.load_default()

    def duplicate_photo_with_mosaic(self, photo_id: str, mosaic_json: str, slot_id: str | None) -> str:
        source = self.photo(photo_id)
        if not source:
            raise ValueError("找不到要建立馬賽克副本的照片。")
        new_photo_id = new_id("PHO")
        source_name = Path(source["original_filename"])
        duplicate_name = f"{source_name.stem}_馬賽克{source_name.suffix}"
        stamp = now_iso()
        self.db.execute(
            """INSERT INTO photos(id, original_filename, original_rel_path, thumbnail_rel_path, preview_rel_path,
               sha256, mime_type, file_size, width, height, captured_at, imported_at, camera_make, camera_model,
               rotation_degrees, crop_json, mosaic_json, global_notes, is_missing, deleted_at)
               VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (new_photo_id, duplicate_name, source["original_rel_path"], source["thumbnail_rel_path"], source["preview_rel_path"],
             source["sha256"], source["mime_type"], source["file_size"], source["width"], source["height"], source["captured_at"], stamp,
             source["camera_make"], source["camera_model"], source["rotation_degrees"], source["crop_json"], mosaic_json,
             source["global_notes"], source["is_missing"], ""),
        )
        source_placement = self.placement_for_photo(photo_id, slot_id)
        if source_placement:
            position = int(source_placement["position"]) + 1
            self.db.execute(
                "INSERT INTO placements(id, photo_id, slot_id, position, caption, construction_location, include_in_report, is_primary, is_human_confirmed, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (new_id("PLC"), new_photo_id, slot_id, position, source_placement["caption"], source_placement["construction_location"],
                 source_placement["include_in_report"], 0, 1, stamp, stamp),
            )
            self._normalize_slot_positions(slot_id)
        else:
            self._create_placement(new_photo_id, slot_id, confirmed=True)
        self.db.commit()
        return new_photo_id

    def _ensure_column(self, table: str, column: str, definition: str) -> None:
        columns = {row["name"] for row in self.db.execute(f"PRAGMA table_info({table})")}
        if column not in columns:
            self.db.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")

    @staticmethod
    def _apply_mosaic(image: Image.Image, regions: list) -> None:
        width, height = image.size
        for region in regions:
            if isinstance(region, (list, tuple)) and len(region) == 4:
                region = {"type": "rectangle", "box": list(region)}
            if not isinstance(region, dict):
                continue
            region_type = region.get("type", "rectangle")
            if region_type in {"rectangle", "ellipse"}:
                values = region.get("box", [])
                if not isinstance(values, (list, tuple)) or len(values) != 4:
                    continue
                try:
                    left, top, right, bottom = [float(value) for value in values]
                except (TypeError, ValueError):
                    continue
                box = (
                    max(0, min(width, int(left * width))), max(0, min(height, int(top * height))),
                    max(0, min(width, int(right * width))), max(0, min(height, int(bottom * height))),
                )
                if box[2] <= box[0] or box[3] <= box[1]:
                    continue
                mask = Image.new("L", (width, height), 0)
                drawer = ImageDraw.Draw(mask)
                if region_type == "ellipse":
                    drawer.ellipse(box, fill=255)
                else:
                    drawer.rectangle(box, fill=255)
                ProjectStore._pixelate_masked(image, mask, box, int(region.get("strength", 2)))
                continue
            points = region.get("points", [])
            if not isinstance(points, list) or len(points) < 2:
                continue
            pixel_points = [
                (int(float(point[0]) * width), int(float(point[1]) * height))
                for point in points if isinstance(point, (list, tuple)) and len(point) == 2
            ]
            if len(pixel_points) < 2:
                continue
            mask = Image.new("L", (width, height), 0)
            drawer = ImageDraw.Draw(mask)
            if region_type == "brush":
                radius = max(1, int(min(width, height) * float(region.get("size", 0.04))))
                for x, y in pixel_points:
                    drawer.ellipse((x - radius, y - radius, x + radius, y + radius), fill=255)
            else:
                drawer.polygon(pixel_points, fill=255)
            bbox = mask.getbbox()
            if bbox:
                ProjectStore._pixelate_masked(image, mask, bbox, int(region.get("strength", 2)))

    @staticmethod
    def _pixelate_masked(image: Image.Image, mask: Image.Image, box, strength: int = 2) -> None:
        left, top, right, bottom = box
        patch = image.crop((left, top, right, bottom))
        divisor = {1: 24, 2: 12, 3: 6}.get(max(1, min(3, int(strength))), 12)
        small = patch.resize((max(1, patch.width // divisor), max(1, patch.height // divisor)), Image.Resampling.BILINEAR)
        pixelated = small.resize(patch.size, Image.Resampling.NEAREST)
        image.paste(pixelated, (left, top), mask.crop((left, top, right, bottom)))

    def placements_for_slot(self, slot_id: str | None) -> list[sqlite3.Row]:
        if slot_id is None:
            query = """
                SELECT p.*, ph.original_filename, ph.thumbnail_rel_path, ph.preview_rel_path,
                       ph.original_rel_path, ph.captured_at, ph.width, ph.height,
                       ph.rotation_degrees, ph.crop_json, ph.mosaic_json
                FROM placements p JOIN photos ph ON ph.id = p.photo_id
                WHERE p.slot_id IS NULL AND ph.deleted_at = ''
                ORDER BY CASE WHEN ph.captured_at != '' THEN 0 ELSE 1 END,
                         ph.captured_at, p.position, p.created_at
            """
            return list(self.db.execute(query))
        query = """
            SELECT p.*, ph.original_filename, ph.thumbnail_rel_path, ph.preview_rel_path,
                   ph.original_rel_path, ph.captured_at, ph.width, ph.height,
                   ph.rotation_degrees, ph.crop_json, ph.mosaic_json
            FROM placements p JOIN photos ph ON ph.id = p.photo_id
            WHERE p.slot_id = ? AND ph.deleted_at = '' ORDER BY p.position, p.created_at
        """
        return list(self.db.execute(query, (slot_id,)))

    def placement_for_photo(self, photo_id: str, slot_id: str | None = None) -> sqlite3.Row | None:
        if slot_id is None:
            return self.db.execute("SELECT * FROM placements WHERE photo_id = ? AND slot_id IS NULL ORDER BY created_at LIMIT 1", (photo_id,)).fetchone()
        return self.db.execute("SELECT * FROM placements WHERE photo_id = ? AND slot_id = ? ORDER BY created_at LIMIT 1", (photo_id, slot_id)).fetchone()

    def import_files(self, paths: Iterable[str | Path], progress: Callable[[int, int], None] | None = None) -> tuple[list[str], list[str]]:
        imported: list[str] = []
        skipped: list[str] = []
        sources = list(paths)
        total = len(sources)
        for index, source_value in enumerate(sources, start=1):
            source = Path(source_value)
            if source.suffix.lower() not in SUPPORTED_EXTENSIONS or not source.is_file():
                skipped.append(str(source))
                if progress:
                    progress(index, total)
                continue
            digest = self._sha256(source)
            if self.db.execute("SELECT 1 FROM photos WHERE sha256 = ? AND deleted_at = '' LIMIT 1", (digest,)).fetchone():
                skipped.append(str(source))
                if progress:
                    progress(index, total)
                continue
            photo_id = new_id("PHO")
            original_name = source.name
            stored_name = f"{photo_id}_{original_name}"
            original_rel = Path("originals") / stored_name
            thumb_rel = Path("thumbnails") / f"{photo_id}.jpg"
            preview_rel = Path("previews") / f"{photo_id}.jpg"
            shutil.copy2(source, self.root / original_rel)
            try:
                with Image.open(source) as image:
                    oriented = ImageOps.exif_transpose(image)
                    width, height = oriented.size
                    oriented.thumbnail((320, 320))
                    oriented.convert("RGB").save(self.root / thumb_rel, "JPEG", quality=82, optimize=True)
                    preview = ImageOps.exif_transpose(image)
                    preview.thumbnail((1600, 1600))
                    preview.convert("RGB").save(self.root / preview_rel, "JPEG", quality=88, optimize=True)
                    captured_at = ""
                    exif = image.getexif()
                    if exif:
                        captured_at = str(exif.get(36867) or exif.get(306) or "")
            except Exception:
                (self.root / original_rel).unlink(missing_ok=True)
                skipped.append(str(source))
                if progress:
                    progress(index, total)
                continue
            stamp = now_iso()
            self.db.execute(
                """INSERT INTO photos(id, original_filename, original_rel_path, thumbnail_rel_path, preview_rel_path,
                   sha256, mime_type, file_size, width, height, captured_at, imported_at)
                   VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (photo_id, original_name, str(original_rel), str(thumb_rel), str(preview_rel), digest,
                 f"image/{source.suffix.lower().lstrip('.')}", source.stat().st_size, width, height, captured_at, stamp),
            )
            self._create_placement(photo_id, None, confirmed=False)
            imported.append(photo_id)
            if progress:
                progress(index, total)
        self.db.commit()
        return imported, skipped

    def _create_placement(self, photo_id: str, slot_id: str | None, position: int | None = None, confirmed: bool = False) -> str:
        placement_id = new_id("PLC")
        if position is None:
            if slot_id is None:
                position = self.db.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM placements WHERE slot_id IS NULL").fetchone()[0]
            else:
                position = self.db.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM placements WHERE slot_id = ?", (slot_id,)).fetchone()[0]
        stamp = now_iso()
        self.db.execute(
            "INSERT INTO placements(id, photo_id, slot_id, position, created_at, updated_at, is_human_confirmed) VALUES(?, ?, ?, ?, ?, ?, ?)",
            (placement_id, photo_id, slot_id, position, stamp, stamp, int(confirmed)),
        )
        return placement_id

    def move_photos(self, photo_ids: list[str], slot_id: str | None, copy: bool = False, before_photo_id: str | None = None, confirmed: bool = True) -> None:
        if not photo_ids:
            return
        if before_photo_id:
            before = self.db.execute("SELECT position FROM placements WHERE photo_id = ? AND slot_id IS ? ORDER BY position LIMIT 1", (before_photo_id, slot_id)).fetchone()
            insert_at = before[0] if before else None
        else:
            insert_at = None
        if insert_at is None:
            insert_at = self.db.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM placements WHERE slot_id IS ?", (slot_id,)).fetchone()[0]
        for offset, photo_id in enumerate(photo_ids):
            current = self.db.execute("SELECT id FROM placements WHERE photo_id = ? AND slot_id IS ? ORDER BY created_at LIMIT 1", (photo_id, slot_id)).fetchone()
            if copy or current is None:
                self._create_placement(photo_id, slot_id, insert_at + offset, confirmed)
            else:
                self.db.execute("UPDATE placements SET position = ?, is_human_confirmed = ?, updated_at = ? WHERE id = ?", (insert_at + offset, int(confirmed), now_iso(), current[0]))
        self._normalize_slot_positions(slot_id)
        self.db.commit()

    def relocate_photos(
        self,
        photo_ids: list[str],
        source_slot_id: str | None,
        target_slot_id: str | None,
        before_photo_id: str | None = None,
        copy: bool = False,
        confirmed: bool = True,
    ) -> None:
        """Move or copy placements while preserving a deterministic target order."""
        if not photo_ids:
            return
        target_rows = self.placements_for_slot(target_slot_id)
        target_ids = [row["photo_id"] for row in target_rows]
        if not copy:
            if source_slot_id == target_slot_id:
                target_ids = [photo_id for photo_id in target_ids if photo_id not in photo_ids]
                for photo_id in photo_ids:
                    self.db.execute("DELETE FROM placements WHERE photo_id = ? AND slot_id IS ?", (photo_id, source_slot_id))
            else:
                for photo_id in photo_ids:
                    self.db.execute("DELETE FROM placements WHERE photo_id = ? AND slot_id IS ?", (photo_id, source_slot_id))
        if copy:
            # A copied photo may legitimately appear twice in the same slot.
            target_ids_for_insert = list(photo_ids)
        else:
            target_ids_for_insert = [photo_id for photo_id in photo_ids if photo_id not in target_ids]
        insert_at = len(target_ids)
        if before_photo_id in target_ids:
            insert_at = target_ids.index(before_photo_id)
        target_ids[insert_at:insert_at] = target_ids_for_insert
        if not copy:
            for photo_id in photo_ids:
                self.db.execute("DELETE FROM placements WHERE photo_id = ? AND slot_id IS ?", (photo_id, target_slot_id))
        for position, photo_id in enumerate(target_ids):
            existing = self.db.execute(
                "SELECT id FROM placements WHERE photo_id = ? AND slot_id IS ? ORDER BY created_at LIMIT 1",
                (photo_id, target_slot_id),
            ).fetchone()
            if existing and not copy:
                self.db.execute(
                    "UPDATE placements SET position = ?, is_human_confirmed = ?, updated_at = ? WHERE id = ?",
                    (position, int(confirmed), now_iso(), existing[0]),
                )
            else:
                self._create_placement(photo_id, target_slot_id, position, confirmed=confirmed)
        self.db.commit()

    def reorder_placements(self, slot_id: str | None, ordered_photo_ids: list[str]) -> None:
        rows = self.placements_for_slot(slot_id)
        by_photo = {row["photo_id"]: row["id"] for row in rows}
        for position, photo_id in enumerate(ordered_photo_ids):
            if photo_id in by_photo:
                self.db.execute("UPDATE placements SET position = ?, updated_at = ? WHERE id = ?", (position, now_iso(), by_photo[photo_id]))
        self.db.commit()

    def remove_placements(self, photo_ids: list[str], slot_id: str | None) -> None:
        for photo_id in photo_ids:
            self.db.execute("DELETE FROM placements WHERE photo_id = ? AND slot_id IS ?", (photo_id, slot_id))
        self._normalize_slot_positions(slot_id)
        self.db.commit()

    def update_placement(self, placement_id: str, **values: str | int) -> None:
        allowed = {
            "caption", "construction_location", "include_in_report", "is_primary", "is_human_confirmed",
            "number_text", "number_position", "number_color", "number_size", "number_background_transparent",
        }
        values = {key: value for key, value in values.items() if key in allowed}
        if not values:
            return
        values["updated_at"] = now_iso()
        assignments = ", ".join(f"{key} = ?" for key in values)
        self.db.execute(f"UPDATE placements SET {assignments} WHERE id = ?", (*values.values(), placement_id))
        self.db.commit()

    def set_order(self, slot_id: str | None, photo_ids: list[str]) -> None:
        for position, photo_id in enumerate(photo_ids):
            self.db.execute("UPDATE placements SET position = ?, updated_at = ? WHERE photo_id = ? AND slot_id IS ?", (position, now_iso(), photo_id, slot_id))
        self.db.commit()

    def all_report_rows(self) -> list[sqlite3.Row]:
        query = """
        SELECT s.id AS section_id, s.name AS section_name, s.position AS section_position,
               sl.id AS slot_id, sl.name AS slot_name, sl.position AS slot_position,
               p.id AS placement_id, p.position AS photo_position, p.caption,
               p.construction_location, p.include_in_report, ph.*
        FROM sections s JOIN slots sl ON sl.section_id = s.id
        LEFT JOIN placements p ON p.slot_id = sl.id AND p.include_in_report = 1
        LEFT JOIN photos ph ON ph.id = p.photo_id AND ph.deleted_at = ''
        WHERE s.include_in_report = 1 AND sl.include_in_report = 1
        ORDER BY s.position, sl.position, p.position, p.created_at
        """
        return list(self.db.execute(query))

    def number_slot(self, slot_id: str | None, position: str, color: str, size: str, transparent: bool = False) -> None:
        rows = self.placements_for_slot(slot_id)
        for index, row in enumerate(rows, start=1):
            self.db.execute(
                "UPDATE placements SET number_text = ?, number_position = ?, number_color = ?, number_size = ?, number_background_transparent = ?, updated_at = ? WHERE id = ?",
                (str(index), position, color, size, int(transparent), now_iso(), row["id"]),
            )
        self.db.commit()

    def clear_slot_numbers(self, slot_id: str | None) -> None:
        self.db.execute("UPDATE placements SET number_text = '', updated_at = ? WHERE slot_id IS ?", (now_iso(), slot_id))
        self.db.commit()

    def create_suggestions(self) -> int:
        """Small offline classifier: match filename tokens to section names."""
        sections = self.sections()
        if not sections:
            return 0
        photos = self.db.execute("SELECT * FROM photos WHERE deleted_at = ''").fetchall()
        count = 0
        for photo in photos:
            best = None
            filename = photo["original_filename"].lower()
            for section in sections:
                tokens = [token for token in section["name"].lower().replace("／", " ").split() if len(token) > 1]
                score = sum(1 for token in tokens if token in filename)
                if score and (best is None or score > best[0]):
                    best = (score, section)
            self.db.execute("DELETE FROM suggestions WHERE photo_id = ? AND status = 'pending'", (photo["id"],))
            if best:
                section = best[1]
                slot = self.slots(section["id"])[0]
                self.db.execute(
                    "INSERT INTO suggestions(id, photo_id, suggested_section_id, suggested_slot_id, confidence, reason, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)",
                    (new_id("SUG"), photo["id"], section["id"], slot["id"], min(0.55 + best[0] * 0.15, 0.95), "檔名包含項目名稱關鍵字", now_iso()),
                )
                count += 1
        self.db.commit()
        return count

    def add_ai_suggestions(self, results: list[dict]) -> tuple[int, int]:
        """Save AI suggestions and place confident results for user review.

        AI placement deliberately remains unconfirmed. Any later manual move uses
        ``confirmed=True`` and therefore wins over the original AI suggestion.
        """
        sections = self.sections()
        added = 0
        auto_placed = 0
        for result in results:
            photo_id = result.get("photo_id")
            if not photo_id:
                continue
            section_name = _normalize_label(result.get("section", ""))
            slot_name = _normalize_label(result.get("slot", ""))
            section = next((row for row in sections if _normalize_label(row["name"]) == section_name), None)
            slot = None
            if section:
                slot = next((row for row in self.slots(section["id"]) if _normalize_label(row["name"]) == slot_name), None)
            self.db.execute("DELETE FROM suggestions WHERE photo_id = ? AND status = 'pending'", (photo_id,))
            try:
                confidence = float(result.get("confidence", 0))
            except (TypeError, ValueError):
                confidence = 0.0
            self.db.execute(
                "INSERT INTO suggestions(id, photo_id, suggested_section_id, suggested_slot_id, confidence, reason, engine_name, status, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, 'pending', ?)",
                (new_id("SUG"), photo_id, section["id"] if section else None, slot["id"] if slot else None,
                 confidence, result.get("reason", "AI 視覺分類建議"), "vision_api", now_iso()),
            )
            added += 1
            # Only place a result when both names resolve to the fields the user
            # configured and the model is reasonably confident. Lower-confidence
            # or malformed results remain visible in 未分類 for manual handling.
            if slot and confidence >= 0.55:
                self.relocate_photos([photo_id], None, slot["id"], confirmed=False)
                auto_placed += 1
        self.db.commit()
        return added, auto_placed

    def suggestions(self) -> list[sqlite3.Row]:
        return list(self.db.execute("""
            SELECT sug.*, ph.original_filename, s.name AS section_name, sl.name AS slot_name
            FROM suggestions sug JOIN photos ph ON ph.id = sug.photo_id
            LEFT JOIN sections s ON s.id = sug.suggested_section_id
            LEFT JOIN slots sl ON sl.id = sug.suggested_slot_id
            WHERE sug.status = 'pending' ORDER BY sug.confidence DESC
        """))

    def accept_suggestions(self, suggestion_ids: list[str]) -> None:
        for suggestion_id in suggestion_ids:
            row = self.db.execute("SELECT * FROM suggestions WHERE id = ?", (suggestion_id,)).fetchone()
            if not row or not row["suggested_slot_id"]:
                continue
            placements = self.db.execute(
                "SELECT slot_id, is_human_confirmed FROM placements WHERE photo_id = ? ORDER BY created_at",
                (row["photo_id"],),
            ).fetchall()
            target_slot_id = row["suggested_slot_id"]
            if any(placement["slot_id"] == target_slot_id for placement in placements):
                status = "accepted"
            elif any(placement["is_human_confirmed"] for placement in placements):
                # The user already moved this photo. Accepting the old AI result
                # must never move it back to the model's original guess.
                status = "corrected"
            else:
                source = next((placement for placement in placements if placement["slot_id"] is not None), None)
                self.relocate_photos(
                    [row["photo_id"]],
                    source["slot_id"] if source else None,
                    target_slot_id,
                    confirmed=True,
                )
                status = "accepted"
            self.db.execute("UPDATE suggestions SET status = ?, reviewed_at = ? WHERE id = ?", (status, now_iso(), suggestion_id))
        self.db.commit()

    def reject_suggestions(self, suggestion_ids: list[str]) -> None:
        """Return selected AI-classified photos to 未分類 as an explicit user action."""
        for suggestion_id in suggestion_ids:
            row = self.db.execute("SELECT * FROM suggestions WHERE id = ?", (suggestion_id,)).fetchone()
            if not row:
                continue
            placements = self.db.execute(
                "SELECT slot_id FROM placements WHERE photo_id = ? AND slot_id IS NOT NULL ORDER BY created_at",
                (row["photo_id"],),
            ).fetchall()
            source = placements[0]["slot_id"] if placements else None
            self.relocate_photos([row["photo_id"]], source, None, confirmed=True)
            self.db.execute("UPDATE suggestions SET status = 'rejected', reviewed_at = ? WHERE id = ?", (now_iso(), suggestion_id))
        self.db.commit()

    def save_manifest(self) -> None:
        data = dict(self.project())
        data["sections"] = [dict(row) for row in self.sections()]
        (self.root / "project.json").write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    def deleted_photos(self) -> list[sqlite3.Row]:
        """Return photos that have been soft-deleted from the project."""
        return list(self.db.execute(
            "SELECT * FROM photos WHERE deleted_at != '' ORDER BY deleted_at DESC"
        ))

    def restore_photos(self, photo_ids: list[str]) -> int:
        """Restore soft-deleted photos back to unclassified."""
        restored = 0
        for photo_id in photo_ids:
            row = self.db.execute("SELECT id FROM photos WHERE id = ? AND deleted_at != ''", (photo_id,)).fetchone()
            if not row:
                continue
            self.db.execute("UPDATE photos SET deleted_at = '' WHERE id = ?", (photo_id,))
            # Re-create unclassified placement if none exists
            existing = self.db.execute(
                "SELECT 1 FROM placements WHERE photo_id = ? AND slot_id IS NULL", (photo_id,)
            ).fetchone()
            if not existing:
                self._create_placement(photo_id, None, confirmed=False)
            restored += 1
        self.db.commit()
        return restored

    def rebuild_thumbnails(self, progress: Callable[[int, int], None] | None = None) -> int:
        """Rebuild missing thumbnail/preview images. Returns count rebuilt."""
        photos = self.photos()
        total = len(photos)
        rebuilt = 0
        for index, photo in enumerate(photos):
            thumb = self.root / photo["thumbnail_rel_path"]
            preview = self.root / photo["preview_rel_path"]
            original = self.root / photo["original_rel_path"]
            if thumb.exists() and preview.exists():
                continue
            if not original.exists():
                continue
            try:
                with Image.open(original) as image:
                    oriented = ImageOps.exif_transpose(image)
                    if not thumb.exists():
                        t = oriented.copy()
                        t.thumbnail((320, 320))
                        t.convert("RGB").save(thumb, "JPEG", quality=82, optimize=True)
                    if not preview.exists():
                        pv = oriented.copy()
                        pv.thumbnail((1600, 1600))
                        pv.convert("RGB").save(preview, "JPEG", quality=88, optimize=True)
                rebuilt += 1
            except (OSError, ValueError):
                pass
            if progress:
                progress(index + 1, total)
        return rebuilt

    def confirmed_examples(self, limit: int = 5) -> list[dict]:
        """Return recent human-confirmed placements as few-shot examples for AI."""
        rows = self.db.execute("""
            SELECT ph.original_filename, s.name AS section_name, sl.name AS slot_name
            FROM placements p
            JOIN photos ph ON ph.id = p.photo_id
            JOIN slots sl ON sl.id = p.slot_id
            JOIN sections s ON s.id = sl.section_id
            WHERE p.is_human_confirmed = 1 AND p.slot_id IS NOT NULL AND ph.deleted_at = ''
            ORDER BY p.updated_at DESC
            LIMIT ?
        """, (limit,)).fetchall()
        return [
            {"filename": r["original_filename"], "section": r["section_name"], "slot": r["slot_name"]}
            for r in rows
        ]

    def slot_number_summary(self) -> list[dict]:
        """Return per-slot numbering status for export preview."""
        rows = self.db.execute("""
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
        """).fetchall()
        return [dict(r) for r in rows]

    def _normalize_section_positions(self) -> None:
        for index, row in enumerate(self.sections()):
            self.db.execute("UPDATE sections SET position = ? WHERE id = ?", (index, row["id"]))

    def _normalize_slot_positions(self, slot_id: str | None) -> None:
        rows = self.placements_for_slot(slot_id)
        for index, row in enumerate(rows):
            self.db.execute("UPDATE placements SET position = ? WHERE id = ?", (index, row["id"]))

    @staticmethod
    def _sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()


def _normalize_label(value: str) -> str:
    return "".join(str(value or "").lower().split()).replace("／", "/")
