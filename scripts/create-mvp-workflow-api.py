"""
Create a NEW workflow in n8n from workflows/personal_assistant_mvp.json via REST API.

Use when the UI "Import from File" fails silently (blank canvas, no error).

Writes a timestamped log under logs/ with full HTTP status and response body.

Requires:
  N8N_API_KEY in environment or .env (Settings -> API in n8n)

Usage (repo root):
  python scripts/create-mvp-workflow-api.py

Optional env:
  N8N_BASE_URL — API (default http://localhost:5678; same as 127.0.0.1 for TCP)
  N8N_EDITOR_BASE_URL — если задан, используется только в строке «Open editor» (удобно = localhost)
  MVP_JSON path override
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def load_dotenv_file(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.is_file():
        return env
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        env[key.strip()] = val.strip().strip('"').strip("'")
    return env


def sanitize_create_body(file_wf: dict[str, object]) -> dict[str, object]:
    """Only fields accepted by POST /workflows (avoid extra keys from export files)."""
    out: dict[str, object] = {}
    for key in ("name", "nodes", "connections", "settings"):
        if key in file_wf and file_wf[key] is not None:
            out[key] = file_wf[key]
    # n8n API: "meta" is read-only on create; omit it. pinData/staticData if present.
    for optional in ("staticData", "pinData"):
        if optional in file_wf and file_wf[optional] is not None:
            out[optional] = file_wf[optional]
    return out


def normalize_connections(connections: object) -> object:
    """Accept flat API-ish connections and emit the nested n8n workflow shape."""
    if not isinstance(connections, dict):
        return {}

    normalized: dict[str, object] = {}
    for source_name, source_connections in connections.items():
        if not isinstance(source_connections, dict):
            normalized[source_name] = source_connections
            continue

        normalized_outputs: dict[str, object] = {}
        for output_type, outputs in source_connections.items():
            if not isinstance(outputs, list):
                normalized_outputs[output_type] = outputs
                continue
            if not outputs:
                normalized_outputs[output_type] = []
                continue

            first = outputs[0]
            if isinstance(first, dict) and "node" in first:
                normalized_outputs[output_type] = [outputs]
            else:
                normalized_outputs[output_type] = outputs

        normalized[source_name] = normalized_outputs

    return normalized


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    dotenv = load_dotenv_file(root / ".env")
    api_key = os.environ.get("N8N_API_KEY") or dotenv.get("N8N_API_KEY")
    base_url = (
        os.environ.get("N8N_BASE_URL") or dotenv.get("N8N_BASE_URL") or "http://localhost:5678"
    ).rstrip("/")
    # Ссылка в консоли: совпадает с тем, как ты открываешь UI (из .env N8N_EDITOR_BASE_URL).
    browser_base = (
        os.environ.get("N8N_EDITOR_BASE_URL") or dotenv.get("N8N_EDITOR_BASE_URL") or base_url
    ).rstrip("/")
    json_path = Path(
        os.environ.get("MVP_JSON") or dotenv.get("MVP_JSON") or (root / "workflows" / "personal_assistant_mvp.json")
    )

    logs_dir = root / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    log_file = logs_dir / f"n8n-create-workflow-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}.log"

    lines: list[str] = []

    def append(msg: str) -> None:
        lines.append(msg.rstrip())

    if not api_key:
        append("ERROR: N8N_API_KEY is not set. Create an API key in n8n: Settings -> API.")
        log_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("\n".join(lines), file=sys.stderr)
        print(f"Full log: {log_file}", file=sys.stderr)
        return 1

    if not json_path.is_file():
        append(f"ERROR: JSON not found: {json_path}")
        log_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("\n".join(lines), file=sys.stderr)
        return 1

    raw_wf = json.loads(json_path.read_text(encoding="utf-8"))
    node_count = len(raw_wf.get("nodes") or [])
    conn_keys = len((raw_wf.get("connections") or {}).keys())
    append(f"JSON: {json_path}")
    append(f"Nodes in file: {node_count}, connection sources: {conn_keys}")

    payload = sanitize_create_body(raw_wf)
    payload["connections"] = normalize_connections(payload.get("connections"))
    url = f"{base_url}/api/v1/workflows"
    headers = {"X-N8N-API-KEY": api_key, "Accept": "application/json", "Content-Type": "application/json"}

    body_bytes = json.dumps(payload).encode("utf-8")

    append(f"POST {url}")
    append(f"Payload keys: {list(payload.keys())}")

    created_id: str | None = None

    try:
        req = Request(url, data=body_bytes, headers=headers, method="POST")
        with urlopen(req, timeout=120) as resp:
            raw = resp.read().decode("utf-8")
            append(f"HTTP {resp.status}")
            try:
                data = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                append(f"Non-JSON response (first 2000 chars): {raw[:2000]}")
                data = {}
            else:
                snippet = json.dumps(data, ensure_ascii=False, indent=2)
                if len(snippet) > 12000:
                    append(f"Response (truncated):\n{snippet[:12000]}\n...")
                else:
                    append(f"Response:\n{snippet}")
            if isinstance(data, dict):
                rid = data.get("id")
                if not isinstance(rid, str) and isinstance(data.get("data"), dict):
                    inner = data["data"]
                    rid = inner.get("id") if isinstance(inner.get("id"), str) else rid
                if isinstance(rid, str):
                    created_id = rid
    except HTTPError as e:
        append(f"HTTP {e.code} {e.reason}")
        err_body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        append(f"Body:\n{err_body}")
    except URLError as e:
        append(f"Network error: {e.reason}")

    if created_id:
        append(f"SUCCESS. Open editor: {browser_base}/workflow/{created_id}")

    final = "\n".join(lines) + "\n"
    log_file.write_text(final, encoding="utf-8")
    print(final)
    print(f"Full log written to: {log_file}", file=sys.stderr)

    return 0 if created_id else 1


if __name__ == "__main__":
    raise SystemExit(main())
