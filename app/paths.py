from __future__ import annotations

import os
from pathlib import Path


APP_NAME = "SitePhotoReport"


def user_data_dir() -> Path:
    base = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA")
    if base:
        path = Path(base) / APP_NAME
    else:
        path = Path.home() / f".{APP_NAME.lower()}"
    path.mkdir(parents=True, exist_ok=True)
    return path


def recent_projects_file() -> Path:
    return user_data_dir() / "recent_projects.json"
