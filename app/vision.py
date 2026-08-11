from __future__ import annotations

import base64
import json
import re
import ssl
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def _ssl_context() -> ssl.SSLContext:
    """Build an SSL context that works both in dev and inside PyInstaller."""
    ctx = ssl.create_default_context()
    try:
        import certifi
        ctx.load_verify_locations(certifi.where())
    except ImportError:
        pass
    return ctx


class VisionClassifier:
    """Small OpenAI-compatible vision client used for classification suggestions."""

    MAX_RETRIES = 3
    BACKOFF_BASE = 2  # seconds; 2, 4, 8

    def __init__(self, endpoint: str, api_key: str, model: str, timeout: int = 45):
        self.endpoint = endpoint.rstrip("/")
        self.api_key = api_key.strip()
        self.model = model.strip()
        self.timeout = timeout
        self._ctx = _ssl_context()

    def classify(self, image_path: str | Path, sections: list[dict[str, Any]],
                 examples: list[dict[str, Any]] | None = None,
                 captured_at: str = "") -> dict[str, Any]:
        image_path = Path(image_path)
        encoded = base64.b64encode(image_path.read_bytes()).decode("ascii")
        mime = "image/png" if image_path.suffix.lower() == ".png" else "image/jpeg"
        # Build rich candidate list with descriptions
        candidate_lines = []
        for section in sections:
            desc = str(section.get("description") or "").strip()
            slots_desc = []
            for slot in section["slots"]:
                slot_note = str(slot.get("default_caption") or "").strip()
                if slot_note:
                    slots_desc.append(f"{slot['name']}（{slot_note}）")
                else:
                    slots_desc.append(slot["name"])
            line = f"- 項目：{section['name']}"
            if desc:
                line += f"（{desc}）"
            line += f"；可用欄位：{', '.join(slots_desc)}"
            candidate_lines.append(line)
        candidates = "\n".join(candidate_lines)
        # Few-shot examples from user-confirmed placements
        examples_block = ""
        if examples:
            ex_lines = "\n".join(
                f"  範例：「{ex['filename']}」→ {ex['section']} / {ex['slot']}"
                for ex in examples[:5]
            )
            examples_block = f"\n\n使用者已確認的分類範例（請參考其判斷邏輯）：\n{ex_lines}"
        # Date hint
        date_hint = ""
        if captured_at:
            date_hint = f"\n這張照片的拍攝時間：{captured_at}（可作為施工階段的輔助判斷）"
        prompt = f"""你是工程照片整理助手。請根據照片內容，從下列既有項目與欄位中選出最適合的一組。
不要創造新項目。請只回傳 JSON，不要 Markdown：
{{\"section\": \"項目名稱\", \"slot\": \"欄位名稱\", \"confidence\": 0.0, \"reason\": \"簡短原因\"}}

既有候選：
{candidates}{date_hint}{examples_block}

若無法判斷，section 與 slot 請填空字串，confidence 小於 0.55。"""
        payload = {
            "model": self.model,
            "temperature": 0,
            "messages": [{
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{encoded}", "detail": "low"}},
                ],
            }],
        }
        request = urllib.request.Request(
            self._chat_url(),
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            method="POST",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
        last_error: Exception | None = None
        for attempt in range(self.MAX_RETRIES):
            try:
                with urllib.request.urlopen(request, timeout=self.timeout, context=self._ctx) as response:
                    body = json.loads(response.read().decode("utf-8"))
                break
            except urllib.error.HTTPError as error:
                detail = error.read().decode("utf-8", errors="replace")[:500]
                if error.code == 429 and attempt < self.MAX_RETRIES - 1:
                    wait = self.BACKOFF_BASE * (2 ** attempt)
                    time.sleep(wait)
                    last_error = RuntimeError(f"視覺 API 限速 HTTP 429，{wait} 秒後重試（第 {attempt + 1} 次）")
                    continue
                raise RuntimeError(f"視覺 API 回應 HTTP {error.code}：{detail}") from error
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                if attempt < self.MAX_RETRIES - 1:
                    wait = self.BACKOFF_BASE * (2 ** attempt)
                    time.sleep(wait)
                    last_error = RuntimeError(f"視覺 API 連線失敗，{wait} 秒後重試（第 {attempt + 1} 次）：{error}")
                    continue
                raise RuntimeError(f"視覺 API 連線失敗：{error}") from error
        else:
            raise last_error or RuntimeError("視覺 API 重試次數用盡")
        text = self._response_text(body)
        result = self._parse_json(text)
        return {
            "section": str(result.get("section", "")).strip(),
            "slot": str(result.get("slot", "")).strip(),
            "confidence": self._confidence(result.get("confidence", 0)),
            "reason": str(result.get("reason", "AI 視覺分類建議")).strip(),
        }

    def _chat_url(self) -> str:
        if self.endpoint.endswith("/chat/completions"):
            return self.endpoint
        return f"{self.endpoint}/chat/completions"

    @staticmethod
    def _response_text(body: dict[str, Any]) -> str:
        choices = body.get("choices") or []
        if not choices:
            raise RuntimeError("視覺 API 沒有回傳 choices。")
        content = (choices[0].get("message") or {}).get("content", "")
        if isinstance(content, list):
            content = " ".join(str(item.get("text", "")) for item in content if isinstance(item, dict))
        return str(content).strip()

    @staticmethod
    def _parse_json(text: str) -> dict[str, Any]:
        cleaned = text.strip()
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\s*```$", "", cleaned)
        try:
            value = json.loads(cleaned)
            return value if isinstance(value, dict) else {}
        except json.JSONDecodeError:
            start, end = cleaned.find("{"), cleaned.rfind("}")
            if start >= 0 and end > start:
                try:
                    value = json.loads(cleaned[start:end + 1])
                    return value if isinstance(value, dict) else {}
                except json.JSONDecodeError:
                    pass
            return {}

    @staticmethod
    def _confidence(value: Any) -> float:
        try:
            number = float(value)
        except (TypeError, ValueError):
            return 0.0
        if number > 1:
            number /= 100
        return max(0.0, min(1.0, number))
