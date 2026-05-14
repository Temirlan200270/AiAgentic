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
        env[key.strip()] = val.strip().strip('"').strip("'")
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


def sanitize_workflow_body(file_wf: dict[str, object], *, include_settings: bool = True) -> dict[str, object]:
    out: dict[str, object] = {}
    keys = ("name", "nodes", "connections", "settings") if include_settings else ("name", "nodes", "connections")
    for key in keys:
        if key in file_wf and file_wf[key] is not None:
            out[key] = file_wf[key]
    for optional in ("staticData", "pinData"):
        if optional in file_wf and file_wf[optional] is not None:
            out[optional] = file_wf[optional]
    if include_settings:
        out["settings"] = filter_settings(out.get("settings"))
    out["connections"] = normalize_connections(out.get("connections"))
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


def activate_workflow(base_url: str, headers: dict[str, str], workflow_id: str) -> None:
    http_json("POST", f"{base_url}/api/v1/workflows/{workflow_id}/activate", headers)


def update_main_error_workflow(
    base_url: str,
    headers: dict[str, str],
    main_workflow_id: str,
    error_workflow_id: str,
) -> None:
    live = http_json("GET", f"{base_url}/api/v1/workflows/{main_workflow_id}", headers)
    if not isinstance(live, dict):
        raise RuntimeError("Could not load main workflow to attach errorWorkflow.")

    settings = filter_settings(live.get("settings"))
    settings["errorWorkflow"] = error_workflow_id

    payload: dict[str, object] = {}
    for key in ("name", "nodes", "connections", "staticData", "pinData"):
        if key in live and live[key] is not None:
            payload[key] = live[key]
    payload["connections"] = normalize_connections(payload.get("connections"))
    payload["settings"] = settings
    http_json("PUT", f"{base_url}/api/v1/workflows/{main_workflow_id}", headers, payload)


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    dotenv = load_dotenv_file(root / ".env")
    api_key = os.environ.get("N8N_API_KEY") or dotenv.get("N8N_API_KEY")
    base_url = (os.environ.get("N8N_BASE_URL") or dotenv.get("N8N_BASE_URL") or "http://localhost:5678").rstrip("/")
    browser_base = (os.environ.get("N8N_EDITOR_BASE_URL") or dotenv.get("N8N_EDITOR_BASE_URL") or base_url).rstrip("/")
    error_file = root / "workflows" / "global_error_workflow.json"

    if not api_key:
        print("ERROR: N8N_API_KEY is not set.", file=sys.stderr)
        return 1
    if not error_file.is_file():
        print(f"ERROR: workflow file not found: {error_file}", file=sys.stderr)
        return 1

    headers = {"X-N8N-API-KEY": api_key, "Accept": "application/json"}
    error_wf = json.loads(error_file.read_text(encoding="utf-8"))
    payload = sanitize_workflow_body(error_wf, include_settings=True)

    error_name = str(error_wf.get("name") or "Personal AI Assistant Global Error")
    error_workflow_id = os.environ.get("ERROR_WORKFLOW_ID") or dotenv.get("ERROR_WORKFLOW_ID")
    if not error_workflow_id:
        error_workflow_id = pick_latest_workflow(base_url, headers, error_name)

    try:
        if error_workflow_id:
            http_json("PUT", f"{base_url}/api/v1/workflows/{error_workflow_id}", headers, payload)
        else:
            created = http_json("POST", f"{base_url}/api/v1/workflows", headers, payload)
            if isinstance(created, dict):
                error_workflow_id = created.get("id")
                if not isinstance(error_workflow_id, str) and isinstance(created.get("data"), dict):
                    inner = created["data"]
                    error_workflow_id = inner.get("id") if isinstance(inner.get("id"), str) else None
        if not error_workflow_id:
            print("ERROR: failed to create or update error workflow.", file=sys.stderr)
            return 1

        activate_workflow(base_url, headers, error_workflow_id)

        main_name = "Personal AI Assistant MVP"
        main_workflow_id = os.environ.get("WORKFLOW_ID") or dotenv.get("WORKFLOW_ID") or pick_latest_workflow(
            base_url, headers, main_name
        )
        if not main_workflow_id:
            print("ERROR: main workflow not found to attach errorWorkflow.", file=sys.stderr)
            return 1

        update_main_error_workflow(base_url, headers, main_workflow_id, error_workflow_id)
    except HTTPError as e:
        print(f"HTTP {e.code}: {e.reason}", file=sys.stderr)
        try:
            print(e.read().decode("utf-8", errors="replace"), file=sys.stderr)
        except Exception:
            pass
        return 1
    except URLError as e:
        print(f"Network error: {e.reason}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    print(f"OK: error workflow ready - id={error_workflow_id}")
    print(f"Open editor: {browser_base}/workflow/{error_workflow_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
