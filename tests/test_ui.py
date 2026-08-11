from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PIL import Image
from PySide6.QtCore import QByteArray, QMimeData
from PySide6.QtWidgets import QApplication

from app.main import BatchNameDialog, PHOTO_MIME, MainWindow, PhotoTabBar, sort_unclassified_rows
from app.store import ProjectStore


class PhotoUiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.application = QApplication.instance() or QApplication([])

    def test_tab_drag_payload_preserves_explicit_unclassified_source(self):
        mime = QMimeData()
        mime.setData(PHOTO_MIME, QByteArray(b'{"photo_ids":["P-1","P-2"],"source_slot_id":null,"source_explicit":true}'))
        payload = PhotoTabBar._payload(mime)
        self.assertEqual((["P-1", "P-2"], {"slot_id": None, "explicit": True}), payload)

    def test_tab_drop_route_moves_photos_to_target_field(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "ui-test.sprj"
            store = ProjectStore(root)
            store.ensure_default_sections()
            source = Path(temporary) / "source.jpg"
            Image.new("RGB", (320, 240), (20, 80, 120)).save(source)
            imported, _ = store.import_files([source])
            section_id = store.sections()[0]["id"]
            target_slot = store.slots(section_id)[0]

            window = MainWindow()
            window.store = store
            window.current_section_id = section_id
            window.rebuild_tabs()
            target_index = next(index for index in range(window.tabs.count()) if window.tabs.widget(index).slot_id == target_slot["id"])
            window.handle_tab_photo_drop(target_index, imported, False, {"slot_id": None, "explicit": True})

            self.assertEqual([], store.placements_for_slot(None))
            self.assertEqual([imported[0]], [row["photo_id"] for row in store.placements_for_slot(target_slot["id"])])
            window.close()

    def test_unclassified_sorting_supports_time_and_natural_filename_order(self):
        rows = [
            {"original_filename": "IMG_10.jpg", "captured_at": "2026-07-02 10:00:00", "position": 1, "created_at": "b"},
            {"original_filename": "IMG_2.jpg", "captured_at": "2026-07-01 10:00:00", "position": 0, "created_at": "a"},
            {"original_filename": "IMG_1.jpg", "captured_at": "", "position": 2, "created_at": "c"},
        ]
        self.assertEqual(
            ["IMG_2.jpg", "IMG_10.jpg", "IMG_1.jpg"],
            [row["original_filename"] for row in sort_unclassified_rows(rows, "time_asc")],
        )
        self.assertEqual(
            ["IMG_10.jpg", "IMG_2.jpg", "IMG_1.jpg"],
            [row["original_filename"] for row in sort_unclassified_rows(rows, "filename_desc")],
        )
        self.assertEqual(
            ["IMG_1.jpg", "IMG_2.jpg", "IMG_10.jpg"],
            [row["original_filename"] for row in sort_unclassified_rows(rows, "filename_asc")],
        )

    def test_batch_name_dialog_skips_blank_entries_and_keeps_order(self):
        dialog = BatchNameDialog("測試批次輸入", "名稱")
        dialog.fields[0].setText("第一個")
        dialog.fields[1].setText("")
        dialog.fields[2].setText("第三個")
        self.assertEqual(["第一個", "第三個"], dialog.values())
        dialog.close()


if __name__ == "__main__":
    unittest.main()
