"""
Merge workflows/personal_assistant_mvp.json into an existing n8n workflow via REST API.

Preserves node UUIDs and Postgres credentials from the server (matched by node name).
Replaces connections and node parameters from the repo file (fixes empty graph).

Requires:
  - N8N_API_KEY from n8n UI: Settings -> API (create key)
  - Optional: N8N_BASE_URL (default http://localhost:5678)
  - Optional: WORKFLOW_ID (otherwise the newest workflow with the repo name is used)

Usage (from repo root):
  python scripts/sync-mvp-workflow.py

Or set env without editing .env:
  set N8N_API_KEY=... && python scripts/sync-mvp-workflow.py
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
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
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        env[key] = val
    return env


def http_json(method: str, url: str, headers: dict[str, str], body: object | None = None) -> object:
    data: bytes | None = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers = {**headers, "Content-Type": "application/json"}
    req = Request(url, data=data, headers=headers, method=method)
    with urlopen(req, timeout=120) as resp:
        raw = resp.read().decode("utf-8")
        if not raw:
            return {}
        return json.loads(raw)


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


ALLOWED_SETTINGS_KEYS = {
    "saveExecutionProgress",
    "saveManualExecutions",
    "saveDataErrorExecution",
    "saveDataSuccessExecution",
    "executionTimeout",
    "errorWorkflow",
    "timezone",
    "executionOrder",
    "callerPolicy",
    "callerIds",
    "timeSavedPerExecution",
    "availableInMCP",
}


def filter_settings(settings: object) -> dict[str, object]:
    if not isinstance(settings, dict):
        return {"executionOrder": "v1"}
    filtered = {key: value for key, value in settings.items() if key in ALLOWED_SETTINGS_KEYS}
    return filtered or {"executionOrder": "v1"}


def merge_workflow(live: dict[str, object], file_wf: dict[str, object]) -> dict[str, object]:
    live_nodes: list[dict[str, object]] = live.get("nodes") or []
    live_by_name: dict[str, dict[str, object]] = {}
    for n in live_nodes:
        name = n.get("name")
        if isinstance(name, str):
            live_by_name[name] = n

    file_nodes: list[dict[str, object]] = file_wf.get("nodes") or []
    merged_nodes: list[dict[str, object]] = []

    for fn in file_nodes:
        name = fn.get("name")
        if not isinstance(name, str):
            continue
        if name in live_by_name:
            ln = dict(live_by_name[name])
            ln["parameters"] = fn.get("parameters", ln.get("parameters"))
            if "position" in fn:
                ln["position"] = fn["position"]
            ln["type"] = fn.get("type", ln.get("type"))
            ln["typeVersion"] = fn.get("typeVersion", ln.get("typeVersion"))
            if isinstance(ln.get("credentials"), dict) and ln["credentials"]:
                pass
            elif isinstance(fn.get("credentials"), dict):
                ln["credentials"] = fn["credentials"]
            merged_nodes.append(ln)
        else:
            merged_nodes.append(dict(fn))

    payload = dict(live)
    payload["nodes"] = merged_nodes
    payload["connections"] = normalize_connections(file_wf.get("connections", {}))
    live_settings = dict(live.get("settings") or {})
    file_settings = dict(file_wf.get("settings") or {})
    if "errorWorkflow" not in file_settings and "errorWorkflow" in live_settings:
        file_settings["errorWorkflow"] = live_settings["errorWorkflow"]
    payload["settings"] = filter_settings(file_settings or live_settings or {})
    if isinstance(file_wf.get("name"), str):
        payload["name"] = file_wf["name"]
    return payload


def sanitize_put_body(merged: dict[str, object]) -> dict[str, object]:
    """n8n PUT /workflows/:id rejects unknown root keys (e.g. shared, tags, versionCounter)."""
    out: dict[str, object] = {}
    for key in ("name", "nodes", "connections", "settings"):
        if key in merged and merged[key] is not None:
            out[key] = merged[key]
    out["settings"] = filter_settings(out.get("settings"))
    out["connections"] = normalize_connections(out.get("connections"))
    # Avoid sending staticData / pinData by default. They can bloat the payload and are not
    # needed for source-of-truth workflow sync from the repo file.
    return out


def pick_latest_workflow(base_url: str, headers: dict[str, str], name: str) -> str | None:
    response = http_json("GET", f"{base_url}/api/v1/workflows?{urlencode({'limit': 100})}", headers)
    if not isinstance(response, dict):
        return None

    workflows = response.get("data")
    if not isinstance(workflows, list):
        return None

    matches = [
        workflow
        for workflow in workflows
        if isinstance(workflow, dict) and workflow.get("name") == name and isinstance(workflow.get("id"), str)
    ]
    if not matches:
        return None

    matches.sort(key=lambda workflow: str(workflow.get("updatedAt") or workflow.get("createdAt") or ""), reverse=True)
    return matches[0]["id"]


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    dotenv = load_dotenv_file(root / ".env")
    api_key = os.environ.get("N8N_API_KEY") or dotenv.get("N8N_API_KEY")
    base_url = (
        os.environ.get("N8N_BASE_URL")
        or dotenv.get("N8N_BASE_URL")
        or "http://localhost:5678"
    ).rstrip("/")
    browser_base = (
        os.environ.get("N8N_EDITOR_BASE_URL") or dotenv.get("N8N_EDITOR_BASE_URL") or base_url
    ).rstrip("/")
    repo_file = root / "workflows" / "personal_assistant_mvp.json"

    if not api_key:
        print(
            "Ошибка: не задан N8N_API_KEY.\n"
            "Создайте ключ в n8n: Settings -> API -> Create API key,\n"
            "затем добавьте в .env строку N8N_API_KEY=... или задайте переменную окружения.",
            file=sys.stderr,
        )
        return 1

    if not repo_file.is_file():
        print(f"Не найден файл: {repo_file}", file=sys.stderr)
        return 1

    file_wf = json.loads(repo_file.read_text(encoding="utf-8"))
    headers = {"X-N8N-API-KEY": api_key, "Accept": "application/json"}
    workflow_name = str(file_wf.get("name") or "Personal AI Assistant MVP")
    workflow_id = os.environ.get("WORKFLOW_ID") or dotenv.get("WORKFLOW_ID")
    if not workflow_id:
        workflow_id = pick_latest_workflow(base_url, headers, workflow_name)
    if not workflow_id:
        print(
            f"ERROR: Could not find workflow named {workflow_name!r}. "
            "Set WORKFLOW_ID in .env or create the workflow first.",
            file=sys.stderr,
        )
        return 1

    get_url = f"{base_url}/api/v1/workflows/{workflow_id}"
    try:
        live = http_json("GET", get_url, headers)
    except HTTPError as e:
        print(f"GET workflow HTTP {e.code}: {e.reason}", file=sys.stderr)
        try:
            print(e.read().decode("utf-8", errors="replace"), file=sys.stderr)
        except Exception:
            pass
        return 1
    except URLError as e:
        print(f"Network / URL error: {e.reason}", file=sys.stderr)
        return 1

    payload = sanitize_put_body(merge_workflow(live, file_wf))
    put_url = f"{base_url}/api/v1/workflows/{workflow_id}"

    try:
        updated = http_json("PUT", put_url, headers, payload)
    except HTTPError as e:
        print(f"PUT workflow HTTP {e.code}: {e.reason}", file=sys.stderr)
        try:
            print(e.read().decode("utf-8", errors="replace"), file=sys.stderr)
        except Exception:
            pass
        return 1

    name = updated.get("name", payload.get("name"))
    nodes_count = len(updated.get("nodes") or [])
    print(f"OK: workflow updated - id={workflow_id}, name={name}, nodes={nodes_count}")
    print(f"Open editor: {browser_base}/workflow/{workflow_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
