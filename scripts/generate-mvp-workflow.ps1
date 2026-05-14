$ErrorActionPreference = "Stop"

$workflowDir = Join-Path (Get-Location) "workflows"
New-Item -ItemType Directory -Force -Path $workflowDir | Out-Null
$output = Join-Path $workflowDir "personal_assistant_mvp.json"

function Node($id, $name, $type, $typeVersion, $x, $y, $parameters, $credentials = $null) {
    $node = [ordered]@{
        parameters = $parameters
        id = $id
        name = $name
        type = $type
        typeVersion = $typeVersion
        position = @($x, $y)
    }
    if ($null -ne $credentials) {
        $node.credentials = $credentials
    }
    return $node
}

$postgresCred = @{
    postgres = @{
        id = "gzx4XHPlKqlB1guL"
        name = "Postgres account"
    }
}

$nodes = @()

$nodes += Node "cron" "Telegram Poll Every Minute" "n8n-nodes-base.cron" 1 0 0 @{
    triggerTimes = @{
        item = @(
            @{
                mode = "everyMinute"
            }
        )
    }
}

$nodes += Node "load_poll_state" "Load Telegram Poll State" "n8n-nodes-base.postgres" 2.6 260 0 @{
    operation = "executeQuery"
    query = "SELECT last_update_id FROM telegram_poll_state WHERE id = 1;"
    options = @{
        queryBatching = "single"
    }
} $postgresCred

$nodes += Node "telegram_get_updates" "Telegram getUpdates" "n8n-nodes-base.httpRequest" 4.4 520 0 @{
    method = "GET"
    url = "={{ 'https://api.telegram.org/bot' + `$env.TELEGRAM_BOT_TOKEN + '/getUpdates' }}"
    sendQuery = $true
    queryParameters = @{
        parameters = @(
            @{ name = "offset"; value = "={{ Number(`$json.last_update_id || 0) + 1 }}" },
            @{ name = "timeout"; value = "0" }
        )
    }
    options = @{
        response = @{
            response = @{
                responseFormat = "json"
            }
        }
    }
}

$normalizeUpdates = @'
const updates = $json.result || [];
const items = [];

for (const update of updates) {
  const message = update.message;
  if (!message || typeof message.text !== 'string') continue;
  items.push({
    json: {
      telegram_update_id: update.update_id,
      user_id: message.from?.id,
      chat_id: message.chat?.id,
      message_id: message.message_id,
      user_message: message.text,
      received_at: message.date ? new Date(message.date * 1000).toISOString() : new Date().toISOString()
    }
  });
}

return items;
'@
$nodes += Node "normalize_updates" "Normalize Telegram Updates" "n8n-nodes-base.code" 2 780 0 @{
    mode = "runOnceForAllItems"
    language = "javaScript"
    jsCode = $normalizeUpdates
}

$nodes += Node "save_poll_state" "Save Telegram Poll State" "n8n-nodes-base.postgres" 2.6 1040 0 @{
    operation = "executeQuery"
    query = @'
UPDATE telegram_poll_state
SET last_update_id = GREATEST(last_update_id, {{ `$json.telegram_update_id }}),
    updated_at = NOW()
WHERE id = 1;

SELECT
  {{ `$json.telegram_update_id }}::BIGINT AS telegram_update_id,
  {{ `$json.user_id }}::BIGINT AS user_id,
  {{ `$json.chat_id }}::BIGINT AS chat_id,
  {{ `$json.message_id }}::BIGINT AS message_id,
  `$${{ `$json.user_message }}`$::TEXT AS user_message,
  `$${{ `$json.received_at }}`$::TIMESTAMPTZ AS received_at;
'@
    options = @{
        queryBatching = "single"
    }
} $postgresCred

$nodes += Node "load_memory" "Load Memory" "n8n-nodes-base.postgres" 2.6 1300 0 @{
    operation = "executeQuery"
    query = @'
SELECT
  {{ `$json.telegram_update_id }}::BIGINT AS telegram_update_id,
  {{ `$json.user_id }}::BIGINT AS user_id,
  {{ `$json.chat_id }}::BIGINT AS chat_id,
  {{ `$json.message_id }}::BIGINT AS message_id,
  `$${{ `$json.user_message }}`$::TEXT AS user_message,
  `$${{ `$json.received_at }}`$::TIMESTAMPTZ AS received_at,
  COALESCE(
    (
      SELECT json_agg(row_to_json(m))
      FROM (
        SELECT role, content, created_at
        FROM (
          SELECT role, content, created_at
          FROM chat_memory
          WHERE user_id = {{ `$json.user_id }}
          ORDER BY created_at DESC
          LIMIT 5
        ) recent
        ORDER BY created_at ASC
      ) m
    ),
    '[]'::json
  ) AS memory;
'@
    options = @{
        queryBatching = "single"
    }
} $postgresCred

$routerPrompt = @'
You are the router for a personal AI assistant.
Return only valid JSON. Do not use Markdown.
Available routes: finance_add, finance_report, search, reminder_add, chat.
If unsure, choose chat.
Response format:
{
  "route": "chat",
  "confidence": 0.8,
  "extracted_data": {}
}
Extract these fields when useful: amount, transaction_type, category, description, report_period, search_query, task_text, remind_at, timezone.
Default timezone: Asia/Qyzylorda. Default currency: KZT.
User messages can be in Russian. Keep extracted text in the user's language when useful.
'@
$routerPromptJson = $routerPrompt | ConvertTo-Json -Compress
$routerBodyTemplate = @'
={{ { model: $env.OPENAI_ROUTER_MODEL || 'gpt-5.4-mini', messages: [ { role: 'system', content: @@PROMPT@@ }, { role: 'user', content: 'Chat memory:\n' + JSON.stringify($json.memory || []) + '\n\nUser message:\n' + $json.user_message } ], response_format: { type: 'json_object' }, max_completion_tokens: 700 } }}
'@
$routerBody = $routerBodyTemplate.Replace("@@PROMPT@@", $routerPromptJson).Trim()

$nodes += Node "ai_router" "AI Router" "n8n-nodes-base.httpRequest" 4.4 1560 0 @{
    method = "POST"
    url = "https://api.openai.com/v1/chat/completions"
    sendHeaders = $true
    specifyHeaders = "keypair"
    headerParameters = @{
        parameters = @(
            @{ name = "Authorization"; value = "={{ 'Bearer ' + `$env.OPENAI_API_KEY }}" },
            @{ name = "Content-Type"; value = "application/json" }
        )
    }
    sendBody = $true
    contentType = "json"
    specifyBody = "json"
    jsonBody = $routerBody
    options = @{
        response = @{
            response = @{
                responseFormat = "json"
            }
        }
    }
}

$parseRouter = @'
const base = $items("Load Memory")[0].json;
let raw = $json.choices?.[0]?.message?.content || "{}";
let parsed;
try {
  parsed = JSON.parse(raw);
} catch (error) {
  parsed = { route: "chat", confidence: 0, extracted_data: {}, parse_error: raw };
}
if (!["finance_add", "finance_report", "search", "reminder_add", "chat"].includes(parsed.route)) {
  parsed.route = "chat";
}
return [{ json: { ...base, route: parsed.route, confidence: parsed.confidence || 0, extracted_data: parsed.extracted_data || {} } }];
'@
$nodes += Node "parse_router" "Parse Router JSON" "n8n-nodes-base.code" 2 1820 0 @{
    mode = "runOnceForAllItems"
    language = "javaScript"
    jsCode = $parseRouter
}

function GateNode($id, $name, $route, $x, $y) {
    $code = @"
return items
  .filter(item => item.json.route === "$route")
  .map(item => ({ json: item.json }));
"@
    return Node $id $name "n8n-nodes-base.code" 2 $x $y @{
        mode = "runOnceForAllItems"
        language = "javaScript"
        jsCode = $code
    }
}

$nodes += GateNode "gate_chat" "Gate Chat" "chat" 2080 -360
$nodes += GateNode "gate_search" "Gate Search" "search" 2080 -180
$nodes += GateNode "gate_finance_add" "Gate Finance Add" "finance_add" 2080 0
$nodes += GateNode "gate_finance_report" "Gate Finance Report" "finance_report" 2080 180
$nodes += GateNode "gate_reminder_add" "Gate Reminder Add" "reminder_add" 2080 360

$nodes += Node "tool_chat" "Tool Data Chat" "n8n-nodes-base.code" 2 2340 -360 @{
    mode = "runOnceForAllItems"
    language = "javaScript"
    jsCode = 'return items.map(item => ({ json: { ...item.json, tool_data: { type: "chat" } } }));'
}

$nodes += Node "tavily_search" "Tavily Search" "n8n-nodes-base.httpRequest" 4.4 2340 -180 @{
    method = "POST"
    url = "https://api.tavily.com/search"
    sendHeaders = $true
    specifyHeaders = "keypair"
    headerParameters = @{
        parameters = @(
            @{ name = "Content-Type"; value = "application/json" }
        )
    }
    sendBody = $true
    contentType = "json"
    specifyBody = "json"
    jsonBody = "={{ { api_key: `$env.TAVILY_API_KEY || `$env.SEARCH_API_KEY, query: `$json.extracted_data.search_query || `$json.user_message, max_results: 5 } }}"
    options = @{
        response = @{
            response = @{
                responseFormat = "json"
            }
        }
    }
}

$searchContext = @'
const base = $items("Gate Search")[0].json;
return [{ json: { ...base, tool_data: { type: "search", results: $json.results || [], answer: $json.answer || null } } }];
'@
$nodes += Node "tool_search" "Tool Data Search" "n8n-nodes-base.code" 2 2600 -180 @{
    mode = "runOnceForAllItems"
    language = "javaScript"
    jsCode = $searchContext
}

$nodes += Node "finance_add" "Finance Add SQL" "n8n-nodes-base.postgres" 2.6 2340 0 @{
    operation = "executeQuery"
    query = @'
INSERT INTO finance_log (user_id, chat_id, transaction_type, amount, currency, category, description, transaction_at, source_message_id)
VALUES (
  {{ `$json.user_id }},
  {{ `$json.chat_id }},
  COALESCE(NULLIF(`$${{ `$json.extracted_data.transaction_type || 'expense' }}`$, ''), 'expense'),
  {{ Number(`$json.extracted_data.amount || 0) }},
  COALESCE(NULLIF(`$${{ `$json.extracted_data.currency || 'KZT' }}`$, ''), 'KZT'),
  NULLIF(`$${{ `$json.extracted_data.category || 'other' }}`$, ''),
  NULLIF(`$${{ `$json.extracted_data.description || `$json.user_message }}`$, ''),
  COALESCE(NULLIF(`$${{ `$json.extracted_data.transaction_at || '' }}`$, '')::TIMESTAMPTZ, NOW()),
  {{ `$json.message_id }}
)
RETURNING
  {{ `$json.telegram_update_id }}::BIGINT AS telegram_update_id,
  {{ `$json.user_id }}::BIGINT AS user_id,
  {{ `$json.chat_id }}::BIGINT AS chat_id,
  {{ `$json.message_id }}::BIGINT AS message_id,
  `$${{ `$json.user_message }}`$::TEXT AS user_message,
  '{{ `$json.route }}'::TEXT AS route,
  `$${{ JSON.stringify(`$json.extracted_data) }}`$::JSON AS extracted_data,
  `$${{ JSON.stringify(`$json.memory || []) }}`$::JSON AS memory,
  json_build_object('type', 'finance_add', 'saved', row_to_json(finance_log)) AS tool_data;
'@
    options = @{ queryBatching = "single" }
} $postgresCred

$nodes += Node "finance_report" "Finance Report SQL" "n8n-nodes-base.postgres" 2.6 2340 180 @{
    operation = "executeQuery"
    query = @'
WITH rows AS (
  SELECT category, transaction_type, currency, SUM(amount) AS total_amount, COUNT(*) AS transaction_count
  FROM finance_log
  WHERE user_id = {{ `$json.user_id }}
    AND transaction_at >= COALESCE(NULLIF(`$${{ `$json.extracted_data.report_period?.start || '' }}`$, '')::TIMESTAMPTZ, NOW() - INTERVAL '30 days')
    AND transaction_at < COALESCE(NULLIF(`$${{ `$json.extracted_data.report_period?.end || '' }}`$, '')::TIMESTAMPTZ, NOW() + INTERVAL '1 day')
  GROUP BY category, transaction_type, currency
)
SELECT
  {{ `$json.telegram_update_id }}::BIGINT AS telegram_update_id,
  {{ `$json.user_id }}::BIGINT AS user_id,
  {{ `$json.chat_id }}::BIGINT AS chat_id,
  {{ `$json.message_id }}::BIGINT AS message_id,
  `$${{ `$json.user_message }}`$::TEXT AS user_message,
  '{{ `$json.route }}'::TEXT AS route,
  `$${{ JSON.stringify(`$json.extracted_data) }}`$::JSON AS extracted_data,
  `$${{ JSON.stringify(`$json.memory || []) }}`$::JSON AS memory,
  json_build_object('type', 'finance_report', 'rows', COALESCE(json_agg(row_to_json(rows)), '[]'::json)) AS tool_data
FROM rows;
'@
    options = @{ queryBatching = "single" }
} $postgresCred

$nodes += Node "reminder_add" "Reminder Add SQL" "n8n-nodes-base.postgres" 2.6 2340 360 @{
    operation = "executeQuery"
    query = @'
INSERT INTO reminders (user_id, chat_id, task_text, remind_at, timezone, source_message_id)
VALUES (
  {{ `$json.user_id }},
  {{ `$json.chat_id }},
  `$${{ `$json.extracted_data.task_text || `$json.user_message }}`$,
  COALESCE(NULLIF(`$${{ `$json.extracted_data.remind_at || '' }}`$, '')::TIMESTAMPTZ, NOW() + INTERVAL '1 hour'),
  COALESCE(NULLIF(`$${{ `$json.extracted_data.timezone || 'Asia/Qyzylorda' }}`$, ''), 'Asia/Qyzylorda'),
  {{ `$json.message_id }}
)
RETURNING
  {{ `$json.telegram_update_id }}::BIGINT AS telegram_update_id,
  {{ `$json.user_id }}::BIGINT AS user_id,
  {{ `$json.chat_id }}::BIGINT AS chat_id,
  {{ `$json.message_id }}::BIGINT AS message_id,
  `$${{ `$json.user_message }}`$::TEXT AS user_message,
  '{{ `$json.route }}'::TEXT AS route,
  `$${{ JSON.stringify(`$json.extracted_data) }}`$::JSON AS extracted_data,
  `$${{ JSON.stringify(`$json.memory || []) }}`$::JSON AS memory,
  json_build_object('type', 'reminder_add', 'saved', row_to_json(reminders)) AS tool_data;
'@
    options = @{ queryBatching = "single" }
} $postgresCred

$synthPrompt = @'
You are a personal AI assistant in Telegram.
Always reply in Russian.
Be concise, useful, and friendly.
If an action was saved, confirm it briefly.
If tool data contains search or finance results, summarize them clearly.
Do not mention internal nodes, JSON, n8n, router, or implementation details.
'@
$synthPromptJson = $synthPrompt | ConvertTo-Json -Compress
$synthBodyTemplate = @'
={{ { model: $env.OPENAI_SYNTHESIZER_MODEL || 'gpt-5.4-mini', messages: [ { role: 'system', content: @@PROMPT@@ }, { role: 'user', content: 'Memory:\n' + JSON.stringify($json.memory || []) + '\n\nRoute: ' + $json.route + '\nExtracted data:\n' + JSON.stringify($json.extracted_data || {}) + '\n\nTool data:\n' + JSON.stringify($json.tool_data || {}) + '\n\nUser message:\n' + $json.user_message } ], max_completion_tokens: 900 } }}
'@
$synthBody = $synthBodyTemplate.Replace("@@PROMPT@@", $synthPromptJson).Trim()

$nodes += Node "ai_synth" "AI Synthesizer" "n8n-nodes-base.httpRequest" 4.4 2940 0 @{
    method = "POST"
    url = "https://api.openai.com/v1/chat/completions"
    sendHeaders = $true
    specifyHeaders = "keypair"
    headerParameters = @{
        parameters = @(
            @{ name = "Authorization"; value = "={{ 'Bearer ' + `$env.OPENAI_API_KEY }}" },
            @{ name = "Content-Type"; value = "application/json" }
        )
    }
    sendBody = $true
    contentType = "json"
    specifyBody = "json"
    jsonBody = $synthBody
    options = @{
        response = @{
            response = @{
                responseFormat = "json"
            }
        }
    }
}

$extractReply = @'
const candidates = [
  ...$items("Tool Data Chat").map(i => i.json),
  ...$items("Tool Data Search").map(i => i.json),
  ...$items("Finance Add SQL").map(i => i.json),
  ...$items("Finance Report SQL").map(i => i.json),
  ...$items("Reminder Add SQL").map(i => i.json),
];
const base = candidates.find(Boolean) || {};
const assistant_reply = $json.choices?.[0]?.message?.content || "OK.";
return [{ json: { ...base, assistant_reply } }];
'@
$nodes += Node "extract_reply" "Extract Assistant Reply" "n8n-nodes-base.code" 2 3200 0 @{
    mode = "runOnceForAllItems"
    language = "javaScript"
    jsCode = $extractReply
}

$nodes += Node "telegram_send" "Telegram Send Message" "n8n-nodes-base.httpRequest" 4.4 3460 0 @{
    method = "POST"
    url = "={{ 'https://api.telegram.org/bot' + `$env.TELEGRAM_BOT_TOKEN + '/sendMessage' }}"
    sendBody = $true
    contentType = "json"
    specifyBody = "json"
    jsonBody = "={{ { chat_id: `$json.chat_id, text: `$json.assistant_reply } }}"
    options = @{
        response = @{
            response = @{
                responseFormat = "json"
                neverError = $true
            }
        }
    }
}

$nodes += Node "save_memory" "Save Memory" "n8n-nodes-base.postgres" 2.6 3720 0 @{
    operation = "executeQuery"
    query = @'
INSERT INTO chat_memory (user_id, chat_id, role, content, metadata)
VALUES
({{ `$node["Extract Assistant Reply"].json.user_id }}, {{ `$node["Extract Assistant Reply"].json.chat_id }}, 'user', `$${{ `$node["Extract Assistant Reply"].json.user_message }}`$, json_build_object('message_id', {{ `$node["Extract Assistant Reply"].json.message_id }}, 'route', '{{ `$node["Extract Assistant Reply"].json.route }}')),
({{ `$node["Extract Assistant Reply"].json.user_id }}, {{ `$node["Extract Assistant Reply"].json.chat_id }}, 'assistant', `$${{ `$node["Extract Assistant Reply"].json.assistant_reply }}`$, json_build_object('route', '{{ `$node["Extract Assistant Reply"].json.route }}'))
RETURNING id;
'@
    options = @{ queryBatching = "single" }
} $postgresCred

$connections = [ordered]@{
    "Telegram Poll Every Minute" = @{ main = @(@(@{ node = "Load Telegram Poll State"; type = "main"; index = 0 })) }
    "Load Telegram Poll State" = @{ main = @(@(@{ node = "Telegram getUpdates"; type = "main"; index = 0 })) }
    "Telegram getUpdates" = @{ main = @(@(@{ node = "Normalize Telegram Updates"; type = "main"; index = 0 })) }
    "Normalize Telegram Updates" = @{ main = @(@(@{ node = "Save Telegram Poll State"; type = "main"; index = 0 })) }
    "Save Telegram Poll State" = @{ main = @(@(@{ node = "Load Memory"; type = "main"; index = 0 })) }
    "Load Memory" = @{ main = @(@(@{ node = "AI Router"; type = "main"; index = 0 })) }
    "AI Router" = @{ main = @(@(@{ node = "Parse Router JSON"; type = "main"; index = 0 })) }
    "Parse Router JSON" = @{ main = @(@(
        @{ node = "Gate Chat"; type = "main"; index = 0 },
        @{ node = "Gate Search"; type = "main"; index = 0 },
        @{ node = "Gate Finance Add"; type = "main"; index = 0 },
        @{ node = "Gate Finance Report"; type = "main"; index = 0 },
        @{ node = "Gate Reminder Add"; type = "main"; index = 0 }
    )) }
    "Gate Chat" = @{ main = @(@(@{ node = "Tool Data Chat"; type = "main"; index = 0 })) }
    "Gate Search" = @{ main = @(@(@{ node = "Tavily Search"; type = "main"; index = 0 })) }
    "Tavily Search" = @{ main = @(@(@{ node = "Tool Data Search"; type = "main"; index = 0 })) }
    "Gate Finance Add" = @{ main = @(@(@{ node = "Finance Add SQL"; type = "main"; index = 0 })) }
    "Gate Finance Report" = @{ main = @(@(@{ node = "Finance Report SQL"; type = "main"; index = 0 })) }
    "Gate Reminder Add" = @{ main = @(@(@{ node = "Reminder Add SQL"; type = "main"; index = 0 })) }
    "Tool Data Chat" = @{ main = @(@(@{ node = "AI Synthesizer"; type = "main"; index = 0 })) }
    "Tool Data Search" = @{ main = @(@(@{ node = "AI Synthesizer"; type = "main"; index = 0 })) }
    "Finance Add SQL" = @{ main = @(@(@{ node = "AI Synthesizer"; type = "main"; index = 0 })) }
    "Finance Report SQL" = @{ main = @(@(@{ node = "AI Synthesizer"; type = "main"; index = 0 })) }
    "Reminder Add SQL" = @{ main = @(@(@{ node = "AI Synthesizer"; type = "main"; index = 0 })) }
    "AI Synthesizer" = @{ main = @(@(@{ node = "Extract Assistant Reply"; type = "main"; index = 0 })) }
    "Extract Assistant Reply" = @{ main = @(@(@{ node = "Telegram Send Message"; type = "main"; index = 0 })) }
    "Telegram Send Message" = @{ main = @(@(@{ node = "Save Memory"; type = "main"; index = 0 })) }
}

$workflow = [ordered]@{
    id = "personal-ai-assistant-mvp"
    name = "Personal AI Assistant MVP"
    nodes = $nodes
    connections = $connections
    settings = @{
        executionOrder = "v1"
        timezone = "Asia/Qyzylorda"
    }
    active = $false
    versionId = [guid]::NewGuid().ToString()
    meta = @{
        templateCredsSetupCompleted = $false
    }
    tags = @()
}

$json = $workflow | ConvertTo-Json -Depth 100
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($output, $json, $utf8NoBom)
Write-Host "Generated workflow: $output"
