# -*- coding: utf-8 -*-
"""One-shot patch: add analysis route to workflows/personal_assistant_mvp.json."""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / "workflows" / "personal_assistant_mvp.json"
PROMPTS = ROOT / "docs" / "ai_prompts.md"


def extract_fenced_text(md: str, section_header: str) -> str:
    i = md.index(section_header)
    fence = md.index("```text", i)
    start = fence + len("```text")
    if md[start] == "\n":
        start += 1
    end = md.index("```", start)
    return md[start:end].strip()


def escape_n8n_js_string(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "")


def find_node(nodes: list, node_id: str) -> dict | None:
    for n in nodes:
        if n.get("id") == node_id:
            return n
    return None


ANALYSIS_TIME_RANGE_CODE = r"""const item = items[0].json;
const ed = item.extracted_data || {};
const tr = String(ed.time_range || "last_month").toLowerCase();
const now = new Date();
function toIso(d) { return new Date(d).toISOString(); }
function startUtcDay(d) { const x = new Date(d); x.setUTCHours(0, 0, 0, 0); return x; }
function endUtcDay(d) { const x = new Date(d); x.setUTCHours(23, 59, 59, 999); return x; }
const y = now.getUTCFullYear();
const m = now.getUTCMonth();
const day = now.getUTCDate();
let period_start;
let period_end;
if (tr === "last_day" || tr === "today") { period_start = startUtcDay(now); period_end = now; }
else if (tr === "yesterday") { const d = new Date(Date.UTC(y, m, day - 1)); period_start = startUtcDay(d); period_end = endUtcDay(d); }
else if (tr === "last_week") { const end = now; const start = new Date(end); start.setUTCDate(start.getUTCDate() - 7); period_start = start; period_end = end; }
else if (tr === "this_month" || tr === "month") { period_start = new Date(Date.UTC(y, m, 1)); period_end = now; }
else if (tr === "last_month") { period_start = new Date(Date.UTC(y, m - 1, 1)); period_end = new Date(Date.UTC(y, m, 0, 23, 59, 59, 999)); }
else if (tr === "custom" && ed.custom_range && ed.custom_range.start && ed.custom_range.end) {
  period_start = new Date(ed.custom_range.start);
  period_end = new Date(ed.custom_range.end);
} else {
  period_start = new Date(Date.UTC(y, m - 1, 1));
  period_end = new Date(Date.UTC(y, m, 0, 23, 59, 59, 999));
}
const rs = ed.report_period;
if (rs && rs.start && rs.end) {
  try { period_start = new Date(rs.start); period_end = new Date(rs.end); } catch (e) {}
}
return [{ json: { ...item, analysis_period_start: toIso(period_start), analysis_period_end: toIso(period_end), analysis_time_range_resolved: tr } }];"""

ANALYSIS_BASE_SQL = r"""WITH input AS (
  SELECT
    $1::BIGINT AS telegram_update_id,
    $2::BIGINT AS user_id,
    $3::BIGINT AS chat_id,
    $4::BIGINT AS message_id,
    $5::TEXT AS user_message,
    $6::TEXT AS route,
    $7::JSON AS extracted_data,
    $8::JSON AS memory,
    $9::JSON AS router_usage,
    $10::TEXT AS execution_id,
    $11::BIGINT AS execution_started_at_ms,
    $12::TIMESTAMPTZ AS execution_started_at,
    $13::TEXT AS message_kind,
    $14::BIGINT AS tool_started_at_ms,
    COALESCE(NULLIF($15, '')::TIMESTAMPTZ, NOW() - INTERVAL '30 days') AS period_start,
    COALESCE(NULLIF($16, '')::TIMESTAMPTZ, NOW() + INTERVAL '1 day') AS period_end
),
fin AS (
  SELECT COALESCE(json_agg(row_to_json(x)), '[]'::json) AS j
  FROM (
    SELECT category, transaction_type, currency, SUM(amount)::numeric AS total_amount, COUNT(*)::int AS transaction_count
    FROM finance_log fl, input
    WHERE fl.user_id = input.user_id
      AND transaction_at >= input.period_start
      AND transaction_at < input.period_end
    GROUP BY category, transaction_type, currency
  ) x
),
beh AS (
  SELECT COALESCE(json_agg(row_to_json(y)), '[]'::json) AS j
  FROM (
    SELECT (created_at AT TIME ZONE 'UTC')::date AS day, role, COUNT(*)::int AS msg_count
    FROM chat_memory cm, input
    WHERE cm.user_id = input.user_id
      AND created_at >= input.period_start
      AND created_at < input.period_end
    GROUP BY 1, 2
  ) y
)
SELECT
  input.telegram_update_id, input.user_id, input.chat_id, input.message_id, input.user_message, input.route, input.extracted_data, input.memory, input.router_usage,
  input.execution_id, input.execution_started_at_ms, input.execution_started_at, input.message_kind,
  GREATEST(0, (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT - input.tool_started_at_ms)::INT AS tool_latency_ms,
  COALESCE(fin.j, '[]'::json) AS finance_agg,
  COALESCE(beh.j, '[]'::json) AS behavior_agg,
  input.period_start,
  input.period_end
FROM input
CROSS JOIN fin
CROSS JOIN beh;"""

ANALYSIS_BASE_QUERY_REPLACEMENT = r"""={{ [ Number($json.telegram_update_id || 0), Number($json.user_id || 0), Number($json.chat_id || 0), Number($json.message_id || 0), String($json.user_message || ''), String($json.route || 'analysis'), JSON.stringify($json.extracted_data || {}), JSON.stringify($json.memory || []), JSON.stringify($json.router_usage || {}), String($json.execution_id || ''), Number($json.execution_started_at_ms || Date.now()), String($json.execution_started_at || new Date().toISOString()), String($json.message_kind || 'text'), Number($json.tool_started_at_ms || Date.now()), String($json.analysis_period_start || ''), String($json.analysis_period_end || '') ] }}"""

ANALYSIS_ATTACH_SEARCH_CODE = r"""let base = {};
try { base = { ...$items("Analysis Base SQL")[0].json }; } catch (e) {}
const t = items[0].json;
return [{ json: { ...base, search_results: t.results || [], search_answer: t.answer || null, search_error: t.error ? JSON.stringify(t.error) : null } }];"""

ANALYSIS_ATTACH_SEARCH_EMPTY_CODE = r"""const base = { ...items[0].json };
return [{ json: { ...base, search_results: [], search_answer: null, search_error: null } }];"""

ANALYSIS_PACKAGER_CODE = r"""const item = items[0].json;
const ed = item.extracted_data || {};
const financeRaw = item.finance_agg;
const behaviorRaw = item.behavior_agg;
function parseJ(v) {
  if (v == null) return [];
  if (typeof v === "string") { try { return JSON.parse(v); } catch (e) { return []; } }
  return Array.isArray(v) ? v : [];
}
const analysis_input = {
  question: String(ed.question || item.user_message || ""),
  analysis_type: String(ed.analysis_type || "finance").toLowerCase(),
  time_range: String(ed.time_range || "last_month"),
  entities: Array.isArray(ed.entities) ? ed.entities : [],
  period_start: item.analysis_period_start || item.period_start,
  period_end: item.analysis_period_end || item.period_end,
  datasets: {
    finance: parseJ(financeRaw),
    behavior: parseJ(behaviorRaw),
    search: { results: item.search_results || [], answer: item.search_answer },
  },
};
const analysis_raw = { finance_agg: financeRaw, behavior_agg: behaviorRaw, search: { results: item.search_results || [], answer: item.search_answer, error: item.search_error || null } };
return [{ json: { ...item, analysis_input, analysis_raw } }];"""

TOOL_DATA_ANALYSIS_CODE = r"""let pack = {};
try {
  const pr = $items("Analysis Packager");
  pack = pr[0] ? pr[0].json : {};
} catch (e) {}
const choice = $json.choices && $json.choices[0];
let interpreter_json = {};
try {
  interpreter_json = JSON.parse((choice && choice.message && choice.message.content) ? choice.message.content : "{}");
} catch (e) {
  interpreter_json = { summary: "Ошибка разбора JSON интерпретатора", insights: [], anomalies: [], interpretation: "", recommendations: [] };
}
const usage = { ...($json.usage || {}), model: $json.model || "" };
const apiErr = $json.error ? JSON.stringify($json.error) : null;
const started = Number(pack.tool_started_at_ms || Date.now());
return [{ json: {
  ...pack,
  tool_latency_ms: Date.now() - started,
  tool_data: {
    type: "analysis",
    success: !apiErr,
    interpreter_json,
    raw_datasets: pack.analysis_raw || {},
    error: apiErr,
  },
  interpreter_usage: usage,
}}];"""

SAVE_LLM_USAGE_QUERY = r"""WITH input AS (
  SELECT $1::BIGINT AS user_id, $2::BIGINT AS chat_id, $3::BIGINT AS message_id, $4::TEXT AS route, $5::JSONB AS router_usage, $6::JSONB AS synthesizer_usage, $7::JSONB AS interpreter_usage
), rows AS (
  SELECT user_id, chat_id, message_id, route, 'router'::TEXT AS call_type, router_usage AS usage FROM input WHERE router_usage IS NOT NULL AND router_usage <> '{}'::jsonb
  UNION ALL
  SELECT user_id, chat_id, message_id, route, 'synthesizer'::TEXT AS call_type, synthesizer_usage AS usage FROM input WHERE synthesizer_usage IS NOT NULL AND synthesizer_usage <> '{}'::jsonb
  UNION ALL
  SELECT user_id, chat_id, message_id, route, 'analysis_interpreter'::TEXT AS call_type, interpreter_usage AS usage
  FROM input
  WHERE interpreter_usage IS NOT NULL AND interpreter_usage <> '{}'::jsonb AND COALESCE(interpreter_usage->>'model', '') <> ''
), ins AS (
  INSERT INTO llm_usage_log (user_id, chat_id, message_id, route, call_type, model, prompt_tokens, completion_tokens, total_tokens, raw_usage)
  SELECT user_id, chat_id, message_id, route, call_type, COALESCE(usage->>'model', ''), COALESCE((usage->>'prompt_tokens')::INT, 0), COALESCE((usage->>'completion_tokens')::INT, 0), COALESCE((usage->>'total_tokens')::INT, 0), usage
  FROM rows
  RETURNING id
)
SELECT COUNT(*) AS saved_usage_rows FROM ins;"""

SAVE_LLM_USAGE_REPLACEMENT = r"""={{ [ Number($json.user_id || 0), Number($json.chat_id || 0), Number($json.message_id || 0), String($json.route || 'chat'), JSON.stringify($json.router_usage || {}), JSON.stringify($json.synthesizer_usage || {}), JSON.stringify($json.interpreter_usage || {}) ] }}"""

EXTRACT_REPLY_OLD_SNIPPET = """  ...branchItems("Cost Report SQL").map((i) => i.json),
  ...branchItems("Parse Router JSON").map((i) => i.json),"""

EXTRACT_REPLY_NEW_SNIPPET = """  ...branchItems("Cost Report SQL").map((i) => i.json),
  ...branchItems("Tool Data Analysis").map((i) => i.json),
  ...branchItems("Parse Router JSON").map((i) => i.json),"""


def build_new_nodes(pg_cred: dict) -> list[dict]:
    return [
        {
            "parameters": {
                "jsCode": ANALYSIS_TIME_RANGE_CODE,
                "language": "javaScript",
                "mode": "runOnceForAllItems",
            },
            "id": "analysis_time_range",
            "name": "Analysis Time Range",
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [3260, 480],
        },
        {
            "parameters": {
                "operation": "executeQuery",
                "query": ANALYSIS_BASE_SQL,
                "options": {
                    "queryBatching": "single",
                    "queryReplacement": ANALYSIS_BASE_QUERY_REPLACEMENT,
                },
            },
            "id": "analysis_base_sql",
            "name": "Analysis Base SQL",
            "type": "n8n-nodes-base.postgres",
            "typeVersion": 2.6,
            "position": [3460, 480],
            "credentials": pg_cred,
        },
        {
            "parameters": {
                "mode": "expression",
                "numberOutputs": 2,
                "output": "={{ ['search','mixed'].includes(String(($json.extracted_data || {}).analysis_type || '').toLowerCase()) ? 0 : 1 }}",
            },
            "id": "switch_analysis_web",
            "name": "Switch Analysis Web",
            "type": "n8n-nodes-base.switch",
            "typeVersion": 3.4,
            "position": [3660, 480],
        },
        {
            "parameters": {
                "url": "https://api.tavily.com/search",
                "specifyHeaders": "keypair",
                "contentType": "json",
                "method": "POST",
                "specifyBody": "json",
                "sendBody": True,
                "sendHeaders": True,
                "jsonBody": "={{ { api_key: $env.TAVILY_API_KEY || $env.SEARCH_API_KEY, query: String(($json.extracted_data || {}).search_query || ($json.extracted_data || {}).question || $json.user_message || '').trim(), max_results: 5 } }}",
                "headerParameters": {
                    "parameters": [{"value": "application/json", "name": "Content-Type"}]
                },
                "options": {
                    "response": {"response": {"responseFormat": "json", "neverError": True}}
                },
            },
            "id": "analysis_tavily_search",
            "name": "Analysis Tavily Search",
            "type": "n8n-nodes-base.httpRequest",
            "typeVersion": 4.4,
            "position": [3860, 400],
        },
        {
            "parameters": {
                "jsCode": ANALYSIS_ATTACH_SEARCH_CODE,
                "language": "javaScript",
                "mode": "runOnceForAllItems",
            },
            "id": "analysis_attach_search",
            "name": "Analysis Attach Search",
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [4060, 400],
        },
        {
            "parameters": {
                "jsCode": ANALYSIS_ATTACH_SEARCH_EMPTY_CODE,
                "language": "javaScript",
                "mode": "runOnceForAllItems",
            },
            "id": "analysis_attach_search_empty",
            "name": "Analysis Attach Search Empty",
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [3860, 560],
        },
        {
            "parameters": {
                "jsCode": ANALYSIS_PACKAGER_CODE,
                "language": "javaScript",
                "mode": "runOnceForAllItems",
            },
            "id": "analysis_packager",
            "name": "Analysis Packager",
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [4260, 480],
        },
        {
            "parameters": {
                "url": "https://api.openai.com/v1/chat/completions",
                "specifyHeaders": "keypair",
                "contentType": "json",
                "method": "POST",
                "specifyBody": "json",
                "sendBody": True,
                "sendHeaders": True,
                "jsonBody": "={{ { model: 'gpt-5.4-mini', messages: [] } }}",
                "headerParameters": {
                    "parameters": [
                        {"value": "={{ 'Bearer ' + $env.OPENAI_API_KEY }}", "name": "Authorization"},
                        {"value": "application/json", "name": "Content-Type"},
                    ]
                },
                "options": {
                    "response": {"response": {"responseFormat": "json", "neverError": True}}
                },
            },
            "id": "analysis_interpreter",
            "name": "Analysis Interpreter",
            "type": "n8n-nodes-base.httpRequest",
            "typeVersion": 4.4,
            "position": [4460, 480],
        },
        {
            "parameters": {
                "jsCode": TOOL_DATA_ANALYSIS_CODE,
                "language": "javaScript",
                "mode": "runOnceForAllItems",
            },
            "id": "tool_data_analysis",
            "name": "Tool Data Analysis",
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [4660, 480],
        },
    ]


def patch_connections(conns: dict) -> None:
    sr = conns.setdefault("Switch Route", {}).setdefault("main", [])
    target = [{"node": "Analysis Time Range", "type": "main", "index": 0}]
    if len(sr) == 6:
        sr.append(target)
    elif len(sr) >= 7:
        sr[6] = target

    conns["Analysis Time Range"] = {
        "main": [[{"node": "Analysis Base SQL", "type": "main", "index": 0}]]
    }
    conns["Analysis Base SQL"] = {
        "main": [[{"node": "Switch Analysis Web", "type": "main", "index": 0}]]
    }
    conns["Switch Analysis Web"] = {
        "main": [
            [{"node": "Analysis Tavily Search", "type": "main", "index": 0}],
            [{"node": "Analysis Attach Search Empty", "type": "main", "index": 0}],
        ]
    }
    conns["Analysis Tavily Search"] = {
        "main": [[{"node": "Analysis Attach Search", "type": "main", "index": 0}]]
    }
    conns["Analysis Attach Search"] = {
        "main": [[{"node": "Analysis Packager", "type": "main", "index": 0}]]
    }
    conns["Analysis Attach Search Empty"] = {
        "main": [[{"node": "Analysis Packager", "type": "main", "index": 0}]]
    }
    conns["Analysis Packager"] = {
        "main": [[{"node": "Analysis Interpreter", "type": "main", "index": 0}]]
    }
    conns["Analysis Interpreter"] = {
        "main": [[{"node": "Tool Data Analysis", "type": "main", "index": 0}]]
    }
    conns["Tool Data Analysis"] = {
        "main": [
            [
                {"node": "AI Synthesizer", "type": "main", "index": 0},
                {"node": "Save Tool Execution Log", "type": "main", "index": 0},
            ]
        ]
    }


def patch_nodes(nodes: list, md: str) -> None:
    interp_sys = escape_n8n_js_string(extract_fenced_text(md, "## 3. Analysis Interpreter Prompt"))
    interp_body = (
        "={{ { model: ($env.OPENAI_ANALYSIS_MODEL && String($env.OPENAI_ANALYSIS_MODEL).trim()) "
        "? String($env.OPENAI_ANALYSIS_MODEL).trim() : ($env.OPENAI_SYNTHESIZER_MODEL || 'gpt-5.4-mini'), "
        "messages: [ { role: 'system', content: \""
        + interp_sys
        + "\" }, { role: 'user', content: JSON.stringify($json.analysis_input || {}) } ], "
        "response_format: { type: 'json_object' }, max_completion_tokens: 800 } }}"
    )

    if not find_node(nodes, "analysis_time_range"):
        fin = find_node(nodes, "finance_report")
        pg_cred = copy.deepcopy(fin["credentials"]) if fin and fin.get("credentials") else {}
        insert_at = next(i for i, n in enumerate(nodes) if n.get("id") == "switch_route") + 1
        new_nodes = build_new_nodes(pg_cred)
        for n in new_nodes:
            if n["id"] == "analysis_interpreter":
                n["parameters"]["jsonBody"] = interp_body
        nodes[insert_at:insert_at] = new_nodes
    else:
        ai = find_node(nodes, "analysis_interpreter")
        if ai:
            ai["parameters"]["jsonBody"] = interp_body
        print("Analysis nodes already present; refreshed interpreter prompt.", file=sys.stderr)

    router = find_node(nodes, "ai_router")
    synth = find_node(nodes, "ai_synth")
    parse = find_node(nodes, "parse_router")
    switch = find_node(nodes, "switch_route")
    save_llm = find_node(nodes, "save_llm_usage")
    extract = find_node(nodes, "extract_reply")

    md_router = extract_fenced_text(md, "## 1. AI Router Prompt")
    md_synth = extract_fenced_text(md, "## 2. AI Synthesizer Prompt")

    ru = escape_n8n_js_string(md_router)
    su = escape_n8n_js_string(md_synth)

    router["parameters"]["jsonBody"] = (
        "={{ { model: $env.OPENAI_ROUTER_MODEL || 'gpt-5.4-mini', messages: [ "
        "{ role: 'system', content: \"" + ru + "\" }, "
        "{ role: 'user', content: 'User profile:\\n' + JSON.stringify($json.user_profile || {}) + "
        "'\\n\\nChat memory:\\n' + JSON.stringify($json.memory || []) + "
        "'\\n\\nUser message:\\n' + $json.user_message } ], "
        "response_format: { type: 'json_object' }, max_completion_tokens: 700 } }}"
    )

    synth["parameters"]["jsonBody"] = (
        "={{ { model: $env.OPENAI_SYNTHESIZER_MODEL || 'gpt-5.4-mini', messages: [ "
        "{ role: 'system', content: \"" + su + "\" }, "
        "{ role: 'user', content: 'Memory:\\n' + JSON.stringify($json.memory || []) + "
        "'\\n\\nRoute: ' + $json.route + '\\nExtracted data:\\n' + JSON.stringify($json.extracted_data || {}) + "
        "'\\n\\nTool data:\\n' + JSON.stringify($json.tool_data || ($json.error ? { type: $json.route || 'tool', success: false, error: JSON.stringify($json.error) } : {})) + "
        "'\\n\\nUser message:\\n' + $json.user_message } ], max_completion_tokens: 900 } }}"
    )

    parse_code = parse["parameters"]["jsCode"]
    parse_code = parse_code.replace(
        '[\"finance_add\", \"finance_report\", \"search\", \"reminder_add\", \"ai_cost_report\", \"chat\"]',
        '[\"finance_add\", \"finance_report\", \"search\", \"analysis\", \"reminder_add\", \"ai_cost_report\", \"chat\"]',
    )
    parse["parameters"]["jsCode"] = parse_code

    switch["parameters"]["numberOutputs"] = 7
    switch["parameters"]["output"] = (
        "={{ ({ chat: 0, search: 1, finance_add: 2, finance_report: 3, reminder_add: 4, ai_cost_report: 5, analysis: 6 })[$json.route] ?? 0 }}"
    )

    save_llm["parameters"]["query"] = SAVE_LLM_USAGE_QUERY
    save_llm["parameters"]["options"]["queryReplacement"] = SAVE_LLM_USAGE_REPLACEMENT

    ex = extract["parameters"]["jsCode"]
    if "Tool Data Analysis" not in ex:
        ex = ex.replace(EXTRACT_REPLY_OLD_SNIPPET, EXTRACT_REPLY_NEW_SNIPPET)
        extract["parameters"]["jsCode"] = ex

    base_sql = find_node(nodes, "analysis_base_sql")
    if base_sql:
        base_sql["parameters"]["query"] = ANALYSIS_BASE_SQL
        base_sql["parameters"]["options"]["queryReplacement"] = ANALYSIS_BASE_QUERY_REPLACEMENT


def main() -> int:
    md = PROMPTS.read_text(encoding="utf-8")
    data = json.loads(WORKFLOW.read_text(encoding="utf-8"))

    patch_nodes(data["nodes"], md)
    patch_connections(data["connections"])

    if "activeVersion" in data and isinstance(data["activeVersion"], dict):
        av = data["activeVersion"]
        av["nodes"] = copy.deepcopy(data["nodes"])
        av["connections"] = copy.deepcopy(data["connections"])

    WORKFLOW.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Patched", WORKFLOW)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
