from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from PySide6.QtCore import QByteArray, QEvent, QMimeData, QPoint, QSize, QThread, QTimer, Qt, Signal, QRect, QRectF
from PySide6.QtGui import QAction, QColor, QDrag, QIcon, QKeySequence, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout,
    QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMainWindow,
    QMessageBox, QPushButton, QSplitter, QStyledItemDelegate, QTabBar, QTabWidget,
    QTextEdit, QToolBar, QVBoxLayout, QWidget, QComboBox, QGridLayout, QRadioButton,
    QScrollArea, QSpinBox, QMenu,
)

from . import __version__
from .exporters import PDF_TEMPLATE_OPTIONS, ExportSettings, export_excel, export_pdf, export_word, unique_output_path
from .help_content import CHANGELOG, USER_GUIDE
from .paths import recent_projects_file
from .settings import AppSettings, safe_name, test_api_connection
from .store import ProjectStore, SUPPORTED_EXTENSIONS
from .vision import VisionClassifier


PHOTO_MIME = "application/x-sitephoto-photo-ids"
UNCLASSIFIED_SORT_OPTIONS = (
    ("time_asc", "拍攝時間：由早到晚"),
    ("time_desc", "拍攝時間：由晚到早"),
    ("filename_asc", "檔名：遞增"),
    ("filename_desc", "檔名：遞減"),
)


def sort_photo_rows(rows, mode: str = "manual") -> list:
    """Apply an explicit view sort without changing the stored manual order."""
    if mode == "manual":
        return sorted(
            list(rows),
            key=lambda row: (
                int(row["position"] or 0),
                str(row["created_at"] or ""),
                str(row["id"] or ""),
            ),
        )
    return sort_unclassified_rows(rows, mode)


def sort_unclassified_rows(rows, mode: str = "time_asc") -> list:
    """Sort only the unclassified photo rows while keeping unknown dates last."""
    rows = list(rows)
    if mode not in {value for value, _label in UNCLASSIFIED_SORT_OPTIONS}:
        mode = "time_asc"

    def position_key(row):
        return (int(row["position"] or 0), str(row["created_at"] or ""))

    def filename_key(row):
        name = str(row["original_filename"] or "").casefold()
        return tuple(
            (0, int(part)) if part.isdigit() else (1, part)
            for part in re.split(r"(\d+)", name)
            if part
        )

    if mode.startswith("filename"):
        rows.sort(key=position_key)
        rows.sort(key=filename_key, reverse=mode.endswith("desc"))
        return rows

    dated = [row for row in rows if str(row["captured_at"] or "").strip()]
    undated = [row for row in rows if not str(row["captured_at"] or "").strip()]
    dated.sort(key=position_key)
    dated.sort(key=lambda row: str(row["captured_at"] or ""), reverse=mode.endswith("desc"))
    undated.sort(key=position_key)
    return dated + undated


class PhotoPreviewLabel(QLabel):
    clicked = Signal()

    def mousePressEvent(self, event):  # noqa: N802 - Qt override
        if event.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit()
        super().mousePressEvent(event)


class PanScrollArea(QScrollArea):
    """A scroll area that lets the user pan an oversized photo with the mouse."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._pan_start: QPoint | None = None
        self.setCursor(Qt.CursorShape.OpenHandCursor)

    def mousePressEvent(self, event):  # noqa: N802 - Qt override
        if event.button() == Qt.MouseButton.LeftButton and (self.horizontalScrollBar().maximum() or self.verticalScrollBar().maximum()):
            self._pan_start = event.position().toPoint()
            self.setCursor(Qt.CursorShape.ClosedHandCursor)
            event.accept()
            return
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event):  # noqa: N802 - Qt override
        if self._pan_start is not None:
            current = event.position().toPoint()
            delta = current - self._pan_start
            self._pan_start = current
            self.horizontalScrollBar().setValue(self.horizontalScrollBar().value() - delta.x())
            self.verticalScrollBar().setValue(self.verticalScrollBar().value() - delta.y())
            event.accept()
            return
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):  # noqa: N802 - Qt override
        if event.button() == Qt.MouseButton.LeftButton and self._pan_start is not None:
            self._pan_start = None
            self.setCursor(Qt.CursorShape.OpenHandCursor)
            event.accept()
            return
        super().mouseReleaseEvent(event)


class ImageViewerDialog(QDialog):
    def __init__(self, pixmap: QPixmap, filename: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle(f"照片檢視｜{filename}")
        self.resize(1100, 760)
        self.source_pixmap = pixmap
        self.zoom = 1.0
        self.fit_zoom = 1.0
        self.label = QLabel()
        self.label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.scroll = PanScrollArea()
        self.scroll.setWidgetResizable(False)
        self.scroll.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.label.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        self.scroll.setWidget(self.label)
        zoom_out = QPushButton("−")
        zoom_in = QPushButton("＋")
        fit = QPushButton("符合視窗")
        self.zoom_label = QLabel("100%")
        zoom_out.clicked.connect(lambda: self.set_zoom(self.zoom / 1.25))
        zoom_in.clicked.connect(lambda: self.set_zoom(self.zoom * 1.25))
        fit.clicked.connect(self.fit_image)
        controls = QHBoxLayout()
        controls.addWidget(QLabel("檢視大小"))
        controls.addWidget(zoom_out)
        controls.addWidget(self.zoom_label)
        controls.addWidget(zoom_in)
        controls.addWidget(fit)
        controls.addStretch()
        layout = QVBoxLayout(self)
        layout.addLayout(controls)
        layout.addWidget(self.scroll)
        QTimer.singleShot(0, self.fit_image)

    def fit_image(self):
        if self.source_pixmap.isNull():
            return
        viewport = self.scroll.viewport().size()
        self.fit_zoom = min(
            viewport.width() / max(1, self.source_pixmap.width()),
            viewport.height() / max(1, self.source_pixmap.height()),
            1.0,
        )
        self.set_zoom(self.fit_zoom)

    def set_zoom(self, value: float):
        self.zoom = max(0.1, min(4.0, value))
        size = self.source_pixmap.size() * self.zoom
        self.label.setPixmap(self.source_pixmap.scaled(size, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))
        self.label.resize(size)
        self.zoom_label.setText(f"{round(self.zoom * 100)}%")


class MosaicCanvas(QWidget):
    rectangles_changed = Signal(object)

    def __init__(self, pixmap: QPixmap, parent=None):
        super().__init__(parent)
        self.pixmap = pixmap
        self.regions: list[dict] = []
        self._drawing_start: tuple[float, float] | None = None
        self._drawing_box: list[float] | None = None
        self._drawing_points: list[list[float]] = []
        self.brush_size = 32
        self.mosaic_strength = 2
        self.mode = "brush"
        self.setMinimumSize(640, 420)
        self.setCursor(Qt.CursorShape.CrossCursor)

    def set_rectangles(self, rectangles: list):
        self.regions = []
        for rectangle in rectangles:
            if isinstance(rectangle, dict):
                self.regions.append(rectangle)
            elif isinstance(rectangle, (list, tuple)) and len(rectangle) == 4:
                self.regions.append({"type": "rectangle", "box": list(rectangle)})
        self.update()

    @property
    def rectangles(self):
        return self.regions

    def clear_rectangles(self):
        self.regions = []
        self._drawing_box = None
        self._drawing_points = []
        self.rectangles_changed.emit(self.regions)
        self.update()

    def undo_last(self):
        if self.regions:
            self.regions.pop()
            self.rectangles_changed.emit(self.regions)
            self.update()

    def set_mode(self, mode: str):
        self.mode = mode

    def set_brush_size(self, size: int):
        self.brush_size = max(4, int(size))

    def set_mosaic_strength(self, strength: int):
        self.mosaic_strength = max(1, min(3, int(strength)))
        for region in self.regions:
            region.setdefault("strength", self.mosaic_strength)
            region["strength"] = self.mosaic_strength
        self.update()

    def _target_rect(self) -> QRectF:
        if self.pixmap.isNull():
            return QRectF()
        scaled = self.pixmap.size().scaled(self.size(), Qt.AspectRatioMode.KeepAspectRatio)
        return QRectF((self.width() - scaled.width()) / 2, (self.height() - scaled.height()) / 2, scaled.width(), scaled.height())

    def _normalised(self, point: QPoint) -> tuple[float, float]:
        target = self._target_rect()
        if target.width() <= 0 or target.height() <= 0:
            return 0.0, 0.0
        x = max(0.0, min(1.0, (point.x() - target.x()) / target.width()))
        y = max(0.0, min(1.0, (point.y() - target.y()) / target.height()))
        return x, y

    def _to_screen(self, rectangle: list[float]) -> QRectF:
        target = self._target_rect()
        left, top, right, bottom = rectangle
        return QRectF(target.x() + left * target.width(), target.y() + top * target.height(), (right - left) * target.width(), (bottom - top) * target.height())

    def mousePressEvent(self, event):  # noqa: N802 - Qt override
        if event.button() != Qt.MouseButton.LeftButton:
            return
        x, y = self._normalised(event.position().toPoint())
        self._drawing_start = (x, y)
        if self.mode == "brush":
            self._drawing_points = [[x, y]]
        elif self.mode == "lasso":
            self._drawing_points = [[x, y]]
        else:
            self._drawing_box = [x, y, x, y]
        self.update()

    def mouseMoveEvent(self, event):  # noqa: N802 - Qt override
        if not self._drawing_start:
            return
        x, y = self._normalised(event.position().toPoint())
        if self.mode in {"brush", "lasso"}:
            self._drawing_points.append([x, y])
            self.update()
            return
        start_x, start_y = self._drawing_start
        self._drawing_box = [min(start_x, x), min(start_y, y), max(start_x, x), max(start_y, y)]
        self.update()

    def mouseReleaseEvent(self, event):  # noqa: N802 - Qt override
        if event.button() != Qt.MouseButton.LeftButton:
            self._drawing_start = None
            return
        if self.mode == "brush" and self._drawing_points:
            self.regions.append({"type": "brush", "points": self._drawing_points, "size": self.brush_size / max(1, min(self.pixmap.width(), self.pixmap.height())), "strength": self.mosaic_strength})
        elif self.mode == "lasso" and len(self._drawing_points) >= 3:
            self.regions.append({"type": "polygon", "points": self._drawing_points})
        elif self._drawing_box:
            left, top, right, bottom = self._drawing_box
            if right - left > 0.01 and bottom - top > 0.01:
                self.regions.append({"type": self.mode, "box": [left, top, right, bottom], "strength": self.mosaic_strength})
        self.rectangles_changed.emit(self.regions)
        self._drawing_start = None
        self._drawing_box = None
        self._drawing_points = []
        self.update()

    def _region_path(self, region: dict) -> QPainterPath:
        target = self._target_rect()
        path = QPainterPath()
        region_type = region.get("type", "rectangle")
        if region_type in {"rectangle", "ellipse"}:
            box = region.get("box", [0, 0, 0, 0])
            screen = self._to_screen(box)
            if region_type == "ellipse":
                path.addEllipse(screen)
            else:
                path.addRect(screen)
            return path
        points = region.get("points", [])
        if not points:
            return path
        if region_type == "brush":
            radius = max(2, self.brush_size * min(target.width(), target.height()) / max(1, min(self.pixmap.width(), self.pixmap.height())) / 2)
            for point in points:
                x = target.x() + float(point[0]) * target.width()
                y = target.y() + float(point[1]) * target.height()
                path.addEllipse(QRectF(x - radius, y - radius, radius * 2, radius * 2))
            return path
        path.moveTo(target.x() + float(points[0][0]) * target.width(), target.y() + float(points[0][1]) * target.height())
        for point in points[1:]:
            path.lineTo(target.x() + float(point[0]) * target.width(), target.y() + float(point[1]) * target.height())
        path.closeSubpath()
        return path

    def _draw_region(self, painter: QPainter, region: dict):
        path = self._region_path(region)
        bounds = path.boundingRect().toRect().intersected(self._target_rect().toRect())
        if bounds.width() <= 0 or bounds.height() <= 0:
            return
        target = self._target_rect()
        left = max(0, int((bounds.left() - target.left()) / max(1, target.width()) * self.pixmap.width()))
        top = max(0, int((bounds.top() - target.top()) / max(1, target.height()) * self.pixmap.height()))
        right = min(self.pixmap.width(), max(left + 1, int((bounds.right() - target.left()) / max(1, target.width()) * self.pixmap.width())))
        bottom = min(self.pixmap.height(), max(top + 1, int((bounds.bottom() - target.top()) / max(1, target.height()) * self.pixmap.height())))
        patch = self.pixmap.copy(QRect(left, top, right - left, bottom - top))
        divisor = {1: 24, 2: 12, 3: 6}.get(int(region.get("strength", self.mosaic_strength)), 12)
        small = patch.scaled(max(1, patch.width() // divisor), max(1, patch.height() // divisor), Qt.AspectRatioMode.IgnoreAspectRatio, Qt.TransformationMode.FastTransformation)
        pixelated = small.scaled(bounds.size(), Qt.AspectRatioMode.IgnoreAspectRatio, Qt.TransformationMode.FastTransformation)
        painter.save()
        painter.setClipPath(path)
        painter.drawPixmap(bounds, pixelated)
        painter.restore()
        painter.setPen(QPen(QColor("#ff4444"), 2))
        painter.drawPath(path)

    def paintEvent(self, event):  # noqa: N802 - Qt override
        painter = QPainter(self)
        painter.fillRect(self.rect(), Qt.GlobalColor.black)
        target = self._target_rect()
        if not self.pixmap.isNull():
            painter.drawPixmap(target.toRect(), self.pixmap)
        active = None
        if self.mode in {"brush", "lasso"} and self._drawing_points:
            active = {"type": "brush" if self.mode == "brush" else "polygon", "points": self._drawing_points, "size": self.brush_size / max(1, min(self.pixmap.width(), self.pixmap.height())), "strength": self.mosaic_strength}
        elif self._drawing_box:
            active = {"type": self.mode, "box": self._drawing_box, "strength": self.mosaic_strength}
        for region in self.regions + ([active] if active else []):
            self._draw_region(painter, region)
        painter.end()


class MosaicDialog(QDialog):
    def __init__(self, store: ProjectStore, photo_id: str, slot_id: str | None, parent=None):
        super().__init__(parent)
        self.store = store
        self.photo_id = photo_id
        self.slot_id = slot_id
        self.result_photo_id = photo_id
        self.setWindowTitle("照片馬賽克遮蔽")
        self.resize(900, 650)
        base = store.rendered_photo_path(photo_id, max_side=1400, apply_mosaic=False)
        self.canvas = MosaicCanvas(QPixmap(str(base)) if base else QPixmap())
        photo = store.photo(photo_id)
        try:
            existing = json.loads(photo["mosaic_json"] or "[]") if photo else []
        except json.JSONDecodeError:
            existing = []
        self.canvas.set_rectangles(existing if isinstance(existing, list) else [])
        self.mode = QComboBox()
        self.mode.addItem("筆刷塗抹", "brush")
        self.mode.addItem("方形框選", "rectangle")
        self.mode.addItem("圓形框選", "ellipse")
        self.mode.addItem("手動描邊", "lasso")
        self.mode.currentIndexChanged.connect(lambda index: self.canvas.set_mode(self.mode.itemData(index)))
        brush_size = QSpinBox()
        brush_size.setRange(4, 200)
        brush_size.setValue(32)
        brush_size.setSuffix(" px")
        brush_size.valueChanged.connect(self.canvas.set_brush_size)
        strength = QComboBox()
        # The pixelation divisor is inverse to the visible strength: a larger
        # divisor creates larger blocks and therefore a heavier mosaic.
        strength.addItem("輕度", 3)
        strength.addItem("中度", 2)
        strength.addItem("重度", 1)
        strength.setCurrentIndex(1)
        strength.currentIndexChanged.connect(lambda index: self.canvas.set_mosaic_strength(strength.itemData(index)))
        undo = QPushButton("上一步")
        undo.clicked.connect(self.canvas.undo_last)
        clear = QPushButton("清除全部馬賽克")
        clear.clicked.connect(self.canvas.clear_rectangles)
        self.keep_original = QRadioButton("建立馬賽克副本（保留原版，建議）")
        self.keep_original.setChecked(True)
        self.apply_current = QRadioButton("直接套用目前照片（原始檔仍保留，但報告使用馬賽克版）")
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addWidget(QLabel("筆刷可調整大小並像小畫家一樣塗抹；方形／圓形可拖曳框選；手動描邊可圈出不規則範圍。畫面會即時顯示馬賽克效果。"))
        mode_row = QHBoxLayout()
        mode_row.addWidget(QLabel("工具"))
        mode_row.addWidget(self.mode)
        mode_row.addWidget(QLabel("筆刷大小"))
        mode_row.addWidget(brush_size)
        mode_row.addWidget(QLabel("模糊力度"))
        mode_row.addWidget(strength)
        mode_row.addWidget(undo)
        mode_row.addWidget(clear)
        mode_row.addStretch()
        layout.addLayout(mode_row)
        layout.addWidget(self.canvas)
        layout.addWidget(self.keep_original)
        layout.addWidget(self.apply_current)
        layout.addWidget(buttons)

    def accept(self):
        mosaic_json = json.dumps(self.canvas.rectangles, ensure_ascii=False)
        if self.keep_original.isChecked():
            self.result_photo_id = self.store.duplicate_photo_with_mosaic(self.photo_id, mosaic_json, self.slot_id)
        else:
            self.store.update_photo(self.photo_id, mosaic_json=mosaic_json)
        super().accept()


class VisionWorker(QThread):
    """Classify photos via vision API with parallel workers and per-item error tolerance."""

    progress = Signal(int, str)
    completed = Signal(object)  # list[dict] results (each has photo_id, section, slot, confidence, reason)
    failed = Signal(str)
    CONCURRENCY = 5

    def __init__(self, items: list[dict], sections: list[dict], profile: dict, parent=None, examples: list[dict] | None = None):
        super().__init__(parent)
        self.items = items
        self.sections = sections
        self.profile = profile
        self.examples = examples or []

    def run(self):  # noqa: D401 - Qt thread entry point
        from concurrent.futures import ThreadPoolExecutor, as_completed
        try:
            model = self.profile.get("vision_model") or self.profile.get("model")
            classifier = VisionClassifier(self.profile["endpoint"], self.profile.get("api_key", ""), model)
            total = len(self.items)
            results: list[dict] = []
            errors: list[str] = []
            done_count = 0

            def _classify_one(item: dict) -> dict:
                result = classifier.classify(item["path"], self.sections, examples=self.examples, captured_at=item.get("captured_at", ""))
                result["photo_id"] = item["photo_id"]
                result["_filename"] = item["filename"]
                return result

            with ThreadPoolExecutor(max_workers=self.CONCURRENCY) as pool:
                future_map = {pool.submit(_classify_one, item): item for item in self.items}
                for future in as_completed(future_map):
                    done_count += 1
                    item = future_map[future]
                    try:
                        result = future.result()
                        results.append(result)
                        self.progress.emit(done_count * 100 // max(total, 1), item["filename"])
                    except Exception as exc:  # noqa: BLE001
                        errors.append(f"{item['filename']}：{exc}")
                        self.progress.emit(done_count * 100 // max(total, 1), f"✗ {item['filename']}")

            self.progress.emit(100, "完成")
            if not results and errors:
                self.failed.emit("\n".join(errors[:10]))
            else:
                # Attach error summary so the UI can report partial failures
                for r in results:
                    r["_errors"] = errors
                self.completed.emit(results)
        except Exception as error:  # noqa: BLE001 - user-facing API error
            self.failed.emit(str(error))


class PhotoTabBar(QTabBar):
    """Accept a photo drag on a field tab so fields can be changed directly."""

    photo_tab_dropped = Signal(int, object, bool, object)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setAcceptDrops(True)
        self._highlight_tab: int = -1

    @staticmethod
    def _payload(mime_data):
        if not mime_data.hasFormat(PHOTO_MIME):
            return None
        try:
            payload = json.loads(bytes(mime_data.data(PHOTO_MIME)).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None
        if isinstance(payload, dict):
            ids = payload.get("photo_ids", [])
            source_ref = {
                "slot_id": payload.get("source_slot_id"),
                "explicit": bool(payload.get("source_explicit", False)),
            }
        else:
            ids = payload
            source_ref = {"slot_id": None, "explicit": False}
        return ids, source_ref

    def dragEnterEvent(self, event):  # noqa: N802 - Qt override
        if self._payload(event.mimeData()):
            event.acceptProposedAction()
        else:
            event.ignore()

    def dragMoveEvent(self, event):  # noqa: N802 - Qt override
        idx = self.tabAt(event.position().toPoint())
        if self._payload(event.mimeData()) and idx >= 0:
            if idx != self._highlight_tab:
                self._highlight_tab = idx
                self.update()
            event.acceptProposedAction()
        else:
            if self._highlight_tab >= 0:
                self._highlight_tab = -1
                self.update()
            event.ignore()

    def dropEvent(self, event):  # noqa: N802 - Qt override
        payload = self._payload(event.mimeData())
        index = self.tabAt(event.position().toPoint())
        if not payload or index < 0:
            event.ignore()
            return
        ids, source_ref = payload
        if not isinstance(ids, list) or not ids:
            event.ignore()
            return
        copy = bool(event.keyboardModifiers() & Qt.KeyboardModifier.ControlModifier)
        self._highlight_tab = -1
        self.update()
        self.photo_tab_dropped.emit(index, ids, copy, source_ref)
        event.acceptProposedAction()

    def dragLeaveEvent(self, event):  # noqa: N802 - Qt override
        if self._highlight_tab >= 0:
            self._highlight_tab = -1
            self.update()
        super().dragLeaveEvent(event)

    def paintEvent(self, event):  # noqa: N802 - Qt override
        super().paintEvent(event)
        if self._highlight_tab < 0 or self._highlight_tab >= self.count():
            return
        rect = self.tabRect(self._highlight_tab)
        painter = QPainter(self)
        painter.setPen(QPen(QColor("#1976d2"), 2))
        painter.setBrush(QColor(25, 118, 210, 30))
        painter.drawRoundedRect(rect.adjusted(1, 1, -1, -1), 4, 4)
        painter.end()


class DateSeparatorDelegate(QStyledItemDelegate):
    """Draw date separator rows as a thin line with a date pill label."""

    SEP_ROLE = Qt.ItemDataRole.UserRole + 1

    def paint(self, painter, option, index):
        if index.data(self.SEP_ROLE) != "date_sep":
            super().paint(painter, option, index)
            return
        painter.save()
        rect = option.rect
        cy = rect.top() + rect.height() // 2
        # Full-width line
        painter.setPen(QPen(QColor("#1976d2"), 2))
        painter.drawLine(rect.left() + 4, cy, rect.right() - 4, cy)
        # Date pill
        text = index.data(Qt.ItemDataRole.DisplayRole) or ""
        font = painter.font()
        font.setBold(True)
        font.setPointSize(9)
        painter.setFont(font)
        fm = painter.fontMetrics()
        tw = fm.horizontalAdvance(text) + 16
        th = fm.height() + 6
        pill = QRectF(rect.left() + 10, cy - th / 2, tw, th)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor("#e3f2fd"))
        painter.drawRoundedRect(pill, 4, 4)
        painter.setPen(QColor("#1565c0"))
        painter.drawText(pill, Qt.AlignmentFlag.AlignCenter, text)
        painter.restore()

    def sizeHint(self, option, index):
        if index.data(self.SEP_ROLE) == "date_sep":
            return QSize(99999, 30)
        return super().sizeHint(option, index)


class PhotoGrid(QListWidget):
    photo_dropped = Signal(object, object, bool, object)
    external_paths_dropped = Signal(object)
    delete_requested = Signal()

    def __init__(self, slot_id: str | None, parent=None):
        super().__init__(parent)
        self.slot_id = slot_id
        self.setViewMode(QListWidget.ViewMode.IconMode)
        self.setIconSize(QSize(150, 110))
        self.setResizeMode(QListWidget.ResizeMode.Adjust)
        self.setMovement(QListWidget.Movement.Static)
        self.setSelectionMode(QListWidget.SelectionMode.ExtendedSelection)
        self.setDragEnabled(True)
        self.setDragDropMode(QListWidget.DragDropMode.DragDrop)
        self.setAcceptDrops(True)
        self.viewport().setAcceptDrops(True)
        self.viewport().installEventFilter(self)
        self.setDropIndicatorShown(True)
        self.setDefaultDropAction(Qt.DropAction.MoveAction)
        self.setSpacing(8)
        self._drop_row: int | None = None
        self.setStyleSheet("QListWidget { background: #f5f7f8; border: 1px solid #d4dce1; padding: 8px; } QListWidget::item:selected { background: #cce8f3; color: #123; }")

    def _set_drop_indicator(self, point: QPoint | None):
        if point is None:
            self._drop_row = None
            self.viewport().update()
            return
        item = self.itemAt(point)
        if item is None:
            self._drop_row = self.count()
        else:
            row = self.row(item)
            self._drop_row = row + (1 if point.x() > self.visualItemRect(item).center().x() else 0)
        self.viewport().update()

    def _before_item(self, point: QPoint):
        self._set_drop_indicator(point)
        if self._drop_row is None or self._drop_row >= self.count():
            return None
        return self.item(self._drop_row)

    def eventFilter(self, watched, event):  # noqa: N802 - Qt override
        if watched is self.viewport() and event.type() in (QEvent.Type.DragEnter, QEvent.Type.DragMove):
            if event.mimeData().hasFormat(PHOTO_MIME) or event.mimeData().hasUrls():
                if event.type() == QEvent.Type.DragMove:
                    self._set_drop_indicator(event.position().toPoint())
                event.acceptProposedAction()
                return True
        if watched is self.viewport() and event.type() == QEvent.Type.Drop:
            if event.mimeData().hasFormat(PHOTO_MIME) or event.mimeData().hasUrls():
                self.dropEvent(event)
                return True
        return super().eventFilter(watched, event)

    def startDrag(self, supported_actions):  # noqa: N802 - Qt override
        ids = [item.data(Qt.ItemDataRole.UserRole) for item in self.selectedItems()]
        if not ids:
            return
        mime = QMimeData()
        payload = {"photo_ids": ids, "source_slot_id": self.slot_id, "source_explicit": True}
        mime.setData(PHOTO_MIME, QByteArray(json.dumps(payload).encode("utf-8")))
        drag = QDrag(self)
        drag.setMimeData(mime)
        first = self.currentItem()
        if first:
            drag.setPixmap(first.icon().pixmap(QSize(100, 70)))
        drag.exec(Qt.DropAction.CopyAction | Qt.DropAction.MoveAction)

    def dragEnterEvent(self, event):  # noqa: N802 - Qt override
        if event.mimeData().hasFormat(PHOTO_MIME) or event.mimeData().hasUrls():
            event.acceptProposedAction()
        else:
            event.ignore()

    def dragMoveEvent(self, event):  # noqa: N802 - Qt override
        if event.mimeData().hasFormat(PHOTO_MIME) or event.mimeData().hasUrls():
            self._set_drop_indicator(event.position().toPoint())
            event.acceptProposedAction()
        else:
            event.ignore()

    def dropEvent(self, event):  # noqa: N802 - Qt override
        if event.mimeData().hasUrls():
            self._set_drop_indicator(None)
            paths = []
            for url in event.mimeData().urls():
                path = Path(url.toLocalFile())
                if path.is_dir():
                    paths.extend(str(file) for file in sorted(path.rglob("*")) if file.is_file() and file.suffix.lower() in SUPPORTED_EXTENSIONS)
                elif path.is_file() and path.suffix.lower() in SUPPORTED_EXTENSIONS:
                    paths.append(str(path))
            if paths:
                self.external_paths_dropped.emit(paths)
            event.acceptProposedAction()
            return
        if not event.mimeData().hasFormat(PHOTO_MIME):
            event.ignore()
            return
        try:
            payload = json.loads(bytes(event.mimeData().data(PHOTO_MIME)).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            event.ignore()
            return
        if isinstance(payload, dict):
            ids = payload.get("photo_ids", [])
            source_slot_id = {
                "slot_id": payload.get("source_slot_id"),
                "explicit": bool(payload.get("source_explicit", False)),
            }
        else:
            ids = payload
            source_slot_id = {"slot_id": None, "explicit": False}
        if not isinstance(ids, list) or not ids:
            event.ignore()
            return
        item = self._before_item(event.position().toPoint())
        before_id = item.data(Qt.ItemDataRole.UserRole) if item else None
        copy = bool(event.keyboardModifiers() & Qt.KeyboardModifier.ControlModifier)
        self.photo_dropped.emit(ids, before_id, copy, source_slot_id)
        event.acceptProposedAction()

    def dragLeaveEvent(self, event):  # noqa: N802 - Qt override
        self._set_drop_indicator(None)
        super().dragLeaveEvent(event)

    def paintEvent(self, event):  # noqa: N802 - Qt override
        super().paintEvent(event)
        painter = QPainter(self.viewport())
        # Draw drop indicator
        if self._drop_row is not None:
            painter.setPen(QPen(QColor("#e53935"), 4))
            if self.count() == 0:
                painter.drawLine(12, 12, 12, max(20, self.viewport().height() - 12))
            elif self._drop_row < self.count():
                rect = self.visualItemRect(self.item(self._drop_row))
                x = max(4, rect.left() - 5)
                painter.drawLine(x, rect.top(), x, rect.bottom())
            else:
                rect = self.visualItemRect(self.item(self.count() - 1))
                x = rect.right() + 5
                painter.drawLine(x, rect.top(), x, rect.bottom())
        painter.end()

    def keyPressEvent(self, event):  # noqa: N802 - Qt override
        if event.key() == Qt.Key.Key_Delete:
            self.delete_requested.emit()
            return
        super().keyPressEvent(event)


class SectionList(QListWidget):
    order_changed = Signal(object)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setDragDropMode(QListWidget.DragDropMode.InternalMove)
        self.setDefaultDropAction(Qt.DropAction.MoveAction)
        self.setSelectionMode(QListWidget.SelectionMode.SingleSelection)
        self.setStyleSheet("QListWidget { border: 0; padding: 4px; } QListWidget::item { padding: 9px 6px; } QListWidget::item:selected { background: #245b75; color: white; border-radius: 4px; }")

    def dropEvent(self, event):  # noqa: N802 - Qt override
        super().dropEvent(event)
        self.order_changed.emit([self.item(i).data(Qt.ItemDataRole.UserRole) for i in range(self.count())])


class ProjectDialog(QDialog):
    def __init__(self, project: dict | None = None, parent=None, settings: AppSettings | None = None):
        super().__init__(parent)
        self.setWindowTitle("工程基本資料")
        self.setMinimumWidth(480)
        self.settings = settings or AppSettings()
        project = project or {}
        self.fields = {}
        form = QFormLayout()
        definitions = [
            ("name", "工程名稱", True), ("project_code", "工程編號", False),
            ("report_title", "報告標題", False), ("location", "工程地點", False),
            ("client_name", "業主", False), ("contractor_name", "承包商", False),
            ("manager_name", "承辦人", False), ("company_name", "公司名稱", False),
            ("start_date", "開工日期", False), ("end_date", "完工日期", False),
        ]
        for key, label, required in definitions:
            field = QLineEdit(str(project.get(key, "")))
            field.setPlaceholderText("必填" if required else "可留白")
            self.fields[key] = field
            form.addRow(label, field)
        form.addRow("工程說明", QTextEdit(str(project.get("description", ""))))
        self.description = form.itemAt(form.rowCount() - 1, QFormLayout.ItemRole.FieldRole).widget()
        self.template_combo = QComboBox()
        self.template_combo.setEditable(True)
        self.template_combo.setToolTip("可儲存五組常用的工程基本資料，之後可切換套用。")
        for index, template in enumerate(self.settings.project_templates()):
            self.template_combo.addItem(template["name"], index)
        load_template = QPushButton("套用模板")
        save_template = QPushButton("儲存目前資料")
        load_template.clicked.connect(self.apply_selected_template)
        save_template.clicked.connect(self.save_current_template)
        template_row = QHBoxLayout()
        template_row.addWidget(self.template_combo, 1)
        template_row.addWidget(load_template)
        template_row.addWidget(save_template)
        template_box = QWidget()
        template_box.setLayout(template_row)
        template_box.setToolTip("共五組記憶模板；儲存後可在其他工程資料視窗切換套用。")
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(QLabel("工程資料記憶模板（共 5 組）"))
        layout.addWidget(template_box)
        layout.addWidget(buttons)

    def values(self) -> dict[str, str]:
        return {**{key: field.text().strip() for key, field in self.fields.items()}, "description": self.description.toPlainText().strip()}

    def apply_selected_template(self):
        index = int(self.template_combo.currentData() or 0)
        values = self.settings.load_project_template(index)
        if not values:
            QMessageBox.information(self, "模板尚未儲存", "目前選取的模板還沒有資料。")
            return
        for key, field in self.fields.items():
            if key in values:
                field.setText(values[key])
        self.description.setPlainText(values.get("description", ""))

    def save_current_template(self):
        index = int(self.template_combo.currentData() or 0)
        name = self.template_combo.currentText().strip() or f"模板 {index + 1}"
        self.settings.save_project_template(index, name, self.values())
        self.settings.save()
        self.template_combo.setItemText(index, name)
        QMessageBox.information(self, "模板已儲存", f"目前工程資料已儲存至「{name}」。")

    def accept(self):
        if not self.fields["name"].text().strip():
            QMessageBox.warning(self, "資料不完整", "工程名稱不能空白。")
            return
        super().accept()


class SuggestionDialog(QDialog):
    def __init__(self, store: ProjectStore, parent=None, description: str | None = None):
        super().__init__(parent)
        self.store = store
        self.setWindowTitle("自動分類建議")
        self.resize(720, 430)
        self.table = QListWidget()
        self.table.setSelectionMode(QListWidget.SelectionMode.ExtendedSelection)
        self.refresh()
        accept_selected = QPushButton("接受選取")
        accept_all = QPushButton("接受全部")
        reject_selected = QPushButton("退回未分類")
        close = QPushButton("關閉")
        accept_selected.clicked.connect(self.accept_selected)
        accept_all.clicked.connect(self.accept_all)
        reject_selected.clicked.connect(self.reject_selected)
        close.clicked.connect(self.accept)
        buttons = QHBoxLayout()
        buttons.addWidget(accept_selected)
        buttons.addWidget(accept_all)
        buttons.addWidget(reject_selected)
        buttons.addStretch()
        buttons.addWidget(close)
        layout = QVBoxLayout(self)
        layout.addWidget(QLabel(description or (
            "AI 會先把信心度較高的照片放到建議項目／欄位；低信心或無法辨識的照片會留在未分類。"
            "你可以接受、退回，或關閉視窗後直接拖曳修正。人工移動不會被 AI 覆蓋。"
        )))
        layout.addWidget(self.table)
        layout.addLayout(buttons)

    def refresh(self):
        self.table.clear()
        for row in self.store.suggestions():
            item = QListWidgetItem(f"{row['original_filename']}  →  {row['section_name']} / {row['slot_name']}  ({row['confidence']:.0%})")
            item.setData(Qt.ItemDataRole.UserRole, row["id"])
            self.table.addItem(item)

    def accept_selected(self):
        self.store.accept_suggestions([item.data(Qt.ItemDataRole.UserRole) for item in self.table.selectedItems()])
        self.refresh()

    def accept_all(self):
        self.store.accept_suggestions([self.table.item(i).data(Qt.ItemDataRole.UserRole) for i in range(self.table.count())])
        self.refresh()

    def reject_selected(self):
        self.store.reject_suggestions([item.data(Qt.ItemDataRole.UserRole) for item in self.table.selectedItems()])
        self.refresh()


class NumberingDialog(QDialog):
    _last_settings: dict = {}

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("目前欄位照片編號")
        self.setMinimumWidth(430)
        saved = NumberingDialog._last_settings
        self.position_combo = QComboBox()
        for label, value in (("右上", "top_right"), ("左上", "top_left"), ("右下", "bottom_right"), ("左下", "bottom_left")):
            self.position_combo.addItem(label, value)
        self.position_combo.setCurrentIndex(max(0, self.position_combo.findData(saved.get("position", "top_right"))))
        self.color_combo = QComboBox()
        for label, color in (("紅色", "#D32F2F"), ("藍色", "#1565C0"), ("黑色", "#212121"), ("綠色", "#2E7D32")):
            self.color_combo.addItem(label, color)
        self.color_combo.setCurrentIndex(max(0, self.color_combo.findData(saved.get("color", "#D32F2F"))))
        self.size_spin = QSpinBox()
        self.size_spin.setRange(16, 400)
        self.size_spin.setValue(saved.get("size", 72))
        self.size_spin.setSuffix(" px")
        self.transparent_check = QCheckBox("底色透明（只顯示有顏色的數字）")
        self.transparent_check.setChecked(saved.get("transparent", False))
        form = QFormLayout()
        form.addRow("編號位置", self.position_combo)
        form.addRow("編號顏色", self.color_combo)
        form.addRow("編號大小", self.size_spin)
        form.addRow("底部樣式", self.transparent_check)
        note = QLabel("編號會依目前頁籤欄位的照片順序，由左至右、由上至下重新生成；不會影響其他項目或欄位。")
        note.setWordWrap(True)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(note)
        layout.addWidget(buttons)

    def position(self) -> str:
        return self.position_combo.currentData()

    def color(self) -> str:
        return self.color_combo.currentData()

    def size(self) -> str:
        return str(self.size_spin.value())

    def transparent(self) -> bool:
        return self.transparent_check.isChecked()

    def accept(self):
        NumberingDialog._last_settings = {
            "position": self.position(),
            "color": self.color(),
            "size": self.size_spin.value(),
            "transparent": self.transparent(),
        }
        super().accept()


class HelpDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle(f"使用說明與版本紀錄｜v{__version__}")
        self.resize(760, 560)
        tabs = QTabWidget()
        guide = QTextEdit()
        guide.setReadOnly(True)
        guide.setPlainText(USER_GUIDE)
        changelog = QTextEdit()
        changelog.setReadOnly(True)
        changelog.setPlainText(CHANGELOG)
        tabs.addTab(guide, "使用說明")
        tabs.addTab(changelog, "版本更新紀錄")
        close = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        close.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addWidget(QLabel(f"工程照片整理器 SitePhoto Report v{__version__}"))
        layout.addWidget(tabs)
        layout.addWidget(close)


class ExportDialog(QDialog):
    format_action_requested = Signal(str, bool)

    def __init__(self, settings: AppSettings, project_name: str, project_root: Path, parent=None, number_summary: list[dict] | None = None):
        super().__init__(parent)
        self.setWindowTitle("選擇報告輸出格式")
        self.setMinimumWidth(560)
        self.pdf = QCheckBox("PDF（正式交付報告）")
        self.word = QCheckBox("Word（可再編輯）")
        self.excel = QCheckBox("Excel（照片清冊）")
        for checkbox in (self.pdf, self.word, self.excel):
            checkbox.setChecked(True)
        self.pdf_photos_per_page = QComboBox()
        for label, count in (("每頁 1 張（大圖）", 1), ("每頁 2 張", 2), ("每頁 4 張（建議）", 4), ("每頁 6 張", 6)):
            self.pdf_photos_per_page.addItem(label, count)
        self.pdf_photos_per_page.setCurrentIndex(2)
        self.pdf.toggled.connect(self.pdf_photos_per_page.setEnabled)
        self.pdf_template = QComboBox()
        for template_key, template_label, template_description in PDF_TEMPLATE_OPTIONS:
            self.pdf_template.addItem(template_label, template_key)
            self.pdf_template.setItemData(
                self.pdf_template.count() - 1,
                template_description,
                Qt.ItemDataRole.ToolTipRole,
            )
        self.pdf_template.setCurrentIndex(self.pdf_template.findData("modern"))
        self.pdf.toggled.connect(self.pdf_template.setEnabled)
        template_row = QWidget()
        template_row_layout = QHBoxLayout(template_row)
        template_row_layout.setContentsMargins(0, 0, 0, 0)
        template_preview_button = QPushButton("預覽目前模板")
        template_preview_button.clicked.connect(
            lambda: self.format_action_requested.emit("pdf", True)
        )
        template_row_layout.addWidget(self.pdf_template)
        template_row_layout.addWidget(template_preview_button)
        output_dir = settings.project_export_directory(project_name, project_root)
        self.output_label = QLabel(str(output_dir))
        self.output_label.setWordWrap(True)
        self.timestamp_label = QLabel("開啟" if settings.show_timestamp else "關閉")
        self.filename_label = QLabel("開啟" if settings.show_filename else "關閉")
        self.open_after = QCheckBox("輸出完成後自動開啟資料夾")
        self.open_after.setChecked(settings.open_export_after)
        form = QFormLayout()
        form.addRow("輸出位置", self.output_label)
        form.addRow("照片時間戳", self.timestamp_label)
        form.addRow("輸出檔名", self.filename_label)
        form.addRow("檔案格式", self.pdf)
        form.addRow("", self.word)
        form.addRow("", self.excel)
        form.addRow("PDF 每頁照片數", self.pdf_photos_per_page)
        form.addRow("PDF 模板", template_row)
        form.addRow("", self.open_after)
        # Numbering status summary
        if number_summary:
            parts = []
            for row in number_summary:
                if row["numbered"] > 0:
                    parts.append(f"{row['section_name']}／{row['slot_name']}（{row['numbered']}張✓）")
                else:
                    parts.append(f"{row['section_name']}／{row['slot_name']}（無編號）")
            number_label = QLabel("編號狀態：" + "、".join(parts))
            number_label.setWordWrap(True)
            number_label.setStyleSheet("color: #555; font-size: 11px;")
            form.addRow("照片編號", number_label)
        note = QLabel("PDF 會依選定張數自動建立滿版格線：2 張上下排列、4 張 2×2、6 張 2 欄×3 列；圖片保持比例縮放。模板可選黑白省墨、清爽藍綠或暖棕工程版；按「預覽目前模板」或下方 PDF 預覽即可查看。")
        note.setWordWrap(True)
        individual_title = QLabel("單獨操作（不必關閉本視窗）")
        individual_title.setStyleSheet("font-weight: bold; color: #245B75;")
        individual_buttons = QGridLayout()
        for row_index, (format_name, label) in enumerate((("pdf", "PDF"), ("word", "Word"), ("excel", "Excel"))):
            preview_button = QPushButton(f"{label} 預覽")
            export_button = QPushButton(f"{label} 輸出")
            preview_button.clicked.connect(
                lambda _checked=False, name=format_name: self.format_action_requested.emit(name, True)
            )
            export_button.clicked.connect(
                lambda _checked=False, name=format_name: self.format_action_requested.emit(name, False)
            )
            individual_buttons.addWidget(preview_button, row_index, 0)
            individual_buttons.addWidget(export_button, row_index, 1)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(note)
        layout.addWidget(individual_title)
        layout.addLayout(individual_buttons)
        layout.addWidget(buttons)

    def selected_formats(self) -> list[str]:
        return [name for name, checkbox in (("pdf", self.pdf), ("word", self.word), ("excel", self.excel)) if checkbox.isChecked()]

    def accept(self):
        if not self.selected_formats():
            QMessageBox.warning(self, "尚未選擇格式", "請至少勾選一種輸出格式。")
            return
        super().accept()


class SettingsDialog(QDialog):
    def __init__(self, settings: AppSettings, parent=None):
        super().__init__(parent)
        self.settings = settings
        self.setWindowTitle("程式設定")
        self.resize(760, 560)
        tabs = QTabWidget()
        tabs.addTab(self._build_general_tab(), "一般設定")
        tabs.addTab(self._build_api_tab(), "API 設定")
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addWidget(tabs)
        layout.addWidget(buttons)

    def _build_general_tab(self) -> QWidget:
        widget = QWidget()
        form = QFormLayout(widget)
        self.project_dir = QLineEdit(str(self.settings.default_project_directory))
        self.export_dir = QLineEdit(str(self.settings.export_directory))
        form.addRow("預設工程位置", self._path_row(self.project_dir))
        form.addRow("固定報告輸出位置", self._path_row(self.export_dir))
        self.show_timestamp = QCheckBox("輸出照片拍攝時間戳／日期")
        self.show_timestamp.setChecked(self.settings.show_timestamp)
        self.show_filename = QCheckBox("輸出原始檔名")
        self.show_filename.setChecked(self.settings.show_filename)
        self.open_export_after = QCheckBox("輸出完成後自動開啟工程資料夾")
        self.open_export_after.setChecked(self.settings.open_export_after)
        form.addRow("照片時間戳", self.show_timestamp)
        form.addRow("照片檔名", self.show_filename)
        form.addRow("輸出完成", self.open_export_after)
        note = QLabel("原始照片不會被加入時間戳、檔名或覆寫；這兩個開關只控制報告與照片清冊的顯示。")
        note.setWordWrap(True)
        form.addRow("說明", note)
        return widget

    def _path_row(self, field: QLineEdit) -> QWidget:
        widget = QWidget()
        layout = QHBoxLayout(widget)
        layout.setContentsMargins(0, 0, 0, 0)
        browse = QPushButton("瀏覽…")
        browse.clicked.connect(lambda: self._browse_into(field))
        layout.addWidget(field)
        layout.addWidget(browse)
        return widget

    def _browse_into(self, field: QLineEdit):
        selected = QFileDialog.getExistingDirectory(self, "選擇資料夾", field.text() or str(Path.home()))
        if selected:
            field.setText(selected)

    def _build_api_tab(self) -> QWidget:
        widget = QWidget()
        layout = QVBoxLayout(widget)
        self.api_combo = QComboBox()
        self.api_combo.currentIndexChanged.connect(self._load_selected_api)
        layout.addWidget(QLabel("目前 API 設定"))
        layout.addWidget(self.api_combo)
        form = QFormLayout()
        self.api_name = QLineEdit()
        self.api_endpoint = QLineEdit()
        self.api_endpoint.setPlaceholderText("例如：https://api.openai.com/v1")
        self.api_key = QLineEdit()
        self.api_key.setEchoMode(QLineEdit.EchoMode.Password)
        self.api_model = QLineEdit()
        self.api_model.setPlaceholderText("例如：gpt-4o-mini")
        self.api_vision_model = QLineEdit()
        self.api_vision_model.setPlaceholderText("建議：gemini-3.1-flash-lite")
        form.addRow("設定名稱", self.api_name)
        form.addRow("API Base URL", self.api_endpoint)
        form.addRow("API Key", self.api_key)
        form.addRow("模型名稱", self.api_model)
        form.addRow("視覺模型名稱", self.api_vision_model)
        layout.addLayout(form)
        hint = QLabel("自動分類會把未分類照片送給視覺模型，只產生建議，不會直接覆蓋人工分類。建議 Google Gemini 3.1 Flash-Lite；官方 OpenAI 相容 Base URL：https://generativelanguage.googleapis.com/v1beta/openai/。測試會呼叫 Base URL + /models。")
        hint.setWordWrap(True)
        layout.addWidget(hint)
        buttons = QHBoxLayout()
        new_button = QPushButton("新增設定")
        save_button = QPushButton("儲存此設定")
        delete_button = QPushButton("刪除設定")
        test_button = QPushButton("測試接通")
        new_button.clicked.connect(self._new_api)
        save_button.clicked.connect(self._save_api)
        delete_button.clicked.connect(self._delete_api)
        test_button.clicked.connect(self._test_api)
        for button in (new_button, save_button, delete_button, test_button):
            buttons.addWidget(button)
        layout.addLayout(buttons)
        layout.addStretch()
        self._api_previous_name = ""
        self._refresh_api_combo()
        return widget

    def _refresh_api_combo(self):
        if not hasattr(self, "api_combo"):
            return
        active = self.settings.data.get("active_api_profile", "")
        self.api_combo.blockSignals(True)
        self.api_combo.clear()
        self.api_combo.addItem("（未選擇 API）", "")
        for profile in self.settings.api_profiles():
            self.api_combo.addItem(profile["name"], profile["name"])
        index = self.api_combo.findData(active)
        self.api_combo.setCurrentIndex(index if index >= 0 else 0)
        self.api_combo.blockSignals(False)
        self._load_selected_api(self.api_combo.currentIndex())

    def _load_selected_api(self, index: int):
        name = self.api_combo.itemData(index) if index >= 0 else ""
        profile = next((item for item in self.settings.api_profiles() if item.get("name") == name), None)
        profile = profile or {"name": "", "endpoint": "", "api_key": "", "model": ""}
        self.api_name.setText(profile.get("name", ""))
        self.api_endpoint.setText(profile.get("endpoint", ""))
        self.api_key.setText(profile.get("api_key", ""))
        self.api_model.setText(profile.get("model", ""))
        self.api_vision_model.setText(profile.get("vision_model", ""))
        self._api_previous_name = profile.get("name", "")

    def _new_api(self):
        self.api_combo.setCurrentIndex(0)
        self.api_name.clear()
        self.api_endpoint.clear()
        self.api_key.clear()
        self.api_model.clear()
        self.api_vision_model.clear()
        self._api_previous_name = ""

    def _current_api(self) -> dict[str, str]:
        return {"name": self.api_name.text(), "endpoint": self.api_endpoint.text(), "api_key": self.api_key.text(), "model": self.api_model.text(), "vision_model": self.api_vision_model.text()}

    def _save_api(self):
        profile = self._current_api()
        if not profile["name"].strip() or not profile["endpoint"].strip():
            QMessageBox.warning(self, "資料不完整", "API 設定名稱與 Base URL 不能空白。")
            return
        self.settings.save_api_profile(profile, self._api_previous_name)
        self.settings.save()
        self._refresh_api_combo()
        QMessageBox.information(self, "已儲存", f"API 設定「{profile['name']}」已儲存並設為目前使用。")

    def _delete_api(self):
        name = self.api_name.text().strip()
        if not name:
            return
        if QMessageBox.question(self, "刪除 API 設定", f"確定刪除「{name}」？") != QMessageBox.StandardButton.Yes:
            return
        self.settings.delete_api_profile(name)
        self.settings.save()
        self._refresh_api_combo()

    def _test_api(self):
        endpoint = self.api_endpoint.text().strip()
        if not endpoint:
            QMessageBox.warning(self, "資料不完整", "請先填寫 API Base URL。")
            return
        ok, message = test_api_connection(endpoint, self.api_key.text())
        if ok:
            QMessageBox.information(self, "測試接通", message)
        else:
            QMessageBox.warning(self, "測試失敗", message)

    def accept(self):
        self.settings.set_general(
            project_directory=self.project_dir.text().strip(),
            export_directory=self.export_dir.text().strip(),
            show_timestamp=self.show_timestamp.isChecked(),
            show_filename=self.show_filename.isChecked(),
            open_export_after=self.open_export_after.isChecked(),
        )
        if self.api_name.text().strip() and self.api_endpoint.text().strip():
            self.settings.save_api_profile(self._current_api(), self._api_previous_name)
        self.settings.save()
        super().accept()


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("工程照片整理器 SitePhoto Report")
        self.resize(1400, 850)
        self.app_settings = AppSettings()
        self.store: ProjectStore | None = None
        self.current_section_id: str | None = None
        self.grids: dict[str | None, PhotoGrid] = {}
        self.active_grid: PhotoGrid | None = None
        self.active_placement_id: str | None = None
        self.last_output_dir: Path | None = None
        self.unclassified_sort = "time_asc"
        self.photo_sort_modes = {None: self.unclassified_sort}
        self.ai_worker: VisionWorker | None = None
        self._undo_stack: list[dict] = []
        self._build_ui()
        self._set_enabled(False)
        self.statusBar().showMessage("請新增或開啟工程")

    def _build_ui(self):
        toolbar = QToolBar("主要操作")
        toolbar.setMovable(False)
        self.addToolBar(toolbar)
        actions = [
            ("新增工程", self.new_project, "Ctrl+N"), ("開啟工程", self.open_project, "Ctrl+O"),
            ("工程資料", self.edit_project, ""), ("匯入照片", self.import_photos, "Ctrl+I"),
            ("自動分類", self.auto_classify, ""), ("儲存", self.save_project, "Ctrl+S"),
            ("報告輸出", self.export_reports, "Ctrl+E"),
            ("復原刪除", self.restore_deleted, ""), ("復原上一步", self.undo_last, "Ctrl+Z"),
            ("開啟輸出資料夾", self.open_export_folder, ""), ("設定", self.open_settings, ""),
            ("說明", self.open_help, ""),
        ]
        for label, callback, shortcut in actions:
            action = QAction(label, self)
            if shortcut:
                action.setShortcut(QKeySequence(shortcut))
            action.triggered.connect(callback)
            toolbar.addAction(action)
        self.sections = SectionList()
        self.sections.currentItemChanged.connect(self.section_changed)
        self.sections.order_changed.connect(self.section_order_changed)
        self.sections.itemDoubleClicked.connect(self.rename_section)
        section_box = QWidget()
        section_layout = QVBoxLayout(section_box)
        section_layout.setContentsMargins(6, 6, 6, 6)
        section_layout.addWidget(QLabel("工程項目"))
        section_layout.addWidget(self.sections)
        section_buttons = QGridLayout()
        for index, (label, callback) in enumerate((
            ("新增項目", self.add_section), ("新增欄位", self.add_slot),
            ("上移", lambda: self.nudge_section(-1)), ("下移", lambda: self.nudge_section(1)), ("刪除", self.delete_section),
        )):
            button = QPushButton(label)
            button.clicked.connect(callback)
            section_buttons.addWidget(button, index // 2, index % 2)
        section_layout.addLayout(section_buttons)
        number_all_btn = QPushButton("一鍵全部欄位編號")
        number_all_btn.setToolTip("為所有欄位的照片各自從 1 開始編號")
        number_all_btn.clicked.connect(self.number_all_slots)
        clear_all_btn = QPushButton("一鍵取消所有編號")
        clear_all_btn.clicked.connect(self.clear_all_numbers)
        section_layout.addWidget(number_all_btn)
        section_layout.addWidget(clear_all_btn)

        self.tabs = QTabWidget()
        self.tab_bar = PhotoTabBar()
        self.tabs.setTabBar(self.tab_bar)
        self.tab_bar.photo_tab_dropped.connect(self.handle_tab_photo_drop)
        self.tabs.currentChanged.connect(self.tab_changed)
        self.tabs.tabBar().setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.tabs.tabBar().customContextMenuRequested.connect(self.tab_context_menu)
        self.add_field_button = QPushButton("+")
        self.add_field_button.setFixedSize(24, 24)
        self.add_field_button.setToolTip("一次新增最多 10 個照片欄位；空白名稱會略過")
        self.add_field_button.clicked.connect(self.add_slot)
        self.tabs.setCornerWidget(self.add_field_button, Qt.Corner.TopRightCorner)
        self.empty_label = QLabel("請先開啟工程，再匯入照片。\n照片可拖曳到欄位，也可使用 Ctrl／Shift 多選。")
        self.empty_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.tabs.setEnabled(False)

        self.filename = QLabel("未選取照片")
        self.filename.setWordWrap(True)
        self.photo_preview = PhotoPreviewLabel()
        self.photo_preview.setFixedSize(260, 190)
        self.photo_preview.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.photo_preview.setStyleSheet("background: #eef2f4; border: 1px solid #d4dce1;")
        self.photo_preview.setToolTip("點擊放大檢視照片")
        self.photo_preview.clicked.connect(self.view_selected_photo)
        self.photo_date = QLabel("")
        self.caption = QTextEdit()
        self.caption.setPlaceholderText("照片說明")
        self.caption.setFixedHeight(90)
        self.location = QLineEdit()
        self.location.setPlaceholderText("施工位置（可留白）")
        self.include = QCheckBox("加入報告")
        self.include.setChecked(True)
        save_prop = QPushButton("儲存照片屬性")
        save_prop.clicked.connect(self.save_photo_properties)
        open_original = QPushButton("開啟原始照片")
        open_original.clicked.connect(self.open_original)
        rotate_buttons = QHBoxLayout()
        rotate_left = QPushButton("左轉 90°")
        rotate_right = QPushButton("右轉 90°")
        reset_rotation = QPushButton("還原旋轉")
        rotate_left.clicked.connect(lambda: self.rotate_photo(-90))
        rotate_right.clicked.connect(lambda: self.rotate_photo(90))
        reset_rotation.clicked.connect(self.reset_rotation)
        rotate_buttons.addWidget(rotate_left)
        rotate_buttons.addWidget(rotate_right)
        rotate_buttons.addWidget(reset_rotation)
        self.rotation_label = QLabel("旋轉：0°（原圖不變）")
        property_box = QWidget()
        property_layout = QVBoxLayout(property_box)
        property_layout.setContentsMargins(8, 6, 8, 6)
        property_layout.addWidget(QLabel("照片屬性"))
        property_layout.addWidget(self.photo_preview)
        property_layout.addWidget(self.filename)
        property_layout.addWidget(self.photo_date)
        property_layout.addWidget(self.rotation_label)
        property_layout.addLayout(rotate_buttons)
        mosaic_button = QPushButton("馬賽克遮蔽／塗抹")
        mosaic_button.clicked.connect(self.open_mosaic_editor)
        property_layout.addWidget(mosaic_button)
        number_button = QPushButton("為目前欄位生成編號")
        number_button.clicked.connect(self.open_numbering_dialog)
        clear_number_button = QPushButton("取消目前欄位編號")
        clear_number_button.clicked.connect(self.clear_field_numbers)
        property_layout.addWidget(number_button)
        property_layout.addWidget(clear_number_button)
        property_layout.addWidget(QLabel("照片說明"))
        property_layout.addWidget(self.caption)
        property_layout.addWidget(QLabel("施工位置"))
        property_layout.addWidget(self.location)
        property_layout.addWidget(self.include)
        property_layout.addWidget(save_prop)
        property_layout.addWidget(open_original)
        property_layout.addStretch()

        splitter = QSplitter(Qt.Orientation.Horizontal)
        splitter.addWidget(section_box)
        center_box = QWidget()
        center_layout = QVBoxLayout(center_box)
        center_layout.setContentsMargins(0, 0, 0, 0)
        self.loading_label = QLabel("照片載入中，請稍候…")
        self.loading_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.loading_label.setStyleSheet("QLabel { color: #245b75; background: #fff7d6; border: 1px solid #e6c85c; padding: 6px; }")
        self.loading_label.setVisible(False)
        center_layout.addWidget(self.loading_label)
        center_layout.addWidget(self.tabs)
        self.order_hint = QLabel("排序說明：報告輸出時依目前欄位由左至右、由上至下。拖曳時紅色插入線代表照片會放入的位置；跨欄位請將照片拖到上方目標欄位頁籤。未分類區按右鍵可選拍攝時間或檔名遞增／遞減；編號功能只作用於目前頁籤欄位。")
        self.order_hint.setWordWrap(True)
        self.order_hint.setStyleSheet("QLabel { color: #245b75; background: #eaf4f8; border: 1px solid #c4dce6; padding: 6px; }")
        center_layout.addWidget(self.order_hint)
        splitter.addWidget(center_box)
        splitter.addWidget(property_box)
        splitter.setSizes([240, 850, 300])
        self.setCentralWidget(splitter)

    def _set_enabled(self, enabled: bool):
        self.sections.setEnabled(enabled)
        self.tabs.setEnabled(enabled)

    def _set_loading(self, visible: bool, text: str = "照片載入中，請稍候…"):
        if hasattr(self, "loading_label"):
            self.loading_label.setText(text)
            self.loading_label.setVisible(visible)

    def _close_store(self):
        if self.store:
            self.store.save_manifest()
            self.store.close()
        self.store = None
        self.current_section_id = None
        self.grids.clear()

    def new_project(self):
        dialog = ProjectDialog(parent=self, settings=self.app_settings)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        self.app_settings.default_project_directory.mkdir(parents=True, exist_ok=True)
        parent = QFileDialog.getExistingDirectory(self, "選擇工程專案的儲存位置", str(self.app_settings.default_project_directory))
        if not parent:
            return
        values = dialog.values()
        root = Path(parent) / f"{values['name']}.sprj"
        if root.exists():
            QMessageBox.warning(self, "工程已存在", f"資料夾已存在：\n{root}\n請選擇其他工程名稱或位置。")
            return
        self._close_store()
        self.store = ProjectStore(root)
        self.store.update_project(**values)
        self.store.ensure_default_sections()
        self._remember_recent(root)
        self.refresh_all()

    def open_project(self):
        root = QFileDialog.getExistingDirectory(self, "選擇 .sprj 工程資料夾", str(Path.home() / "Documents"))
        if not root:
            return
        if not (Path(root) / "project.sqlite").exists():
            QMessageBox.warning(self, "不是工程專案", "選取的資料夾找不到 project.sqlite。")
            return
        self._close_store()
        self.store = ProjectStore(root)
        self.store.ensure_default_sections()
        self._remember_recent(Path(root))
        # Rebuild missing thumbnails in background
        missing = sum(1 for ph in self.store.photos()
                      if not (self.store.root / ph["thumbnail_rel_path"]).exists()
                      or not (self.store.root / ph["preview_rel_path"]).exists())
        if missing:
            self._set_loading(True, f"重建縮圖中… 0/{missing}")
            QApplication.processEvents()
            rebuilt = self.store.rebuild_thumbnails(
                progress=lambda i, t: (self._set_loading(True, f"重建縮圖中… {i}/{t}"), QApplication.processEvents()))
            self._set_loading(False)
            if rebuilt:
                self.statusBar().showMessage(f"已重建 {rebuilt} 張縮圖")
        self.refresh_all()

    def edit_project(self):
        if not self.store:
            return
        dialog = ProjectDialog(dict(self.store.project()), self, self.app_settings)
        if dialog.exec() == QDialog.DialogCode.Accepted:
            self.store.update_project(**dialog.values())
            self.refresh_all()

    def import_photos(self):
        if not self.store:
            return
        paths, _ = QFileDialog.getOpenFileNames(self, "匯入工程照片", str(Path.home()), "圖片 (*.jpg *.jpeg *.png *.webp *.bmp)")
        if not paths:
            return
        imported, skipped = [], []
        self._set_loading(True, f"照片載入中… 0/{len(paths)}")
        QApplication.processEvents()
        try:
            imported, skipped = self.store.import_files(
                paths,
                progress=lambda index, total: self._import_progress(index, total),
            )
            self.refresh_grids()
        finally:
            self._set_loading(False)
        self.statusBar().showMessage(f"已匯入 {len(imported)} 張照片；略過 {len(skipped)} 張。")

    def _import_progress(self, index: int, total: int):
        self._set_loading(True, f"照片載入中… {index}/{total}")
        QApplication.processEvents()

    def add_section(self):
        if not self.store:
            return
        dialog = BatchNameDialog("批次新增工程項目", "項目名稱", self)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        names = dialog.values()
        if not names:
            return
        section_id = None
        for name in names:
            section_id = self.store.add_section(name)
        self.refresh_sections(section_id)
        self.statusBar().showMessage(f"已新增 {len(names)} 個工程項目")

    def add_slot(self):
        if not self.store or not self.current_section_id:
            return
        dialog = BatchNameDialog("批次新增照片欄位", "欄位名稱", self)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        names = dialog.values()
        if not names:
            return
        for name in names:
            self.store.add_slot(self.current_section_id, name)
        self.rebuild_tabs()
        self.statusBar().showMessage(f"已新增 {len(names)} 個照片欄位")

    def tab_context_menu(self, point: QPoint):
        index = self.tabs.tabBar().tabAt(point)
        if index <= 0 or index >= self.tabs.count():
            return
        grid = self.tabs.widget(index)
        slot_id = grid.slot_id if isinstance(grid, PhotoGrid) else None
        if not slot_id:
            return
        menu = QMenu(self)
        menu.addAction("刪除欄位", lambda: self.delete_slot(slot_id))
        menu.exec(self.tabs.tabBar().mapToGlobal(point))

    def delete_slot(self, slot_id: str | None = None):
        if not self.store:
            return
        slot_id = slot_id or (self.active_grid.slot_id if self.active_grid else None)
        if not slot_id:
            return
        slot = self.store.db.execute("SELECT * FROM slots WHERE id = ?", (slot_id,)).fetchone()
        if not slot:
            return
        count = len(self.store.placements_for_slot(slot_id))
        answer = QMessageBox.question(
            self, "刪除照片欄位",
            f"確定刪除欄位「{slot['name']}」？\n其中 {count} 張照片會回到未分類區。",
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        self.store.delete_slot(slot_id)
        self.rebuild_tabs()
        self.statusBar().showMessage(f"欄位「{slot['name']}」已刪除，照片已回到未分類。")

    def rename_section(self, item):
        if not self.store:
            return
        section_id = item.data(Qt.ItemDataRole.UserRole)
        dialog = SimpleTextDialog("修改工程項目", "項目名稱", self, item.text())
        if dialog.exec() == QDialog.DialogCode.Accepted:
            self.store.rename_section(section_id, dialog.value())
            self.refresh_sections(section_id)

    def delete_section(self):
        if not self.store or not self.current_section_id:
            return
        section = next((row for row in self.store.sections() if row["id"] == self.current_section_id), None)
        if not section:
            return
        answer = QMessageBox.question(self, "刪除工程項目", f"刪除「{section['name']}」？其中照片會回到未分類區。")
        if answer != QMessageBox.StandardButton.Yes:
            return
        self.store.delete_section(self.current_section_id)
        self.refresh_all()

    def nudge_section(self, direction: int):
        if self.store and self.current_section_id:
            self.store.move_section(self.current_section_id, direction)
            self.refresh_sections(self.current_section_id)

    def section_order_changed(self, section_ids):
        if self.store:
            self.store.set_section_order(list(section_ids))

    def section_changed(self, current, previous):
        self.current_section_id = current.data(Qt.ItemDataRole.UserRole) if current else None
        self.rebuild_tabs()

    def tab_changed(self, index: int):
        if 0 <= index < self.tabs.count():
            self.active_grid = self.tabs.widget(index)
            self.clear_properties()

    def rebuild_tabs(self):
        self.tabs.blockSignals(True)
        while self.tabs.count():
            self.tabs.removeTab(0)
        self.grids.clear()
        if not self.store or not self.current_section_id:
            self.tabs.blockSignals(False)
            return
        unclassified = PhotoGrid(None, self)
        self._connect_grid(unclassified)
        self.grids[None] = unclassified
        self.tabs.addTab(unclassified, "未分類")
        for slot in self.store.slots(self.current_section_id):
            grid = PhotoGrid(slot["id"], self)
            self._connect_grid(grid)
            self.grids[slot["id"]] = grid
            self.tabs.addTab(grid, slot["name"])
        self.tabs.blockSignals(False)
        self.tabs.setCurrentIndex(0)
        self.refresh_grids()

    def _connect_grid(self, grid: PhotoGrid):
        grid.setItemDelegate(DateSeparatorDelegate(grid))
        grid.photo_dropped.connect(lambda ids, before, copy, source_slot, target=grid: self.handle_photo_drop(target, ids, before, copy, source_slot))
        grid.external_paths_dropped.connect(lambda paths, target=grid: self.handle_external_drop(target, paths))
        grid.itemSelectionChanged.connect(lambda target=grid: self.grid_selection_changed(target))
        grid.delete_requested.connect(lambda target=grid: self.delete_selected(target))
        grid.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        grid.customContextMenuRequested.connect(lambda point, target=grid: self.show_photo_menu(target, point))

    def handle_tab_photo_drop(self, index: int, photo_ids: list[str], copy: bool, source_ref: object):
        """Move a drag to the field represented by a tab label.

        Only one field is visible at a time, so the tab bar is the explicit
        cross-field drop target.  The source reference is carried in the MIME
        payload, including an explicit ``None`` for the unclassified field.
        """
        if not (0 <= index < self.tabs.count()):
            return
        target = self.tabs.widget(index)
        if isinstance(target, PhotoGrid):
            self.handle_photo_drop(target, photo_ids, None, copy, source_ref)

    def handle_external_drop(self, target: PhotoGrid, paths: list[str]):
        if not self.store or target.slot_id is not None:
            QMessageBox.information(self, "請拖到未分類", "外部資料夾照片請一次拖到「未分類」區域。")
            return
        imported, skipped = [], []
        self._set_loading(True, f"照片載入中… 0/{len(paths)}")
        QApplication.processEvents()
        try:
            imported, skipped = self.store.import_files(
                paths,
                progress=lambda index, total: self._import_progress(index, total),
            )
            self.refresh_grids()
        finally:
            self._set_loading(False)
        self.statusBar().showMessage(f"已從外部資料夾批次匯入 {len(imported)} 張照片；略過 {len(skipped)} 張。")

    def refresh_all(self):
        if not self.store:
            self.setWindowTitle("工程照片整理器 SitePhoto Report")
            self._set_enabled(False)
            return
        self._set_enabled(True)
        self.setWindowTitle(f"工程照片整理器｜{self.store.project()['name']}")
        self.refresh_sections(self.current_section_id)
        self.statusBar().showMessage(f"專案：{self.store.root}｜照片 {len(self.store.photos())} 張")

    def refresh_sections(self, selected_id: str | None = None):
        if not self.store:
            return
        selected_id = selected_id or self.current_section_id
        self.sections.blockSignals(True)
        self.sections.clear()
        rows = self.store.sections()
        for index, row in enumerate(rows):
            item = QListWidgetItem(f"{index + 1:02d}  {row['name']}")
            item.setData(Qt.ItemDataRole.UserRole, row["id"])
            self.sections.addItem(item)
        self.sections.blockSignals(False)
        if rows:
            index = next((i for i, row in enumerate(rows) if row["id"] == selected_id), 0)
            self.sections.setCurrentRow(index)
        else:
            self.current_section_id = None
            self.rebuild_tabs()

    def refresh_grids(self):
        if not self.store:
            return
        for slot_id, grid in self.grids.items():
            selected_ids = {item.data(Qt.ItemDataRole.UserRole) for item in grid.selectedItems()}
            grid.blockSignals(True)
            grid.clear()
            last_date = None
            rows = self.store.placements_for_slot(slot_id)
            sort_mode = self.photo_sort_modes.get(slot_id, "manual")
            rows = sort_photo_rows(rows, sort_mode)
            for row in rows:
                # Date separator for unclassified grid
                if slot_id is None:
                    raw_day = str(row["captured_at"] or "").strip()[:10]
                    day = raw_day.replace(":", "-") if raw_day else ""
                    if day and day != last_date:
                        last_date = day
                        sep = QListWidgetItem(f"📅 {day}")
                        sep.setFlags(Qt.ItemFlag.ItemIsEnabled)
                        sep.setSizeHint(QSize(99999, 30))
                        sep.setData(Qt.ItemDataRole.UserRole + 1, "date_sep")
                        grid.addItem(sep)
                edited = bool(row["number_text"] or row["rotation_degrees"] or row["crop_json"] or row["mosaic_json"])
                thumbnail = (self.store.rendered_placement_path(row["id"], max_side=320) if edited else None) or (self.store.root / row["thumbnail_rel_path"])
                label = f"{row['number_text']}  {row['original_filename']}" if row["number_text"] else row["original_filename"]
                item = QListWidgetItem(QIcon(str(thumbnail)), label)
                item.setSizeHint(QSize(175, 155))
                item.setData(Qt.ItemDataRole.UserRole, row["photo_id"])
                item.setToolTip(f"{row['original_filename']}\n{row['caption'] or '尚未填寫說明'}")

                if row["photo_id"] in selected_ids:
                    item.setSelected(True)
                grid.addItem(item)
            grid.blockSignals(False)
        if self.active_grid:
            self.grid_selection_changed(self.active_grid)

    def grid_selection_changed(self, grid: PhotoGrid):
        if not grid.selectedItems():
            return
        self.active_grid = grid
        photo_id = grid.selectedItems()[0].data(Qt.ItemDataRole.UserRole)
        placement = self.store.placement_for_photo(photo_id, grid.slot_id) if self.store else None
        photo = self.store.photo(photo_id) if self.store else None
        if not photo:
            return
        self.active_placement_id = placement["id"] if placement else None
        self.filename.setText(photo["original_filename"])
        self.photo_date.setText(f"拍攝時間：{photo['captured_at'] or '未知'}｜尺寸：{photo['width']}×{photo['height']}")
        self.rotation_label.setText(f"旋轉：{int(photo['rotation_degrees'] or 0)}°（原圖不變）")
        self.caption.setPlainText(placement["caption"] if placement else "")
        self.location.setText(placement["construction_location"] if placement else "")
        self.include.setChecked(bool(placement["include_in_report"]) if placement else True)
        preview = self.store.rendered_placement_path(placement["id"], max_side=1600) if placement else self.store.rendered_photo_path(photo_id, max_side=1600)
        preview = preview or (self.store.root / photo["preview_rel_path"])
        pixmap = QPixmap(str(preview))
        self.photo_preview.setPixmap(pixmap.scaled(self.photo_preview.size(), Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))

    def clear_properties(self):
        self.active_placement_id = None
        self.filename.setText("未選取照片")
        self.photo_date.clear()
        self.rotation_label.setText("旋轉：0°（原圖不變）")
        self.photo_preview.clear()
        self.caption.clear()
        self.location.clear()
        self.include.setChecked(True)

    def save_photo_properties(self):
        if self.store and self.active_placement_id:
            self.store.update_placement(self.active_placement_id, caption=self.caption.toPlainText().strip(), construction_location=self.location.text().strip(), include_in_report=int(self.include.isChecked()), is_human_confirmed=1)
            self.refresh_grids()
            self.statusBar().showMessage("照片屬性已儲存")

    def selected_photo_id(self) -> str | None:
        if not self.active_grid or not self.active_grid.selectedItems():
            return None
        return self.active_grid.selectedItems()[0].data(Qt.ItemDataRole.UserRole)

    def rotate_photo(self, degrees: int):
        if not self.store:
            return
        photo_id = self.selected_photo_id()
        photo = self.store.photo(photo_id) if photo_id else None
        if not photo:
            return
        current = int(photo["rotation_degrees"] or 0)
        self.store.update_photo(photo_id, rotation_degrees=current + degrees)
        self.refresh_grids()
        self.restore_photo_selection(photo_id)
        self.statusBar().showMessage("照片旋轉已儲存；原始照片未修改。")

    def reset_rotation(self):
        if not self.store:
            return
        photo_id = self.selected_photo_id()
        if photo_id:
            self.store.update_photo(photo_id, rotation_degrees=0)
            self.refresh_grids()
            self.restore_photo_selection(photo_id)
            self.statusBar().showMessage("照片旋轉已還原。")

    def restore_photo_selection(self, photo_id: str):
        if not self.active_grid:
            return
        for index in range(self.active_grid.count()):
            item = self.active_grid.item(index)
            if item.data(Qt.ItemDataRole.UserRole) == photo_id:
                self.active_grid.setCurrentItem(item)
                item.setSelected(True)
                self.grid_selection_changed(self.active_grid)
                return

    def open_mosaic_editor(self):
        if not self.store:
            return
        photo_id = self.selected_photo_id()
        if not photo_id:
            QMessageBox.information(self, "尚未選取照片", "請先選取要遮蔽的照片。")
            return
        dialog = MosaicDialog(self.store, photo_id, self.active_grid.slot_id if self.active_grid else None, self)
        if dialog.exec() == QDialog.DialogCode.Accepted:
            self.refresh_grids()
            self.restore_photo_selection(dialog.result_photo_id)
            self.statusBar().showMessage("馬賽克遮蔽已儲存；原始照片未修改。")

    def number_all_slots(self):
        """Number all slots across all sections, each starting from 1."""
        if not self.store:
            return
        all_slots = []
        for section in self.store.sections():
            for slot in self.store.slots(section["id"]):
                if self.store.placements_for_slot(slot["id"]):
                    all_slots.append(slot)
        if not all_slots:
            QMessageBox.information(self, "沒有照片", "目前沒有任何欄位有照片。")
            return
        dialog = NumberingDialog(self)
        if dialog.exec() == QDialog.DialogCode.Accepted:
            count = 0
            for slot in all_slots:
                self.store.number_slot(slot["id"], dialog.position(), dialog.color(), dialog.size(), dialog.transparent())
                count += 1
            self.refresh_grids()
            self.statusBar().showMessage(f"已為 {count} 個欄位生成編號（各自從 1 開始）")

    def clear_all_numbers(self):
        """Clear numbering from all slots."""
        if not self.store:
            return
        count = 0
        for section in self.store.sections():
            for slot in self.store.slots(section["id"]):
                self.store.clear_slot_numbers(slot["id"])
                count += 1
        self.refresh_grids()
        self.statusBar().showMessage(f"已取消所有欄位編號（{count} 個欄位）")

    def open_numbering_dialog(self):
        if not self.store or not self.active_grid:
            return
        if not self.store.placements_for_slot(self.active_grid.slot_id):
            QMessageBox.information(self, "目前欄位沒有照片", "請先在目前頁籤放入照片。")
            return
        dialog = NumberingDialog(self)
        if dialog.exec() == QDialog.DialogCode.Accepted:
            self.store.number_slot(self.active_grid.slot_id, dialog.position(), dialog.color(), dialog.size(), dialog.transparent())
            self.refresh_grids()
            self.statusBar().showMessage("目前欄位已重新生成照片編號。")

    def clear_field_numbers(self):
        if not self.store or not self.active_grid:
            return
        if QMessageBox.question(self, "取消欄位編號", "取消目前頁籤欄位的全部照片編號？") != QMessageBox.StandardButton.Yes:
            return
        self.store.clear_slot_numbers(self.active_grid.slot_id)
        self.refresh_grids()
        self.statusBar().showMessage("目前欄位照片編號已取消。")

    def view_selected_photo(self):
        if not self.store:
            return
        photo_id = self.selected_photo_id()
        photo = self.store.photo(photo_id) if photo_id else None
        if not photo:
            return
        path = self.store.rendered_photo_path(photo_id, max_side=2400)
        if path:
            ImageViewerDialog(QPixmap(str(path)), photo["original_filename"], self).exec()

    def handle_photo_drop(self, target: PhotoGrid, photo_ids: list[str], before_id: str | None, copy: bool, source_slot_id: str | None = None):
        if not self.store or not photo_ids:
            return
        source = self.active_grid
        source_explicit = isinstance(source_slot_id, dict) and source_slot_id.get("explicit", False)
        source_slot = source_slot_id.get("slot_id") if isinstance(source_slot_id, dict) else source_slot_id
        if not source_explicit and source_slot_id is None:
            source_slot = source.slot_id if source else None
        if not source_explicit and source_slot_id is not None and not isinstance(source_slot_id, dict):
            source_slot = source_slot_id
        if not source_explicit and source and source is not target:
            # The drag source is the grid that owns the selected items.
            for candidate in self.grids.values():
                if set(photo_ids).issubset({candidate.item(i).data(Qt.ItemDataRole.UserRole) for i in range(candidate.count())}):
                    source_slot = candidate.slot_id
                    break
        self._set_loading(True, f"照片移動中… {len(photo_ids)} 張")
        QApplication.processEvents()
        if not copy and source_slot != target.slot_id:
            self._undo_stack.append({"kind": "relocate", "photo_ids": list(photo_ids), "source_slot": source_slot, "target_slot": target.slot_id})
            if len(self._undo_stack) > 20:
                self._undo_stack.pop(0)
        self.store.relocate_photos(photo_ids, source_slot, target.slot_id, before_id, copy)
        self.refresh_grids()
        self._set_loading(False)
        self.statusBar().showMessage(f"已{'複製' if copy else '移動'} {len(photo_ids)} 張照片")

    def delete_selected(self, grid: PhotoGrid):
        self.delete_photos(grid)

    def delete_photos(self, grid: PhotoGrid):
        if not self.store:
            return
        ids = [item.data(Qt.ItemDataRole.UserRole) for item in grid.selectedItems()]
        if ids and QMessageBox.question(
            self, "從工程刪除照片",
            f"從目前工程移除選取的 {len(ids)} 張照片？\n原始檔仍會保留在工程 originals 資料夾。",
        ) == QMessageBox.StandardButton.Yes:
            self._undo_stack.append({"kind": "delete", "photo_ids": list(ids)})
            if len(self._undo_stack) > 20:
                self._undo_stack.pop(0)
            self.store.delete_photos(ids)
            self.refresh_grids()
            self.statusBar().showMessage(f"已從工程移除 {len(ids)} 張照片；原始檔仍保留。")

    def show_photo_menu(self, grid: PhotoGrid, point: QPoint):
        if not self.store:
            return
        from PySide6.QtWidgets import QMenu
        menu = QMenu(self)
        sort_menu = menu.addMenu("目前欄位排列方式")
        current_slot_id = grid.slot_id
        current_sort_mode = self.photo_sort_modes.get(current_slot_id, "manual")
        sort_choices = (("manual", "手動排序（保留拖曳順序）"),) + UNCLASSIFIED_SORT_OPTIONS
        for sort_value, sort_label in sort_choices:
            sort_action = sort_menu.addAction(sort_label)
            sort_action.setCheckable(True)
            sort_action.setChecked(sort_value == current_sort_mode)
            sort_action.triggered.connect(
                lambda _checked=False, selected_mode=sort_value, selected_slot=current_slot_id:
                self.set_photo_sort_mode(selected_slot, selected_mode)
            )
        menu.addSeparator()
        if not grid.selectedItems():
            menu.exec(grid.viewport().mapToGlobal(point))
            return
        move_menu = menu.addMenu("移至項目／欄位")
        for section in self.store.sections():
            section_menu = move_menu.addMenu(section["name"])
            for slot in self.store.slots(section["id"]):
                action = section_menu.addAction(slot["name"])
                action.triggered.connect(lambda _checked=False, target=slot["id"]: self.move_selected_to(grid, target))
        menu.addSeparator()
        copy_menu = menu.addMenu("複製到項目／欄位")
        for section in self.store.sections():
            section_menu = copy_menu.addMenu(section["name"])
            for slot in self.store.slots(section["id"]):
                action = section_menu.addAction(slot["name"])
                action.triggered.connect(lambda _checked=False, target=slot["id"]: self.move_selected_to(grid, target, copy=True))
        menu.addAction("移回未分類", lambda: self.move_selected_to(grid, None))
        menu.addSeparator()
        menu.addAction("刪除照片（從工程移除）", lambda: self.delete_photos(grid))
        menu.exec(grid.viewport().mapToGlobal(point))

    def set_unclassified_sort(self, mode: str):
        if mode not in {value for value, _label in UNCLASSIFIED_SORT_OPTIONS}:
            return
        self.unclassified_sort = mode
        self.refresh_grids()
        label = dict(UNCLASSIFIED_SORT_OPTIONS)[mode]
        self.statusBar().showMessage(f"未分類已改為：{label}")

    def move_selected_to(self, source_grid: PhotoGrid, target_slot: str | None, copy: bool = False):
        if not self.store:
            return
        photo_ids = [item.data(Qt.ItemDataRole.UserRole) for item in source_grid.selectedItems()]
        if photo_ids:
            self.store.relocate_photos(photo_ids, source_grid.slot_id, target_slot, copy=copy)
            self.refresh_grids()

    def auto_classify(self):
        if not self.store:
            return
        profile = self.app_settings.active_api_profile()
        vision_model = (profile or {}).get("vision_model") or (profile or {}).get("model")
        if profile and profile.get("endpoint") and vision_model:
            endpoint = profile["endpoint"]
            if not any(host in endpoint.lower() for host in ("localhost", "127.0.0.1", "::1")):
                answer = QMessageBox.question(
                    self,
                    "確認傳送照片給 AI",
                    f"這次分類會把未分類照片傳送到：\n{endpoint}\n\n照片可能包含住戶、人臉、車牌或工程文件。是否繼續？",
                    QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                    QMessageBox.StandardButton.No,
                )
                if answer != QMessageBox.StandardButton.Yes:
                    return
            if self.ai_worker and self.ai_worker.isRunning():
                QMessageBox.information(self, "AI 分類進行中", "目前已有一個 AI 分類工作正在執行。")
                return
            items = []
            for photo in self.store.unclassified_photos():
                path = self.store.rendered_photo_path(photo["id"], max_side=1024)
                if path:
                    items.append({"photo_id": photo["id"], "path": str(path), "filename": photo["original_filename"], "captured_at": str(photo["captured_at"] or "")})
            if not items:
                QMessageBox.information(self, "沒有待分類照片", "目前沒有尚未分類的照片。")
                return
            sections = [{"id": section["id"], "name": section["name"], "description": section["description"], "slots": [dict(slot) for slot in self.store.slots(section["id"])]} for section in self.store.sections()]
            examples = self.store.confirmed_examples(limit=5)
            self.ai_worker = VisionWorker(items, sections, profile, self, examples=examples)
            self.ai_worker.progress.connect(lambda percent, name: self.statusBar().showMessage(f"AI 分類中 {percent}%：{name}"))
            self.ai_worker.completed.connect(self.ai_classify_completed)
            self.ai_worker.failed.connect(self.ai_classify_failed)
            self.statusBar().showMessage(f"AI 視覺分類開始，共 {len(items)} 張照片；完成後請確認建議。")
            self.ai_worker.start()
            return
        count = self.store.create_suggestions()
        dialog = SuggestionDialog(
            self.store,
            self,
            "目前沒有設定視覺 API；這次使用檔名關鍵字產生建議，接受後才會移動照片。"
            "你也可以直接關閉視窗並手動拖曳修正。",
        )
        dialog.exec()
        self.refresh_grids()
        self.statusBar().showMessage(f"已產生 {count} 筆自動分類建議")

    def ai_classify_completed(self, results):
        if not self.store:
            return
        errors = results[0].get("_errors", []) if results else []
        # Strip internal keys before saving
        clean = [{k: v for k, v in r.items() if not k.startswith("_")} for r in results]
        count, auto_placed = self.store.add_ai_suggestions(clean)
        self.refresh_grids()
        dialog = SuggestionDialog(self.store, self)
        dialog.exec()
        self.refresh_grids()
        pending = count - auto_placed
        msg = f"AI 已分析 {count} 張：先放入 {auto_placed} 張，{pending} 張留在未分類／待確認。"
        if errors:
            msg += f"（{len(errors)} 張失敗）"
        self.statusBar().showMessage(msg)
        if self.ai_worker:
            self.ai_worker.deleteLater()
            self.ai_worker = None

    def ai_classify_failed(self, message: str):
        QMessageBox.warning(self, "AI 分類失敗", f"AI 視覺分類未完成：\n{message}\n\n照片沒有被移動。")
        self.statusBar().showMessage("AI 分類失敗；照片沒有被移動。")
        if self.ai_worker:
            self.ai_worker.deleteLater()
            self.ai_worker = None

    def restore_deleted(self):
        """Show a dialog to restore soft-deleted photos."""
        if not self.store:
            return
        deleted = self.store.deleted_photos()
        if not deleted:
            QMessageBox.information(self, "沒有已刪除的照片", "目前沒有可復原的照片。")
            return
        dialog = QDialog(self)
        dialog.setWindowTitle("復原已刪除照片")
        dialog.resize(500, 350)
        table = QListWidget(dialog)
        table.setViewMode(QListWidget.ViewMode.IconMode)
        table.setIconSize(QSize(120, 90))
        table.setGridSize(QSize(145, 140))
        table.setResizeMode(QListWidget.ResizeMode.Adjust)
        table.setSelectionMode(QListWidget.SelectionMode.ExtendedSelection)
        for row in deleted:
            thumb = self.store.root / row["thumbnail_rel_path"]
            icon = QIcon(str(thumb)) if thumb.exists() else QIcon()
            item = QListWidgetItem(icon, f"{row['original_filename']}\n刪除於 {row['deleted_at'][:10]}")
            item.setData(Qt.ItemDataRole.UserRole, row["id"])
            table.addItem(item)
        restore_btn = QPushButton("復原選取")
        restore_all_btn = QPushButton("復原全部")
        close_btn = QPushButton("關閉")
        def do_restore(ids):
            if ids:
                count = self.store.restore_photos(ids)
                self.refresh_grids()
                self.statusBar().showMessage(f"已復原 {count} 張照片至未分類")
                # Refresh the list
                table.clear()
                for row in self.store.deleted_photos():
                    thumb = self.store.root / row["thumbnail_rel_path"]
                    icon = QIcon(str(thumb)) if thumb.exists() else QIcon()
                    item = QListWidgetItem(icon, f"{row['original_filename']}\n刪除於 {row['deleted_at'][:10]}")
                    item.setData(Qt.ItemDataRole.UserRole, row["id"])
                    table.addItem(item)
        restore_btn.clicked.connect(lambda: do_restore([item.data(Qt.ItemDataRole.UserRole) for item in table.selectedItems()]))
        restore_all_btn.clicked.connect(lambda: do_restore([table.item(i).data(Qt.ItemDataRole.UserRole) for i in range(table.count())]))
        close_btn.clicked.connect(dialog.accept)
        btn_layout = QHBoxLayout()
        btn_layout.addWidget(restore_btn)
        btn_layout.addWidget(restore_all_btn)
        btn_layout.addStretch()
        btn_layout.addWidget(close_btn)
        layout = QVBoxLayout(dialog)
        layout.addWidget(QLabel(f"共 {len(deleted)} 張已刪除照片（原始檔仍保留在 originals 資料夾）"))
        layout.addWidget(table)
        layout.addLayout(btn_layout)
        dialog.exec()

    def undo_last(self):
        """Undo the last relocate or delete operation."""
        if not self.store or not self._undo_stack:
            self.statusBar().showMessage("沒有可復原的操作")
            return
        action = self._undo_stack.pop()
        kind = action.get("kind")
        if kind == "relocate":
            # Move photos back to source slot
            self.store.relocate_photos(
                action["photo_ids"], action["target_slot"], action["source_slot"],
                confirmed=True,
            )
            self.refresh_grids()
            self.statusBar().showMessage(f"已復原：{len(action['photo_ids'])} 張照片移回原欄位")
        elif kind == "delete":
            count = self.store.restore_photos(action["photo_ids"])
            self.refresh_grids()
            self.statusBar().showMessage(f"已復原：{count} 張照片")

    def save_project(self):
        if self.store:
            self.store.save_manifest()
            self.statusBar().showMessage("專案已儲存")

    def set_photo_sort_mode(self, slot_id, mode: str):
        if mode != "manual" and mode not in {value for value, _label in UNCLASSIFIED_SORT_OPTIONS}:
            mode = "time_asc"
        self.photo_sort_modes[slot_id] = mode
        if slot_id is None:
            self.unclassified_sort = mode
        self.refresh_grids()
        label = next((label for value, label in UNCLASSIFIED_SORT_OPTIONS if value == mode), mode)
        self.statusBar().showMessage(f"目前欄位排列：{label}")

    def set_unclassified_sort(self, mode: str):
        self.set_photo_sort_mode(None, mode)

    def export_reports(self):
        if not self.store:
            return
        project = self.store.project()
        number_summary = self.store.slot_number_summary()
        dialog = ExportDialog(self.app_settings, project["name"], self.store.root, self, number_summary=number_summary)
        dialog.format_action_requested.connect(
            lambda format_name, preview: self.export_single_report(dialog, format_name, preview)
        )
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        output_dir = self.app_settings.project_export_directory(project["name"], self.store.root)
        output_dir.mkdir(parents=True, exist_ok=True)
        base = safe_name(project["report_title"] or project["name"])
        export_settings = self._export_settings_from_dialog(dialog)
        outputs = []
        try:
            selected = set(dialog.selected_formats())
            if "pdf" in selected:
                outputs.append(export_pdf(self.store, unique_output_path(output_dir, base, ".pdf"), export_settings))
            if "word" in selected:
                outputs.append(export_word(self.store, unique_output_path(output_dir, base, ".docx"), export_settings))
            if "excel" in selected:
                outputs.append(export_excel(self.store, unique_output_path(output_dir, base, ".xlsx"), export_settings))
        except Exception as error:
            QMessageBox.critical(self, "輸出失敗", f"報告輸出失敗：\n{error}")
            return
        self.last_output_dir = output_dir
        self.save_project()
        output_text = "\n".join(str(path) for path in outputs)
        QMessageBox.information(self, "輸出完成", f"已輸出至工程專屬資料夾：\n{output_dir}\n\n檔案：\n{output_text}")
        if dialog.open_after.isChecked():
            self._open_path(output_dir)

    def _export_settings_from_dialog(self, dialog: ExportDialog) -> ExportSettings:
        return ExportSettings(
            show_date=self.app_settings.show_timestamp,
            show_filename=self.app_settings.show_filename,
            photos_per_page=int(dialog.pdf_photos_per_page.currentData() or 4),
            pdf_template=str(dialog.pdf_template.currentData() or "modern"),
        )

    def export_single_report(self, dialog: ExportDialog, format_name: str, preview: bool = False):
        """Preview or export one format without closing the report settings dialog."""
        if not self.store:
            return
        project = self.store.project()
        base = safe_name(project["report_title"] or project["name"])
        extensions = {"pdf": ".pdf", "word": ".docx", "excel": ".xlsx"}
        exporters = {"pdf": export_pdf, "word": export_word, "excel": export_excel}
        labels = {"pdf": "PDF", "word": "Word", "excel": "Excel"}
        if format_name not in exporters:
            return
        if preview:
            output_dir = Path(tempfile.gettempdir()) / "SitePhotoReportPreview" / safe_name(project["name"])
        else:
            output_dir = self.app_settings.project_export_directory(project["name"], self.store.root)
        output_dir.mkdir(parents=True, exist_ok=True)
        output = unique_output_path(output_dir, base, extensions[format_name])
        try:
            path = exporters[format_name](self.store, output, self._export_settings_from_dialog(dialog))
            self.save_project()
        except Exception as error:
            QMessageBox.critical(self, f"{labels[format_name]} 操作失敗", f"{labels[format_name]} 處理失敗：\n{error}")
            return
        if preview:
            self.statusBar().showMessage(f"{labels[format_name]} 預覽檔已建立：{path}")
            self._open_path(path)
        else:
            self.last_output_dir = output_dir
            QMessageBox.information(self, f"{labels[format_name]} 輸出完成", f"已輸出至：\n{path}")
            if dialog.open_after.isChecked():
                self._open_path(output_dir)

    def open_settings(self):
        dialog = SettingsDialog(self.app_settings, self)
        if dialog.exec() == QDialog.DialogCode.Accepted:
            self.statusBar().showMessage("程式設定已儲存")

    def open_help(self):
        HelpDialog(self).exec()

    def open_export_folder(self):
        if self.last_output_dir:
            target = self.last_output_dir
        elif self.store:
            target = self.app_settings.project_export_directory(self.store.project()["name"], self.store.root)
        else:
            target = self.app_settings.export_directory
        target.mkdir(parents=True, exist_ok=True)
        self._open_path(target)

    def _open_path(self, path: str | Path):
        path = Path(path)
        if sys.platform.startswith("win"):
            os.startfile(str(path))  # type: ignore[attr-defined]
        elif sys.platform == "darwin":
            subprocess.run(["open", str(path)], check=False)
        else:
            subprocess.run(["xdg-open", str(path)], check=False)
        self.save_project()

    def open_original(self):
        if not self.store or not self.active_grid or not self.active_grid.currentItem():
            return
        photo = self.store.photo(self.active_grid.currentItem().data(Qt.ItemDataRole.UserRole))
        if not photo:
            return
        path = self.store.root / photo["original_rel_path"]
        self._open_path(path)

    def _remember_recent(self, root: Path):
        path = recent_projects_file()
        try:
            recent = json.loads(path.read_text(encoding="utf-8")) if path.exists() else []
        except json.JSONDecodeError:
            recent = []
        recent = [str(root)] + [item for item in recent if item != str(root)]
        path.write_text(json.dumps(recent[:10], ensure_ascii=False, indent=2), encoding="utf-8")

    def closeEvent(self, event):  # noqa: N802 - Qt override
        self.save_project()
        self._close_store()
        event.accept()


class SimpleTextDialog(QDialog):
    def __init__(self, title: str, label: str, parent=None, value: str = ""):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.field = QLineEdit(value)
        self.field.selectAll()
        form = QFormLayout()
        form.addRow(label, self.field)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(buttons)

    def value(self) -> str:
        return self.field.text().strip()

    def accept(self):
        if not self.value():
            QMessageBox.warning(self, "資料不完整", "名稱不能空白。")
            return
        super().accept()


class BatchNameDialog(QDialog):
    def __init__(self, title: str, label: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setMinimumSize(520, 460)
        self.fields = []
        form = QFormLayout()
        for index in range(10):
            field = QLineEdit()
            field.setPlaceholderText("留白則略過")
            self.fields.append(field)
            form.addRow(f"{index + 1:02d}  {label}", field)
        note = QLabel("請由上到下輸入名稱；按確定後會依序新增，留白欄位不會建立。")
        note.setWordWrap(True)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addWidget(note)
        layout.addLayout(form)
        layout.addWidget(buttons)
        self.fields[0].setFocus()

    def values(self) -> list[str]:
        return [field.text().strip() for field in self.fields if field.text().strip()]

    def accept(self):
        if not self.values():
            QMessageBox.warning(self, "資料不完整", "請至少輸入一個名稱，或按取消離開。")
            return
        super().accept()


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("SitePhotoReport")
    app.setStyle("Fusion")
    window = MainWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
