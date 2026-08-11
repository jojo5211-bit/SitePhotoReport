from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from .paths import user_data_dir


def _documents_dir() -> Path:
    return Path.home() / "Documents"


def _default_settings() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "default_project_directory": str(_documents_dir() / "工程相片專案"),
        "export_directory": str(_documents_dir() / "工程照片報告"),
        "show_timestamp": True,
        "show_filename": True,
        "open_export_after": True,
        "api_profiles": [],
        "active_api_profile": "",
        "project_templates": [{"name": f"模板 {index}", "values": {}} for index in range(1, 6)],
    }


class AppSettings:
    """User-level settings shared by all projects on this computer."""

    def __init__(self, path: str | Path | None = None):
        self.path = Path(path) if path else user_data_dir() / "settings.json"
        self.data = _default_settings()
        self.load()

    def load(self) -> None:
        if self.path.exists():
            try:
                loaded = json.loads(self.path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    self.data.update(loaded)
            except (OSError, json.JSONDecodeError):
                pass

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp_path = self.path.with_suffix(".tmp")
        temp_path.write_text(json.dumps(self.data, ensure_ascii=False, indent=2), encoding="utf-8")
        temp_path.replace(self.path)

    @property
    def default_project_directory(self) -> Path:
        return Path(str(self.data["default_project_directory"]))

    @property
    def export_directory(self) -> Path:
        return Path(str(self.data["export_directory"]))

    @property
    def show_timestamp(self) -> bool:
        return bool(self.data.get("show_timestamp", True))

    @property
    def show_filename(self) -> bool:
        return bool(self.data.get("show_filename", True))

    @property
    def open_export_after(self) -> bool:
        return bool(self.data.get("open_export_after", True))

    def set_general(self, *, project_directory: str, export_directory: str, show_timestamp: bool, show_filename: bool, open_export_after: bool) -> None:
        self.data.update({
            "default_project_directory": project_directory,
            "export_directory": export_directory,
            "show_timestamp": bool(show_timestamp),
            "show_filename": bool(show_filename),
            "open_export_after": bool(open_export_after),
        })

    def api_profiles(self) -> list[dict[str, str]]:
        profiles = self.data.get("api_profiles", [])
        return [profile for profile in profiles if isinstance(profile, dict) and profile.get("name")]

    def active_api_profile(self) -> dict[str, str] | None:
        active = str(self.data.get("active_api_profile", ""))
        return next((profile for profile in self.api_profiles() if profile.get("name") == active), None)

    def save_api_profile(self, profile: dict[str, str], previous_name: str = "") -> None:
        profile = {
            "name": profile.get("name", "").strip(),
            "endpoint": profile.get("endpoint", "").strip().rstrip("/"),
            "api_key": profile.get("api_key", "").strip(),
            "model": profile.get("model", "").strip(),
            "vision_model": profile.get("vision_model", "").strip(),
        }
        profiles = self.api_profiles()
        replaced = False
        for index, existing in enumerate(profiles):
            if existing.get("name") == (previous_name or profile["name"]):
                profiles[index] = profile
                replaced = True
                break
        if not replaced:
            profiles.append(profile)
        self.data["api_profiles"] = profiles
        self.data["active_api_profile"] = profile["name"]

    def delete_api_profile(self, name: str) -> None:
        self.data["api_profiles"] = [profile for profile in self.api_profiles() if profile.get("name") != name]
        if self.data.get("active_api_profile") == name:
            self.data["active_api_profile"] = ""

    def set_active_api_profile(self, name: str) -> None:
        self.data["active_api_profile"] = name

    def project_templates(self) -> list[dict[str, Any]]:
        """Return exactly five reusable project-data template slots."""
        raw = self.data.get("project_templates", [])
        templates = []
        for index in range(5):
            item = raw[index] if isinstance(raw, list) and index < len(raw) and isinstance(raw[index], dict) else {}
            templates.append({
                "name": str(item.get("name") or f"模板 {index + 1}"),
                "values": dict(item.get("values") or {}) if isinstance(item.get("values"), dict) else {},
            })
        return templates

    def save_project_template(self, index: int, name: str, values: dict[str, str]) -> None:
        if not 0 <= int(index) < 5:
            return
        templates = self.project_templates()
        templates[int(index)] = {
            "name": name.strip() or f"模板 {int(index) + 1}",
            "values": {str(key): str(value) for key, value in values.items()},
        }
        self.data["project_templates"] = templates

    def load_project_template(self, index: int) -> dict[str, str]:
        if not 0 <= int(index) < 5:
            return {}
        return dict(self.project_templates()[int(index)]["values"])

    def project_export_directory(self, project_name: str, project_root: str | Path | None = None) -> Path:
        base = self.export_directory
        if not str(base).strip():
            base = Path(project_root) / "exports" if project_root else _documents_dir() / "工程照片報告"
        return base / _safe_folder_name(project_name)


def _ssl_context():
    """Build an SSL context that works both in dev and inside PyInstaller."""
    import ssl
    ctx = ssl.create_default_context()
    try:
        import certifi
        ctx.load_verify_locations(certifi.where())
    except ImportError:
        pass
    return ctx


def test_api_connection(endpoint: str, api_key: str = "", timeout: int = 12) -> tuple[bool, str]:
    """Test an OpenAI-compatible endpoint. Tries /models first, then a minimal chat call."""
    endpoint = endpoint.strip().rstrip("/")
    if not endpoint:
        return False, "API 端點不能空白。"
    ctx = _ssl_context()
    headers = {"Accept": "application/json"}
    if api_key.strip():
        headers["Authorization"] = f"Bearer {api_key.strip()}"

    # --- Attempt 1: GET /models ---
    models_url = endpoint if endpoint.endswith("/models") else f"{endpoint}/models"
    try:
        req = urllib.request.Request(models_url, method="GET", headers=headers)
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            if 200 <= resp.status < 300:
                return True, f"連線成功（/models HTTP {resp.status}）。"
    except urllib.error.HTTPError as e:
        models_err = f"HTTP {e.code} {e.reason}"
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        models_err = str(getattr(e, "reason", e))
    else:
        models_err = "unknown"

    # --- Attempt 2: minimal chat/completions ---
    chat_url = endpoint if endpoint.endswith("/chat/completions") else f"{endpoint}/chat/completions"
    payload = json.dumps({
        "model": "gpt-4o-mini",
        "messages": [{"role": "user", "content": "hi"}],
        "max_tokens": 1,
    }).encode("utf-8")
    try:
        req = urllib.request.Request(chat_url, data=payload, method="POST", headers={
            **headers, "Content-Type": "application/json",
        })
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            if 200 <= resp.status < 300:
                return True, f"連線成功（chat HTTP {resp.status}）。"
            return False, f"chat 回應 HTTP {resp.status}。"
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8", errors="replace")[:300]
        except Exception:
            pass
        if e.code in (401, 403):
            return False, f"API 可連線但認證失敗（HTTP {e.code}）。請檢查 API Key。\n{detail}"
        if e.code == 404:
            return False, f"端點不存在（HTTP 404）。請確認 Base URL 正確。\n/models: {models_err}\n/chat: {detail}"
        return False, f"API 回應 HTTP {e.code}：{detail or e.reason}"
    except urllib.error.URLError as e:
        return False, f"無法連線：{e.reason}\n（/models 也失敗：{models_err}）"
    except TimeoutError:
        return False, f"連線逾時（{timeout} 秒）。\n（/models 也失敗：{models_err}）"
    except OSError as e:
        return False, f"連線失敗：{e}\n（/models 也失敗：{models_err}）"


def _safe_folder_name(name: str) -> str:
    cleaned = re.sub(r"[<>:\"/\\|?*\x00-\x1f]", "_", name).strip(" .")
    return cleaned or "未命名工程"


def safe_name(name: str) -> str:
    return _safe_folder_name(name)
