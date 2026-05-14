import json
import os

wf_path = 'workflows/personal_assistant_mvp.json'
with open(wf_path, 'r', encoding='utf-8') as f:
    wf = json.load(f)

for node in wf['nodes']:
    if node['name'] == 'AI Router':
        node['parameters']['jsonBody'] = node['parameters']['jsonBody'].replace('reminder_add, chat.', 'reminder_add, ai_cost_report, chat.')
    elif node['name'] == 'Parse Router JSON':
        node['parameters']['jsCode'] = node['parameters']['jsCode'].replace('"finance_report", "search", "reminder_add", "chat"', '"finance_report", "search", "reminder_add", "ai_cost_report", "chat"')
    elif node['name'] == 'Switch Route':
        node['parameters']['numberOutputs'] = 6
        node['parameters']['output'] = "={{ ({ chat: 0, search: 1, finance_add: 2, finance_report: 3, reminder_add: 4, ai_cost_report: 5 })[$json.route] ?? 0 }}"
    elif node['name'] == 'Extract Assistant Reply':
        node['parameters']['jsCode'] = node['parameters']['jsCode'].replace('...branchItems("Reminder Add SQL").map((i) => i.json),', '...branchItems("Reminder Add SQL").map((i) => i.json),\n  ...branchItems("Cost Report SQL").map((i) => i.json),')

cost_node = {
  'parameters': {
    'operation': 'executeQuery',
    'query': '''WITH input AS (
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
    COALESCE(NULLIF($15, '')::TIMESTAMPTZ, date_trunc('month', NOW())) AS period_start,
    COALESCE(NULLIF($16, '')::TIMESTAMPTZ, NOW() + INTERVAL '1 day') AS period_end
),
agg AS (
  SELECT 
    COUNT(*) as total_calls,
    SUM(prompt_tokens) as total_prompt,
    SUM(completion_tokens) as total_completion,
    SUM(total_tokens) as total_tokens
  FROM llm_usage_log
  WHERE user_id = (SELECT user_id FROM input)
    AND created_at >= (SELECT period_start FROM input)
    AND created_at < (SELECT period_end FROM input)
)
SELECT 
  input.*,
  GREATEST(0, (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT - input.tool_started_at_ms)::INT AS tool_latency_ms,
  json_build_object(
    'type', 'ai_cost_report',
    'success', true,
    'period_start', input.period_start,
    'period_end', input.period_end,
    'stats', (SELECT row_to_json(agg) FROM agg),
    'estimated_usd', (SELECT ROUND((COALESCE(SUM(prompt_tokens),0) * 0.15 / 1000000 + COALESCE(SUM(completion_tokens),0) * 0.60 / 1000000), 4) FROM llm_usage_log WHERE user_id = input.user_id AND created_at >= input.period_start AND created_at < input.period_end)
  ) AS tool_data
FROM input;''',
    'options': {
      'queryBatching': 'single',
      'queryReplacement': '={{ [ Number($json.telegram_update_id || 0), Number($json.user_id || 0), Number($json.chat_id || 0), Number($json.message_id || 0), String($json.user_message || ""), String($json.route || "ai_cost_report"), JSON.stringify($json.extracted_data || {}), JSON.stringify($json.memory || []), JSON.stringify($json.router_usage || {}), String($json.execution_id || ""), Number($json.execution_started_at_ms || Date.now()), String($json.execution_started_at || new Date().toISOString()), String($json.message_kind || "text"), Number($json.tool_started_at_ms || Date.now()), String((($json.extracted_data || {}).report_period || {}).start || ""), String((($json.extracted_data || {}).report_period || {}).end || "") ] }}'
    }
  },
  'id': 'cost_report_sql',
  'name': 'Cost Report SQL',
  'type': 'n8n-nodes-base.postgres',
  'typeVersion': 2.6,
  'position': [3260, 480],
  'credentials': {
    'postgres': {
      'id': 'gzx4XHPlKqlB1guL',
      'name': 'Postgres account'
    }
  },
  'onError': 'continueRegularOutput',
  'retryOnFail': True,
  'maxTries': 2,
  'waitBetweenTries': 1000
}

if not any(n['name'] == 'Cost Report SQL' for n in wf['nodes']):
    wf['nodes'].append(cost_node)

if 'Switch Route' in wf['connections']:
    # n8n: Switch "main" must be [ outputs ], each output is [ { node, type, index }, ... ].
    # Never append to main[0] to pad "output count" — that breaks validation (Destination node not found).
    main_connections = wf['connections']['Switch Route']['main']
    while len(main_connections) < 6:
        main_connections.append([])
    main_connections[5] = [{'node': 'Cost Report SQL', 'type': 'main', 'index': 0}]

wf['connections']['Cost Report SQL'] = {
  'main': [
    [
      {'node': 'AI Synthesizer', 'type': 'main', 'index': 0},
      {'node': 'Save Tool Execution Log', 'type': 'main', 'index': 0}
    ]
  ]
}

with open(wf_path, 'w', encoding='utf-8') as f:
    json.dump(wf, f, indent=2)

print('Successfully patched the JSON.')
