$ErrorActionPreference = 'Stop'

$path = Join-Path $PSScriptRoot '..\\workflows\\personal_assistant_mvp.json'
$path = (Resolve-Path $path).Path
$wf = Get-Content $path -Raw | ConvertFrom-Json

function Get-Node([string]$name) {
    return @($wf.nodes | Where-Object { $_.name -eq $name })[0]
}

function Set-Connection([string]$name, $value) {
    $existing = $wf.connections.PSObject.Properties[$name]
    if ($existing) {
        $existing.Value = $value
    }
    else {
        $wf.connections | Add-Member -NotePropertyName $name -NotePropertyValue $value
    }
}

function Read-JsonValue([string]$json) {
    return $json | ConvertFrom-Json
}

$loadMemory = Get-Node 'Load Memory'
$loadMemory.parameters.query = @'
SELECT
  $1::BIGINT AS telegram_update_id,
  $2::BIGINT AS user_id,
  $3::BIGINT AS chat_id,
  $4::BIGINT AS message_id,
  $5::TEXT AS user_message,
  $6::TIMESTAMPTZ AS received_at,
  $7::BOOLEAN AS is_allowed,
  $8::TEXT AS message_kind,
  NULLIF($9, '')::TEXT AS input_error,
  NULLIF($10, '')::TEXT AS transcription_error,
  $11::TEXT AS execution_id,
  $12::BIGINT AS execution_started_at_ms,
  $13::TIMESTAMPTZ AS execution_started_at,
  COALESCE(
    (
      SELECT json_agg(row_to_json(m))
      FROM (
        SELECT role, LEFT(content, 500) AS content, created_at
        FROM (
          SELECT role, content, created_at
          FROM chat_memory
          WHERE user_id = $2
          ORDER BY created_at DESC
          LIMIT 4
        ) recent_router
        ORDER BY created_at ASC
      ) m
    ),
    '[]'::json
  ) AS router_memory,
  COALESCE(
    (
      SELECT json_agg(row_to_json(m))
      FROM (
        SELECT role, LEFT(content, 1200) AS content, created_at
        FROM (
          SELECT role, content, created_at
          FROM chat_memory
          WHERE user_id = $2
          ORDER BY created_at DESC
          LIMIT 6
        ) recent_synth
        ORDER BY created_at ASC
      ) m
    ),
    '[]'::json
  ) AS synth_memory,
  COALESCE(
    (
      SELECT json_agg(row_to_json(m))
      FROM (
        SELECT role, LEFT(content, 1200) AS content, created_at
        FROM (
          SELECT role, content, created_at
          FROM chat_memory
          WHERE user_id = $2
          ORDER BY created_at DESC
          LIMIT 6
        ) recent_memory
        ORDER BY created_at ASC
      ) m
    ),
    '[]'::json
  ) AS memory,
  COALESCE(
    (
      SELECT json_build_object(
        'default_city', up.default_city,
        'default_country', up.default_country,
        'location_mode', up.location_mode,
        'search_radius_km', up.search_radius_km
      )
      FROM user_profile up
      WHERE up.user_id = $2
      LIMIT 1
    ),
    json_build_object(
      'default_city', 'Pavlodar',
      'default_country', 'Kazakhstan',
      'location_mode', 'auto',
      'search_radius_km', null
    )
  ) AS user_profile;
'@

$aiRouter = Get-Node 'AI Router'
$aiRouter.parameters.jsonBody = @'
={{ { model: $env.OPENAI_ROUTER_MODEL || 'gpt-5.4-mini', messages: [ { role: 'system', content: "You are the router for a personal AI assistant.\n\nReturn only valid JSON. Do not use Markdown.\n\nAvailable routes:\n- finance_add\n- finance_report\n- search\n- research\n- analysis\n- task_plan\n- reminder_add\n- ai_cost_report\n- chat\n\nIf unsure, choose chat.\nIf transcription_error or input_error is present, choose chat and explain briefly in extracted_data.error.\n\nResponse format:\n{\n  \"route\": \"chat\",\n  \"confidence\": 0.8,\n  \"extracted_data\": {},\n  \"direct_response\": \"\"\n}\n\nFor simple greetings, casual small talk, thanks, or short conversational replies that do not need tools, route to chat and set direct_response to a concise final answer for the user.\nLeave direct_response empty for all tool routes and for chat requests that still need the synthesizer.\n\nExtract when useful:\n- amount, transaction_type, category, description, transaction_at, report_period\n- search_query, search_scope, location, radius_km\n- analysis_type, time_range, custom_range, entities, question\n- comparison_axes, deliverable_format, research_goal\n- goal, constraints, reason\n- task_text, remind_at, timezone\n\nThe user message begins with a User profile JSON block: default_city, default_country (defaults Pavlodar, Kazakhstan when no DB row).\n\nfinance_report vs analysis:\n- finance_report: user wants totals, lists, or a factual report for a period without asking for trends, causes, or comparisons across time.\n- analysis: user asks to compare periods, find patterns or trends, explain why something changed, evaluate habits, or combine finance + activity + optional web context.\n\nsearch vs research:\n- search: use when the user needs fresh web information, a quick lookup, latest facts, or a short answer based on recent web data.\n- research: use when the user wants a fuller internet-based analysis, comparison, recommendation, almost-ready memo/report, or multi-criteria evaluation from web sources.\n- Prefer research when the request explicitly asks to compare options, analyze findings, produce conclusions, recommendations, or a structured report based on internet data.\n\ntask_plan rules:\n- Use task_plan when the request is clearly sequential, scenario-based, or needs decomposition into multiple explicit steps before execution.\n- Prefer task_plan only when the request does not fit one deterministic branch cleanly.\n- Keep goal short and constraints compact.\n\nSearch rules:\n- Route search or research when the user needs fresh web information.\n- search_scope \"local\" for cafes, restaurants, gyms, shops, services, events nearby, city weather, local transport; Russian cues like где поесть, кафе, бар, рядом, аптека, поликлиника; use local when the user does not clearly name another city or country.\n- search_scope \"global\" for crypto, stocks, APIs, programming, world news without a local tie, or when another city or country is explicit in the message.\n- location: for local scope, set explicit \"City, Country\" if the user names a place (e.g. Алматы); otherwise null so the pipeline applies profile defaults.\n- radius_km: optional positive number for local distance-sensitive queries; otherwise null.\n- search_query: concise keywords; avoid repeating the city in the query when location is set separately.\n- comparison_axes: optional short list of criteria such as price, rating, reliability, features, reviews, or distance.\n- deliverable_format: optional short hint such as memo, comparison, shortlist, report, recommendation, or top_list.\n\nRouting priority:\n- If the user asks to compare options, rank results, evaluate by multiple criteria, give a final recommendation, produce a structured ????/?????, or mentions a format like table/top/report, prefer research over search.\n- For local discovery requests that include compare, ???????, ??????, ??????????, ??????/???, recommendation, ????, shortlist, or multi-criteria ranking, prefer research.\n\nRules:\n- finance_add: use when the user reports income or expense.\n- finance_report: use when the user asks for totals, lists, or summaries for a period without interpretive why/trend/compare analysis.\n- search: use when the user needs a quick factual web lookup without multi-criteria comparison or report formatting.\n- research: use when the user wants a structured internet-based analysis, comparison, recommendation, top list, or ready-to-read report.\n- analysis: use when the user asks for trends, comparisons, patterns, anomalies, or interpretive summaries over time.\n- task_plan: use when the user asks for a bounded multi-step plan or sequential computational workflow.\n- reminder_add: use when the user asks to be reminded about something.\n- ai_cost_report: use when the user asks about token usage, API spend, or LLM costs for this assistant.\n- chat: use for normal conversation and anything that does not require tools.\n\nFor finance_add:\n- amount must be a positive number when present.\n- transaction_type must be income or expense.\n- Default currency is KZT.\n\nFor reminder_add:\n- remind_at should be ISO 8601 when the time can be determined.\n- Default timezone is Asia/Qyzylorda.\n\nFor analysis:\n- analysis_type must be one of: finance, behavior, search, mixed.\n- time_range: last_day, last_week, last_month, or custom.\n- question: short analytical intent in the user language.\n- entities: optional list of keywords.\n\nFor research:\n- research_goal: short restatement of the desired report outcome.\n- comparison_axes: optional short list of comparison criteria.\n- deliverable_format: optional short label for the expected report style.\n\nFor task_plan:\n- goal: short restatement of the target outcome.\n- constraints: optional list of limits, assumptions, or conditions.\n- reason: short explanation of why a bounded plan is needed.\n\nUser messages can be in Russian. Keep extracted text in the user's language when useful." }, { role: 'user', content: 'User profile:\n' + JSON.stringify($json.user_profile || {}) + '\n\nChat memory:\n' + JSON.stringify($json.router_memory || []) + '\n\nUser message:\n' + $json.user_message } ], response_format: { type: 'json_object' }, max_completion_tokens: 260 } }}
'@
$aiRouter.parameters.jsonBody = @'
={{ { model: $env.OPENAI_ROUTER_MODEL || 'gpt-5.4-mini', messages: [ { role: 'system', content: "You are the router for a personal AI assistant.\n\nReturn only valid JSON. Do not use Markdown.\n\nAvailable routes:\n- finance_add\n- finance_report\n- search\n- research\n- analysis\n- task_plan\n- reminder_add\n- ai_cost_report\n- chat\n\nIf unsure, choose chat.\nIf transcription_error or input_error is present, choose chat and explain briefly in extracted_data.error.\n\nResponse format:\n{\n  \"route\": \"chat\",\n  \"confidence\": 0.8,\n  \"extracted_data\": {},\n  \"direct_response\": \"\"\n}\n\nFor simple greetings, casual small talk, thanks, or short conversational replies that do not need tools, route to chat and set direct_response to a concise final answer for the user.\nLeave direct_response empty for all tool routes and for chat requests that still need the synthesizer.\n\nExtract when useful:\n- amount, transaction_type, category, description, transaction_at, report_period\n- search_query, search_scope, location, radius_km\n- analysis_type, time_range, custom_range, entities, question\n- comparison_axes, deliverable_format, research_goal\n- goal, constraints, reason\n- task_text, remind_at, timezone\n\nThe user message begins with a User profile JSON block: default_city, default_country (defaults Pavlodar, Kazakhstan when no DB row).\n\nfinance_report vs analysis:\n- finance_report: user wants totals, lists, or a factual report for a period without asking for trends, causes, or comparisons across time.\n- analysis: user asks to compare periods, find patterns or trends, explain why something changed, evaluate habits, or combine finance + activity + optional web context.\n\nsearch vs research:\n- search: use when the user needs fresh web information, a quick lookup, latest facts, or a short answer based on recent web data.\n- research: use when the user wants a fuller internet-based analysis, comparison, recommendation, almost-ready memo/report, or multi-criteria evaluation from web sources.\n- Prefer research when the request explicitly asks to compare options, analyze findings, produce conclusions, recommendations, or a structured report based on internet data.\n\ntask_plan rules:\n- Use task_plan when the request is clearly sequential, scenario-based, or needs decomposition into multiple explicit steps before execution.\n- Prefer task_plan only when the request does not fit one deterministic branch cleanly.\n- Keep goal short and constraints compact.\n\nSearch rules:\n- Route search or research when the user needs fresh web information.\n- search_scope \"local\" for cafes, restaurants, bars, gyms, shops, services, events nearby, city weather, or local transport; also treat messages asking where to eat nearby, find cafes, pharmacies, or clinics as local when no other city or country is explicit.\n- search_scope \"global\" for crypto, stocks, APIs, programming, world news without a local tie, or when another city or country is explicit in the message.\n- location: for local scope, set explicit \"City, Country\" if the user names a place; otherwise null so the pipeline applies profile defaults.\n- radius_km: optional positive number for local distance-sensitive queries; otherwise null.\n- search_query: concise keywords; avoid repeating the city in the query when location is set separately.\n- comparison_axes: optional short list of criteria such as price, rating, reliability, features, reviews, or distance.\n- deliverable_format: optional short hint such as memo, comparison, shortlist, report, recommendation, or top_list.\n\nRouting priority:\n- If the user asks to compare options, rank results, evaluate by multiple criteria, give a final recommendation, produce a structured report or memo, or mentions a format like table, top list, or report, prefer research over search.\n- For local discovery requests that include compare, ranking, reviews, ratings, recommendation, top list, shortlist, or multi-criteria evaluation, prefer research.\n\nRules:\n- finance_add: use when the user reports income or expense.\n- finance_report: use when the user asks for totals, lists, or summaries for a period without interpretive why/trend/compare analysis.\n- search: use when the user needs a quick factual web lookup without multi-criteria comparison or report formatting.\n- research: use when the user wants a structured internet-based analysis, comparison, recommendation, top list, or ready-to-read report.\n- analysis: use when the user asks for trends, comparisons, patterns, anomalies, or interpretive summaries over time.\n- task_plan: use when the user asks for a bounded multi-step plan or sequential computational workflow.\n- reminder_add: use when the user asks to be reminded about something.\n- ai_cost_report: use when the user asks about token usage, API spend, or LLM costs for this assistant.\n- chat: use for normal conversation and anything that does not require tools.\n\nFor finance_add:\n- amount must be a positive number when present.\n- transaction_type must be income or expense.\n- Default currency is KZT.\n\nFor reminder_add:\n- remind_at should be ISO 8601 when the time can be determined.\n- Default timezone is Asia/Qyzylorda.\n\nFor analysis:\n- analysis_type must be one of: finance, behavior, search, mixed.\n- time_range: last_day, last_week, last_month, or custom.\n- question: short analytical intent in the user language.\n- entities: optional list of keywords.\n\nFor research:\n- research_goal: short restatement of the desired report outcome.\n- comparison_axes: optional short list of comparison criteria.\n- deliverable_format: optional short label for the expected report style.\n\nFor task_plan:\n- goal: short restatement of the target outcome.\n- constraints: optional list of limits, assumptions, or conditions.\n- reason: short explanation of why a bounded plan is needed.\n\nUser messages can be in Russian. Keep extracted text in the user's language when useful." }, { role: 'user', content: 'User profile:\n' + JSON.stringify($json.user_profile || {}) + '\n\nChat memory:\n' + JSON.stringify($json.router_memory || []) + '\n\nUser message:\n' + $json.user_message } ], response_format: { type: 'json_object' }, max_completion_tokens: 260 } }}
'@

$parseRouter = Get-Node 'Parse Router JSON'
$parseRouter.parameters.jsCode = @'
const mem = $items("Load Memory");
const base = (mem && mem[0] && mem[0].json) ? mem[0].json : {};
const choice = $json.choices && $json.choices[0];
const raw = (choice && choice.message && choice.message.content) ? choice.message.content : "{}";
let parsed;
try {
  parsed = JSON.parse(raw);
} catch (error) {
  parsed = { route: "chat", confidence: 0, extracted_data: {}, parse_error: raw };
}
if (!["finance_add", "finance_report", "search", "research", "analysis", "task_plan", "reminder_add", "ai_cost_report", "chat"].includes(parsed.route)) {
  parsed.route = "chat";
}
if (base.input_error || base.transcription_error) {
  parsed.route = "chat";
}
const direct_response = typeof parsed.direct_response === "string" ? parsed.direct_response.trim() : "";
return [{ json: { ...base, route: parsed.route, confidence: parsed.confidence || 0, extracted_data: parsed.extracted_data || {}, direct_response, router_usage: { ...($json.usage || {}), model: $json.model || "" }, tool_started_at_ms: Date.now() } }];
'@

$normalizeVoice = Get-Node 'Normalize Voice Transcription'
if ($normalizeVoice) {
    $normalizeVoice.parameters.jsCode = @'
const base = $items("Voice Context")[0]?.json || {};
const response = items[0]?.json || {};
const latency = Date.now() - Number(base.voice_tool_started_at_ms || base.execution_started_at_ms || Date.now());

if (base.input_error) {
  return [{ json: { ...base, user_message: "", transcription_error: String(base.input_error), voice_tool_latency_ms: latency } }];
}

if (response.error) {
  const message = String(response.error?.message || response.error?.error?.message || "Не удалось распознать голосовое сообщение.");
  return [{ json: { ...base, user_message: "", transcription_error: message, voice_tool_latency_ms: latency } }];
}

const transcript = String(response.text || response.transcript || "").trim();
if (!transcript) {
  return [{ json: { ...base, user_message: "", transcription_error: "Не удалось распознать голосовое сообщение.", voice_tool_latency_ms: latency } }];
}

return [{
  json: {
    ...base,
    user_message: transcript,
    transcription_error: null,
    voice_tool_latency_ms: latency
  }
}];
'@
    $normalizeVoice.parameters.language = 'javaScript'
    $normalizeVoice.parameters.mode = 'runOnceForAllItems'
}

$toolDataAnalysis = Get-Node 'Tool Data Analysis'
if ($toolDataAnalysis) {
    $toolDataAnalysis.parameters.jsCode = @'
let pack = {};
try {
  const pr = $items("Analysis Packager");
  pack = pr[0] ? pr[0].json : {};
} catch (error) {
  pack = {};
}

const choice = $json.choices && $json.choices[0];
let interpreter_json = {};
try {
  interpreter_json = JSON.parse((choice && choice.message && choice.message.content) ? choice.message.content : "{}");
} catch (error) {
  interpreter_json = {
    summary: "Не удалось разобрать аналитический ответ модели.",
    insights: [],
    anomalies: [],
    interpretation: "",
    recommendations: []
  };
}

const hasError = Boolean($json.error);
return [{
  json: {
    ...pack,
    tool_latency_ms: Date.now() - Number(pack.tool_started_at_ms || Date.now()),
    interpreter_usage: { ...($json.usage || {}), model: $json.model || "" },
    tool_data: {
      type: "analysis",
      success: !hasError,
      interpreter_json,
      raw_datasets: pack.analysis_raw || {},
      error: hasError ? JSON.stringify($json.error) : null
    }
  }
}];
'@
    $toolDataAnalysis.parameters.language = 'javaScript'
    $toolDataAnalysis.parameters.mode = 'runOnceForAllItems'
}

$analysisTimeRange = Get-Node 'Analysis Time Range'
if ($analysisTimeRange) {
    $analysisTimeRange.parameters.jsCode = @'
const item = items[0].json;
const ed = item.extracted_data || {};
const tr = String(ed.time_range || "last_month").toLowerCase();
const tz = "Asia/Qyzylorda";

function partsFor(date) {
  const fmt = new Intl.DateTimeFormat("en-CA", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  const out = {};
  for (const part of fmt.formatToParts(date)) {
    if (part.type !== "literal") out[part.type] = Number(part.value);
  }
  return out;
}

function localIso(date) {
  return new Intl.DateTimeFormat("sv-SE", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).format(date).replace(" ", "T");
}

function zonedDate(year, month, day, hour = 0, minute = 0, second = 0, ms = 0) {
  const utcGuess = new Date(Date.UTC(year, month - 1, day, hour, minute, second, ms));
  const localFromGuess = localIso(utcGuess);
  const desired = `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}T${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}:${String(second).padStart(2, "0")}`;
  const deltaMs = Date.parse(`${desired}Z`) - Date.parse(`${localFromGuess}Z`);
  return new Date(utcGuess.getTime() + deltaMs);
}

const now = new Date();
const nowParts = partsFor(now);
let period_start;
let period_end;

if (tr === "last_day" || tr === "today") {
  period_start = zonedDate(nowParts.year, nowParts.month, nowParts.day, 0, 0, 0, 0);
  period_end = now;
} else if (tr === "yesterday") {
  const y = new Date(period_start || now);
  const startToday = zonedDate(nowParts.year, nowParts.month, nowParts.day, 0, 0, 0, 0);
  const startYesterday = new Date(startToday.getTime() - 24 * 60 * 60 * 1000);
  const yParts = partsFor(startYesterday);
  period_start = zonedDate(yParts.year, yParts.month, yParts.day, 0, 0, 0, 0);
  period_end = zonedDate(yParts.year, yParts.month, yParts.day, 23, 59, 59, 999);
} else if (tr === "last_week") {
  period_end = now;
  period_start = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
} else if (tr === "this_month" || tr === "month") {
  period_start = zonedDate(nowParts.year, nowParts.month, 1, 0, 0, 0, 0);
  period_end = now;
} else if (tr === "last_month") {
  const thisMonthStart = zonedDate(nowParts.year, nowParts.month, 1, 0, 0, 0, 0);
  const prevMonthEnd = new Date(thisMonthStart.getTime() - 1);
  const prevParts = partsFor(prevMonthEnd);
  period_start = zonedDate(prevParts.year, prevParts.month, 1, 0, 0, 0, 0);
  period_end = zonedDate(prevParts.year, prevParts.month, prevParts.day, 23, 59, 59, 999);
} else if (tr === "custom" && ed.custom_range && ed.custom_range.start && ed.custom_range.end) {
  period_start = new Date(ed.custom_range.start);
  period_end = new Date(ed.custom_range.end);
} else {
  const thisMonthStart = zonedDate(nowParts.year, nowParts.month, 1, 0, 0, 0, 0);
  const prevMonthEnd = new Date(thisMonthStart.getTime() - 1);
  const prevParts = partsFor(prevMonthEnd);
  period_start = zonedDate(prevParts.year, prevParts.month, 1, 0, 0, 0, 0);
  period_end = zonedDate(prevParts.year, prevParts.month, prevParts.day, 23, 59, 59, 999);
}

const rs = ed.report_period;
if (rs && rs.start && rs.end) {
  try {
    period_start = new Date(rs.start);
    period_end = new Date(rs.end);
  } catch (error) {}
}

return [{
  json: {
    ...item,
    analysis_period_start: new Date(period_start).toISOString(),
    analysis_period_end: new Date(period_end).toISOString(),
    analysis_time_range_resolved: tr,
    analysis_timezone: tz
  }
}];
'@
    $analysisTimeRange.parameters.language = 'javaScript'
    $analysisTimeRange.parameters.mode = 'runOnceForAllItems'
}

$analysisBaseSql = Get-Node 'Analysis Base SQL'
if ($analysisBaseSql) {
    $analysisBaseSql.parameters.query = @'
WITH input AS (
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
    SELECT (created_at AT TIME ZONE 'Asia/Qyzylorda')::date AS day, role, COUNT(*)::int AS msg_count
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
CROSS JOIN beh;
'@
}

$switchRoute = Get-Node 'Switch Route'
$switchRoute.parameters.numberOutputs = 9
$switchRoute.parameters.output = '={{ ({ chat: 0, search: 1, research: 2, finance_add: 3, finance_report: 4, reminder_add: 5, ai_cost_report: 6, analysis: 7, task_plan: 8 })[$json.route] ?? 0 }}'

$aiSynth = Get-Node 'AI Synthesizer'
$aiSynth.parameters.jsonBody = @'
={{ { model: $env.OPENAI_SYNTHESIZER_MODEL || 'gpt-5.4-mini', messages: [ { role: 'system', content: "You are Asteron, a personal assistant in Telegram.\n\nAlways answer in Russian, but keep your style natural, warm, concise, and practical.\nIf the user asks several things in one message, answer in short separate blocks.\n\nDo not use Markdown asterisks.\nIf emphasis is useful, use only Telegram HTML tags: <b>, <i>, <code>.\nUse formatting sparingly.\n\nNever mention internal node names, JSON, n8n, router, tool_data, or implementation details.\n\nIf an action was saved, confirm it with specific details.\nFor reminders and dates, include a concrete date and time when available in the data.\nIf the user asks for the current time, answer directly with the user's local time when available.\nIf tool_data contains search, finance, or analysis results, summarize them clearly. For route analysis, lean on tool_data.interpreter_json and do not contradict raw numbers in tool_data.raw_datasets. If tool_data contains a task plan, explain the plan as short numbered steps and clearly say when background execution would be needed.\nIf tool_data.type is research, always produce a structured Telegram-friendly report with these sections in Russian: <b>????</b>, <b>???-5</b>, <b>?????????</b>, <b>?????</b>, <b>????????????</b>, <b>?????????</b>.\nFor research:\n- Do NOT use HTML tables, markdown tables, or pseudo-table rows with pipes.\n- Render the shortlist as a numbered list, one place per line.\n- Each shortlist line should look like: 1. ???????? ? ??????? X, ??????? Y, ??????????: Z.\n- Lean on tool_data.report_json and tool_data.search_results.\n- Keep source links grounded in tool_data.report_json.sources.\n- Mention caveats only when present and only where relevant.If tool_data.success is false, briefly explain that the action failed and say what the user can retry.\n\nBy default assume the user is in Pavlodar, Kazakhstan for local life advice unless memory, tool_data, or the user message clearly specifies another place.\n\nDo not invent facts that are not present in memory or tool_data." }, { role: 'user', content: 'Memory:\n' + JSON.stringify($json.synth_memory || $json.memory || []) + '\n\nRoute: ' + $json.route + '\nExtracted data:\n' + JSON.stringify($json.extracted_data || {}) + '\n\nTool data:\n' + JSON.stringify($json.tool_data || ($json.error ? { type: $json.route || 'tool', success: false, error: JSON.stringify($json.error) } : {})) + '\n\nUser message:\n' + $json.user_message } ], max_completion_tokens: 800 } }}
'@
$aiSynth.parameters.jsonBody = @'
={{ { model: $env.OPENAI_SYNTHESIZER_MODEL || 'gpt-5.4-mini', messages: [ { role: 'system', content: "You are Asteron, a personal assistant in Telegram.\n\nAlways answer in Russian, but keep your style natural, warm, concise, and practical.\nIf the user asks several things in one message, answer in short separate blocks.\n\nDo not use Markdown asterisks.\nIf emphasis is useful, use only Telegram HTML tags: <b>, <i>, <code>.\nUse formatting sparingly.\n\nNever mention internal node names, JSON, n8n, router, tool_data, or implementation details.\n\nIf an action was saved, confirm it with specific details.\nFor reminders and dates, include a concrete date and time when available in the data.\nIf the user asks for the current time, answer directly with the user's local time when available.\nIf tool_data contains search, finance, or analysis results, summarize them clearly. For route analysis, lean on tool_data.interpreter_json and do not contradict raw numbers in tool_data.raw_datasets. If tool_data contains a task plan, explain the plan as short numbered steps and clearly say when background execution would be needed.\nIf tool_data.type is research, always produce a structured Telegram-friendly report with six sections written in Russian: goal, top-5, comparison, conclusion, recommendation, and sources.\nFor research:\n- Do NOT use HTML tables, markdown tables, or pseudo-table rows with pipes.\n- Render the shortlist as a numbered list, one place per line.\n- Each shortlist line should look like: 1. Place Name - rating X, reviews Y, distance: Z.\n- Lean on tool_data.report_json and tool_data.search_results.\n- Keep source links grounded in tool_data.report_json.sources.\n- Mention caveats only when present and only where relevant.\nIf tool_data.success is false, briefly explain that the action failed and say what the user can retry.\n\nBy default assume the user is in Pavlodar, Kazakhstan for local life advice unless memory, tool_data, or the user message clearly specifies another place.\n\nDo not invent facts that are not present in memory or tool_data." }, { role: 'user', content: 'Memory:\n' + JSON.stringify($json.synth_memory || $json.memory || []) + '\n\nRoute: ' + $json.route + '\nExtracted data:\n' + JSON.stringify($json.extracted_data || {}) + '\n\nTool data:\n' + JSON.stringify($json.tool_data || ($json.error ? { type: $json.route || 'tool', success: false, error: JSON.stringify($json.error) } : {})) + '\n\nUser message:\n' + $json.user_message } ], max_completion_tokens: 800 } }}
'@

$extractReply = Get-Node 'Extract Assistant Reply'
$extractReply.parameters.jsCode = @'
function branchItems(nodeName) {
  try {
    const rows = $items(nodeName);
    return Array.isArray(rows) ? rows : [];
  } catch (error) {
    return [];
  }
}
const candidates = [
  ...branchItems("Tool Data Chat").map((i) => i.json),
  ...branchItems("Tool Data Search").map((i) => i.json),
  ...branchItems("Tool Data Research").map((i) => i.json),
  ...branchItems("Finance Add SQL").map((i) => i.json),
  ...branchItems("Finance Report SQL").map((i) => i.json),
  ...branchItems("Reminder Add SQL").map((i) => i.json),
  ...branchItems("Cost Report SQL").map((i) => i.json),
  ...branchItems("Tool Data Analysis").map((i) => i.json),
  ...branchItems("Task Plan Tool Data").map((i) => i.json),
  ...branchItems("Parse Router JSON").map((i) => i.json),
];
const base = candidates.find((json) => json && json.chat_id) || candidates.find(Boolean) || {};
const choice = $json.choices && $json.choices[0];
let assistant_reply = (choice && choice.message && choice.message.content) ? choice.message.content : "Не получилось подготовить ответ. Попробуй еще раз.";
if ($json.error) {
  assistant_reply = "Не получилось подготовить ответ из-за ошибки AI-модели. Попробуй еще раз.";
}
function sanitizeTelegramHtml(input) {
  let text = String(input || "");
  text = text
    .replace(/<\/?(table|thead|tbody|tfoot)[^>]*>/gi, "\n")
    .replace(/<tr[^>]*>/gi, "\n")
    .replace(/<\/tr>/gi, "\n")
    .replace(/<t[dh][^>]*>/gi, " | ")
    .replace(/<\/t[dh]>/gi, " ");
  text = text.replace(/<(?!\/?(b|i|code|pre|a)(\s|>|$))[^>]+>/gi, "");
  text = text.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  return text;
}
assistant_reply = sanitizeTelegramHtml(assistant_reply);
return [{ json: { ...base, assistant_reply, synthesizer_usage: { ...($json.usage || {}), model: $json.model || "" } } }];
'@

$saveUsage = Get-Node 'Save LLM Usage'
$saveUsage.parameters.query = @'
WITH input AS (
  SELECT $1::BIGINT AS user_id, $2::BIGINT AS chat_id, $3::BIGINT AS message_id, $4::TEXT AS route, $5::JSONB AS router_usage, $6::JSONB AS synthesizer_usage, $7::JSONB AS interpreter_usage, $8::JSONB AS planner_usage
), rows AS (
  SELECT user_id, chat_id, message_id, route, 'router'::TEXT AS call_type, router_usage AS usage FROM input WHERE router_usage IS NOT NULL AND router_usage <> '{}'::jsonb
  UNION ALL
  SELECT user_id, chat_id, message_id, route, 'synthesizer'::TEXT AS call_type, synthesizer_usage AS usage FROM input WHERE synthesizer_usage IS NOT NULL AND synthesizer_usage <> '{}'::jsonb
  UNION ALL
  SELECT user_id, chat_id, message_id, route, 'analysis_interpreter'::TEXT AS call_type, interpreter_usage AS usage
  FROM input
  WHERE interpreter_usage IS NOT NULL AND interpreter_usage <> '{}'::jsonb AND COALESCE(interpreter_usage->>'model', '') <> ''
  UNION ALL
  SELECT user_id, chat_id, message_id, route, 'task_planner'::TEXT AS call_type, planner_usage AS usage
  FROM input
  WHERE planner_usage IS NOT NULL AND planner_usage <> '{}'::jsonb AND COALESCE(planner_usage->>'model', '') <> ''
), ins AS (
  INSERT INTO llm_usage_log (user_id, chat_id, message_id, route, call_type, model, prompt_tokens, completion_tokens, total_tokens, raw_usage)
  SELECT user_id, chat_id, message_id, route, call_type, COALESCE(usage->>'model', ''), COALESCE((usage->>'prompt_tokens')::INT, 0), COALESCE((usage->>'completion_tokens')::INT, 0), COALESCE((usage->>'total_tokens')::INT, 0), usage
  FROM rows
  RETURNING id
)
SELECT COUNT(*) AS saved_usage_rows FROM ins;
'@
$saveUsage.parameters.options.queryReplacement = '={{ [ Number($json.user_id || 0), Number($json.chat_id || 0), Number($json.message_id || 0), String($json.route || ''chat''), JSON.stringify($json.router_usage || {}), JSON.stringify($json.synthesizer_usage || {}), JSON.stringify($json.interpreter_usage || {}), JSON.stringify($json.planner_usage || {}) ] }}'

if (-not (Get-Node 'Direct Reply Builder')) {
    $directNode = [pscustomobject][ordered]@{
        parameters = [ordered]@{
            jsCode = @'
const item = items[0].json;
const td = item.tool_data || {};
function fmtDate(value) {
  if (!value) return null;
  try {
    return new Intl.DateTimeFormat('ru-RU', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Asia/Qyzylorda' }).format(new Date(value));
  } catch (error) {
    return String(value);
  }
}
let assistant_reply = 'Готово.';
if (td.type === 'finance_add') {
  if (td.success && td.saved) {
    const row = td.saved;
    const when = fmtDate(row.transaction_at);
    assistant_reply = `Записал ${row.transaction_type === 'income' ? 'доход' : 'расход'}: ${row.amount} ${row.currency}${row.category ? `, категория ${row.category}` : ''}${when ? `, дата ${when}` : ''}.`;
  } else {
    assistant_reply = 'Не смог сохранить расход или доход. Проверь сумму и тип операции и попробуй еще раз.';
  }
} else if (td.type === 'reminder_add') {
  if (td.success && td.saved) {
    const row = td.saved;
    const when = fmtDate(row.remind_at);
    assistant_reply = `Напоминание поставил${when ? ` на ${when}` : ''}: ${row.task_text}.`;
  } else {
    assistant_reply = 'Не смог поставить напоминание. Уточни текст или время и попробуй еще раз.';
  }
} else if (td.type === 'ai_cost_report') {
  const stats = td.stats || {};
  assistant_reply = `За выбранный период: ${stats.total_calls || 0} LLM-вызовов, ${stats.total_tokens || 0} токенов, оценка стоимости ${td.estimated_usd || 0} USD.`;
}
return [{ json: { ...item, assistant_reply, synthesizer_usage: {}, direct_reply: true } }];
'@
            language = 'javaScript'
            mode = 'runOnceForAllItems'
        }
        id = 'direct_reply_builder'
        name = 'Direct Reply Builder'
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(3500, 760)
    }
    $wf.nodes += $directNode
}

$directReply = Get-Node 'Direct Reply Builder'
$directReply.parameters.jsCode = @'
const item = items[0].json;
const td = item.tool_data || {};
function fmtDate(value) {
  if (!value) return null;
  try {
    return new Intl.DateTimeFormat('ru-RU', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Asia/Qyzylorda' }).format(new Date(value));
  } catch (error) {
    return String(value);
  }
}
function toArray(value) {
  return Array.isArray(value) ? value.filter((x) => x !== null && x !== undefined && String(x).trim() !== "") : [];
}
function clean(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}
function stripPipes(value) {
  return clean(String(value || "").replace(/\|+/g, " "));
}
function shortUrl(value) {
  try {
    const url = new URL(String(value || ""));
    return url.hostname.replace(/^www\./i, "");
  } catch (error) {
    return clean(value);
  }
}
function pickDistance(result, comparisonLines, caveats) {
  const combined = [
    clean(result.distance),
    ...toArray(comparisonLines),
    ...toArray(caveats)
  ].join(" ");
  const match = combined.match(/(\d+(?:[.,]\d+)?)\s*(км|km|м|m)\b/i);
  if (match) {
    return `${match[1]} ${match[2]}`.replace("km", "км").replace(/\bm\b/i, "м");
  }
  return "не указано";
}
function formatResearchReply(report, results, effectiveQuery) {
  const goal = clean(report.goal) || "Собрать и сравнить варианты по интернет-источникам.";
  const whatFound = toArray(report.what_found).map(stripPipes);
  const comparison = toArray(report.comparison).map(stripPipes);
  const recommendations = toArray(report.recommendations).map(stripPipes);
  const caveats = toArray(report.caveats).map(stripPipes);
  const sourceRows = Array.isArray(report.sources) ? report.sources : [];
  const shortlist = [];

  for (const row of results || []) {
    const title = stripPipes(row.title);
    if (!title) continue;
    const info = clean(row.content);
    const rating = (info.match(/рейтинг[^0-9]{0,12}(\d(?:[.,]\d)?)/i) || info.match(/\b(\d(?:[.,]\d))\b/))?.[1] || "";
    const reviews = (info.match(/(\d{1,6})\s*(?:отзыв|reviews?)/i) || info.match(/(\d{2,6})/))?.[1] || "";
    const distance = pickDistance(row, comparison, caveats);
    const parts = [];
    if (rating) parts.push(`рейтинг ${rating}`);
    if (reviews) parts.push(`отзывов ${reviews}`);
    parts.push(`расстояние: ${distance}`);
    shortlist.push(`${shortlist.length + 1}. ${title} — ${parts.join(", ")}.`);
    if (shortlist.length >= 5) break;
  }

  if (!shortlist.length) {
    shortlist.push("1. Не удалось собрать надежный топ-5 по найденным источникам.");
  }

  const sources = [];
  for (const row of sourceRows) {
    const title = stripPipes(row.title);
    const url = clean(row.url);
    if (!title && !url) continue;
    const label = title || shortUrl(url);
    const why = stripPipes(row.why_relevant);
    sources.push(`- ${label}${url ? ` — ${url}` : ""}${why ? ` (${why})` : ""}`);
    if (sources.length >= 5) break;
  }
  if (!sources.length && effectiveQuery) {
    sources.push(`- Поисковый запрос: ${stripPipes(effectiveQuery)}`);
  }

  const sections = [
    `<b>Цель</b>\n${goal}`,
    `<b>Топ-5</b>\n${shortlist.join("\n")}`,
    `<b>Сравнение</b>\n${(comparison.length ? comparison : whatFound.slice(0, 4)).join("\n") || "Сравнение получилось ограниченным: в источниках не хватает части критериев."}`,
    `<b>Вывод</b>\n${stripPipes(report.conclusion) || "По найденным данным лучший вариант стоит выбирать по сочетанию рейтинга, отзывов и удобства для вас."}`,
    `<b>Рекомендация</b>\n${recommendations.join("\n") || "Уточни район или приоритеты, и я сузлю выбор до 2-3 лучших вариантов."}`,
    `<b>Источники</b>\n${sources.join("\n")}`
  ];

  if (caveats.length) {
    sections.splice(2, 0, `<b>Ограничения</b>\n${caveats.join("\n")}`);
  }

  return sections.join("\n\n");
}
let assistant_reply = 'Готово.';
if (td.type === 'chat') {
  const direct = String(item.direct_response || td.direct_response || '').trim();
  assistant_reply = direct || 'Чем помочь?';
} else if (td.type === 'finance_add') {
  if (td.success && td.saved) {
    const row = td.saved;
    const when = fmtDate(row.transaction_at);
    assistant_reply = `Записал ${row.transaction_type === 'income' ? 'доход' : 'расход'}: ${row.amount} ${row.currency}${row.category ? `, категория ${row.category}` : ''}${when ? `, дата ${when}` : ''}.`;
  } else {
    assistant_reply = 'Не смог сохранить расход или доход. Проверь сумму и тип операции и попробуй еще раз.';
  }
} else if (td.type === 'reminder_add') {
  if (td.success && td.saved) {
    const row = td.saved;
    const when = fmtDate(row.remind_at);
    assistant_reply = `Напоминание поставил${when ? ` на ${when}` : ''}: ${row.task_text}.`;
  } else {
    assistant_reply = 'Не смог поставить напоминание. Уточни текст или время и попробуй еще раз.';
  }
} else if (td.type === 'ai_cost_report') {
  const stats = td.stats || {};
  assistant_reply = `За выбранный период: ${stats.total_calls || 0} LLM-вызовов, ${stats.total_tokens || 0} токенов, оценка стоимости ${td.estimated_usd || 0} USD.`;
} else if (td.type === 'research') {
  if (td.success !== false) {
    assistant_reply = formatResearchReply(
      td.report_json || {},
      td.search_results || [],
      td.effective_query || ''
    );
  } else {
    assistant_reply = 'Не удалось подготовить интернет-отчет. Попробуй уточнить запрос или повторить чуть позже.';
  }
}
return [{ json: { ...item, assistant_reply, synthesizer_usage: {}, direct_reply: true } }];
'@
$directReply.parameters.language = 'javaScript'
$directReply.parameters.mode = 'runOnceForAllItems'

$toolChat = Get-Node 'Tool Data Chat'
$toolChat.parameters.jsCode = @'
return items.map(item => {
  const directResponse = String(item.json.direct_response || '').trim();
  return {
    json: {
      ...item.json,
      tool_data: {
        type: 'chat',
        success: true,
        direct_response: directResponse || null
      },
      tool_latency_ms: Date.now() - Number(item.json.tool_started_at_ms || Date.now())
    }
  };
});
'@
$toolChat.parameters.language = 'javaScript'
$toolChat.parameters.mode = 'runOnceForAllItems'

if (-not (Get-Node 'Chat Direct Response Switch')) {
    $chatSwitch = [pscustomobject][ordered]@{
        parameters = [ordered]@{
            mode = 'expression'
            numberOutputs = 2
            output = '={{ (($json.tool_data || {}).direct_response ? 0 : 1) }}'
        }
        id = 'chat_direct_response_switch'
        name = 'Chat Direct Response Switch'
        type = 'n8n-nodes-base.switch'
        typeVersion = 3.4
        position = @(3480, -320)
    }
    $wf.nodes += $chatSwitch
}

$researchPlanner = Get-Node 'Research Planner'
if (-not $researchPlanner) {
    $researchPlanner = [pscustomobject][ordered]@{
        parameters = [ordered]@{}
        id = 'research_planner'
        name = 'Research Planner'
        type = 'n8n-nodes-base.httpRequest'
        typeVersion = 4.4
        position = @(3260, -520)
    }
    $wf.nodes += $researchPlanner
}
$researchPlanner.parameters.url = 'https://api.openai.com/v1/chat/completions'
$researchPlanner.parameters.specifyHeaders = 'keypair'
$researchPlanner.parameters.contentType = 'json'
$researchPlanner.parameters.method = 'POST'
$researchPlanner.parameters.specifyBody = 'json'
$researchPlanner.parameters.sendBody = $true
$researchPlanner.parameters.sendHeaders = $true
$researchPlanner.parameters.jsonBody = @'
={{ { model: ($env.OPENAI_ANALYSIS_MODEL && String($env.OPENAI_ANALYSIS_MODEL).trim()) ? String($env.OPENAI_ANALYSIS_MODEL).trim() : ($env.OPENAI_SYNTHESIZER_MODEL || 'gpt-5.4-mini'), messages: [ { role: 'system', content: "You are an internet research planner inside a personal assistant.\n\nReturn ONLY valid JSON. No Markdown. No text outside JSON.\n\nYour job is to transform the user's request into a compact research plan for one focused web research pass.\nDo not execute searches. Do not invent findings.\n\nOutput schema:\n{\n  \"goal\": \"\",\n  \"primary_query\": \"\",\n  \"comparison_axes\": [],\n  \"deliverable_sections\": [\"goal\", \"what_found\", \"comparison\", \"conclusion\", \"recommendations\", \"sources\"],\n  \"notes\": []\n}\n\nRules:\n- goal: short restatement of the report outcome.\n- primary_query: one concise web search query that best supports the goal.\n- comparison_axes: 0 to 4 short criteria such as price, rating, reliability, features, reviews, safety, location, speed, or support.\n- deliverable_sections should usually keep the default six sections.\n- notes are optional caveats, missing context, or assumptions.\n- Keep everything compact. Do not produce completed analysis results." }, { role: 'user', content: JSON.stringify({ user_message: $json.user_message || '', extracted_data: $json.extracted_data || {}, user_profile: $json.user_profile || {} }) } ], response_format: { type: 'json_object' }, max_completion_tokens: 220 } }}
'@
$researchPlanner.parameters.headerParameters = [ordered]@{
    parameters = @(
        [ordered]@{ value = '={{ ''Bearer '' + $env.OPENAI_API_KEY }}'; name = 'Authorization' },
        [ordered]@{ value = 'application/json'; name = 'Content-Type' }
    )
}
$researchPlanner.parameters.options = [ordered]@{
    response = [ordered]@{
        response = [ordered]@{
            responseFormat = 'json'
            neverError = $true
        }
    }
}
$researchPlanner.id = 'research_planner'
$researchPlanner.name = 'Research Planner'
$researchPlanner.type = 'n8n-nodes-base.httpRequest'
$researchPlanner.typeVersion = 4.4
$researchPlanner.position = @(3260, -520)

$researchQuery = Get-Node 'Research Query Builder'
if (-not $researchQuery) {
    $researchQuery = [pscustomobject][ordered]@{
        parameters = [ordered]@{}
        id = 'research_query_builder'
        name = 'Research Query Builder'
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(3460, -520)
    }
    $wf.nodes += $researchQuery
}
$researchQuery.parameters.jsCode = @'
let base = {};
try {
  const candidates = $items("Parse Router JSON").map((i) => i.json);
  base = candidates.find((json) => json.route === "research") || candidates[0] || {};
} catch (error) {
  base = {};
}
const choice = $json.choices && $json.choices[0];
let plan_json = {};
try {
  plan_json = JSON.parse((choice && choice.message && choice.message.content) ? choice.message.content : "{}");
} catch (error) {
  plan_json = { goal: base.user_message || "", primary_query: "", comparison_axes: [], deliverable_sections: ["goal", "what_found", "comparison", "conclusion", "recommendations", "sources"], notes: ["research_planner_json_parse_error"] };
}
const ed = base.extracted_data || {};
const profile = base.user_profile || {};
const rawScope = String(ed.search_scope || "global").toLowerCase();
const scope = rawScope === "local" ? "local" : "global";
const explicitLoc = String(ed.location || "").trim();
const envCity = String($env.DEFAULT_USER_CITY || "").trim();
const envCountry = String($env.DEFAULT_USER_COUNTRY || "").trim();
const defaultCity = envCity || String(profile.default_city || "Pavlodar").trim();
const defaultCountry = envCountry || String(profile.default_country || "Kazakhstan").trim();
const locationUsed = scope === "local" ? (explicitLoc || (defaultCity + ", " + defaultCountry)) : null;
const baseQuery = String(plan_json.primary_query || ed.search_query || base.user_message || "").trim();
let effectiveQuery = baseQuery;
if (scope === "local" && locationUsed) {
  const cityToken = locationUsed.split(",")[0].trim().toLowerCase();
  const qLower = baseQuery.toLowerCase();
  if (cityToken && !qLower.includes(cityToken)) {
    effectiveQuery = (baseQuery + " in " + locationUsed).trim();
  }
}
const comparisonAxes = Array.isArray(plan_json.comparison_axes) && plan_json.comparison_axes.length
  ? plan_json.comparison_axes
  : (Array.isArray(ed.comparison_axes) ? ed.comparison_axes : []);
return [{
  json: {
    ...base,
    extracted_data: {
      ...ed,
      search_scope: scope,
      location_used: locationUsed,
      tavily_query: effectiveQuery,
      comparison_axes: comparisonAxes,
      research_goal: String(plan_json.goal || ed.research_goal || base.user_message || "").trim(),
      deliverable_format: String(ed.deliverable_format || "report").trim(),
    },
    research_plan: {
      goal: String(plan_json.goal || ed.research_goal || base.user_message || "").trim(),
      primary_query: baseQuery,
      comparison_axes: comparisonAxes,
      deliverable_sections: Array.isArray(plan_json.deliverable_sections) && plan_json.deliverable_sections.length ? plan_json.deliverable_sections : ["goal", "what_found", "comparison", "conclusion", "recommendations", "sources"],
      notes: Array.isArray(plan_json.notes) ? plan_json.notes : [],
    },
    planner_usage: { ...($json.usage || {}), model: $json.model || "" },
  }
}];
'@
$researchQuery.parameters.language = 'javaScript'
$researchQuery.parameters.mode = 'runOnceForAllItems'
$researchQuery.id = 'research_query_builder'
$researchQuery.name = 'Research Query Builder'
$researchQuery.type = 'n8n-nodes-base.code'
$researchQuery.typeVersion = 2
$researchQuery.position = @(3460, -520)

$researchSearch = Get-Node 'Research Tavily Search'
if (-not $researchSearch) {
    $researchSearch = [pscustomobject][ordered]@{
        parameters = [ordered]@{}
        id = 'research_tavily_search'
        name = 'Research Tavily Search'
        type = 'n8n-nodes-base.httpRequest'
        typeVersion = 4.4
        position = @(3660, -520)
    }
    $wf.nodes += $researchSearch
}
$researchSearch.parameters.url = 'https://api.tavily.com/search'
$researchSearch.parameters.specifyHeaders = 'keypair'
$researchSearch.parameters.contentType = 'json'
$researchSearch.parameters.method = 'POST'
$researchSearch.parameters.specifyBody = 'json'
$researchSearch.parameters.sendBody = $true
$researchSearch.parameters.sendHeaders = $true
$researchSearch.parameters.jsonBody = @'
={{ { api_key: $env.TAVILY_API_KEY || $env.SEARCH_API_KEY, query: ($json.extracted_data || {}).tavily_query || ($json.research_plan || {}).primary_query || ($json.extracted_data || {}).search_query || $json.user_message, search_depth: 'advanced', max_results: 5, include_answer: true } }}
'@
$researchSearch.parameters.headerParameters = [ordered]@{
    parameters = @(
        [ordered]@{ value = 'application/json'; name = 'Content-Type' }
    )
}
$researchSearch.parameters.options = [ordered]@{
    response = [ordered]@{
        response = [ordered]@{
            responseFormat = 'json'
            neverError = $true
        }
    }
}
$researchSearch.id = 'research_tavily_search'
$researchSearch.name = 'Research Tavily Search'
$researchSearch.type = 'n8n-nodes-base.httpRequest'
$researchSearch.typeVersion = 4.4
$researchSearch.position = @(3660, -520)

$researchInput = Get-Node 'Research Analysis Input'
if (-not $researchInput) {
    $researchInput = [pscustomobject][ordered]@{
        parameters = [ordered]@{}
        id = 'research_analysis_input'
        name = 'Research Analysis Input'
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(3860, -520)
    }
    $wf.nodes += $researchInput
}
$researchInput.parameters.jsCode = @'
let base = {};
try {
  const rows = $items("Research Query Builder");
  base = rows[0] && rows[0].json ? rows[0].json : {};
} catch (error) {
  base = {};
}
const results = Array.isArray($json.results) ? $json.results : [];
const answer = $json.answer || null;
const normalizedResults = results.map((row) => ({
  title: String(row.title || "").trim(),
  url: String(row.url || "").trim(),
  content: String(row.content || "").replace(/\s+/g, " ").trim().slice(0, 420),
  score: row.score ?? null,
}));
const comparisonAxes = Array.isArray(base.research_plan?.comparison_axes) ? base.research_plan.comparison_axes : [];
return [{
  json: {
    ...base,
    search_results: normalizedResults,
    search_answer: answer,
    research_input: {
      user_message: base.user_message || "",
      goal: base.research_plan?.goal || "",
      primary_query: base.research_plan?.primary_query || "",
      comparison_axes: comparisonAxes,
      deliverable_sections: Array.isArray(base.research_plan?.deliverable_sections) ? base.research_plan.deliverable_sections : ["goal", "what_found", "comparison", "conclusion", "recommendations", "sources"],
      notes: Array.isArray(base.research_plan?.notes) ? base.research_plan.notes : [],
      search_scope: base.extracted_data?.search_scope || "global",
      location_used: base.extracted_data?.location_used || null,
      search_answer: answer ? String(answer).replace(/\s+/g, " ").trim().slice(0, 500) : null,
      search_results: normalizedResults,
    }
  }
}];
'@
$researchInput.parameters.language = 'javaScript'
$researchInput.parameters.mode = 'runOnceForAllItems'
$researchInput.id = 'research_analysis_input'
$researchInput.name = 'Research Analysis Input'
$researchInput.type = 'n8n-nodes-base.code'
$researchInput.typeVersion = 2
$researchInput.position = @(3860, -520)

$researchInterpreter = Get-Node 'Research Interpreter'
if (-not $researchInterpreter) {
    $researchInterpreter = [pscustomobject][ordered]@{
        parameters = [ordered]@{}
        id = 'research_interpreter'
        name = 'Research Interpreter'
        type = 'n8n-nodes-base.httpRequest'
        typeVersion = 4.4
        position = @(4060, -520)
    }
    $wf.nodes += $researchInterpreter
}
$researchInterpreter.parameters.url = 'https://api.openai.com/v1/chat/completions'
$researchInterpreter.parameters.specifyHeaders = 'keypair'
$researchInterpreter.parameters.contentType = 'json'
$researchInterpreter.parameters.method = 'POST'
$researchInterpreter.parameters.specifyBody = 'json'
$researchInterpreter.parameters.sendBody = $true
$researchInterpreter.parameters.sendHeaders = $true
$researchInterpreter.parameters.jsonBody = @'
={{ { model: ($env.OPENAI_ANALYSIS_MODEL && String($env.OPENAI_ANALYSIS_MODEL).trim()) ? String($env.OPENAI_ANALYSIS_MODEL).trim() : ($env.OPENAI_SYNTHESIZER_MODEL || 'gpt-5.4-mini'), messages: [ { role: 'system', content: "You are a senior internet research analyst inside a personal assistant.\n\nYou will receive JSON only. Base your work only on the supplied search results and planner context. Do not invent sources or unsupported facts.\n\nReturn ONLY valid JSON. No Markdown. No text outside JSON.\n\nOutput schema:\n{\n  \"goal\": \"\",\n  \"what_found\": [],\n  \"comparison\": [],\n  \"conclusion\": \"\",\n  \"recommendations\": [],\n  \"sources\": [\n    { \"title\": \"\", \"url\": \"\", \"why_relevant\": \"\" }\n  ],\n  \"caveats\": []\n}\n\nRules:\n- what_found: 2 to 5 short factual bullets grounded in the search results.\n- comparison: use the provided comparison_axes when possible; compare only what can be supported from the results.\n- conclusion: compact synthesis, not a long essay.\n- recommendations: practical next steps or a shortlist recommendation.\n- sources: include only sources present in the input search_results.\n- caveats: mention missing data, uncertainty, conflicting evidence, or weak coverage.\n- If the results are weak or sparse, say so in caveats and keep the report conservative." }, { role: 'user', content: JSON.stringify($json.research_input || {}) } ], response_format: { type: 'json_object' }, max_completion_tokens: 650 } }}
'@
$researchInterpreter.parameters.headerParameters = [ordered]@{
    parameters = @(
        [ordered]@{ value = '={{ ''Bearer '' + $env.OPENAI_API_KEY }}'; name = 'Authorization' },
        [ordered]@{ value = 'application/json'; name = 'Content-Type' }
    )
}
$researchInterpreter.parameters.options = [ordered]@{
    response = [ordered]@{
        response = [ordered]@{
            responseFormat = 'json'
            neverError = $true
        }
    }
}
$researchInterpreter.id = 'research_interpreter'
$researchInterpreter.name = 'Research Interpreter'
$researchInterpreter.type = 'n8n-nodes-base.httpRequest'
$researchInterpreter.typeVersion = 4.4
$researchInterpreter.position = @(4060, -520)

$researchTool = Get-Node 'Tool Data Research'
if (-not $researchTool) {
    $researchTool = [pscustomobject][ordered]@{
        parameters = [ordered]@{}
        id = 'tool_data_research'
        name = 'Tool Data Research'
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(4260, -520)
    }
    $wf.nodes += $researchTool
}
$researchTool.parameters.jsCode = @'
let base = {};
try {
  const rows = $items("Research Analysis Input");
  base = rows[0] && rows[0].json ? rows[0].json : {};
} catch (error) {
  base = {};
}
const choice = $json.choices && $json.choices[0];
let report_json = {};
try {
  report_json = JSON.parse((choice && choice.message && choice.message.content) ? choice.message.content : "{}");
} catch (error) {
  report_json = {
    goal: base.research_plan?.goal || base.user_message || "",
    what_found: [],
    comparison: [],
    conclusion: "Не удалось собрать структурированный интернет-отчет.",
    recommendations: [],
    sources: [],
    caveats: ["research_report_json_parse_error"],
  };
}
const hasError = Boolean($json.error);
return [{
  json: {
    ...base,
    tool_latency_ms: Date.now() - Number(base.tool_started_at_ms || Date.now()),
    interpreter_usage: { ...($json.usage || {}), model: $json.model || "" },
    tool_data: {
      type: "research",
      success: !hasError,
      planner_json: base.research_plan || {},
      report_json,
      search_results: base.search_results || [],
      search_answer: base.search_answer || null,
      effective_query: base.extracted_data?.tavily_query || base.research_plan?.primary_query || null,
      error: hasError ? JSON.stringify($json.error) : null,
    },
  },
}];
'@
$researchTool.parameters.language = 'javaScript'
$researchTool.parameters.mode = 'runOnceForAllItems'
$researchTool.id = 'tool_data_research'
$researchTool.name = 'Tool Data Research'
$researchTool.type = 'n8n-nodes-base.code'
$researchTool.typeVersion = 2
$researchTool.position = @(4260, -520)

 $taskPlanner = Get-Node 'Task Planner'
if (-not $taskPlanner) {
    $taskPlanner = [pscustomobject][ordered]@{
        parameters = [ordered]@{}
        id = 'task_planner'
        name = 'Task Planner'
        type = 'n8n-nodes-base.httpRequest'
        typeVersion = 4.4
        position = @(3260, 640)
    }
    $wf.nodes += $taskPlanner
}
$taskPlanner.parameters.url = 'https://api.openai.com/v1/chat/completions'
$taskPlanner.parameters.specifyHeaders = 'keypair'
$taskPlanner.parameters.contentType = 'json'
$taskPlanner.parameters.method = 'POST'
$taskPlanner.parameters.specifyBody = 'json'
$taskPlanner.parameters.sendBody = $true
$taskPlanner.parameters.sendHeaders = $true
$taskPlanner.parameters.jsonBody = @'
={{ { model: ($env.OPENAI_ANALYSIS_MODEL && String($env.OPENAI_ANALYSIS_MODEL).trim()) ? String($env.OPENAI_ANALYSIS_MODEL).trim() : ($env.OPENAI_SYNTHESIZER_MODEL || 'gpt-5.4-mini'), messages: [ { role: 'system', content: "You are a task planner inside a personal assistant.\n\nReturn ONLY valid JSON. No Markdown. No text outside JSON.\n\nYour job is to break a non-trivial user request into at most 3 explicit steps. Do not call tools. Do not execute anything. Do not replan in a loop.\n\nOutput schema:\n{\n  \"goal\": \"\",\n  \"requires_async\": false,\n  \"steps\": [\n    { \"step\": 1, \"type\": \"fetch_data\", \"description\": \"\" }\n  ],\n  \"notes\": []\n}\n\nRules:\n- Prefer synchronous plans that fit in 1 to 3 steps.\n- Set requires_async to true if the task is too broad, open-ended, or depends on future background execution.\n- Use short step types such as fetch_data, compute, compare, summarize, save_result, or ask_user.\n- Notes are optional short caveats, assumptions, or missing-data warnings.\n- Do not invent completed results. Produce only the plan." }, { role: 'user', content: JSON.stringify({ user_message: $json.user_message || '', extracted_data: $json.extracted_data || {}, memory: $json.synth_memory || $json.memory || [], user_profile: $json.user_profile || {} }) } ], response_format: { type: 'json_object' }, max_completion_tokens: 450 } }}
'@
$taskPlanner.parameters.headerParameters = [ordered]@{
    parameters = @(
        [ordered]@{ value = '={{ ''Bearer '' + $env.OPENAI_API_KEY }}'; name = 'Authorization' },
        [ordered]@{ value = 'application/json'; name = 'Content-Type' }
    )
}
$taskPlanner.parameters.options = [ordered]@{
    response = [ordered]@{
        response = [ordered]@{
            responseFormat = 'json'
            neverError = $true
        }
    }
}
$taskPlanner.id = 'task_planner'
$taskPlanner.name = 'Task Planner'
$taskPlanner.type = 'n8n-nodes-base.httpRequest'
$taskPlanner.typeVersion = 4.4
$taskPlanner.position = @(3260, 640)

 $taskTool = Get-Node 'Task Plan Tool Data'
if (-not $taskTool) {
    $taskTool = [pscustomobject][ordered]@{
        parameters = [ordered]@{}
        id = 'task_plan_tool_data'
        name = 'Task Plan Tool Data'
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(3500, 640)
    }
    $wf.nodes += $taskTool
}
$taskTool.parameters.jsCode = @'
let base = {};
try {
  const candidates = $items("Parse Router JSON").map((i) => i.json);
  base = candidates.find((json) => json.route === "task_plan") || candidates[0] || {};
} catch (error) {
  base = {};
}
const choice = $json.choices && $json.choices[0];
let plan_json = {};
try {
  plan_json = JSON.parse((choice && choice.message && choice.message.content) ? choice.message.content : "{}");
} catch (error) {
  plan_json = { goal: base.user_message || "", requires_async: false, steps: [], notes: ["planner_json_parse_error"] };
}
const hasError = Boolean($json.error);
return [{
  json: {
    ...base,
    tool_latency_ms: Date.now() - Number(base.tool_started_at_ms || Date.now()),
    planner_usage: { ...($json.usage || {}), model: $json.model || "" },
    tool_data: {
      type: "task_plan",
      success: !hasError,
      plan_json,
      error: hasError ? JSON.stringify($json.error) : null,
    },
  },
}];
'@
$taskTool.parameters.language = 'javaScript'
$taskTool.parameters.mode = 'runOnceForAllItems'
$taskTool.id = 'task_plan_tool_data'
$taskTool.name = 'Task Plan Tool Data'
$taskTool.type = 'n8n-nodes-base.code'
$taskTool.typeVersion = 2
$taskTool.position = @(3500, 640)

$wf.connections.'Switch Route'.main = @(
    @(@{ node = 'Tool Data Chat'; type = 'main'; index = 0 }),
    @(@{ node = 'Search Context Builder'; type = 'main'; index = 0 }),
    @(@{ node = 'Research Planner'; type = 'main'; index = 0 }),
    @(@{ node = 'Finance Add SQL'; type = 'main'; index = 0 }),
    @(@{ node = 'Finance Report SQL'; type = 'main'; index = 0 }),
    @(@{ node = 'Reminder Add SQL'; type = 'main'; index = 0 }),
    @(@{ node = 'Cost Report SQL'; type = 'main'; index = 0 }),
    @(@{ node = 'Analysis Time Range'; type = 'main'; index = 0 }),
    @(@{ node = 'Task Planner'; type = 'main'; index = 0 })
)

$wf.connections.'Finance Add SQL'.main = (Read-JsonValue '{"main":[[{"node":"Direct Reply Builder","type":"main","index":0},{"node":"Save Tool Execution Log","type":"main","index":0}]]}').main
$wf.connections.'Reminder Add SQL'.main = (Read-JsonValue '{"main":[[{"node":"Direct Reply Builder","type":"main","index":0},{"node":"Save Tool Execution Log","type":"main","index":0}]]}').main
$wf.connections.'Cost Report SQL'.main = (Read-JsonValue '{"main":[[{"node":"Direct Reply Builder","type":"main","index":0},{"node":"Save Tool Execution Log","type":"main","index":0}]]}').main
Set-Connection 'Tool Data Chat' (Read-JsonValue '{"main":[[{"node":"Chat Direct Response Switch","type":"main","index":0},{"node":"Save Tool Execution Log","type":"main","index":0}]]}')
Set-Connection 'Chat Direct Response Switch' (Read-JsonValue '{"main":[[{"node":"Direct Reply Builder","type":"main","index":0}],[{"node":"AI Synthesizer","type":"main","index":0}]]}')
Set-Connection 'Direct Reply Builder' (Read-JsonValue '{"main":[[{"node":"Telegram Send Message","type":"main","index":0},{"node":"Save LLM Usage","type":"main","index":0}]]}')
Set-Connection 'Research Planner' (Read-JsonValue '{"main":[[{"node":"Research Query Builder","type":"main","index":0}]]}')
Set-Connection 'Research Query Builder' (Read-JsonValue '{"main":[[{"node":"Research Tavily Search","type":"main","index":0}]]}')
Set-Connection 'Research Tavily Search' (Read-JsonValue '{"main":[[{"node":"Research Analysis Input","type":"main","index":0}]]}')
Set-Connection 'Research Analysis Input' (Read-JsonValue '{"main":[[{"node":"Research Interpreter","type":"main","index":0}]]}')
Set-Connection 'Research Interpreter' (Read-JsonValue '{"main":[[{"node":"Tool Data Research","type":"main","index":0}]]}')
Set-Connection 'Tool Data Research' (Read-JsonValue '{"main":[[{"node":"Direct Reply Builder","type":"main","index":0},{"node":"Save Tool Execution Log","type":"main","index":0}]]}')
Set-Connection 'Task Planner' (Read-JsonValue '{"main":[[{"node":"Task Plan Tool Data","type":"main","index":0}]]}')
Set-Connection 'Task Plan Tool Data' (Read-JsonValue '{"main":[[{"node":"AI Synthesizer","type":"main","index":0},{"node":"Save Tool Execution Log","type":"main","index":0}]]}')

if ($wf.activeVersion) {
    $wf.activeVersion.nodes = $wf.nodes
    $wf.activeVersion.connections = $wf.connections
    $wf.activeVersion.name = $wf.name
    $wf.activeVersion.description = $wf.description
}

$json = $wf | ConvertTo-Json -Depth 100
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $json, $enc)

